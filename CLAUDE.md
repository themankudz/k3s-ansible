# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. For generic Ansible/repo conventions (source-of-truth rules, coding style, molecule/testing workflow, commit message format) see [AGENTS.md](AGENTS.md) — this file covers our specific cluster setup, not general repo conventions.

## Related Repository

All cluster **applications** are managed via ArgoCD in a separate repository at `../../homelab-k3s/`. That repo has its own `CLAUDE.md` with full application-level guidance including GitOps workflows, adding new apps, DNS, ingress patterns, and per-application upgrade instructions. Changes to running workloads (Longhorn config, ingress, app deployments) belong there, not here.

This repository is solely for **cluster infrastructure** — provisioning nodes, installing k3s, and OS-level configuration via Ansible.

---

## Overview

Ansible-based automation for deploying a k3s Kubernetes homelab cluster with kube-vip and MetalLB. Mixed architecture: Raspberry Pi, Unraid, and x86 nodes.

**Current Configuration**:
- **k3s version**: v1.33.10+k3s1
- **API Endpoint (VIP)**: 192.168.50.200
- **MetalLB IP Range**: 192.168.50.202-192.168.50.227 (homelab-cluster); 192.168.50.228-192.168.50.254 (workload-cluster)
- **CNI**: Flannel (eth0 interface)
- **Custom Registry**: Harbor at harbor.homecluster.co (caching docker.io, ghcr.io, quay.io, registry.k8s.io)
- **Master Taint**: Disabled (masters can run workloads)

---

## Key Commands

```bash
# Deploy a fresh cluster (bootstrap-only — never run against a live cluster)
ansible-playbook site.yml -i inventory/homelab-cluster/hosts.ini

# Day-to-day fleet maintenance: converges the full node baseline (prereq,
# raspberrypi, registries, longhorn/nfs, mail relay, unattended-upgrades) AND
# safely rolls k3s/kube-vip/MetalLB version bumps, one node at a time. This is
# the playbook to run routinely against an already-established cluster.
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini

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

`setup-mail.yml`, `prereq.yaml`, `pre-reqs.yml`, and `storage.yml` are older
one-off playbooks that each cover a slice of what `upgrade-k3s.yml` now
converges on every routine run. They still work (useful for a narrowly
targeted one-off, e.g. `--limit` to a single node) but are redundant for
day-to-day use — reach for `upgrade-k3s.yml` first.

After `site.yml` completes, `./kubeconfig` is written to the repo root (gitignored) containing the cluster kubeconfig with the VIP endpoint.

**Note**: `ansible.cfg` is gitignored (copy `ansible.example.cfg` and adjust locally). Its `inventory` default, if set, only covers one cluster — always pass `-i inventory/homelab-cluster/hosts.ini` or `-i inventory/workload-cluster/hosts.ini` explicitly rather than relying on it, especially for `upgrade-k3s.yml` where running against the wrong cluster is exactly the mistake Play 1's context sanity check exists to catch.

### Generic Infra Playbook (standalone VMs)

`infra.yml` prepares any Debian/Ubuntu VM (not necessarily a k3s node) with base OS config, unattended-upgrades, a postfix→SES mail relay, and an OpenTelemetry collector forwarding **host metrics + host logs** to the self-hosted SigNoz (`signoz-ingress.homecluster.co:443`, gRPC OTLP, TLS). It is fully separate from the live k3s path (`site.yml`/`prereq`/`upgrade-k3s.yml` are untouched).

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

### Fleet maintenance (`upgrade-k3s.yml`)

`upgrade-k3s.yml` is the primary day-to-day playbook for an
already-established cluster — not just a k3s version bump. Every run
reconciles the full node baseline via `tasks/reconcile-node.yml` (shared by
both the master and agent plays): `prereq`, `raspberrypi`,
`k3s_custom_registries`, `longhorn_node_fix`, `node_longhorn`, `node_nfs`,
`mail_relay`, and `unattended_upgrades`. It is fully idempotent — an
already-converged node reports no changes — and only restarts k3s when
something that actually requires it changed (kubelet/containerd config, the
systemd unit, custom registries, or the k3s version itself); `mail_relay` and
`unattended_upgrades` never trigger a restart. `site.yml`'s "Prepare k3s
nodes" play applies the same role set (see `.github/scripts/test-baseline-parity.sh`,
which fails CI if the two drift), so a freshly bootstrapped node ends up at
the same baseline as a routinely maintained one.

**NEVER run `site.yml` against an already-established cluster.** `site.yml`'s
`k3s_server` role is fresh-bootstrap-only: it unconditionally stops
`k3s.service` on every master in one step (`site.yml` sets no `serial:` at
all) and then brings up only the first master alone via a transient
`--cluster-init` unit, waiting for its own `/readyz`. Against a live cluster
this deadlocks — a lone etcd member of an already-established N-member
cluster can never reach quorum by itself — and leaves every master's real
service stopped. This caused a full cluster outage on 2026-09-05. `--serial`
is also not a real `ansible-playbook` CLI flag in the first place; `serial:`
is a play-level YAML keyword, so the old commands below would either error or
silently run with no serialization at all.

To upgrade an existing cluster (k3s version, and/or kube-vip/MetalLB), update
the version variables in `inventory/<cluster>/group_vars/all.yml`, then run
the dedicated rolling-upgrade playbook — `upgrade-k3s.yml` — which stops,
swaps, and restarts one node at a time, gated on real cluster health at every
step:

```bash
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini

