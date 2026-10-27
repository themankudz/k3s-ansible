# Kitchen node — handoff

**Phase completed:** Phase 0 (2026-10-27) — plan only, no code.
- `docs/kitchen-node/ROADMAP.md` written: Pi 4 (wired) as tainted k3s agent `k3s-9` on the management cluster.
- Logs stay in RAM (journald volatile, tmpfs `/var/log/pods`); SigNoz is the history.

**Next phase:** Phase 1 — inventory + role changes, no live node touched.

**Files for Phase 1:**
- `inventory/homelab-cluster/hosts.ini`, `inventory/homelab-cluster/group_vars/all.yml` (gitignored; never print token/secrets)
- `roles/prereq/tasks/node-hygiene.yml` (journald cap to override for the SD node)
- `roles/prereq/defaults/main.yml`, `roles/raspberrypi/tasks/setup/Ubuntu.yml`
- `tasks/reconcile-node.yml`, `site.yml` (prepare play), `.github/scripts/test-baseline-parity.sh`
- `roles/k3s_server_post/tasks/metallb.yml` (speaker toleration), `cluster-health.sh` (warn on `Cluster` LBs)
- `molecule/` scenarios

**Invariants / gotchas:**
- Never run `site.yml` against the live cluster; Phase 2 writes a dedicated `join-agent.yml`.
- k3s-9 is an **agent**, never a server (no etcd on SD).
- `node.longhorn.io/create-default-disk=false` must be set before join.
- MetalLB is re-downloaded on every upgrade: the speaker toleration must be re-patched each run.
- Same IP pool: safe only while every management LoadBalancer is `Local` (homelab-k3s switches the last 3 before join).
- No `--diff` on any run that renders k3s units/env (token in cleartext).
- AGENTS.md: no real IPs/tokens in committed role/sample files (inventory is gitignored).
