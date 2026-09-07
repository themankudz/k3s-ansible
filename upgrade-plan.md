# k3s Cluster Upgrade Plan

## 2026-09-05 incident summary

An attempt to bump k3s from `v1.33.6+k3s1` to `v1.33.10+k3s1` on the 3-master
workload cluster by running `site.yml` (the previous, pre-`upgrade-k3s.yml`
practice) caused a full cluster outage, from two independent root causes.

**Root cause 1 — `site.yml` is fresh-bootstrap-only.** A 53-commit upstream
merge (`timothystewart6/k3s-ansible`) restructured `roles/k3s_server` around a
fresh-bootstrap model. `site.yml` has no `serial:` anywhere, so it stopped
`k3s.service` on all three masters in one step, then tried to bring up only
the first master alone via a transient `k3s-init` unit and waited for its own
`/readyz`. A lone etcd member of an already-established 3-member cluster can
never reach quorum by itself (needs 2-of-3 votes, but its peers were stopped),
so the play deadlocked with every master's real service stopped. Confirmed in
etcd logs (`dial tcp <peer>:2380: connection refused`); recovered by manually
starting `k3s.service` on all three nodes at once so they could re-form
quorum from existing on-disk data.

**Root cause 2 — a poisoned containerd config template (independent bug).**
`roles/prereq/files/containerd-config.toml.tmpl` was missing the
`{{ template "base" . }}` directive that tells k3s to extend its
auto-generated containerd config rather than replace it outright. The file's
own header comment asserted the opposite of the truth. It had been deployed
to all three nodes earlier in the same session (harmlessly, since it takes a
containerd restart to bite) and detonated when the etcd-recovery restart
above regenerated `config.toml` from the poisoned template on every node at
once — wiping the CRI runtime config, CNI `bin_dir`/`conf_dir`, and the
`certs.d` registry-mirror wiring. Every node went `NotReady` with
`NetworkPluginNotReady: cni plugin not initialized`, and Longhorn volumes
went `faulted`/`unknown` as a downstream effect (instance-manager pods
couldn't schedule). Fixed by adding the missing directive and rolling it out
node-by-node before re-attempting anything else.

Both fixes, plus a new safe rolling-upgrade playbook (`upgrade-k3s.yml`)
adapted from the official (separate) `k3s-io/k3s-ansible` project's
`playbooks/upgrade.yml`, landed the same session. See `upgrade-k3s.yml`'s
header comment for the full design rationale, and `CLAUDE.md`'s "Fleet
maintenance" section for the day-to-day usage.

**Never run `site.yml` against an established cluster.** It remains
fresh-bootstrap-only by upstream design; there is no automated in-place
upgrade path in the upstream project to adopt. Use `upgrade-k3s.yml` instead.

## `upgrade-k3s.yml` is now the primary fleet-maintenance playbook (2026-09-07)

`upgrade-k3s.yml` originally only reconciled part of the node baseline
(`raspberrypi`, `k3s_custom_registries`, `longhorn_node_fix`, `node_longhorn`,
`node_nfs`, plus the kubelet/containerd config files copied inline). Everything
else — `prereq` proper, the mail relay, unattended-upgrades — either lived in
`site.yml` (bootstrap-only, never run against a live cluster) or in a separate
one-off playbook nobody ran regularly, so node config could drift silently
between upgrade runs.

`upgrade-k3s.yml` now converges the **full** node baseline on every run, via a
shared `tasks/reconcile-node.yml` included by both its master and agent plays:
`prereq` (baseline, then runtime-config), `raspberrypi`, `k3s_custom_registries`,
`longhorn_node_fix`, `node_longhorn`, `node_nfs`, `mail_relay`, and
`unattended_upgrades`. It stays fully idempotent — a second run against an
already-converged fleet reports zero changes — and only restarts k3s when
something that actually requires it changed (kubelet/containerd config, the
rendered systemd unit, custom registries, or the k3s version). `mail_relay`
and `unattended_upgrades` never feed the restart decision.

`site.yml`'s "Prepare k3s nodes" play applies the same role set (`mail_relay`
and `unattended_upgrades` added there too), so a freshly bootstrapped node
converges to the same baseline as a routinely maintained one. The two role
lists are kept in sync by `.github/scripts/test-baseline-parity.sh` (a
pre-commit hook), not by sharing a single meta-role — see that script for the
small, documented exclusion list (`download`, `lxc`) of roles that
legitimately belong on only one side.

