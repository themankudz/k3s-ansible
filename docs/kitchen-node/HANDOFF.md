# Kitchen node — handoff

**Phase completed:** Phase 3 (Mop-up), second part (2026-10-29) — rows 1, 7, 10, 13, 15 fixed.
- `site.yml` refuses an established cluster (first play, `hosts: all`, `tags: always`) and a `--limit` that drops a master.
- One `k3s_primary_master` (`vars/k3s-primary-master.yml`, loaded with `vars_files`) for cluster-init, joins, the
  agent join token (no stale `k3s_token` fallback), addon/CNI manifests, kubeconfig. Tagged includes `apply` their tags.
- SD-card nodes drop the old persistent journal (k3s-9's 23M goes at the next `upgrade-k3s.yml` run).

**Next phase:** Phase 3 continued — rows 17 and 18 (found today). Then archive the plan (row 6's end-of-Nov
re-check lives in homelab-k3s, `plans/kitchen-node-apps-plan.md` Mop-up row 1).

**Files for the open rows:**
- 17: `roles/node_monitoring/tasks/` (traverse ACL task), `inventory/*/group_vars/all.yml` `node_monitoring_traverse_dirs`
  (gitignored); k3s resets `agent/containerd`'s mode at every start → ACL mask `---`.
- 18: `upgrade-k3s.yml` preflight ("Assert every inventory host maps to an actual cluster node", reads facts of
  limited-out hosts), `tasks/reconcile-node.yml` (untagged includes, so `--tags hygiene` etc. reach nothing).

**Invariants / gotchas:**
- Never `site.yml` on a live cluster (it now refuses); never `--diff` (join token, SMTP secrets). Always pass `-i`.
- `k3s_primary_master` comes from play `vars_files`, so an inventory value is ignored (only `-e` overrides). A new
  play that runs k3s_server/k3s_server_post/k3s_agent or the agent template must load it (`test-addon-master.py`).
- The inventory `k3s_token` is stale; the agent template fails if `token` isn't set on the primary first.
- `run_once` + a `when` on a specific host only evaluates the first host — use one or the other.
- k3s-8 is never drained; workload needs `-e k3s_upgrade_drain=false`. `--check` of `upgrade-k3s.yml` needs
  `-e k3s_upgrade_etcd_snapshot=false`. Expected `--check` noise: traverse ACL (row 17), `/tmp/k3s` CR copy.
