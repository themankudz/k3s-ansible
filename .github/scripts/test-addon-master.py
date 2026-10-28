#!/usr/bin/env python3
"""Regression test for the master that owns the addon manifests.

The kube-vip/MetalLB manifests in server/manifests must always be written to
the same master. groups['master'] has no stable order when a host sits in two
of its child groups (k3s-7 in primary-master and pi-master: ansible-core 2.21
returned k3s-1 or k3s-7 first at random), so the role resolves
k3s_server_addon_master from primary-master instead. This test checks that:

- k3s_server_addon_master prefers primary-master over group_name_master's
  first host, and falls back to it when there is no primary-master group;
- the addon task files gate on k3s_server_addon_master, not on
  groups[group_name_master][0];
- each of them keeps its manifests off the other masters
  (primary-only-manifests.yml).
"""

from __future__ import print_function

import os
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


def render(expression, groups):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    env.filters["intersect"] = lambda a, b: [x for x in a if x in b]
    return env.from_string(expression).render(groups=groups, group_name_master="master")


def main():
    role = os.path.join(repo_root(), "roles", "k3s_server")
    with open(os.path.join(role, "defaults", "main.yml"), encoding="utf-8") as handle:
        expression = yaml.safe_load(handle)["k3s_server_addon_master"]

    for master in (["k3s-1", "k3s-6", "k3s-7"], ["k3s-7", "k3s-1", "k3s-6"]):
        chosen = render(expression, {"primary-master": ["k3s-7"], "master": master})
        if chosen != "k3s-7":
            fail("picked {0} instead of primary-master for master order {1}".format(chosen, master))
    if render(expression, {"primary-master": ["typo"], "master": ["m1", "m2"]}) != "m1":
        fail("a primary-master host outside the master group was used")
    if render(expression, {"master": ["m1", "m2"]}) != "m1":
        fail("no fallback to the first master when there is no primary-master group")

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

    print("Addon master regression test passed")


if __name__ == "__main__":
    main()
