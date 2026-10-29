# Kitchen node (k3s-9): join a tainted, SD-card Pi 4 to the management cluster

> **Status:** IN PROGRESS — Phase 3 (Mop-up). Phase 2 fully verified 2026-10-29. Rows 1–5, 7, 9–11, 13–15, 17 fixed; 6, 8, 12, 16 moved to homelab-k3s; both clusters on k3s v1.36.5+k3s1 / kube-vip v1.2.4 / MetalLB v0.16.1. Open: rows 18 (`upgrade-k3s.yml` `--limit`/role tags), 19 (k3s-w1 rancher dirs 644). Rows 10 and 17 verified live 2026-10-29. (checked 2026-10-29)

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
- **Validated 2026-10-27:** `upgrade-k3s.yml --check --tags always` against homelab — all preflight
  assertions pass (incl. "every inventory host maps to a node" with the empty `pi-kitchen` group),
  `changed=0` everywhere. `pre-commit run --all-files` (pinned hooks): every hook touching Phase 1
  code passes, incl. the new tolerations test and baseline parity; the failing hooks (ansible-lint 35,
  yamllint, shellcheck, whitespace fixers, k3s bootstrap test) fail identically on `3081dc6`, the
  commit before Phase 1 — Mop-up rows 3–5. Molecule not run (no Vagrant here); accepted.

### Phase 2 — flash, join and verify k3s-9 ✅ 2026-10-28
- [x] Flash Ubuntu Server 24.04 arm64 (hostname `k3s-9`, user `k3s`, SSH key); fixed IP `192.168.50.90`; wired.
- [x] `[k3s-9]` / `192.168.50.90` in `inventory/homelab-cluster/hosts.ini`, `k3s-9` under `[pi-kitchen:children]`.
- [x] `join-agent.yml --limit k3s-9 --check` (no `--diff`), then for real. Never `site.yml`.
- [x] Checks: node Ready (`v1.36.4+k3s1`); taint `location=kitchen:NoSchedule`, labels `location=kitchen`,
      `create-default-disk=false`; no Longhorn node object; otel-agent + smartctl-exporter Running; SigNoz has
      `k8s.node.name = k3s-9` pod logs and `log.source = node` journald logs (k3s-node, kernel, ssh);
      `hci0` powered, `Experimental = true`, not rfkill-blocked (**no `pi-bluetooth` needed**); `/var/log/pods`
      is a 256M tmpfs; journald writes `/run/log/journal` only; `configz` → `containerLogMaxSize "5Mi"`,
      `containerLogMaxFiles 2` (**k3s keeps foreign files in `kubelet.conf.d`**).
- [x] Precondition: every management LoadBalancer is `Local` (14/14, 2026-10-28).
- [x] MetalLB rollout (`upgrade-k3s.yml --tags addons`): speaker tolerates `location=kitchen` and runs on
      k3s-9; no existing LB IP resolves to k3s-9's MAC (ARP check of all 13 IPs).
