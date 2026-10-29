#!/usr/bin/env python3
"""Regression test: a tagged include_tasks must also apply its tags.

A tag on an include_tasks without `apply:` only selects the include itself,
so `--tags metallb` (or calico, cilium, kubevip, hygiene, static_hosts) ran
the include and then skipped every task in the included file. Every tagged
include_tasks in roles/ must carry the same tags under `apply.tags`.
"""

from __future__ import print_function

import glob
import os
import subprocess

import yaml

MODULES = ("ansible.builtin.include_tasks", "include_tasks")


def repo_root():
    return subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()


def as_list(tags):
    if tags is None:
        return []
    return [tags] if isinstance(tags, str) else list(tags)


def walk(tasks, path, problems):
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        for key in ("block", "rescue", "always"):
            walk(task.get(key), path, problems)
        for module in MODULES:
            if module not in task or not task.get("tags"):
                continue
            args = task[module]
            applied = args.get("apply", {}).get("tags") if isinstance(args, dict) else None
            if set(as_list(task["tags"])) - set(as_list(applied)):
                problems.append("{0}: {1!r} tags {2} without apply.tags".format(
                    path, task.get("name"), as_list(task["tags"])))


def main():
    root = repo_root()
    problems = []
    files = sorted(glob.glob(os.path.join(root, "roles", "*", "tasks", "**", "*.yml"), recursive=True))
    if not files:
        raise SystemExit("include apply-tags test failed: no role task files found")
    for path in files:
        with open(path, encoding="utf-8") as handle:
            walk(yaml.safe_load(handle), os.path.relpath(path, root), problems)
    if problems:
        raise SystemExit("include apply-tags test failed:\n  " + "\n  ".join(problems))
    print("include apply-tags regression test passed")


if __name__ == "__main__":
    main()
