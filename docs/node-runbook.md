# Node runbook — disk, VM and host operations

Hands-on commands for the k3s nodes and the Unraid host that runs the
workload-cluster VMs (`k3s-w1/w2/w3`, 192.168.50.81–83, host 192.168.50.52).
Everything here was used for real during the 2026-09-17/18 outage recovery
(root cause + plan: `homelab-k3s/plans/harbor-ha-mirror-and-otel-queue-bounding-plan.md`).

Conventions: `k3s@<node>` for the guests (passwordless sudo), `root@192.168.50.52`
for Unraid. Workload vdisks live at `/mnt/nvmcache/domains/<vm>/vdiskN.qcow2`
(`vdisk1` = root `/dev/vda`, `vdisk2` = Longhorn `/dev/vdb`).

---

## 1. Grow a node's root disk

Root disks are 128G as of 2026-09-18 (were 60G; the GPU node's live image set
alone is ~30G unpacked). The whole procedure is online — no drain, no reboot.

### 1a. Grow the vdisk on Unraid

Running VM (virtio-blk picks the new size up live):

```bash
virsh blockresize k3s-w1 /mnt/nvmcache/domains/k3s-w1/vdisk1.qcow2 128G
```

Stopped VM:

```bash
qemu-img resize /mnt/nvmcache/domains/k3s-w1/vdisk1.qcow2 128G
qemu-img info   /mnt/nvmcache/domains/k3s-w1/vdisk1.qcow2 | grep 'virtual size'
```

The qcow2 only grows on disk as space is actually used; NOCOW (`C`) attr and
`cache='none'` are unaffected.

### 1b. Grow partition → PV → LV → filesystem in the guest

```bash
sudo -i
echo 1 > /sys/class/block/vda/device/rescan      # running-VM case only; makes the kernel see the new size
lsblk /dev/vda                                    # vda shows 128G, vda3 still the old size
growpart /dev/vda 3                               # extend partition 3 to the end of the disk
pvresize /dev/vda3
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/ubuntu-vg/ubuntu-lv                # ext4 grows online
df -h /
```

Gotchas seen:
- `growpart` fails with `mkdir: cannot create directory '/tmp/growpart.NNN': No space left on device`
  when the root fs is 100% full. Point its temp dir at tmpfs:
  `TMPDIR=/run growpart /dev/vda 3` — or free a sliver first (`journalctl --vacuum-size=100M; apt-get clean`).
- `Failed to add inotify watch for /run/udev: Too many open files` after the
  `CHANGED:` line is cosmetic (udevadm settle hitting the inotify limit); the
  resize succeeded. The `prereq` role now raises `fs.inotify.max_user_instances`.
- If `pvresize` says the device didn't grow: `partprobe /dev/vda` (or `partx -u /dev/vda`) and retry.
- k3s crash-looping on a 0-bytes-free disk recovers by itself once `resize2fs` finishes.

---

## 2. Convert a vdisk to NOCOW + defragment (btrfs on Unraid)

**Why:** qcow2 on btrfs with copy-on-write fragments without bound (w1's root
vdisk reached 604,799 extents) and drives NVMe write latency to 200 ms+. NOCOW
cannot be applied to an existing non-empty file, so a copy is mandatory.
`qemu-img convert` produces a contiguous, zero-compacted copy in one pass.

VM must be **stopped** (`virsh domstate <vm>` → `shut off`). Needs free pool
space ≥ the VM's allocated vdisk size.

```bash
cd /mnt/nvmcache/domains
chattr +C <vm>                                          # directory: new files inherit NOCOW
for v in vdisk1 vdisk2; do                              # add vdisk3 etc. as attached
  qemu-img convert -p -O qcow2 <vm>/$v.qcow2 <vm>/$v.new.qcow2
  qemu-img check <vm>/$v.new.qcow2 | tail -2            # expect "0.00% fragmented", no errors
done
lsattr <vm>/*.new.qcow2                                 # every line must show C
cd <vm>
for v in vdisk1 vdisk2; do mv $v.qcow2 $v.old.qcow2 && mv $v.new.qcow2 $v.qcow2; done
chown root:users vdisk*.qcow2 && chmod 666 vdisk*.qcow2
```

Then edit the VM XML (Unraid VM tab → Edit → XML view) before starting:

```xml
<driver name='qemu' type='qcow2' cache='none' discard='unmap'/>
<source file='/mnt/nvmcache/domains/<vm>/vdisk1.qcow2'/>
```

- `cache='none'` (O_DIRECT): no host page-cache dependency; `io='native'` optional.
- `/mnt/nvmcache/...` not `/mnt/user/...`: bypasses the shfs FUSE layer.
- keep `discard='unmap'`: guest `fstrim` reclaims space in the qcow2.
- The `domains` share must be pool-only (Secondary storage: None) so the mover
  can never relocate a file the VM opens by direct path.