- [x] After the next k3s-7 k3s restart, confirm the speaker DaemonSet still has the kitchen toleration
      (it's in k3s-7's manifest; k3s-1's copy is `.skip`ped). 2026-10-29 (v1.36.5 rollout): toleration present,
      speaker on all 5 nodes. bt-proxy `.203` is announced by k3s-9 (ServiceL2Status + ARP = k3s-9's MAC, 6053 open).
- [x] `upgrade-k3s.yml` preflight passes with k3s-9; agent play `--check` → k3s-9 `changed=0`; `reboot.yml`
      includes it (`serial: 1`); `cluster-health.sh` has no FAIL (2 WARNs not k3s-9: Mop-up 9, 12).
- [x] `CLAUDE.md` Node Topology + inventory description.
- **Done:**
  - **k3s-9's image had no `noble-updates`/`noble-backports`** in `ubuntu.sources` (but shipped `-updates`
    packages), so `apt install acl` failed. `prereq` baseline now adds the pockets to a main stanza that lists only
    the release suite (no-op on every other node). Then the apt-cacher served a spliced `noble-updates/InRelease`
    (`BADSIG` fleet-wide) — Mop-up 6; root-cause fix `VfileUseRangeOps=-1` pushed in homelab-k3s.
  - **`node_monitoring` failed on a not-yet-k3s node**: the traverse ACL on `agent/containerd`, which k3s creates
    at first start. The role now skips missing dirs; `join-agent.yml` re-runs it once the node is Ready.
    `join-agent.yml --check` can't get past "Manage k3s service" (no unit yet) — expected.
  - **Addon manifests went to a random master.** `groups['master']` has no stable order (k3s-7 is in
    `primary-master` and `pi-master`; ansible-core 2.21 put k3s-1 or k3s-7 first), and the k3s_server role
    default `group_name_master: master` made the "first master" `groups['master'][0]`. k3s-1 had held identical
    MetalLB/kube-vip manifests since 2026-09-06 and re-applied them at every start — it would have undone the
    toleration (and any future version bump). Now `k3s_server_addon_master` (first of `primary-master`) and
    `tasks/primary-only-manifests.yml` (`<file>.skip` on other masters, removed on the primary — k3s v1.36.4
    `pkg/deploy` ignores skipped files, deletes nothing). k3s-1 has the 3 `.skip` files. Test
    `test-addon-master.py`. Workload: only k3s-w1 holds them, no strays.
  - `cluster-health.sh` checks the Longhorn CSI driver and iscsid only on Longhorn nodes.

### Phase 3 — Mop-up
Issues found along the way that weren't their phase's job. Before starting: re-check each row still
reproduces and have the user confirm the list.

Re-checked and confirmed with the user 2026-10-29. Done so far (branch `homelab-current`, pushed):
`629a242` upstream merge (6 commits; RedHat reboot gated off the live path via `prereq_allow_reboot`),
`54faa23` lint green, `3b6bb11` MetalLB build-then-install, `969423b` version bumps, `c54f860` MetalLB
cleanup race. Rolled out 2026-10-29: workload (`-e k3s_upgrade_drain=false`, then `--tags addons,verify`),
then homelab — every node v1.36.5+k3s1, no reboots needed.

| # | Found in (phase, date) | Where | Issue | Notes / suspected cause |
|---|---|---|---|---|
| 1 | Phase 0 review, 2026-10-27 | `site.yml` | Nothing stops `site.yml` from running against an already-established cluster (the 2026-09-05 outage); only docs warn. | Add a guard play first: fail if any master already has `/var/lib/rancher/k3s/server/db` or the VIP's `/readyz` answers. Not needed for k3s-9 (joins via `join-agent.yml`), so not this plan's job — fix here or split into its own plan. **Fixed 2026-10-29:** first play of `site.yml` (`hosts: all`, `tags: always`, `any_errors_fatal`) fails when a master has `/var/lib/rancher/k3s/server/db` or `--limit` leaves a master out; `-e site_allow_existing_cluster=true` overrides. Verified `--check --tags <none>` on both clusters + `--limit k3s-9`. Test `test-site-guard.py`. |
| 2 | Phase 1, 2026-10-27 | `roles/k3s_server/tasks/metallb.yml` | The upstream manifest is fetched with `get_url` and no `force:`, so once `/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml` exists it is never re-downloaded — a `metal_lb_controller_tag_version` bump may not reach the cluster (and the speaker-tag check would then fail). Not reproduced; the upgrade-k3s.yml header says the opposite. | Suspected from reading the task. Check against the 2026-09-06 v0.15.3 → v0.16.0 bump before touching it. **2026-10-29: not reproduced** — ansible-core 2.21 `get_url` re-downloads every run (raw.githubusercontent ignores If-Modified-Since). Superseded by row 11's fix (`force: true` on a build file). |
| 3 | Phase 1, 2026-10-27 | lint (whole repo) | `pre-commit run --all-files` isn't green: pinned ansible-lint v6.22.2 reports 35 `production`-profile failures (local 26.4 reports 40); yamllint errors in `pre-reqs.yml`, `k3s_restore_from_backup.yaml`, `inventory/sample/group_vars/all.yml`. Identical on `3081dc6`. | Pre-existing; Phase 1 added none. `pre-commit` now installed (`~/.local/bin`). **Fixed 2026-10-29** (`54faa23`): `pre-commit run --all-files` green. |
| 4 | Phase 1, 2026-10-27 | `.github/scripts/test-k3s-server-bootstrap.sh` | Fails: still greps `roles/k3s_server/tasks/main.yml` for `map('extract', hostvars, 'ansible_hostname')`. | Broken since `7f37374` switched to `ansible_facts['hostname']`; the test wasn't updated. Fails on `3081dc6` too. **Fixed 2026-10-29** by the upstream merge (`629a242`). |
| 5 | Phase 1, 2026-10-27 | whitespace + `cluster-health.sh` | pre-commit fixers rewrite `k3s_restore_from_backup.yaml`, `pre-reqs.yml`, `roles/prereq/files/multipath.conf`, `roles/prereq/templates/apt-proxy`, `sudoers-k3s-root` (tabs/EOF/trailing spaces — reverted, not committed); shellcheck SC2086/SC2046/SC2116 in `cluster-health.sh` (version-skew lines, Longhorn CSI line). | Pre-existing (`dde9230` for the script). Check `apt-proxy`/`multipath.conf`/sudoers rendering before letting the fixers change them. **Fixed 2026-10-29** (`54faa23`); `apt-proxy`/`multipath.conf` excluded from end-of-file-fixer (template keeps trailing newlines — rendering would change). |
| 6 | Phase 2, 2026-10-28 | apt-cacher-ng (homelab-k3s `apt-cacher`) | Served a spliced `noble-updates/InRelease` (same size as upstream, same `Date`, wrong hashes from line 328 on, `BADSIG` on every node — k3s-7 too); cached copy written 07:56, after the 03:20 daily index purge. Third time (2026-09-18, 09-19). Fixed for now by deleting the cached file + `.head`. | Root cause per the purge CronJob's own comment: a range/resumed fetch of a volatile file from a mirror pool (`ports.ubuntu.com` backends) that changed between requests. apt-cacher-ng's `VfileUseRangeOps` (default `1`) is exactly that path; set `VfileUseRangeOps: -1` (whole-file fetch for volatile files). Belongs in homelab-k3s; image is `sameersbn/apt-cacher-ng:latest` (3.7.4) — pin it too. 2026-10-28: Deployment arg `VfileUseRangeOps=-1` pushed in homelab-k3s and rolled out (daemon runs with it; proxied InRelease = upstream for noble/-updates/-security). Follow-up: if no `BADSIG` by ~end of Nov, drop the CronJob's index-purge half (keep the `.deb` purge). **Moved to homelab-k3s 2026-10-29** (user): fix is live there; re-check for `BADSIG` ~end of Nov in that repo. |
| 7 | Phase 2, 2026-10-28 | `roles/k3s_server/defaults/main.yml` (`server_init_args`), `tasks/main.yml` (cluster-init), `k3s_server_post/tasks/{cilium,calico}.yml` | Still use `groups[group_name_master][0]` (= `groups['master'][0]`, unstable order — see Phase 2) to pick the `--cluster-init` master and the cilium/calico manifest master. | Bootstrap-only (`site.yml`) / unused CNIs, so no live effect; a fresh bootstrap could init on a random master. Switch to `k3s_server_addon_master` (or a shared `k3s_primary_master`). **Fixed 2026-10-29:** one `k3s_primary_master` (`vars/k3s-primary-master.yml`, `vars_files` in every play that needs it) replaces every `groups[...][0]`/`[1:]`; joins loop `difference([k3s_primary_master])`; calico/cilium dropped `run_once` (it evaluated the `when` on the first host only). `upgrade-k3s.yml --check` on both clusters: no unit change. Test `test-addon-master.py`. |
| 8 | Phase 2, 2026-10-28 | MetalLB speakers (all 5) | `http: TLS handshake error from 192.168.50.97: client sent an HTTP request to an HTTPS server` every ~30s on every speaker. | Pre-existing (old speakers too). Probably a scraper hitting the speaker's HTTPS metrics port over HTTP (k8s-infra/SigNoz on k3s-7?). **Won't fix here — moved to homelab-k3s 2026-10-29** (user): MetalLB v0.16.0 made speaker metrics HTTPS-only; the scraper on k3s-7 still uses HTTP (scrape config). |
| 9 | Phase 2, 2026-10-28 | k3s-8 | `upgrade-k3s.yml --check --tags agents`: k3s-8 has pending changes (k3s-node-guard script, `registries.yaml`, traverse ACL on `agent/containerd`) → **the next run restarts k3s-node on k3s-8**. `cluster-health.sh` also warns: failed `systemd-networkd-wait-online.service`. | Repo changes not yet rolled to k3s-8 since its last run. Not k3s-9's job; plan a run (k3s-8 is never drained). **Fixed 2026-10-29** by the v1.36.5 rollout (drift was on k3s-1/6/7/8, not just k3s-8). The `systemd-networkd-wait-online` warning remains (harmless, from k3s-8's last boot). |
| 10 | Phase 2, 2026-10-28 | k3s-9 `/var/log/journal` | 5 persistent journal files (~40 MB) from before `Storage=volatile` stay on the SD card; never rotated or read again (journalctl still lists them). | Harmless. `node_sd_card` could remove `/var/log/journal` once volatile. **Fixed 2026-10-29:** `node-hygiene.yml` removes `/var/log/journal` on `node_sd_card` nodes, restarting journald first when the drop-in changed or the dir still exists. `--check`: only k3s-9 changes. |
| 11 | Phase 2, 2026-10-28 | `roles/k3s_server/tasks/metallb.yml` | `Download to first master` reports `changed` in `--check` even when the file exists (checksum_src of an empty body) — noisy dry runs. | Related to row 2 (`get_url` without `force:`). **Fixed 2026-10-29** (`3b6bb11`), worse than recorded: every run rewrote the live manifest with plain upstream, then edited it in place, inside the dir k3s watches. Now built at `metallb_manifest_build`, verified, then copied in (`test-metallb-speaker-tolerations.py`). |
| 12 | Phase 2, 2026-10-28 | ArgoCD `media-server` | `cluster-health.sh` warns `Synced/Progressing`. | Not this plan (homelab-k3s). **Won't fix here — moved to homelab-k3s 2026-10-29** (user). |
| 13 | Mop-up, 2026-10-29 | `roles/k3s_agent` (`group_name_master: master` default) | The agent templates read the join token from `hostvars[groups['master'][0]]`, but the playbooks set it on `primary-master` (k3s-7) — with the unstable order (row 7) an agent could fall back to the inventory `k3s_token`. Unverified. | Fix with row 7: one shared primary-master variable across `k3s_server`, `k3s_server_post`, `k3s_agent`. Row 7 is also wider: `join_master.yml`, `main.yml` (joins, `length > 1`), `fetch_k3s_init_logs.yml`, `k3s_server_post` metallb temp dir/CRs. **Confirmed + fixed 2026-10-29:** inventory `k3s_token` is stale (hash ≠ node-token; both live agent units hold the right one). Template reads `hostvars[k3s_primary_master]['token']` with no fallback (fails loudly); the token play runs on `k3s_cluster` so an agent-only `--limit` still sets it. |
| 14 | Mop-up, 2026-10-29 | `roles/k3s_server_post/tasks/metallb.yml` | Workload v0.16.0 → v0.16.1: "Delete outdated metallb replicas" ran before k3s applied the new manifest, deleted the current RS, the Deployment recreated it, the bump scaled it to 0 → "Wait for MetalLB resources" timed out on it and failed the addons play. | **Fixed 2026-10-29** (`c54f860`): wait for the Deployment's target tag, then its rollout, before cleanup; suffix tag match. Test in `test-metallb-namespace.py`. Homelab rollout: no retries. |
| 15 | Mop-up, 2026-10-29 | `roles/k3s_server_post/tasks/main.yml` | `--tags metallb` runs nothing in `metallb.yml`: a tag on `include_tasks` without `apply:` covers only the include. Pre-existing (code review). | Add `apply: {tags: metallb}` (same for calico/cilium). **Fixed 2026-10-29:** the 7 tagged `include_tasks` in roles use `apply: {tags: …}` (verified in a scratch playbook; `--tags addons` unaffected). Test `test-include-apply-tags.py`. `upgrade-k3s.yml` still can't select them (row 18). |
| 16 | Mop-up, 2026-10-29 | homelab-k3s `homeassistant/` | Homelab rollout drained the HA Pi; the only `group=hass` pods left were matter-server + mosquitto-exporter on k3s-8 (no `platform: pi`), so hass/esphome/zigbee2mqtt/matter-hub (Pi + required podAffinity) stayed Pending ~35 min. Unblocked by deleting those two pods. | **Moved to homelab-k3s:** PR #103 (Pi selectors + `homeassistant/scripts/check-placement.py`). matter-server's selector was removed there 2026-05-04 (`3f75815`). |
| 17 | Mop-up, 2026-10-29 | `roles/node_monitoring` traverse ACLs (`node_monitoring_traverse_dirs`) | Every k3s (re)start resets `agent/containerd`'s mode, which drops the ACL mask to `---`: the `otelcol-contrib:--x` entry stays but is ineffective (`#effective:---`) until the next `upgrade-k3s.yml` re-grants it — so every node shows this task `changed` after a restart (all 8 on 2026-10-29), and host-level collection under that dir is dark in between. | Pre-existing. Confirmed otelcol could not read `containerd.log` on k3s-9 after its restart. **Fixed 2026-10-29:** `node_monitoring` installs `<unit>.service.d/60-otelcol-log-acl.conf` (`ExecStartPost=-/usr/bin/setfacl -m u:otelcol-contrib:x <dir>`, which recalculates the mask) on `k3s` (masters) or `k3s-node` (agents) via `node_monitoring_k3s_unit`, and removes stale copies. It only reloads systemd and never restarts k3s. The chmod lands 4–6s before READY on all 8 nodes. `reset` removes it. Test: `test-node-monitoring-acl-dropin.py`. Live 2026-10-29: rolled out on both clusters with no k3s restarts. After a k3s-9 restart the mask is `--x` and the log is readable (k3s-w1 excepted, see row 19). |
| 18 | Mop-up, 2026-10-29 | `upgrade-k3s.yml` preflight | `--limit <host>` fails "Assert every inventory host maps to an actual cluster node" (`object of type 'dict' has no attribute 'hostname'`): the check reads facts of hosts the limit left out. `--tags hygiene`/`static_hosts` also never reach the prereq tasks (tags don't pass through `tasks/reconcile-node.yml`'s untagged include). | Pre-existing. Either gather facts for all hosts in the preflight, or refuse `--limit` with a clear message; document that per-role tags only work in `site.yml`. |
| 19 | Mop-up, 2026-10-29 | k3s-w1 `/var/lib/rancher`, `/var/lib/rancher/k3s` | Both are mode `644` (no `x`) on k3s-w1 only, since its install on 2026-04-24; every other node has `755`. Non-root users can't traverse them, so otelcol has likely never read w1's `containerd.log`. | Pre-existing. Nothing in the repo sets these modes. Suggested fix: a prereq task that ensures `0755` on both, with a test. |
