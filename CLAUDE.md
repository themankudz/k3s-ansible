# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Related Repository

All cluster **applications** are managed via ArgoCD in a separate repository at `../../homelab-k3s/`. That repo has its own `CLAUDE.md` with full application-level guidance including GitOps workflows, adding new apps, DNS, ingress patterns, and per-application upgrade instructions. Changes to running workloads (Longhorn config, ingress, app deployments) belong there, not here.

This repository is solely for **cluster infrastructure** — provisioning nodes, installing k3s, and OS-level configuration via Ansible.

---

## Overview

Ansible-based automation for deploying a k3s Kubernetes homelab cluster with kube-vip and MetalLB. Mixed architecture: Raspberry Pi, Unraid, and x86 nodes.

**Current Configuration**:
- **k3s version**: v1.33.6+k3s1
- **API Endpoint (VIP)**: 192.168.50.200
- **MetalLB IP Range**: 192.168.50.202-192.168.50.254
- **CNI**: Flannel (eth0 interface)
- **Custom Registry**: Harbor at harbor.homecluster.co (caching docker.io, ghcr.io, quay.io, registry.k8s.io)
- **Master Taint**: Disabled (masters can run workloads)

---

## Key Commands

```bash
# Deploy the cluster
ansible-playbook site.yml -i inventory/homelab-cluster/hosts.ini

# Run prerequisites only (packages, kernel modules, kubelet config, udev rules)
ansible-playbook pre-reqs.yml -i inventory/homelab-cluster/hosts.ini

# Apply Longhorn node fixes only (udev bcache rule)
ansible-playbook longhorn-node-fix.yml -i inventory/homelab-cluster/hosts.ini

# Roll out kubelet config changes to a live cluster (serial: 1, agents first then masters)
ansible-playbook update-kubelet-config.yml -i inventory/homelab-cluster/hosts.ini

# Set up custom registries on existing cluster
ansible-playbook setup-custom-registries.yml -i inventory/homelab-cluster/hosts.ini

# Destroy the cluster completely
ansible-playbook reset.yml -i inventory/homelab-cluster/hosts.ini

# Reboot all cluster nodes
ansible-playbook reboot.yml -i inventory/homelab-cluster/hosts.ini

# Restore from backup
ansible-playbook k3s_restore_from_backup.yaml -i inventory/homelab-cluster/hosts.ini
```

**Note**: `ansible.cfg` points to `inventory/homeserver-cluster/hosts.ini` which doesn't exist. Always pass `-i inventory/homelab-cluster/hosts.ini` explicitly.

---

## Cluster Architecture

### Node Topology

**Master Nodes** (3 — HA embedded etcd):
| Node | IP | Hardware | Disk |
|------|----|----------|------|
| k3s-5 | 192.168.50.108 | Unraid host | Large (102G free) |
| k3s-6 | 192.168.50.138 | Raspberry Pi 5 | Large (322G free) |
| k3s-7 | 192.168.50.97 | Raspberry Pi 5 | Large (368G free) |

**Worker Nodes** (5):
| Node | IP | Hardware | Disk | Notes |
|------|----|----------|------|-------|
| k3s-1 | 192.168.50.115 | Raspberry Pi 5 | Large (339G free) | |
| k3s-2 | 192.168.50.92 | Raspberry Pi 4 | SD card ~28GB (74% used) | ⚠ Watch disk usage |
| k3s-3 | 192.168.50.146 | Unraid host | Large (98G free) | |
| k3s-4 | 192.168.50.72 | Raspberry Pi 4 | SD card ~28GB (79% used) | ⚠ Watch disk usage |
| k3s-8 | 192.168.50.179 | x86 host | Large (113G free) | |

**k3s-2 and k3s-4** are the only nodes running the OS from SD cards. They are more susceptible to instability under I/O load. If disk usage approaches 90%, the soft eviction threshold (10%) will trigger pod evictions.

### k3s Service Names (for manual intervention)
- Masters: `k3s` (systemd unit: `k3s.service`)
- Agents: `k3s-node` (systemd unit: `k3s-node.service`)

---

## Ansible Roles

| Role | Purpose |
|------|---------|
| **prereq** | System prerequisites: timezone (Europe/London), packages (open-iscsi, nfs-common), multipath config, kubelet config, apt proxy (192.168.50.220:3142) |
| **download** | Download and install k3s binary |
| **raspberrypi** | Pi-specific boot config (cgroups, cmdline.txt) — Pi nodes only |
| **k3s_custom_registries** | Configure Harbor registry mirrors with insecure TLS |
| **k3s_server** | Deploy k3s control plane with kube-vip v1.0.2 and MetalLB v0.15.3 |
| **k3s_agent** | Join worker nodes to cluster |
| **k3s_server_post** | Configure MetalLB Layer2 mode |
| **longhorn_node_fix** | OS-level fixes for stable Longhorn operation (see below) |
| **reset** | Complete cluster teardown |

### longhorn_node_fix role

Deploys `/etc/udev/rules.d/60-longhorn-no-bcache.rules` on all nodes.

**Why it exists**: Ubuntu ships a udev rule (`69-bcache.rules`) that runs `probe-bcache` on every block device including Longhorn iSCSI volumes. When an iSCSI session drops, `probe-bcache` hangs indefinitely, gets killed by udev after ~107s, then immediately respawns — an endless loop that exhausts udev workers, causes memory pressure, kills journald, and locks up the node. k3s-2 and k3s-4 both suffered this failure on 2026-03-26.

