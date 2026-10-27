# Kitchen node (k3s-9): join a tainted, SD-card Pi 4 to the management cluster

> **Status:** NOT STARTED (2026-10-27). Phase 0 (this plan) written; Phase 1 next. (checked 2026-10-27)

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
  - `/var/log/pods` on a **tmpfs** (e.g. 128M) rather than log2ram: log2ram rsyncs back to the SD
    card daily and at shutdown, which is wear we don't need since SigNoz holds the history.
    Accepted trade-off: a reboot while SigNoz is unreachable loses that window's node logs.
  - kubelet container-log rotation for this node only: `container-log-max-size=5Mi`,
    `container-log-max-files=2` (keeps the tmpfs small).
- **Bluetooth host stack:** `bluez` installed, `bluetoothd --experimental` via a systemd drop-in
  (bt-proxy needs it for passive scanning, BlueZ ≥ 5.56 — Ubuntu 24.04 ships 5.72), adapter
  unblocked (`rfkill unblock bluetooth`). The container talks to BlueZ over `/var/run/dbus`.
- **Longhorn:** label `node.longhorn.io/create-default-disk=false` **before** the node joins (or the
  default disk gets created on the SD card). Longhorn's DaemonSets don't tolerate the taint anyway, so
  kitchen pods can't mount Longhorn volumes — none of them need one.
- **Kitchen apps use MetalLB, not hostNetwork** (decided 2026-10-27). bt-proxy and the voice
  satellite speak the ESPHome API over plain TCP 6053; HA adds them by IP (no mDNS discovery). Pod
  networking means no port clash between them and no host-network privileges.
  - **MetalLB speaker gets a toleration for `location=kitchen:NoSchedule`**, added by this repo
    whenever MetalLB is installed/upgraded (`roles/k3s_server_post/tasks/metallb.yml`, also run by
    `upgrade-k3s.yml` Play 5 — it re-downloads `metallb-native.yaml`, so the patch must be re-applied
    every time, not done once). Kitchen Services use `externalTrafficPolicy: Local`, so they're
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

### Phase 1 — inventory + roles for an SD-card BLE agent (no node touched)
- [ ] Inventory: new host `k3s-9` in a new group (e.g. `pi-kitchen`) under `node`; host_vars for
      `extra_agent_args` adding `--node-taint location=kitchen:NoSchedule`,
      `--node-label location=kitchen`, `--node-label node.longhorn.io/create-default-disk=false`,
      and the two `--kubelet-arg=container-log-max-*` args (on top of the shared `extra_args`).
- [ ] SD-card hygiene, gated by a var (e.g. `node_sd_card: true`): journald volatile + RuntimeMaxUse
      (must win over `node-hygiene.yml`'s persistent `SystemMaxUse=500M` cap), tmpfs for
      `/var/log/pods` in fstab. Keep `node_guard` on.
- [ ] Bluetooth, gated by a var (e.g. `node_bluetooth: true`): `bluez`, the `--experimental` drop-in,
      rfkill unblock that survives reboot.
- [ ] MetalLB: speaker toleration patch applied after every manifest apply in
      `roles/k3s_server_post/tasks/metallb.yml` (idempotent; covers `site.yml` and `upgrade-k3s.yml`
      Play 5). Vars-driven (e.g. `metal_lb_speaker_extra_tolerations`), empty = today's behaviour, so
      the workload cluster is untouched. No pool/L2Advertisement change.
      Rollout to the live cluster is part of Phase 2 (addon-only `upgrade-k3s.yml` run).
- [ ] `cluster-health.sh`: warn when a LoadBalancer Service on the management cluster has
      `externalTrafficPolicy: Cluster` (could be announced from k3s-9).
- [ ] Molecule/lint coverage as the repo already does; `test-baseline-parity.sh` must still pass
      (whatever `site.yml`'s prepare play gets, `tasks/reconcile-node.yml` gets too).
- **Done when:** lint + molecule green, nothing applied to any live node.

### Phase 2 — flash, join and verify k3s-9
- [ ] Flash Ubuntu Server 24.04 arm64 with Raspberry Pi Imager (hostname `k3s-9`, user `k3s`, SSH key);
      DHCP reservation for a fixed IP; wired to the kitchen Ethernet port (Wi-Fi left unconfigured).
- [ ] **There is no "add a node to a live cluster" playbook** — `site.yml` is fresh-bootstrap-only and
      must never run against the live cluster. Write a small `join-agent.yml` (limit to the new host):
      `tasks/reconcile-node.yml` baseline (prereq, raspberrypi, registries, node_monitoring, …) →
      `download` → read the node-token from the primary master (as `upgrade-k3s.yml` does) →
      `k3s_agent`. Dry-run with `--check` (**never `--diff`** — the agent unit/env carries the token).
- [ ] Run it; check: node Ready, taint and labels present, no Longhorn disk, otel-agent pod running
      and its logs visible in SigNoz (`k8s.node.name = k3s-9`), `log.source = node` journald logs
      arriving, `bluetoothctl show` lists a powered controller, `/var/log/pods` is tmpfs,
      `journalctl --header` shows a runtime journal only.
- [ ] **Precondition:** homelab-k3s has switched the three `Cluster` Services to `Local` and
      `cluster-health.sh` reports no `Cluster` LoadBalancers on management.
- [ ] Roll out the MetalLB change (addon-only `upgrade-k3s.yml` run, as in CLAUDE.md). Check:
      speaker pod Running on k3s-9; no existing LoadBalancer IP moved to k3s-9 (ARP table from
      another host: none of them resolve to k3s-9's MAC); the bt-proxy LoadBalancer IP (once
      deployed) resolves to k3s-9.
- [ ] Confirm `upgrade-k3s.yml` preflight (`every inventory host maps to a node`, agent play) and
      `reboot.yml` handle k3s-9; run `cluster-health.sh`.
- [ ] Update `CLAUDE.md` Node Topology (+ inventory description) with k3s-9.
- **Done when:** all checks above pass and the cluster health script is green.

### Phase 3 — Mop-up
Issues found along the way that weren't their phase's job. Before starting: re-check each row still
reproduces and have the user confirm the list.

| # | Found in (phase, date) | Where | Issue | Notes / suspected cause |
|---|---|---|---|---|
| — | — | — | (none yet) | — |
