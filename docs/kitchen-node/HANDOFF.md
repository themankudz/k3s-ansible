# Kitchen node — handoff

**Phase completed:** Phase 3 (Mop-up), third part (2026-10-29). Row 17 is fixed and verified live.
- `node_monitoring` puts the drop-in `60-otelcol-log-acl.conf` on `k3s` (masters) or `k3s-node` (agents). Its
  `ExecStartPost=-setfacl` re-grants the otelcol traverse ACL that k3s's chmod of `agent/containerd` masks at
  every start. It only reloads systemd and never restarts k3s. Stale copies are removed, and `reset` removes it too.
- Both clusters' `--check` runs are clean: only the drop-in, the ACL, the known `/tmp/k3s` noise and k3s-9's journal.

**Next phase:** Phase 3 continued: rows 18 and 19, then archive the plan. Row 6's end-of-Nov re-check
lives in homelab-k3s, in `plans/kitchen-node-apps-plan.md` Mop-up row 1.

**Files for the open work:**
- 18: the `upgrade-k3s.yml` preflight ("Assert every inventory host maps to an actual cluster node") reads facts of
  limited-out hosts. `tasks/reconcile-node.yml` has untagged includes, so `--tags hygiene` etc. reach nothing.
- 19: `roles/prereq/tasks/` (ensure `/var/lib/rancher` and `/var/lib/rancher/k3s` are `0755`; only k3s-w1 has `644`).

**Invariants / gotchas:**
- Never run `site.yml` on a live cluster (it now refuses). Never use `--diff` (join token, SMTP secrets). Always pass `-i`.
- `k3s_primary_master` comes from play `vars_files`, so an inventory value is ignored (only `-e` overrides it). A new
  play that runs k3s_server, k3s_server_post, k3s_agent or the agent template must load it (`test-addon-master.py`).
- The inventory `k3s_token` is stale. The agent template fails if `token` isn't set on the primary first.
- `run_once` combined with a `when` on a specific host evaluates only the first host, so use one or the other.
- k3s-8 is never drained, and workload needs `-e k3s_upgrade_drain=false`. `--check` of `upgrade-k3s.yml` needs
  `-e k3s_upgrade_etcd_snapshot=false`.
- The ACL drop-in must not override the mask (`m::`). setfacl recalculates it.
