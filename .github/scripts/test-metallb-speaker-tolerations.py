#!/usr/bin/env python3
"""Regression test for the extra MetalLB speaker tolerations.

roles/k3s_server/tasks/metallb.yml writes metal_lb_speaker_extra_tolerations
into the downloaded MetalLB manifest itself (k3s re-applies every file in
server/manifests at each start, so a kubectl patch would be reset). The edit
is an ansible.builtin.replace anchored on the speaker's upstream control-plane
toleration. This test runs the task's own regexp/replace (rendered like
Ansible would, applied with re.MULTILINE like the replace module) against the
upstream speaker snippet and checks that:

- the tolerations land in the speaker's tolerations list (valid YAML);
- a second run changes nothing (idempotent);
- a changed list replaces the block instead of adding a second one;
- an empty list restores the upstream text exactly;
- the edit runs before the manifest is read back for verification;
- download and edits work on the build file, and it is copied into
  server/manifests only after verification (k3s never sees it half-edited).
"""

from __future__ import print_function

import os
import re
import subprocess

import jinja2
import yaml

# Upstream v0.16.0 metallb-native.yaml, speaker DaemonSet pod spec tail.
UPSTREAM = """\
      serviceAccountName: speaker
      terminationGracePeriodSeconds: 2
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
      - effect: NoSchedule
        key: node-role.kubernetes.io/control-plane
        operator: Exists
      volumes:
      - name: memberlist
        secret:
          defaultMode: 420
          secretName: memberlist
"""

KITCHEN = {"effect": "NoSchedule", "key": "location", "operator": "Equal", "value": "kitchen"}
OTHER = {"effect": "NoExecute", "key": "other", "operator": "Exists"}
TASK_NAME = "Set extra MetalLB speaker tolerations in the manifest"


def repo_root():
    return subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()


def fail(message):
    raise SystemExit("MetalLB speaker tolerations test failed: " + message)


def find_index(tasks, name):
    for index, entry in enumerate(tasks):
        if entry.get("name") == name:
            return index
    fail("could not find the '{0}' task".format(name))
    return None


def to_nice_yaml(value, indent=2):
    # Same settings as Ansible's to_nice_yaml (sorted keys, block style).
    return yaml.dump(value, indent=indent, default_flow_style=False, allow_unicode=True)


def apply(task, tolerations, text):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    env.filters["to_nice_yaml"] = to_nice_yaml
    context = {"metal_lb_speaker_extra_tolerations": tolerations}
    context["metallb_speaker_tolerations_block"] = env.from_string(
        task["vars"]["metallb_speaker_tolerations_block"]
    ).render(**context)
    args = task["ansible.builtin.replace"]
    pattern = re.compile(env.from_string(args["regexp"]).render(**context), re.MULTILINE)
    replacement = env.from_string(args["replace"]).render(**context)
    return pattern.subn(replacement, text)


def speaker_tolerations(text):
    return yaml.safe_load(text)["tolerations"]


def check_build_then_install(tasks):
    """k3s must never apply a half-edited manifest: download and edits target
    the build file outside server/manifests, and the copy into manifests/
    comes only after the verification tasks."""
    manifest = "/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml"
    build = "{{ metallb_manifest_build }}"
    for task in tasks:
        for module in ("ansible.builtin.get_url", "ansible.builtin.replace"):
            if module in task and task[module].get("dest", task[module].get("path")) != build:
                fail("{0!r} must work on {1}, not in server/manifests".format(task["name"], build))
    install_index = find_index(tasks, "Install the MetalLB manifest for k3s to apply")
    install = tasks[install_index]["ansible.builtin.copy"]
    if install.get("src") != build or install.get("dest") != manifest or not install.get("remote_src"):
        fail("the install task must copy {0} to {1} on the host".format(build, manifest))
    if tasks[install_index].get("check_mode") is False:
        fail("the install task must not run under --check (it writes the live manifest)")
    for name in ("Read back MetalLB manifest from first master",
                 "Fail if MetalLB speaker tag was not applied to the manifest",
                 "Fail if the extra MetalLB speaker tolerations were not written to the manifest"):
        if not find_index(tasks, name) < install_index:
            fail("{0!r} must run before the manifest is installed".format(name))


def main():
    task_file = os.path.join(repo_root(), "roles", "k3s_server", "tasks", "metallb.yml")
    with open(task_file, encoding="utf-8") as handle:
        tasks = yaml.safe_load(handle)

    edit_index = find_index(tasks, TASK_NAME)
    if not find_index(tasks, "Set image versions in manifest for metallb-{{ metal_lb_type }}") < edit_index:
        fail("the toleration edit must run after the manifest is downloaded")
    if not edit_index < find_index(tasks, "Read back MetalLB manifest from first master"):
        fail("the toleration edit must run before the manifest is read back")
    check_build_then_install(tasks)
    task = tasks[edit_index]
    upstream_tolerations = speaker_tolerations(UPSTREAM)

    once, count = apply(task, [KITCHEN], UPSTREAM)
    if count != 1:
        fail("the anchor matched {0} times, expected once".format(count))
    if speaker_tolerations(once) != upstream_tolerations + [KITCHEN]:
        fail("tolerations not appended to the speaker list:\n" + once)

    twice, _ = apply(task, [KITCHEN], once)
    if twice != once:
        fail("a second run changed the manifest:\n" + twice)

    changed, _ = apply(task, [KITCHEN, OTHER], once)
    if speaker_tolerations(changed) != upstream_tolerations + [KITCHEN, OTHER]:
        fail("a changed list did not replace the block:\n" + changed)

    removed, _ = apply(task, [], changed)
    if removed != UPSTREAM:
        fail("an empty list did not restore the upstream text:\n" + removed)

    untouched, _ = apply(task, [], UPSTREAM)
    if untouched != UPSTREAM:
        fail("an empty list changed the upstream manifest:\n" + untouched)

    print("MetalLB speaker tolerations regression test passed")


if __name__ == "__main__":
    main()
