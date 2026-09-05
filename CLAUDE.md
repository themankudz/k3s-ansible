# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. For generic Ansible/repo conventions (source-of-truth rules, coding style, molecule/testing workflow, commit message format) see [AGENTS.md](AGENTS.md) — this file covers our specific cluster setup, not general repo conventions.

## Related Repository

All cluster **applications** are managed via ArgoCD in a separate repository at `../../homelab-k3s/`. That repo has its own `CLAUDE.md` with full application-level guidance including GitOps workflows, adding new apps, DNS, ingress patterns, and per-application upgrade instructions. Changes to running workloads (Longhorn config, ingress, app deployments) belong there, not here.

This repository is solely for **cluster infrastructure** — provisioning nodes, installing k3s, and OS-level configuration via Ansible.

---

## Overview

Ansible-based automation for deploying a k3s Kubernetes homelab cluster with kube-vip and MetalLB. Mixed architecture: Raspberry Pi, Unraid, and x86 nodes.

**Current Configuration**:
- **k3s version**: v1.33.6+k3s1
- **API Endpoint (VIP)**: 192.168.50.200
- **MetalLB IP Range**: 192.168.50.202-192.168.50.227 (homelab-cluster); 192.168.50.228-192.168.50.254 (workload-cluster)
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

# Set up postfix/unattended-upgrade email notifications
ansible-playbook setup-mail.yml -i inventory/homelab-cluster/hosts.ini
```

After `site.yml` completes, `./kubeconfig` is written to the repo root (gitignored) containing the cluster kubeconfig with the VIP endpoint.

**Note**: `ansible.cfg` points to `inventory/homeserver-cluster/hosts.ini` which doesn't exist. Always pass `-i inventory/homelab-cluster/hosts.ini` explicitly.

### Generic Infra Playbook (standalone VMs)

`infra.yml` prepares any Debian/Ubuntu VM (not necessarily a k3s node) with base OS config, unattended-upgrades, a postfix→SES mail relay, and an OpenTelemetry collector forwarding **host metrics + host logs** to the self-hosted SigNoz (`signoz-ingress.homecluster.co:443`, gRPC OTLP, TLS). It is fully separate from the live k3s path (`site.yml`/`prereq`/`mail-setup` are untouched).

```bash
# Run the full infra baseline (vault password required for secrets)
ansible-playbook infra.yml -i inventory/infra/hosts.ini --ask-vault-pass
# or, with a password file:
ANSIBLE_VAULT_PASSWORD_FILE=.vault_pass ansible-playbook infra.yml -i inventory/infra/hosts.ini

# Syntax check / dry run
ansible-playbook infra.yml -i inventory/infra/hosts.ini --syntax-check --ask-vault-pass
ansible-playbook infra.yml -i inventory/infra/hosts.ini --check --ask-vault-pass
```

Per-VM toggles: `mail_relay_enabled` and `node_monitoring_enabled` (both default `true`); `mail_relay_send_test: true` sends a one-off test email.

**Secrets (ansible-vault)**: `inventory/infra/group_vars/all/vault.yml` is vault-encrypted (holds `vault_smtp_key`, `vault_signoz_ingestion_key`) so inventories can be committed to git. The vault password lives in `.vault_pass` (gitignored). Edit secrets with `ansible-vault edit --vault-password-file .vault_pass inventory/infra/group_vars/all/vault.yml`. Non-secret config is in `inventory/infra/group_vars/all/main.yml`, which references the `vault_*` vars.

### Linting

```bash
# Run all pre-commit hooks (yamllint, ansible-lint, shellcheck, whitespace checks)
pre-commit run --all-files

# Install hooks so they run automatically on commit
pre-commit install

# Run ansible-lint alone
ansible-lint

# Run yamllint alone
yamllint .
```

ansible-lint runs with `profile: production`. The only suppressed rule is `var-naming[no-role-prefix]`.

### Upgrading k3s

To upgrade to a new k3s version (or bump kube-vip/MetalLB), update the version variables in `inventory/homelab-cluster/group_vars/all.yml`, then do a rolling upgrade:

```bash
# Masters one at a time (preserves etcd quorum)
ansible-playbook site.yml -i inventory/homelab-cluster/hosts.ini --limit master --serial 1

