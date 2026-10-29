#!/usr/bin/env python3
"""Regression test for site.yml's established-cluster guard.

site.yml is bootstrap-only (full outage 2026-09-05 when run against a live
cluster). Its first play must refuse to continue when any master already has
k3s server state or --limit leaves a master out, run for every --tags
selection (tags: always), and stop the whole run (any_errors_fatal) before
any other play touches a node. It targets all hosts: with hosts: master, an
unreachable master only stopped the masters and the agents carried on.
"""

from __future__ import print_function

import os
import subprocess

import yaml

STATE = "/var/lib/rancher/k3s/server/db"


def repo_root():
    return subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()


def fail(message):
    raise SystemExit("site.yml guard test failed: " + message)


def main():
    with open(os.path.join(repo_root(), "site.yml"), encoding="utf-8") as handle:
        plays = yaml.safe_load(handle)
    guard = plays[0]
    if guard.get("hosts") != "all":
        fail("the first play must target all hosts, got {0!r}".format(guard.get("hosts")))
    if "always" not in ([guard["tags"]] if isinstance(guard.get("tags"), str) else guard.get("tags", [])):
        fail("the guard play must be tagged always, or --tags skips it")
    if guard.get("any_errors_fatal") is not True:
        fail("the guard play must set any_errors_fatal, or the other masters carry on")
    tasks = guard.get("tasks", [])
    stats = [t for t in tasks if t.get("ansible.builtin.stat", {}).get("path") == STATE]
    fails = [t for t in tasks if "ansible.builtin.fail" in t]
    if len(stats) != 1:
        fail("the guard must stat {0}".format(STATE))
    register = stats[0].get("register")

    def conditions(task):
        when = task.get("when", [])
        return [when] if isinstance(when, str) else when

    if not any("ansible_play_hosts_all" in c for t in fails for c in conditions(t)):
        fail("the guard must fail when --limit leaves a master out")
    state_fails = [t for t in fails if any("{0}.stat.exists".format(register) in c for c in conditions(t))]
    if len(state_fails) != 1:
        fail("one fail task must be conditioned on {0}.stat.exists".format(register))
    for task in stats + state_fails:
        if not any("groups['master']" in c for c in conditions(task)):
            fail("{0!r} must only run on the masters".format(task.get("name")))
    print("site.yml guard regression test passed")


if __name__ == "__main__":
    main()
