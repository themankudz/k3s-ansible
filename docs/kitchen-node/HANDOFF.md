# Kitchen node — handoff

**Phase completed:** Phase 3 (Mop-up), first part (2026-10-29) — rows 2–5, 9, 11, 14 fixed; 6, 8, 12, 16 moved
to homelab-k3s. Phase 2 is fully verified (kitchen toleration after k3s-7's restart; bt-proxy `.203` on k3s-9).
- Upstream merged; lint green; MetalLB manifest built outside `server/manifests` then copied in; cleanup waits
  for the controller rollout. Both clusters on k3s v1.36.5+k3s1 / kube-vip v1.2.4 / MetalLB v0.16.1.
- Homelab drain stranded Home Assistant (row 16) — fix is homelab-k3s PR #103 (merge + sync pending).

**Next phase:** Phase 3 continued — open rows 1, 7+13, 10, 15. Archive the plan once they're done (row 6's
end-of-Nov re-check lives in homelab-k3s now, so it doesn't hold this plan open).

**Files for the open rows:**
- 1: `site.yml` (guard play: fail if a master has `/var/lib/rancher/k3s/server/db` or the VIP answers `/readyz`)
- 7+13: one shared primary-master var — `roles/k3s_server/defaults/main.yml` (`k3s_server_addon_master`,
  `server_init_args`), `roles/k3s_server/tasks/{main,join_master,fetch_k3s_init_logs}.yml`,
  `roles/k3s_server_post/tasks/{metallb,calico,cilium}.yml`, `roles/k3s_agent/` (token lookup, defaults);
  `.github/scripts/test-addon-master.py`
- 10: `roles/prereq/tasks/node-hygiene.yml` (`node_sd_card`: remove `/var/log/journal`)
- 15: `roles/k3s_server_post/tasks/main.yml` (`apply: {tags: ...}` on the includes)

**Invariants / gotchas:**
- Never `site.yml` on a live cluster; never `--diff` (join token, SMTP secrets). Always pass `-i`.
- k3s-8 is never drained; workload needs `-e k3s_upgrade_drain=false`. A drain can strand HA until PR #103 syncs.
- Addon manifests live only on `k3s_server_addon_master`; `.skip` copies elsewhere are inert.
- `metallb.yml` build file: edits and checks run on `metallb_manifest_build`; only the final copy touches
  `server/manifests` (k3s re-applies on change). Tests: `test-metallb-speaker-tolerations.py`,
  `test-metallb-namespace.py`.
- `--check` of `upgrade-k3s.yml` needs `-e k3s_upgrade_etcd_snapshot=false`; with a version bump it stops at
  "Re-read the kubeletVersion after restart" (nothing upgrades in check mode) — expected.
- Live inventories (gitignored) are already bumped; `docs/registries.md` unchanged.
