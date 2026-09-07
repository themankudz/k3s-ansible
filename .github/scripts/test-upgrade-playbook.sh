#!/usr/bin/env bash
#
# Regression guard for upgrade-k3s.yml. Every assertion here encodes a
# property whose violation caused the 2026-09-05 outage: site.yml's
# fresh-bootstrap-only k3s_server role stopped every master at once with no
# serial:, brought up only the first master alone via a transient
# --cluster-init unit, and deadlocked waiting for its own /readyz — a lone
# etcd member of an already-established cluster can never reach quorum by
# itself. A second, independent bug (a containerd config template missing
# the k3s base-config include) then took every node NotReady on the
# etcd-recovery restart. See upgrade-plan.md for the full incident.

set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
playbook="$repo_root/upgrade-k3s.yml"
reconcile_tasks="$repo_root/tasks/reconcile-node.yml"
containerd_tmpl="$repo_root/roles/prereq/files/containerd-config.toml.tmpl"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -f "$playbook" ] || fail "upgrade-k3s.yml not found at $playbook"
[ -f "$reconcile_tasks" ] || fail "tasks/reconcile-node.yml not found at $reconcile_tasks"

grep -Fq -- 'serial: 1' "$playbook" ||
  fail 'upgrade-k3s.yml must upgrade masters serial: 1 — a batch of more than one master can lose etcd quorum.'

grep -Fq -- 'any_errors_fatal: true' "$playbook" ||
  fail 'upgrade-k3s.yml must set any_errors_fatal: true so a single bad node halts the whole run.'

# Both files: upgrade-k3s.yml's own tasks, and tasks/reconcile-node.yml, the
# shared Part A reconciliation block it includes from both the master and
# agent plays (see the 2026-09-07 "primary fleet-maintenance playbook" work —
# without checking this second file too, the greps below silently stop
# protecting the code that was moved out of upgrade-k3s.yml).
for target in "$playbook" "$reconcile_tasks"; do
  # Strip comment-only lines first: upgrade-k3s.yml's header comment
  # deliberately explains the 2026-09-05 incident in prose, which names
  # --cluster-init/k3s-init/etc. as things NOT to do. Only forbid these
  # tokens in actual executable content.
  code_only="$(grep -Ev '^[[:space:]]*#' "$target")"

  for forbidden in '--cluster-init' 'systemd-run' 'k3s-init'; do
    grep -Fq -- "$forbidden" <<<"$code_only" &&
      fail "$target must not use '$forbidden' — that is the fresh-bootstrap-only path that deadlocked an established cluster on 2026-09-05."
  done

  grep -Fq -- 'k3s --version' <<<"$code_only" &&
    fail "$target must gate on node.status.nodeInfo.kubeletVersion, not 'k3s --version' (which reports the on-disk binary, not the running process)."

  # A `delegate_to` that stops/restarts a service on a host other than the
  # current batch host would reintroduce the "stop every master at once" bug.
  # The only services this playbook restarts are k3s/k3s-node, and every such
  # task must run un-delegated (on inventory_hostname, i.e. the current batch
  # host) — so no delegate_to line should appear within the small task block
  # that starts at an ansible.builtin.systemd action line.
  if grep -A3 'ansible.builtin.systemd:' "$target" | grep -q 'delegate_to'; then
    fail "$target must not delegate_to on an ansible.builtin.systemd task — every k3s/k3s-node restart must run on the current batch host only."
  fi
done

grep -Fq -- 'kubeletVersion' "$playbook" ||
  fail 'upgrade-k3s.yml must read kubeletVersion somewhere to gate on the actually-running version.'

grep -Fq -- 'get --raw=/readyz' "$playbook" ||
  fail 'upgrade-k3s.yml must gate a master restart on peer /readyz — this is the pre-stop quorum check absent on 2026-09-05.'

grep -Fq -- 'template "base"' "$containerd_tmpl" ||
  fail "$containerd_tmpl is missing the {{ template \"base\" . }} directive — without it this file REPLACES k3s's entire generated containerd config (CRI/CNI/registry mirrors) instead of extending it, and every node goes NotReady on the next containerd restart. This is the second, independent bug from the 2026-09-05 outage."

# Go's text/template engine evaluates {{ }} actions even inside "#" comment
# lines. Writing the literal directive text in a comment (e.g. to explain it)
# renders a SECOND copy of the base config and corrupts the output TOML —
# this exact bug broke k3s-w1 on 2026-09-06, right after the check above was
# added. Guard against regressing it: the directive must appear exactly once,
# and never on a line starting with '#'.
tmpl_code_hits="$(grep -Ev '^[[:space:]]*#' "$containerd_tmpl" | grep -Fc -- 'template "base"' || true)"
tmpl_comment_hits="$(grep -E '^[[:space:]]*#' "$containerd_tmpl" | grep -Fc -- 'template "base"' || true)"

[ "$tmpl_code_hits" -eq 1 ] ||
  fail "$containerd_tmpl must contain the base-config include directive exactly once on a real (non-comment) line; found $tmpl_code_hits."

[ "$tmpl_comment_hits" -eq 0 ] ||
  fail "$containerd_tmpl has the base-config include directive written inside a '#' comment ($tmpl_comment_hits occurrence(s)) — Go's text/template still executes it there, rendering a duplicate and corrupting the output TOML."

printf 'upgrade-k3s.yml regression test passed\n'