**Now redundant for routine use** (each still works standalone, e.g. for a
single-node `--limit` run, but `upgrade-k3s.yml` supersedes them for day-to-day
maintenance): `setup-mail.yml`, `prereq.yaml`, `pre-reqs.yml`, `storage.yml`.

## Roles excluded from the shared baseline

Three roles that `site.yml`'s "Prepare k3s nodes" play could plausibly run
are deliberately **not** part of the `prereq`/`mail_relay`/`unattended_upgrades`
baseline this work folded into `tasks/reconcile-node.yml`:

- **`node_monitoring`** — duplicates the in-cluster SigNoz `k8s-infra`
  DaemonSet, which already collects these nodes' metrics/logs from inside the
  cluster. Only relevant for non-k3s VMs via `infra.yml`.
- **`lxc` / `proxmox_lxc`** — both are reboot-handler-driven roles for tuning
  a k3s node that itself runs *inside* a Proxmox LXC container. `lxc` also
  references `templates/rc.local.j2`, which does not currently exist in the
  role, so including it unconditionally would hard-fail. Excluded "for now" —
  see the migration note below.
- **`base_system`** — a strict subset of `prereq` with a different
  `base_ip_forward` default (`false`, wrong for a k3s node that must forward
  pod traffic). `infra.yml`-only, not applicable to k3s nodes.
- **`hermes_agent`** — targets a separate, unrelated inventory by design.

**Future work — Proxmox migration.** `lxc`/`proxmox_lxc` are excluded from
the shared baseline "for now" pending the Unraid→Proxmox migration tracked at
`~/Development/GenAI_Projects/homelab-upgrade/unraid-virtualisation/unraid-to-proxmox-migration.md`
(a sibling repo, not part of this one). Important nuance found on inspection:
that plan's Phase 5 puts the k3s VM nodes (`k3s-3`, `k3s-5`) on Proxmox as
**VMs**, not LXC containers — only Plex and the OTel collector move into
Proxmox LXC (Phase 4/6). So `proxmox_lxc` (which tunes `/etc/pve/lxc/<id>.conf`
for a k3s node running *inside* an LXC container) may never become relevant to
this repo at all; the more likely future need is a `proxmox` host group plus
PBS-backed backup roles for the hypervisor layer itself, not a k3s-node role.
The migration doc currently marks Phase 0 (drive replacement) and Phase 1.5
(physical rewiring) complete, with Phases 2–8 (Proxmox install through
post-migration verification) still open — re-read that doc's current state
before doing any related work here, since it evolves independently of this
repo.

## Staged version-hop plan

Kubernetes/k3s control-plane upgrades must move one minor version at a time.
`upgrade-k3s.yml` enforces this (`k3s_upgrade_max_minor_skew: 1` by default).
The stepping-stone hop through a k3s release bundling etcd 3.5.26 is
mandatory: etcd's own maintainers describe no safe direct upgrade path from
3.5 straight to 3.6 (which k3s starts shipping from v1.34 onward).