Boot the VM, confirm k3s Ready, then delete `*.old.qcow2`. Expect a btrfs
async-discard backlog afterwards (`/sys/fs/btrfs/<uuid>/discard/discardable_bytes`)
that inflates host load for a while.

Reclaim stale allocation inside the guest afterwards (a 200G Longhorn disk was
found holding 180G of dead blocks): `fstrim -v /var/lib/longhorn; fstrim -v /`.

---

## 3. Disk-usage triage on a node

```bash
df -h /                                                 # the truth
du -xsh /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/server \
        /var/log /var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir/otel-agent-queue /var/lib/longhorn 2>/dev/null | sort -rh
```

**Always `du -x`.** Plain `du` crosses mounts and double-counts: `/run/k3s`
shows ~20G (it's the overlay rootfs of every running container, on a 2G
tmpfs), `/var/lib/kubelet` shows terabytes (mounted PVCs).

What each thing is and whether it's disposable:

| path | what | disposable? |
|---|---|---|
| `.../containerd/io.containerd.content.v1.content` | compressed image blobs | leftovers via lease cleanup (§4); unused images by kubelet GC at 85% |
| `.../containerd/io.containerd.snapshotter.v1.overlayfs` | unpacked layers (~2.5–3× the blobs) | same |
| `/var/lib/rancher/k3s/server/db` | etcd | **no** |
| `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir/otel-agent-queue` | otel-agent replay buffer (emptyDir, 20Gi sizeLimit, 4GiB byte cap per signal — was an unbounded hostPath at `/var/lib/otel-agent-queue` before 2026-09-19) | last resort — kubelet already caps it; `rm` contents then restart the agent *container* (`crictl stop`) so it drops the open fd |
| `…/otel-agent-queue/tempdb*` older than 1h | orphaned compaction copies (only from `on_start` compaction, now disabled) | yes, always |
| `/var/log/journal` | journald (capped 500M by `prereq`) | `journalctl --vacuum-size=…` |
| `/var/log/syslog*` | rsyslog (disabled by `prereq`) | yes |