# Workers in small batches
ansible-playbook site.yml -i inventory/homelab-cluster/hosts.ini --limit node --serial 2
```

Pre-upgrade: snapshot etcd from a master node — `sudo k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)`. See `upgrade-plan.md` for the full checklist.

---

## Cluster Architecture

### Node Topology

**Control-Plane Nodes** (3 — all Pi5 NVMe, HA embedded etcd):
| Node | IP | Hardware | Disk |
|------|----|----------|------|
| k3s-1 | 192.168.50.115 | Raspberry Pi 5 + NVMe | Large (339G free) |
| k3s-6 | 192.168.50.138 | Raspberry Pi 5 + NVMe | Large (322G free) |
| k3s-7 | 192.168.50.97 | Raspberry Pi 5 + NVMe | Large (368G free) |

**Worker Nodes** (1 — temporary, scheduled for removal after Proxmox migration):
| Node | IP | Hardware | Disk | Notes |
|------|----|----------|------|-------|
| k3s-8 | 192.168.50.179 | x86 host | Large (113G free) | Leaving cluster when migrated to Proxmox |

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
| **node_longhorn** | Format and mount a dedicated Longhorn disk (`node_longhorn_disk`). Default is empty (skip). Configure per-node or per-group in host/group vars. |
| **node_nfs** | Declaratively manage Unraid NFS mounts (`node_nfs_server` + `node_nfs_mounts`) and the `nfs-remount` stale-mount watchdog. The role owns exactly the mounts in `node_nfs_mounts` (tracked via `/var/lib/node_nfs/managed.list`); set the list to `[]` (keeping `node_nfs_server`) to remove all. Empty `node_nfs_server` = no-op. |
| **longhorn_node_fix** | OS-level fixes for stable Longhorn operation (see below) |
| **reset** | Complete cluster teardown |

### Generic infra roles (used by `infra.yml`, not `site.yml`)

| Role | Purpose |
|------|---------|
| **base_system** | Generic Debian/Ubuntu OS baseline: timezone, apt-proxy, optional `base_packages`, optional `base_ip_forward` sysctl (off by default). The non-k3s extraction of `prereq`. |
| **unattended_upgrades** | Installs and fully owns unattended-upgrades: `20auto-upgrades`, `50unattended-upgrades` (allowed origins, remove-unused, optional auto-reboot, and the `Mail`/`MailReport` directives gated on `unattended_upgrades_mail`), plus the `InhibitDelayMaxSec=90` logind tweak. |
| **mail_relay** | Postfix send-only relay to an SMTP smarthost (Amazon SES). Refactor of `mail-setup`: postmap runs via handler, test email is opt-in (`mail_relay_send_test`), and it no longer touches `50unattended-upgrades`. |
| **node_monitoring** | Installs `otelcol-contrib` (arch-mapped GitHub `.deb`, pinned by `otelcol_version`) and configures it to forward host metrics (`hostmetrics`) + host logs (`journald`) to SigNoz (`signoz_otlp_endpoint`, TLS). Runs as the `otelcol-contrib` user in the `systemd-journal`/`adm` groups. |

### longhorn_node_fix role

Deploys `/etc/udev/rules.d/60-longhorn-no-bcache.rules` on all nodes.

**Why it exists**: Ubuntu ships a udev rule (`69-bcache.rules`) that runs `probe-bcache` on every block device including Longhorn iSCSI volumes. When an iSCSI session drops, `probe-bcache` hangs indefinitely, gets killed by udev after ~107s, then immediately respawns — an endless loop that exhausts udev workers, causes memory pressure, kills journald, and locks up the node. k3s-2 and k3s-4 both suffered this failure on 2026-03-26 (both nodes have since been removed from the cluster; the udev rule remains deployed on all surviving nodes as defence-in-depth).

**What the rule does**: Sets `ID_FS_TYPE=not-bcache` for any block device whose `ID_PATH` matches `ip-*-iscsi-iqn.2019-10.io.longhorn:*`. This causes `69-bcache.rules` to bail out before calling `probe-bcache`. Scoped specifically to Longhorn IQNs — does not affect local disks on any node type.

---

## Configuration

### Inventory

Two active inventories:

- `inventory/homelab-cluster/` — homelab cluster, 4 nodes: k3s-1/6/7 (Pi5, control-plane) + k3s-8 (x86 worker, temporary) (VIP: 192.168.50.200, pod CIDR: 10.52.0.0/16)
- `inventory/workload-cluster/` — second cluster for heavier workloads (VIP: 192.168.50.201, pod CIDR: 10.53.0.0/16, dedicated `/dev/vdb` Longhorn disk and Unraid NFS mounts pre-configured)

```
inventory/<cluster>/
├── hosts.ini          # Node definitions and group hierarchy
└── group_vars/
    └── all.yml        # All cluster config (k3s version, VIP, extra_args, etc.)
```

Group hierarchy in `hosts.ini`: individual nodes → hardware-type groups (`pi-master`, `x86-workers`, etc.) → role groups (`master`, `node`) → `k3s_cluster`.

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
- Cluster CIDR: `10.52.0.0/16` (homelab-cluster) / `10.53.0.0/16` (workload-cluster)
- Control plane VIP: `192.168.50.200` (kube-vip ARP mode)
- MetalLB: Layer2, `192.168.50.202-192.168.50.227`
- Apt proxy: `http://192.168.50.220:3142`
- Unraid server (NFS): `192.168.50.52`

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
for node in 192.168.50.115 192.168.50.138 192.168.50.97 192.168.50.179; do
  echo "=== $(ssh k3s@$node hostname) ==="
  ssh k3s@$node "free -m | awk '/Mem:/{print \"mem available: \"\$7\"Mi\"}'; df -h / | awk 'NR==2{print \"disk: \"\$4\" free (\"\$5\" used)\"}'"
done

# Check for udev worker hangs (the bcache issue)
ssh k3s@<node-ip> "sudo journalctl -n 50 | grep -E '(probe-bcache|udev-worker|memory pressure)'"

# Check iSCSI sessions on a node
ssh k3s@<node-ip> "sudo iscsiadm -m session"

# Check NVMe errors (all current nodes are Pi5 + NVMe)
ssh k3s@<node-ip> "sudo dmesg -T | grep -E '(nvme|I/O error)' | tail -20"

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