| Step | Target k3s version | Notes |
| :--- | :--- | :--- |
| 0 (done) | `v1.33.10+k3s1` | Same-minor bump; picks up etcd v3.5.26, the mandatory stepping stone before etcd 3.6. |
| 1 (done on workload-cluster, 2026-09-06) | `v1.34.11+k3s1` | First hop into the etcd 3.6 line. Binary rollback is no longer possible past this point — an etcd snapshot restore becomes the only path back. `upgrade-k3s.yml` ran clean end-to-end (`-e k3s_upgrade_drain=false`); homelab-cluster not yet upgraded. See "GPU Operator autoUpgrade side effect" below — an unrelated but real gotcha this hop surfaced on workload-cluster. |
| 2 (done on workload-cluster, 2026-09-06) | `v1.35.8+k3s1` | Same etcd/containerd as Step 1 (etcd v3.6.14-k3s1, containerd v2.2.7-k3s1). Kubernetes 1.35 removed cgroup v1 support (kubelet won't start without cgroup v2) and the `--pod-infra-container-image` kubelet flag — checked both before upgrading: all 3 workload nodes already run `cgroup2fs`, and the flag isn't set anywhere in this repo. Clean, no GPU Operator involvement (ClusterPolicy stayed `ready`, k3s-w3 never cordoned). |
| 3 (done on workload-cluster, 2026-09-06) | `v1.36.4+k3s1` | Final step of this staged plan. Containerd bumped again (`2.2.7-k3s1` -> `2.3.4-k3s1.36`) — the same kind of change that triggered the GPU Operator incident at Step 1 — but this time it did **not** re-trigger a driver reconcile at all (no `GPUDriverUpgrade` events fired), so the earlier hypothesis that any containerd bump alone triggers it was wrong; something more specific about the Step 1 transition did. The `deleteEmptyDir` fix (see below) remains in place as a safety net regardless. Only other v1.36-relative change found: a `kube-controller-manager` metric rename (`volume_operation_total_errors` -> `volume_operation_errors_total`) — not upgrade-blocking, but worth checking SigNoz dashboards/alerts don't reference the old name. kube-vip/MetalLB images matched their target tags, VIP reachable, Longhorn stayed healthy throughout.|
| Patch (done on homelab-cluster, 2026-09-06) | `v1.33.10+k3s1` | homelab-cluster (management) was still on `v1.33.6+k3s1` live despite its group_vars already targeting `v1.33.10+k3s1` — this is the exact version bump whose old `site.yml`-based attempt caused the 2026-09-05 outage described at the top of this file; this run used the new `upgrade-k3s.yml` and completed cleanly (`-e k3s_upgrade_drain=false`, chosen deliberately over the default `drain: true` given this cluster's history, even though CPU headroom here — 25-38% — is genuinely good). Surfaced a real bug in `roles/k3s_server_post/tasks/metallb.yml`'s "Delete outdated metallb replicas" task (see below) — fixed same session. ArgoCD, PiHole (both instances), Home Assistant, and Longhorn all verified healthy afterward. This was homelab-cluster's first-ever run of the staged plan; steps 1-3 (the `v1.34`/`v1.35`/`v1.36` hops) have only been done on workload-cluster so far. |
| 1 (done on homelab-cluster, 2026-09-06) | `v1.34.11+k3s1` | First hop into etcd 3.6 on homelab-cluster — binary rollback no longer possible here from this point on (etcd snapshot restore only). Ran with `-e k3s_upgrade_drain=false` (same rationale as the patch step). No GPU Operator involvement — this cluster runs no GPU workloads at all (`gpu-operator` namespace doesn't exist here). MetalLB stayed on a single controller ReplicaSet throughout (version unchanged this hop, v0.16.0), so the patch step's stale-RS bug class didn't apply. All 4 nodes (k3s-1, k3s-6, k3s-7, k3s-8) verified at target version and `Ready=True`; each node's `Ready` condition `lastTransitionTime` predates the upgrade entirely, confirming no node ever actually went `NotReady`. ArgoCD, both PiHole instances, Home Assistant, and kube-vip (VIP reachable) all verified healthy with no restarts attributable to the upgrade window. |
| 2 (done on homelab-cluster, 2026-09-06) | `v1.35.8+k3s1` | Same etcd/containerd line as Step 1. All 4 nodes confirmed on cgroup v2 (`cgroup2fs`) before upgrading, since 1.35 dropped cgroup v1 support. Ran with `-e k3s_upgrade_drain=false`. Play recap and final-verification play both passed clean (`failed=0` on every host, all 4 nodes reporting target `kubeletVersion`, kube-vip/MetalLB image assertions all passed) — the background-task runner reported an ambiguous `exit code -1` on this run because the detached process lost its real exit status, not because Ansible actually failed; re-verified directly against the live cluster to confirm. No GPU Operator (still N/A on this cluster) and no MetalLB stale-RS issue (version unchanged). No outage: every node's `Ready` `lastTransitionTime` still predates the upgrade, no `NodeNotReady` events, and ArgoCD/PiHole/Home Assistant pod restarts all predate the upgrade window. |
| 3 (done on homelab-cluster, 2026-09-06) | `v1.36.4+k3s1` | **Final step of the staged plan — homelab-cluster now matches workload-cluster's fully completed progression.** Containerd bumped `2.2.7-k3s1` -> `2.3.4-k3s1.36` (same bump that triggered the workload-cluster GPU Operator incident at its own Step 3 — N/A here, no GPU Operator on this cluster). Ran with `-e k3s_upgrade_drain=false`. Play recap clean (`failed=0` on every host), final-verification play confirmed all 4 nodes at target version, kube-vip/MetalLB image assertions passed, VIP reachable. No outage: every node's `Ready` `lastTransitionTime` still predates the upgrade, no `NodeNotReady` events, ArgoCD/PiHole/Home Assistant pod restarts all predate the upgrade window, MetalLB stayed on a single healthy controller ReplicaSet. |

## MetalLB stale-ReplicaSet bug in k3s_server_post (fixed 2026-09-06)

`roles/k3s_server_post/tasks/metallb.yml`'s "Delete outdated metallb
replicas" task used to only inspect `.items[0]` from
`kubectl get replicasets -l component=controller,app=metallb` — the API
doesn't guarantee ordering, so once the new controller Deployment had
already rolled out (new ReplicaSet at its desired replica count, old one
scaled to 0), `.items[0]` could just as easily be the already-correct new
RS, silently leaving the stale old one completely undetected and
undeleted. That stale RS still carries the same `component=controller,
app=metallb` labels, so the very next task ("Wait for MetalLB resources")
selector-matches it too — and since a scaled-to-0 RS's
`status.readyReplicas`/`fullyLabeledReplicas`/`availableReplicas` can never
reach `1`, `kubectl wait` exhausts every retry (`download_retries: 5` x
`metal_lb_available_timeout: 240s` + `download_delay: 10s` each — over 20
minutes) and eventually fails the whole play.

Hit for real upgrading homelab-cluster's MetalLB from `v0.15.3` (years-old,
never bumped before) to `v0.16.0` — this bug didn't surface across
workload-cluster's Step 1/2/3 hops because MetalLB there was already at
`v0.16.0` from its initial deployment, so those runs never created a new
controller ReplicaSet in the first place (no version change to react to).
Worked around live by manually `kubectl delete rs <stale-name>`, which let
the already-running `kubectl wait` retry loop pick up immediately. Fixed
properly in the task itself: it now iterates every matching ReplicaSet and
deletes any whose image doesn't match `metal_lb_controller_tag_version`,
regardless of API return order.

## GPU Operator autoUpgrade side effect (workload-cluster only, fixed 2026-09-06)

Bumping k3s on workload-cluster restarts containerd on every master (it's
bundled and versioned with k3s — this hop moved it `2.2.2-k3s1.33` ->
`2.2.7-k3s1`). On k3s-w3 (the cluster's only GPU node), this made the NVIDIA
GPU Operator's `ClusterPolicy` (`driver.upgradePolicy.autoUpgrade`, chart
default `true`, not set in this repo) immediately trigger its own driver
reconcile/upgrade cycle on that node — nothing to do with `upgrade-k3s.yml`
itself, a separate operator reacting to the runtime change underneath it.

That cycle failed deterministically in under 2 seconds every time: the
`pod-deletion-required` step's drain helper refused to evict pods with local
`emptyDir` storage (`metrics-server` and `tdarr`, the latter's 50Gi `/temp`
scratch dir — see the media-server section of `homelab-k3s/CLAUDE.md`),
leaving `k3s-w3` cordoned indefinitely with
`nvidia.com/gpu-driver-upgrade-state=upgrade-failed`. Clearing that label
without changing the policy just re-triggers and re-fails the same cycle
in ~2 seconds — not a real fix.

Fixed in `homelab-k3s/gpu-operator/values.yaml` by setting
`driver.upgradePolicy.gpuPodDeletion.deleteEmptyDir: true` (both pods'
emptyDir contents are disposable). **Gotcha**: the chart's Helm value is
`gpuPodDeletion`, not `podDeletion` — that name only exists on the
resulting `ClusterPolicy` CR (and matches the failing reconciler step's
name, `ProcessPodDeletionRequiredNodes`), so a values.yaml key named
`podDeletion` is silently dropped by Helm with no error, leaving the CRD's
own `false` default in place. Always check `helm show values <chart> --version
<v>` before assuming a CR's own field names are the Helm-configurable keys.

After the fix synced, clearing the stale label let the operator complete
the driver reinstall (`nvidia-driver-daemonset` pod cycled cleanly,
`ClusterPolicy` state went `ready`) — but it did **not** auto-uncordon
`k3s-w3` afterward, because it had separately recorded (from an earlier
failed attempt) an annotation saying the node was "already unschedulable"
before this cycle started, and treats that as an externally-managed cordon
it shouldn't override. Manual `kubectl uncordon` was required even though
the upgrade itself reached `upgrade-done`.

At each step:

```bash
# 1. Bump k3s_version (and, if warranted by that release's notes, kube_vip_tag_version /
#    metal_lb_speaker_tag_version / metal_lb_controller_tag_version) in
#    inventory/<cluster>/group_vars/all.yml. Read that k3s release's upgrade notes first.

# 2. Run the rolling upgrade — etcd snapshot, preflight asserts, and per-node
#    health gates are all automatic:
ansible-playbook upgrade-k3s.yml -i inventory/<cluster>/hosts.ini

# 3. Confirm Play 6 (verify) passed cleanly before starting the next hop.
```

On workload-cluster specifically, pass `-e k3s_upgrade_drain=false` until CPU
headroom and PodDisruptionBudgets there are improved (see the playbook
header for the exact numbers this was checked against) — see `CLAUDE.md`.

## Rollback

- **Same-minor bump** (e.g. a `v1.33.x` patch bump): practical rollback is
  just re-running `upgrade-k3s.yml` with the previous `k3s_version`.
- **Once a hop has crossed into a k3s release bundling etcd 3.6** (v1.34+):
  binary rollback is no longer possible — etcd does not support a 3.6 → 3.5
  downgrade. The pre-upgrade etcd snapshot that `upgrade-k3s.yml` takes
  automatically (`k3s_upgrade_etcd_snapshot: true`) becomes the only path
  back, via `k3s_restore_from_backup.yaml` (full `--cluster-reset
  --cluster-reset-restore-path=<snapshot>` on one master, plus wiping the
  other masters' data directories).

## Post-upgrade verification

`upgrade-k3s.yml`'s Play 6 automates this, but for reference it checks:

1. Every node's `kubeletVersion` matches the target `k3s_version`.
2. Every node reports `Ready=True`.
3. No pod in `kube-system` sits outside `Running`/`Succeeded`.
4. kube-vip DaemonSet and MetalLB controller/speaker images match their
   target tags.
5. The VIP (`apiserver_endpoint`) is reachable through `kubectl_context`.