# Addon-only bump (kube-vip/MetalLB), skipping the k3s version gate:
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini --tags addons

# workload-cluster currently needs drain disabled — see the playbook header
# for why (CPU headroom / PodDisruptionBudgets) before that's fixed:
ansible-playbook upgrade-k3s.yml -i inventory/workload-cluster/hosts.ini -e k3s_upgrade_drain=false
```

The etcd snapshot is automated by this playbook (`k3s_upgrade_etcd_snapshot:
true` by default) — no separate manual `k3s etcd-snapshot save` step needed.
See `upgrade-plan.md` for the staged version-hop plan and the full incident
writeup this playbook was built to prevent recurring.

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
| **prereq** | System prerequisites: timezone (Europe/London), packages (open-iscsi, nfs-common), multipath config, kubelet config, apt proxy (192.168.50.220:3142). Split into `tasks/baseline.yml` (live-node-safe, no k3s restart) and `tasks/runtime-config.yml` (kubelet/containerd config — requires a restart, left to the caller); `tasks/main.yml` runs both in order for the bootstrap (`site.yml`) path. |
| **download** | Download and install k3s binary |
| **raspberrypi** | Pi-specific boot config (cgroups, cmdline.txt) — Pi nodes only |
| **k3s_custom_registries** | Configure Harbor registry mirrors with insecure TLS |
| **k3s_server** | Deploy k3s control plane with kube-vip v1.2.3 and MetalLB v0.16.0 |
| **k3s_agent** | Join worker nodes to cluster |
| **k3s_server_post** | Configure MetalLB Layer2 mode |
| **node_longhorn** | Format and mount a dedicated Longhorn disk (`node_longhorn_disk`). Default is empty (skip). Configure per-node or per-group in host/group vars. |
| **node_nfs** | Declaratively manage Unraid NFS mounts (`node_nfs_server` + `node_nfs_mounts`) and the `nfs-remount` stale-mount watchdog. The role owns exactly the mounts in `node_nfs_mounts` (tracked via `/var/lib/node_nfs/managed.list`); set the list to `[]` (keeping `node_nfs_server`) to remove all. Empty `node_nfs_server` = no-op. |
| **longhorn_node_fix** | OS-level fixes for stable Longhorn operation (see below) |
| **reset** | Complete cluster teardown |

### Shared / generic infra roles

`unattended_upgrades` and `mail_relay` are used by **both** `infra.yml` (non-k3s VMs) and the k3s
path (`site.yml`'s "Prepare k3s nodes" play, and every `upgrade-k3s.yml` run via
`tasks/reconcile-node.yml`). `base_system` remains `infra.yml`-only — k3s nodes use `prereq` instead.

| Role | Purpose |
|------|---------|
| **base_system** | Generic Debian/Ubuntu OS baseline: timezone, apt-proxy, optional `base_packages`, optional `base_ip_forward` sysctl (off by default). The non-k3s extraction of `prereq`. `infra.yml`-only. |
| **unattended_upgrades** | Installs and fully owns unattended-upgrades: `20auto-upgrades`, `50unattended-upgrades` (allowed origins, remove-unused, optional auto-reboot, and the `Mail`/`MailReport` directives gated on `unattended_upgrades_mail`), plus the `InhibitDelayMaxSec=90` logind tweak. |
| **mail_relay** | Postfix send-only relay to an SMTP smarthost (Amazon SES). Refactor of the retired `mail-setup` role: postmap runs via handler, test email is opt-in (`mail_relay_send_test`), and it no longer touches `50unattended-upgrades`. Gated on `mail_relay_enabled` (default `true`) wherever it's included. |
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
