#!/usr/bin/env bash
#
# Guards the parity between site.yml's "Prepare k3s nodes" play (the
# bootstrap-only node baseline) and tasks/reconcile-node.yml (the shared
# per-host reconciliation block upgrade-k3s.yml runs against an
# already-established cluster). A role added to one but not the other means a
# rebuilt node and a routinely-maintained node silently diverge — exactly the
# kind of drift upgrade-k3s.yml was built to close. See upgrade-plan.md.
#
# site.yml's role list must be a subset of reconcile-node.yml's, modulo a
# small documented exclusion list — roles that legitimately only belong on
# one side.

set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
site_playbook="$repo_root/site.yml"
reconcile_tasks="$repo_root/tasks/reconcile-node.yml"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -f "$site_playbook" ] || fail "site.yml not found at $site_playbook"
[ -f "$reconcile_tasks" ] || fail "tasks/reconcile-node.yml not found at $reconcile_tasks"

# Roles legitimately absent from tasks/reconcile-node.yml:
#   download - only belongs inside the guarded restart's drain block, never
#     unconditionally in per-host reconciliation.
#   lxc      - deliberately excluded (references a template that does not
#     exist and targets Proxmox LXC nodes only; see upgrade-plan.md).
excluded_roles=(download lxc)

is_excluded() {
  local role="$1"
  local excluded
  for excluded in "${excluded_roles[@]}"; do
    [ "$role" = "$excluded" ] && return 0
  done
  return 1
}

site_roles="$(
  awk '/^- name: Prepare k3s nodes/{flag=1; next} /^- name:/{flag=0} flag' "$site_playbook" \
    | grep -oE -- '- role: [A-Za-z0-9_]+' \
    | awk '{print $NF}' \
    | sort -u
)"

[ -n "$site_roles" ] || fail "found no roles in site.yml's 'Prepare k3s nodes' play — parity check can't run."

reconcile_roles="$(
  grep -A1 -- 'ansible.builtin.include_role:' "$reconcile_tasks" \
    | grep -E -- '^\s*name:' \
    | awk '{print $NF}' \
    | sort -u
)"

[ -n "$reconcile_roles" ] || fail "found no include_role names in tasks/reconcile-node.yml — parity check can't run."

missing=()
while IFS= read -r role; do
  [ -n "$role" ] || continue
  if ! grep -qx -- "$role" <<<"$reconcile_roles" && ! is_excluded "$role"; then
    missing+=("$role")
  fi
done <<<"$site_roles"

if [ "${#missing[@]}" -gt 0 ]; then
  fail "site.yml's 'Prepare k3s nodes' play includes role(s) [${missing[*]}] that tasks/reconcile-node.yml does not — a rebuilt node (site.yml) would diverge from a routinely-maintained one (upgrade-k3s.yml). Add the role to tasks/reconcile-node.yml, or add it to the excluded_roles list in this script with a documented reason if it genuinely belongs on the bootstrap path only."
fi

printf 'Baseline parity test passed\n'
