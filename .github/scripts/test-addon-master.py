#!/usr/bin/env python3
"""Regression test for the primary master and the addon manifests' master.

groups['master'] has no stable order when a host sits in two of its child
groups (k3s-7 in primary-master and pi-master: ansible-core 2.21 returned
k3s-1 or k3s-7 first at random), so "the first master" -- cluster-init, the
joins, the join token the agent unit reads, the addon and CNI manifests, the
kubeconfig fetch -- is k3s_primary_master (vars/k3s-primary-master.yml). This
test checks that:

- k3s_primary_master prefers primary-master over group_name_master's first
  host, and falls back to it when there is no primary-master group;
- k3s_server_addon_master is k3s_primary_master;
- nothing picks a master by index (groups[group_name_master...][0] / [1:]);
- every play that runs these roles or uses k3s_primary_master loads the vars
  file;
- the agent unit has no stale-token fallback, and the CNI blocks don't pair
  the primary-master when with run_once;
- the addon task files gate on k3s_server_addon_master and keep their
  manifests off the other masters (primary-only-manifests.yml).
"""

from __future__ import print_function

import glob
import os
import re
import subprocess

import jinja2
import yaml

ADDON_TASK_FILES = {
    "vip.yml": ["vip-rbac.yaml", "vip.yaml"],
    "metallb.yml": ["metallb-crds.yaml"],
    "kube-vip.yml": ["kube-vip-cloud-controller.yaml", "kubevip.yaml"],
}
INCLUDE = "primary-only-manifests.yml"


def repo_root():
    return subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()


def fail(message):
    raise SystemExit("Addon master test failed: " + message)


VARS_FILE = "vars/k3s-primary-master.yml"
PLAYBOOKS = ("site.yml", "upgrade-k3s.yml", "join-agent.yml")
NEEDS_PRIMARY = re.compile(r"k3s_primary_master|\b(k3s_server|k3s_server_post|k3s_agent)\b|reconcile-node")
INDEXED = re.compile(r"groups\[group_name_master[^\]]*\](\[0\]|\[1:\])")


def render(expression, groups, **context):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    env.filters["intersect"] = lambda a, b: [x for x in a if x in b]
    return env.from_string(expression).render(groups=groups, **context)


def check_no_indexed_master(root):
    paths = glob.glob(os.path.join(root, "roles", "**", "*.*"), recursive=True)
    paths += glob.glob(os.path.join(root, "tasks", "*.yml"))
    paths += [os.path.join(root, name) for name in PLAYBOOKS]
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            if INDEXED.search(handle.read()):
                fail(os.path.relpath(path, root) + " picks a master by index; use k3s_primary_master")


def check_plays_load_vars(root):
    for name in PLAYBOOKS:
        with open(os.path.join(root, name), encoding="utf-8") as handle:
            plays = yaml.safe_load(handle)
        for play in plays:
            body = {key: value for key, value in play.items() if key != "vars_files"}
            if NEEDS_PRIMARY.search(yaml.safe_dump(body)) and VARS_FILE not in play.get("vars_files", []):
                fail("{0}: play {1!r} must load {2}".format(name, play.get("name"), VARS_FILE))


def main():
    root = repo_root()
    role = os.path.join(root, "roles", "k3s_server")
    with open(os.path.join(root, VARS_FILE), encoding="utf-8") as handle:
        expression = yaml.safe_load(handle)["k3s_primary_master"]

    # Role scope sets group_name_master: master; playbook scope leaves it unset.
    for context in ({"group_name_master": "master"}, {}):
        for master in (["k3s-1", "k3s-6", "k3s-7"], ["k3s-7", "k3s-1", "k3s-6"]):
            chosen = render(expression, {"primary-master": ["k3s-7"], "master": master}, **context)
            if chosen != "k3s-7":
                fail("picked {0} instead of primary-master for master order {1}".format(chosen, master))
        if render(expression, {"primary-master": ["typo"], "master": ["m1", "m2"]}, **context) != "m1":
            fail("a primary-master host outside the master group was used")
        if render(expression, {"master": ["m1", "m2"]}, **context) != "m1":
            fail("no fallback to the first master when there is no primary-master group")

    with open(os.path.join(role, "defaults", "main.yml"), encoding="utf-8") as handle:
        if yaml.safe_load(handle)["k3s_server_addon_master"] != "{{ k3s_primary_master }}":
            fail("k3s_server_addon_master must be k3s_primary_master")
    check_no_indexed_master(root)
    template = os.path.join(root, "roles", "k3s_agent", "templates", "k3s.service.j2")
    with open(template, encoding="utf-8") as handle:
        if "default(k3s_token)" in handle.read():
            fail("the agent unit must not fall back to the inventory k3s_token (it goes stale)")
    for cni in ("calico.yml", "cilium.yml"):
        with open(os.path.join(root, "roles", "k3s_server_post", "tasks", cni), encoding="utf-8") as handle:
            block = yaml.safe_load(handle)[0]
        if "k3s_primary_master" in str(block.get("when")) and block.get("run_once"):
            fail(cni + ": run_once evaluates the primary-master when on the first host only")
    check_plays_load_vars(root)

    for name, manifests in ADDON_TASK_FILES.items():
        with open(os.path.join(role, "tasks", name), encoding="utf-8") as handle:
            text = handle.read()
            handle.seek(0)
            tasks = yaml.safe_load(handle)
        if "groups[group_name_master" in text:
            fail(name + " still gates on groups[group_name_master]")
        includes = [
            task for task in tasks
            if task.get("ansible.builtin.include_tasks") == INCLUDE
        ]
        if len(includes) != 1:
            fail("{0} must include {1} once".format(name, INCLUDE))
        listed = includes[0].get("vars", {}).get("k3s_server_primary_only_manifests")
        if listed != manifests:
            fail("{0} passes {1} to {2}, expected {3}".format(name, listed, INCLUDE, manifests))

    print("Primary/addon master regression test passed")


if __name__ == "__main__":
    main()
