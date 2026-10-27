# Kitchen node (k3s-9): join a tainted, SD-card Pi 4 to the management cluster

> **Status:** IN PROGRESS. Phase 1 done 2026-10-27 (roles, `join-agent.yml`, inventory group — no node touched); Phase 2 next. k3s-9 is booted at `192.168.50.90`. (checked 2026-10-27)

## Why

Home Assistant's Bermuda BLE room tracking has no scanner in the kitchen, and a local voice
satellite there needs a mic/speaker host. A spare **Raspberry Pi 4** placed in the kitchen joins the
**management** cluster as a **dedicated agent**: tainted so only kitchen workloads run on it, and set
up so its SD card isn't worn out by logs. The workloads themselves (bt-proxy, voice satellite) are
GitOps apps — see `homelab-k3s/plans/kitchen-node-apps-plan.md`. HA-side configuration is in
`homeassistant/docs/kitchen-node/ROADMAP.md`.

## Cross-repo order

| Step | Repo | What | Blocks |
|---|---|---|---|
| 1 | this repo, Phase 1 | Inventory + role changes for an SD-card BLE/audio agent, MetalLB speaker toleration (no node touched) | 2 |
| 1b | homelab-k3s P1 | Switch the management LoadBalancers still on `Cluster` to `Local` | 2 |
| 2 | this repo, Phase 2 | Flash, join, verify k3s-9; roll out the speaker toleration | gitops P2, P4 |
| — | homelab-k3s P3 (Whisper/Piper on workload) | independent, can run any time | — |
| 3 | homelab-k3s P2 | bt-proxy on k3s-9 behind a MetalLB IP | HA P1 |
| 4 | homelab-k3s P4 | voice satellite on k3s-9 (needs USB speakerphone) | HA P3 |

## Decisions (made 2026-10-27)

