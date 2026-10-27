# Kitchen node — handoff

**Phase completed:** Phase 1 (2026-10-27) — roles, `join-agent.yml`, inventory group; no node touched.
- `node_sd_card` (prereq): journald `Storage=volatile`, `/var/log/pods` tmpfs, kubelet drop-in
  `kubelet.conf.d/50-sd-card-logs.conf` (5Mi × 2); new `node_bluetooth` role (bluez, rfkill, `Experimental = true`).
- MetalLB speaker toleration written into the manifest file (`metal_lb_speaker_extra_tolerations`, k3s_server);
  `cluster-health.sh` warns on `Cluster`-policy LBs (homelab only); `join-agent.yml` written, not run.

**Next phase:** Phase 2 — flash done (k3s-9 is up at `192.168.50.90`, Ubuntu 24.04.5, Pi 4 8 GB); join + verify.

**Files for Phase 2:**
- `inventory/homelab-cluster/hosts.ini` — add `[k3s-9]`/`192.168.50.90`, and `k3s-9` under `[pi-kitchen:children]`
- `inventory/homelab-cluster/group_vars/pi-kitchen.yml`, `group_vars/all.yml` (gitignored; never print secrets)
- `join-agent.yml`, `tasks/reconcile-node.yml`, `roles/k3s_agent/`
- `roles/k3s_server/tasks/metallb.yml` (addon-only `upgrade-k3s.yml --tags addons` rollout)
- `cluster-health.sh`, `reboot.yml`, `CLAUDE.md` (Node Topology + inventory description)

**Invariants / gotchas:**
- Precondition before the join: homelab-k3s has switched the 3 `Cluster` LBs to `Local`
  (`./cluster-health.sh` shows no `Cluster` warning). The speaker toleration is already in inventory,
  so the speaker lands on k3s-9 as soon as it joins once the manifest change is rolled out.
- Never `site.yml`, not even with `--limit`. `join-agent.yml` refuses to run without `--limit`.
- No `--diff` on any run that renders the k3s unit (join token in cleartext). `--check` alone is fine.
- Don't run `upgrade-k3s.yml` between adding the host line and a successful join (preflight fails).
- Taint/labels (incl. `create-default-disk=false`) only apply at first registration — check them
  before anything else; a wrong value means removing the node and joining again.
- Unverified: k3s keeps foreign files in `kubelet.conf.d` (check `configz`); onboard BT needs no `pi-bluetooth`.
- The raspberrypi role reboots the Pi mid-run on first converge (cgroup cmdline) — expected.
- k3s-9 is an agent only (no etcd on SD).
