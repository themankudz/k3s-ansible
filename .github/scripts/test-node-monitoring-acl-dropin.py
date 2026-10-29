#!/usr/bin/env python3
"""Regression test: the otelcol traverse ACL survives a k3s restart.

k3s chmods agent/containerd back to 0700 at every start, and chmod rewrites
the ACL mask, so otelcol-contrib lost containerd.log after every restart
until the next upgrade-k3s.yml run (kitchen-node Mop-up row 17). The
node_monitoring role installs a drop-in on the k3s unit that re-grants the
ACL after each start. Checks:
  * the template renders one non-fatal setfacl ExecStartPost per dir, with
    no mask override (setfacl must recalculate it);
  * the unit default picks k3s on masters, k3s-node on agents, none off k3s;
  * the role installs the drop-in, removes the copies that no longer apply
    (no dirs, other unit, not a k3s node), and reloads systemd without ever
    restarting k3s;
  * reset.yml removes both drop-ins.
"""

from __future__ import print_function

import os
import subprocess
import sys

import jinja2
import yaml


def repo_root():
    return subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()


ROOT = repo_root()
ROLE = os.path.join(ROOT, "roles", "node_monitoring")
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def bool_filter(value):
    return str(value).lower() in ("true", "1", "yes")


env = jinja2.Environment(undefined=jinja2.StrictUndefined)
env.filters["bool"] = bool_filter
env.filters["difference"] = lambda a, b: [x for x in a if x not in b]

# --- template -------------------------------------------------------------
with open(os.path.join(ROLE, "templates", "k3s-log-acl.conf.j2")) as f:
    template = env.from_string(f.read())
dirs = ["/var/lib/rancher/k3s/agent", "/var/lib/rancher/k3s/agent/containerd"]
rendered = template.render(ansible_managed="managed", node_monitoring_traverse_dirs=dirs)
lines = [ln for ln in rendered.splitlines() if ln.startswith("ExecStartPost=")]
check("[Service]" in rendered.splitlines(), "drop-in has no [Service] section")
check(
    lines == ["ExecStartPost=-/usr/bin/setfacl -m u:otelcol-contrib:x %s" % d for d in dirs],
    "unexpected ExecStartPost lines: %r" % lines,
)
check("m::" not in rendered, "drop-in must not override the ACL mask")

# --- unit default ---------------------------------------------------------
with open(os.path.join(ROLE, "defaults", "main.yml")) as f:
    defaults = yaml.safe_load(f)
unit_expr = env.from_string(defaults["node_monitoring_k3s_unit"])
groups = {"master": ["m1"], "node": ["a1"]}
for host, k8s, want in (("m1", True, "k3s"), ("a1", True, "k3s-node"), ("m1", False, "")):
    got = unit_expr.render(
        inventory_hostname=host, groups=groups, node_monitoring_k8s_node=k8s
    ).strip()
    check(got == want, "unit for %s (k8s=%s) is %r, want %r" % (host, k8s, got, want))
got = unit_expr.render(inventory_hostname="vm", groups={}, node_monitoring_k8s_node=False).strip()
check(got == "", "unit on a non-k3s VM is %r, want ''" % got)

# --- tasks ----------------------------------------------------------------
with open(os.path.join(ROLE, "tasks", "main.yml")) as f:
    tasks = yaml.safe_load(f)
by_name = {t.get("name"): t for t in tasks}
install = by_name.get("Re-grant the traverse ACLs after every k3s start")
remove = by_name.get("Remove ACL drop-ins that no longer apply")
reload_ = by_name.get("Reload systemd for the ACL drop-in")
check(install is not None and install.get("ansible.builtin.template", {}).get("src") == "k3s-log-acl.conf.j2",
      "role does not template the drop-in")
check(remove is not None and remove.get("ansible.builtin.file", {}).get("state") == "absent",
      "role does not remove stale drop-ins")
if remove is not None:
    loop = env.from_string(remove["loop"])
    for unit, tdirs, want in (
        ("k3s", dirs, ["k3s-node"]),
        ("k3s-node", dirs, ["k3s"]),
        ("k3s", [], ["k3s", "k3s-node"]),
        ("", dirs, ["k3s", "k3s-node"]),
    ):
        got = loop.render(node_monitoring_k3s_unit=unit, node_monitoring_traverse_dirs=tdirs)
        check(got == str(want), "removal for unit %r, dirs %r is %s, want %s" % (unit, tdirs, got, want))
check(reload_ is not None and reload_.get("ansible.builtin.systemd", {}).get("daemon_reload") is True,
      "role does not daemon-reload after changing the drop-in")
for task in tasks:
    module = task.get("ansible.builtin.systemd") or task.get("ansible.builtin.service") or {}
    name = str(module.get("name", ""))
    check(not name.startswith("k3s"), "task %r touches the %s unit" % (task.get("name"), name))

with open(os.path.join(ROOT, "roles", "reset", "tasks", "main.yml")) as f:
    reset_text = f.read()
for unit in ("k3s", "k3s-node"):
    check("%s.service.d/60-otelcol-log-acl.conf" % unit in reset_text,
          "reset does not remove the %s drop-in" % unit)

if failures:
    for msg in failures:
        print("FAIL: " + msg)
    sys.exit(1)
print("OK: node_monitoring ACL drop-in")