- **Hardware:** the spare **Raspberry Pi 4** (Bluetooth 5.0, gigabit Ethernet). SD card for now —
  buy a *high-endurance* card. A USB SSD boot later removes the wear concern; if that happens, drop
  the SD-specific vars, nothing else changes. Use a proper 3 A supply (undervoltage is the usual
  cause of flaky Pi Bluetooth, per bt-proxy's docs).
- **Network: wired Ethernet only** (kitchen wall port). No k3s node goes on Wi-Fi — a node can end up
  carrying other nodes' traffic, and Wi-Fi would also share the radio with Bluetooth.
- **OS:** Ubuntu Server 24.04 LTS arm64, like every other node (the `raspberrypi` role's
  `setup/Ubuntu.yml` path, `/var/run/reboot-required`, `69-bcache.rules` all assume Ubuntu).
- **Name:** `k3s-9`, fleet numbering. Its role is carried by labels, not the hostname.
- **Role:** k3s **agent** only, never a server — etcd on an SD card is the worst-case write load.
- **Taint/label:** `location=kitchen:NoSchedule` + label `location=kitchen`. No `platform` label,
  so nothing that selects `platform: pi` (HA, Blocky, …) lands there even with a toleration.
- **Logs: RAM only, SigNoz is the history.** Shipping is already handled — the k8s-infra
  `otel-agent` DaemonSet tolerates every taint (`operator: Exists`, checked 2026-10-27) and the
  host `node_monitoring` collector ships journald. So the node keeps only what hasn't shipped yet:
  - journald `Storage=volatile`, small `RuntimeMaxUse` (e.g. 64M). `node_monitoring` reads the
    runtime journal just the same.
  - `/var/log/pods` on a **tmpfs** (256M cap; only what's written uses RAM) rather than log2ram: log2ram rsyncs back to the SD
    card daily and at shutdown, which is wear we don't need since SigNoz holds the history.
    Accepted trade-off: a reboot while SigNoz is unreachable loses that window's node logs.
  - kubelet container-log rotation for this node only: `containerLogMaxSize: 5Mi`,
    `containerLogMaxFiles: 2` (keeps the tmpfs small) — as a kubelet **drop-in** in k3s's
    `--config-dir` (`/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-sd-card-logs.conf`), not as
    the deprecated `--container-log-max-*` kubelet flags (decided in Phase 1).
- **Bluetooth host stack:** `bluez` + `rfkill` installed (neither is on the stock Ubuntu Pi image),
  experimental interfaces via `Experimental = true` in `/etc/bluetooth/main.conf` — the config form
  of `bluetoothd --experimental`, so no `ExecStart` override with a release-specific binary path
  (bt-proxy needs it for passive scanning, BlueZ ≥ 5.56 — Ubuntu 24.04 ships 5.72), adapter
  unblocked (`rfkill unblock bluetooth`; systemd-rfkill keeps it across reboots). The container talks to BlueZ over `/var/run/dbus`.
- **Longhorn:** label `node.longhorn.io/create-default-disk=false` **before** the node joins (or the
  default disk gets created on the SD card). Longhorn's DaemonSets don't tolerate the taint anyway, so
  kitchen pods can't mount Longhorn volumes — none of them need one.
- **Kitchen apps use MetalLB, not hostNetwork** (decided 2026-10-27). bt-proxy and the voice
  satellite speak the ESPHome API over plain TCP 6053; HA adds them by IP (no mDNS discovery). Pod
  networking means no port clash between them and no host-network privileges.
  - **MetalLB speaker gets a toleration for `location=kitchen:NoSchedule`**, written by this repo
    **into the MetalLB manifest file** (`roles/k3s_server/tasks/metallb.yml`, run by `site.yml` and
    `upgrade-k3s.yml` Play 5) after the speaker's upstream control-plane toleration, between marker
    comments. Not a `kubectl patch` (decided in Phase 1): k3s re-applies every `server/manifests/`
    file at each k3s start (k3s-7's journal, 2026-10-18 and 2026-10-27, file unchanged since
    2026-09-06), which would reset a patched DaemonSet after any primary-master restart. A separate
    manifest can't overlay the DaemonSet either (k3s applies whole objects, no kustomize). Kitchen Services use `externalTrafficPolicy: Local`, so they're
    announced from k3s-9 itself.
  - **Same IP pool, no fence — every management LoadBalancer uses `Local`.** In L2 mode MetalLB only
    restricts the announcer to nodes with a ready endpoint for `Local` Services; for `Cluster` any
    speaker node can win (checked in v0.16 `speaker/layer2_controller.go`, no setting to prefer
    endpoint nodes). k3s-9 never runs non-kitchen pods (taint), so with `Local` everywhere it can
    never announce e.g. ingress `.215`. The three `Cluster` Services on management today
    (internal-nginx `.215`, blocky-redis `.223`, matter-server `.222`) are switched to `Local` in
    homelab-k3s (its kitchen plan, step before the node joins). Guard: `cluster-health.sh` warns on
    any management LoadBalancer with `Cluster` policy. Residual risk if one slips through: a brief
    blip for that IP while k3s-9 is unplugged — acceptable on Ethernet.

## Known effects of the taint (checked 2026-10-27, management cluster)

| DaemonSet | Lands on k3s-9? | Note |
|---|---|---|
| k8s-infra otel-agent | yes (`Exists`) | wanted — ships pod logs. Its replay queue is an emptyDir on the SD card (20Gi sizeLimit, 4GiB/signal cap); only grows while SigNoz is unreachable. Accepted. |
| smartctl-exporter | yes | harmless on an SD card |
| kube-vip-ds | check | tolerates all taints; confirm its nodeSelector keeps it on control-plane nodes |
| longhorn-manager / csi / engine-image | no | intended |
| metallb speaker | **yes, after Phase 1** | toleration added by this repo; only announces `Local` Services whose pod runs on k3s-9 (see Decisions) |
| harbor-prepull | no | images just pull on first start via `registries.yaml` |

## Phases

### Phase 0 — plan (this document) ✅ 2026-10-27
Docs only: this ROADMAP, `HANDOFF.md`, `docs/INDEX.md` row.

### Phase 1 — inventory + roles for an SD-card BLE agent (no node touched) ✅ 2026-10-27
- [x] Inventory: an empty group (e.g. `pi-kitchen`) under `node`, plus its group_vars/host_vars:
      `extra_agent_args` adding `--node-taint location=kitchen:NoSchedule`,
      `--node-label location=kitchen`, `--node-label node.longhorn.io/create-default-disk=false`
      (on top of the shared `extra_args`). *Done:* `[pi-kitchen:children]` (empty) under
      `[node:children]`, `group_vars/pi-kitchen.yml` (`node_sd_card`, `node_bluetooth_enabled`,
      `extra_agent_args`), `metal_lb_speaker_extra_tolerations` in `group_vars/all.yml`. Log rotation
      moved to a kubelet drop-in (see Decisions), so no `--kubelet-arg` here.
      **The `k3s-9` host line itself is not added until Phase 2** (or only as a comment): a host in the
      inventory that isn't a cluster node fails `upgrade-k3s.yml`'s "every inventory host maps to an
      actual cluster node" preflight, and `reboot.yml`/`patch.yml` would try to reach it — so routine
      maintenance between the phases would break.
- [x] Write `join-agent.yml` (written and linted here, **run only in Phase 2**). There is no "add a
      node to a live cluster" playbook today, and `site.yml` is not one, even with `--limit`: its agent
      unit falls back to the inventory `k3s_token` (only `k3s_server` sets the live token), its
      hostname-uniqueness pre-task reads facts of hosts a `--limit` didn't gather, and nothing stops a
      run without `--limit` from repeating the 2026-09-05 outage. Agent-only by design; plays:
      1. Preflight (localhost/run_once): `ansible_limit` must be set (refuse to run against all of
         `node`); the kubectl-context check from `upgrade-k3s.yml` Play 1; every targeted host must be
         in `node`, not `master`, and must **not** already be a cluster node (the inverse of
         `upgrade-k3s.yml`'s drift assert — makes a rerun a no-op failure, not a re-join).
      2. On the new host: read the node-token from the **primary** master with `slurp` +
         `delegate_to: groups[group_name_master | default('primary-master')][0]` + `no_log: true`
         (same file and same host as `upgrade-k3s.yml:428–458`; `delegate_to` is unaffected by
         `--limit`), and set it as `token` on that master's hostvars so the agent template picks it
         up instead of the inventory `k3s_token`.
      3. `tasks/reconcile-node.yml` with the agent unit vars (as `upgrade-k3s.yml`'s agent play),
         then `download`, then the `k3s_agent` role (it **enables** `k3s-node`; the upgrade play only
         restarts it, so it can't be used to join).
      4. Wait for the node to be Ready (delegated to the primary master); assert its taint and labels.
      Lint-clean and covered like the other playbooks; `--syntax-check` passes. *Done;* handlers are
      flushed after the baseline so the Pi cgroup reboot happens before k3s first starts; the
      taint/label check parses `--node-taint`/`--node-label` out of `extra_agent_args`; the preflight
      also refuses when the control plane isn't already on `k3s_version` (version skew).
- [x] SD-card hygiene, gated by `node_sd_card` (prereq role): `Storage=volatile` + `RuntimeMaxUse`
      in the same journald drop-in as the `SystemMaxUse` cap (other nodes render byte-identical),
      tmpfs for `/var/log/pods` (mounted at once only when the dir is empty or already a tmpfs,
      otherwise fstab-only until reboot), kubelet drop-in in `runtime-config.yml` — it feeds
      `upgrade-k3s.yml`'s restart decision like `kubelet.config`. `node_guard` stays on.
      `node_monitoring`'s journald receivers read `node_monitoring_journald_directory`, which follows
      `node_sd_card` (`/run/log/journal`) — `journalctl --directory` reads only that directory, so
      without it the volatile journal would never reach SigNoz (found in review).
- [x] Bluetooth: new `node_bluetooth` role gated by `node_bluetooth_enabled`, in both `site.yml`'s
      prepare play and `tasks/reconcile-node.yml` (parity test green).
- [x] MetalLB: speaker toleration added on every MetalLB deploy (idempotent; covers `site.yml` and
      `upgrade-k3s.yml` Play 5). Vars-driven (`metal_lb_speaker_extra_tolerations`), empty = today's behaviour, so
      the workload cluster is untouched. No pool/L2Advertisement change. *Done differently:* first
      built as a patch in `k3s_server_post`, then moved into the manifest file after review showed
      k3s re-applies it at every start (see Decisions). `ansible.builtin.replace` anchored on the
      upstream control-plane toleration (unique in v0.14.9–v0.16.0), fails loudly if the anchor is
      gone; `.github/scripts/test-metallb-speaker-tolerations.py` (+ pre-commit hook).
      Rollout to the live cluster is part of Phase 2 (addon-only `upgrade-k3s.yml` run).
- [x] `cluster-health.sh`: warn when a LoadBalancer Service on the management cluster has
      `externalTrafficPolicy: Cluster` (could be announced from k3s-9).
- [x] Molecule/lint coverage as the repo already does; `test-baseline-parity.sh` must still pass
      (whatever `site.yml`'s prepare play gets, `tasks/reconcile-node.yml` gets too). *Done:* no
      molecule scenario added (no Vagrant here; the new code is off by default, so existing scenarios
      cover the "off" path). Instead a `--check` (no `--diff`) of prereq + `node_bluetooth` against
      the real k3s-9 via a scratch inventory: 0 failures.
- **Done when:** lint + molecule green, `join-agent.yml` passes `--syntax-check`, nothing applied to
  any live node, and `upgrade-k3s.yml --check` still passes its preflight (no `k3s-9` in inventory yet).

### Phase 2 — flash, join and verify k3s-9
- [ ] Flash Ubuntu Server 24.04 arm64 with Raspberry Pi Imager (hostname `k3s-9`, user `k3s`, SSH key);
      DHCP reservation for a fixed IP; wired to the kitchen Ethernet port (Wi-Fi left unconfigured).
- [ ] Add `[k3s-9]` / `192.168.50.90` to `inventory/homelab-cluster/hosts.ini` and `k3s-9` under
      `[pi-kitchen:children]` (the per-node group pattern the other hosts use) — only
      now, right before the join (see Phase 1). From here until the join succeeds, don't run
      `upgrade-k3s.yml`.
- [ ] Dry-run `ansible-playbook join-agent.yml -i inventory/homelab-cluster/hosts.ini --limit k3s-9
      --check` (**never `--diff`** — the agent unit/env carries the token), then run it for real.
      Never `site.yml`, with or without `--limit`.
- [ ] Check: node Ready, taint and labels present, no Longhorn disk, otel-agent pod running
      and its logs visible in SigNoz (`k8s.node.name = k3s-9`), `log.source = node` journald logs
      arriving, `bluetoothctl show` lists a powered controller, `/var/log/pods` is tmpfs,
      `journalctl --header` shows a runtime journal only, and kubelet really picked up the drop-in:
      `kubectl get --raw /api/v1/nodes/k3s-9/proxy/configz | jq .kubeletconfig.containerLogMaxSize`
      → `"5Mi"` (k3s must not prune unknown files in `kubelet.conf.d` — unverified until now);
      `hci0` exists (`bluetoothctl list`) — if not, the Pi 4's UART radio may also need Ubuntu's
      `pi-bluetooth` package (add it to `node_bluetooth_packages` in `pi-kitchen.yml`); SigNoz shows
      `log.source = node` logs from k3s-9 (node_monitoring reads `/run/log/journal` there).
- [ ] **Precondition:** homelab-k3s has switched the three `Cluster` Services to `Local` and
      `cluster-health.sh` reports no `Cluster` LoadBalancers on management.
- [ ] Roll out the MetalLB change (addon-only `upgrade-k3s.yml` run, as in CLAUDE.md). Check:
      speaker pod Running on k3s-9; no existing LoadBalancer IP moved to k3s-9 (ARP table from
      another host: none of them resolve to k3s-9's MAC); the bt-proxy LoadBalancer IP (once
      deployed) resolves to k3s-9. After the next primary-master k3s restart, confirm the speaker
      DaemonSet still has the kitchen toleration (it's in the manifest, so k3s's re-apply keeps it).
- [ ] Confirm `upgrade-k3s.yml` preflight (`every inventory host maps to a node`, agent play) and
      `reboot.yml` handle k3s-9; run `cluster-health.sh`.
- [ ] Update `CLAUDE.md` Node Topology (+ inventory description) with k3s-9.
- **Done when:** all checks above pass and the cluster health script is green.

### Phase 3 — Mop-up
Issues found along the way that weren't their phase's job. Before starting: re-check each row still
reproduces and have the user confirm the list.

| # | Found in (phase, date) | Where | Issue | Notes / suspected cause |
|---|---|---|---|---|
| 1 | Phase 0 review, 2026-10-27 | `site.yml` | Nothing stops `site.yml` from running against an already-established cluster (the 2026-09-05 outage); only docs warn. | Add a guard play first: fail if any master already has `/var/lib/rancher/k3s/server/db` or the VIP's `/readyz` answers. Not needed for k3s-9 (joins via `join-agent.yml`), so not this plan's job — fix here or split into its own plan. |
| 2 | Phase 1, 2026-10-27 | `roles/k3s_server/tasks/metallb.yml` | The upstream manifest is fetched with `get_url` and no `force:`, so once `/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml` exists it is never re-downloaded — a `metal_lb_controller_tag_version` bump may not reach the cluster (and the speaker-tag check would then fail). Not reproduced; the upgrade-k3s.yml header says the opposite. | Suspected from reading the task. Check against the 2026-09-06 v0.15.3 → v0.16.0 bump before touching it. |
| 3 | Phase 1, 2026-10-27 | local lint tooling | `pre-commit` isn't installed on this machine, and the local `ansible-lint` (26.4, ansible-core 2.21) reports 40 pre-existing `production`-profile failures that the pinned v6.22.2 hook may not; yamllint flags the gitignored inventories and the vendored `.ansible/collections` copy. | Phase 1 kept the count at 40 (no new failures). Decide which version is the source of truth. |
