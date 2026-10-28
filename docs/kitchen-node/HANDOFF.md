# Kitchen node — handoff

**Phase completed:** Phase 2 (2026-10-28) — k3s-9 joined and verified; MetalLB speaker runs on it.
- k3s-9 (`192.168.50.90`, Pi 4, SD) Ready, tainted `location=kitchen:NoSchedule`, no Longhorn; BLE `hci0` up;
  journald + `/var/log/pods` in RAM, kubelet log drop-in live (`5Mi` × 2); logs in SigNoz (pods + `log.source=node`).
- Fixes found by the join: prereq adds missing `-updates`/`-backports` apt pockets; `node_monitoring` skips
  traverse dirs that don't exist yet (join-agent re-runs it); addon manifests now go to `k3s_server_addon_master`
  (first of `primary-master` — `groups['master']` order was random) with `.skip` on stray copies (k3s-1 has 3).
- apt-cacher spliced-InRelease root cause fixed in homelab-k3s (`VfileUseRangeOps=-1`, pushed + rolled out).

**Next phase:** Phase 3 — Mop-up (12 rows). Re-check each row still reproduces and have the user confirm the
list first. Still-open Phase 2 verifications (keep the plan unarchived until done): the speaker's kitchen
toleration after the next k3s-7 k3s restart; the bt-proxy LB IP resolves to k3s-9 (after homelab-k3s P2).

**Files for Phase 3 (by row):**
- 1: `site.yml` · 2, 11: `roles/k3s_server/tasks/metallb.yml` · 3, 5: repo-wide lint, `cluster-health.sh`
- 4: `.github/scripts/test-k3s-server-bootstrap.sh` · 6: `../../homelab-k3s/apt-cacher/` (purge decision ~end Nov)
- 7: `roles/k3s_server/defaults/main.yml` (`server_init_args`), `roles/k3s_server/tasks/main.yml`,
  `roles/k3s_server_post/tasks/{cilium,calico}.yml` · 8: MetalLB speaker metrics scrape (homelab-k3s?)
- 9: k3s-8 pending drift (`upgrade-k3s.yml` will restart k3s-node there) · 10: `roles/prereq/tasks/node-hygiene.yml`
- 12: homelab-k3s `media-server`

**Invariants / gotchas:**
- Never `site.yml` on a live cluster; never `--diff` (join token, SMTP secrets). `-i inventory/homelab-cluster/hosts.ini`.
- Addon manifests must only live on `k3s_server_addon_master`; never delete them from the primary. `.skip` is
  inert (k3s v1.36.4 `pkg/deploy`: skipped files are ignored, nothing deleted). `test-addon-master.py` guards it.
- Taint/labels only apply at first registration; changing them means removing and re-joining k3s-9.
- k3s-8 is never drained (`k3s_upgrade_skip_drain`). k3s-9 is agent-only (no etcd on SD).
- `join-agent.yml --check` stops at "Manage k3s service" on a fresh node (no unit yet) — expected.