**What the rule does**: Sets `ID_FS_TYPE=not-bcache` for any block device whose `ID_PATH` matches `ip-*-iscsi-iqn.2019-10.io.longhorn:*`. This causes `69-bcache.rules` to bail out before calling `probe-bcache`. Scoped specifically to Longhorn IQNs — does not affect local disks on any node type.

---

## Configuration

### Inventory

Active inventory: `inventory/homelab-cluster/`

```
inventory/homelab-cluster/
├── hosts.ini          # Node definitions and group hierarchy
└── group_vars/
    └── all.yml        # All cluster config (k3s version, VIP, extra_args, etc.)
```

Group hierarchy in `hosts.ini`: individual nodes → hardware-type groups (`pi-master`, `unraid-workers`, etc.) → role groups (`master`, `node`) → `k3s_cluster`.

### Kubelet Config (`roles/prereq/files/kubelet.config`)

Deployed to `/data/k3s/kubelet.config` on all nodes, referenced via `--kubelet-arg="config=/data/k3s/kubelet.config"` in `group_vars/all.yml`.

Current settings:
- `shutdownGracePeriod: 75s` / `shutdownGracePeriodCriticalPods: 25s`
- **Eviction hard**: memory < 300Mi, disk < 5%
- **Eviction soft**: memory < 500Mi, disk < 10% (2m / 1m30s grace periods)

**Longhorn pods are protected**: They use `priorityClass: longhorn-critical` (value: 1,000,000,000). Kubelet evicts lowest-priority pods first — Longhorn pods are only evicted after all regular workloads are gone.

To update kubelet config on a live cluster, always use the dedicated playbook (not `site.yml`) to ensure serial rollout:
```bash
ansible-playbook update-kubelet-config.yml -i inventory/homelab-cluster/hosts.ini
```

### Network

- SSH user: `k3s`
- Flannel interface: `eth0`
- Cluster CIDR: `10.52.0.0/16`
- Control plane VIP: `192.168.50.200` (kube-vip ARP mode)
- MetalLB: Layer2, `192.168.50.202-192.168.50.254`
- Apt proxy: `http://192.168.50.220:3142`

---

## Known Issues & Fixes Applied

### 1. probe-bcache hanging on Longhorn iSCSI volumes (Fixed 2026-03-26)

**Symptom**: Node becomes unreachable, requires hard reboot. Logs show `udev-worker` processes for `probe-bcache` being repeatedly spawned and killed, followed by memory pressure and journald watchdog timeout.

**Root cause**: `69-bcache.rules` probing iSCSI-backed Longhorn volumes when they disconnect.

**Fix**: `longhorn_node_fix` role — deployed to all nodes. Udev rule: `/etc/udev/rules.d/60-longhorn-no-bcache.rules`.

### 2. Pods stuck on unreachable nodes (Fixed 2026-03-27)

**Symptom**: After a node goes unreachable, pods with Longhorn PVCs stay stuck for hours. `kubectl delete` also hangs.

**Root cause**: Longhorn `node-down-pod-deletion-policy` was `do-nothing`. Pod volume finalizers can never be cleared by an unreachable kubelet, blocking both automatic eviction and manual deletion.

**Fix**: `nodeDownPodDeletionPolicy: delete-both-stateful-and-replicated-pods` set in `../../homelab-k3s/longhorn/values.yaml`.

**Manual recovery for stuck pods** (if needed):
```bash
# Force delete the pod
kubectl delete pod <name> -n <namespace> --force --grace-period=0

# If still stuck, strip the finalizer
kubectl patch pod <name> -n <namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge

# If a VolumeAttachment is stuck on the dead node
kubectl get volumeattachment | grep <node-name>
kubectl delete volumeattachment <name>
```

---

## Debugging Nodes

```bash
# Check disk and memory across all nodes
for node in 192.168.50.115 192.168.50.92 192.168.50.146 192.168.50.72 192.168.50.108 192.168.50.138 192.168.50.97 192.168.50.179; do
  echo "=== $(ssh k3s@$node hostname) ==="
  ssh k3s@$node "free -m | awk '/Mem:/{print \"mem available: \"\$7\"Mi\"}'; df -h / | awk 'NR==2{print \"disk: \"\$4\" free (\"\$5\" used)\"}'"
done

# Check for udev worker hangs (the bcache issue)
ssh k3s@<node-ip> "sudo journalctl -n 50 | grep -E '(probe-bcache|udev-worker|memory pressure)'"

# Check iSCSI sessions on a node
ssh k3s@<node-ip> "sudo iscsiadm -m session"

# Check SD card errors (Pi 4 nodes: k3s-2, k3s-4)
ssh k3s@<node-ip> "sudo dmesg -T | grep -E '(mmcblk|mmc|I/O error)' | tail -20"

# Check for stuck VolumeAttachments cluster-wide
kubectl get volumeattachment | grep -v " true "

# Check Longhorn pod priority classes
kubectl get pods -n longhorn-system -o custom-columns='NAME:.metadata.name,PRIORITY:.spec.priorityClassName'
```

---

## Development Workflow

1. Install Ansible 2.11+
2. Install required collections: `ansible-galaxy collection install -r ./collections/requirements.yml`
3. Install `netaddr` Python package (if using pip-based Ansible)
4. Configure passwordless SSH as user `k3s` to all cluster nodes
5. Always pass `-i inventory/homelab-cluster/hosts.ini` (ansible.cfg inventory path is wrong)
6. All infrastructure changes must go through this repo — do not make manual changes on nodes
7. Application-level changes (Longhorn settings, workloads, ingress) belong in `../../homelab-k3s/`