Per-pod attribution (kubelet's view; hostPath usage is invisible here):

```bash
kubectl --context workload get --raw /api/v1/nodes/<node>/proxy/stats/summary | jq '.node.fs, [.pods[] | {p: .podRef.name, e: ."ephemeral-storage".usedBytes}] | sort_by(-.e)[:5]'
```

---

## 4. Stale containerd leases (image store bloat after interrupted pulls)

Every k3s restart kills containerd mid-pull; each abandoned pull leaves a
lease that pins its layers forever (CRI pull leases have no expiry; the
transfer service's are 24h). Symptom: `k3s ctr images ls` shows far more than
`crictl images`, and the store is much bigger than the images account for.

```bash
k3s ctr -n k8s.io leases ls | tail -n +2 | wc -l      # hundreds = problem
k3s ctr -n k8s.io images ls -q | grep -vc ^sha256      # containerd's view
k3s crictl images -q | wc -l                            # kubelet's view
```

Cleanup (what `k3s-node-guard.sh` does hourly when enabled; only run while
k3s is stable — a bulk `leases rm` during a crash loop just hits a dead socket):

```bash
now=$(date +%s)
k3s ctr -n k8s.io leases ls | tail -n +2 | while read -r id created _; do
  ts=$(date -d "$created" +%s 2>/dev/null) || continue
  (( now - ts > 7200 )) && k3s ctr -n k8s.io leases rm "$id"
done
sleep 30                                                # GC runs after deletions
```

Don't reach for `crictl rmi --prune` as a routine step: kubelet's image GC
already removes unused images LRU-first above 85%, and the cached images are
what Spegel serves to peers. The lease sweep only frees leftovers of
interrupted pulls -- complete images are referenced and survive GC.

Reclaimed 19G on w3 and 21G on w2 in one pass on 2026-09-18.

---

## 5. Is the Unraid host the problem? (check this first when etcd is slow)

Guest-side leading indicators:

```bash
journalctl -u k3s --since '30 min ago' | grep -c 'slow fdatasync'    # >0 sustained = disk latency
journalctl -u k3s --since today | grep -c 'leaderelection lost'       # k3s crash loops
iostat -dx 5 2 | grep vda                                             # util ~100% at low w/s = host-side latency
```

Host side:

```bash
uptime; free -g                                        # available must stay > ~12G; Σ VM RAM ≤ host − 12G
iostat -dx 5 2 | grep nvme                             # await should be single-digit ms
lsattr /mnt/nvmcache/domains/*/*.qcow2                 # every vdisk must show C
filefrag /mnt/nvmcache/domains/k3s-w1/vdisk1.qcow2     # extents in the low thousands, not 600k
virsh dumpxml k3s-w1 | grep -E "source file|cache="   # /mnt/nvmcache path, cache='none'
cat /sys/fs/btrfs/$(findmnt -n -o UUID /mnt/nvmcache)/discard/discardable_bytes   # async-discard backlog
for d in k3s-w1 k3s-w2 k3s-w3; do virsh dominfo $d | grep 'Used memory'; done
```

Load average on the host counts qemu I/O threads stuck in D-state, so a high
load with idle CPU means storage latency, not compute.

---

## 6. Longhorn: before taking a node down

```bash
# no volume may depend solely on the node you're about to stop
kubectl --context workload get volumes.longhorn.io -n longhorn-system \
  -o custom-columns=PVC:.status.kubernetesStatus.pvcName,STATE:.status.state,ROBUST:.status.robustness | grep -v healthy
kubectl --context workload get replicas.longhorn.io -n longhorn-system -o json | jq -r '
  [.items[] | select(.status.currentState=="running" and (.spec.failedAt // "")=="") | {v:.spec.volumeName, n:.spec.nodeID}]
  | group_by(.v) | map(select(length==1)) | .[][0] | "\(.n)\t\(.v)"'   # single-healthy-replica volumes
kubectl --context workload drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=10m
# ... stop/convert/resize ...
kubectl --context workload uncordon <node>
```

With every volume `healthy` (2 replicas), a plain drain is enough — Longhorn's
`block-if-contains-last-replica` policy lets it through and the volumes run
degraded for the minutes the node is away, then delta-resync. Requesting a
Longhorn eviction instead copies every replica off the node first (slow,
heavy I/O on the host) and is only needed if a node is going away for good.

---

## 7. Node telemetry: is the host collector actually delivering?

`roles/node_monitoring` ships the host journal (+ kernel, + containerd.log)
and, on server nodes, etcd's loopback-only metrics to SigNoz. "Service active,
no errors" is not proof — on 2026-09-19 the collector ran happily for 14 h on
an empty stream (`dmesg` + `units` in one journald receiver), and SigNoz's own
collector was separately wedged in the logs-exporter deadlock, so nothing
landed either way.

On the node:

```bash
systemctl is-active otelcol-contrib
journalctl -u otelcol-contrib -n 30 --no-pager | grep -E "Journalctl command|Exporting failed|error"
pgrep -a -P "$(systemctl show -p MainPID --value otelcol-contrib)"   # one journalctl child per receiver
for p in $(pgrep -P "$(systemctl show -p MainPID --value otelcol-contrib)"); do awk '/wchar/' /proc/$p/io; done   # growing = producing
```

Don't try `curl localhost:8888/metrics` for the collector's own counters on a
k3s node: the k8s-infra otel-agent DaemonSet publishes `hostPort` 8888 (and
4317/4318/13133), so CNI DNATs even loopback traffic on those ports into the
pod and you get `connection refused`.

In SigNoz (Logs explorer): filter `log.source = node`, group by `host.name`;
attributes `systemd.unit`, `syslog.identifier`, `journald.transport=kernel`.
Metrics: `etcd_disk_wal_fsync_duration_seconds.bucket` (p99 per `host.name`).

If the SigNoz MCP server isn't reachable from the session, query the API from
inside the cluster without the key ever leaving it:

```bash
kubectl --context workload run signoz-api-probe -n signoz-monitoring --restart=Never \
  --image=harbor.homecluster.co/util-image/util-image:latest \
  --overrides='{"spec":{"containers":[{"name":"p","image":"harbor.homecluster.co/util-image/util-image:latest","command":["sleep","7200"],"envFrom":[{"secretRef":{"name":"signoz-mcp-secrets"}}]}]}}'
kubectl --context workload exec -n signoz-monitoring signoz-api-probe -- sh -c \
  'curl -s -H "SIGNOZ-API-KEY: $SIGNOZ_API_KEY" http://signoz.signoz-monitoring.svc.cluster.local:8080/api/v1/rules' | jq '.data.rules[].alert'
# POST /api/v4/query_range (logs builder queries) / /api/v5/query_range (metrics, schemaVersion v1) the same way
kubectl --context workload delete pod -n signoz-monitoring signoz-api-probe
```

If log counts are zero for *everything*, not just node logs, check the SigNoz
collector for `couldn't PrepareBatch for inserting resource fingerprints` —
that's the logs-exporter deadlock; run `homelab-k3s/signoz/otel-logs-queue-recovery.sh`.
