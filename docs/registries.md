# Container registry mirrors (`/etc/rancher/k3s/registries.yaml`)

The `custom_registries_yaml` block in `inventory/<cluster>/group_vars/all.yml`
is what `roles/k3s_custom_registries` writes (verbatim, via `blockinfile`) to
`/etc/rancher/k3s/registries.yaml` on every node. Both inventories are
**gitignored**, so the canonical copy of the block is recorded here. It holds
no auth — every in-cluster pull is anonymous from public Harbor projects — so
it is safe to keep in git. Keep this file in sync when the block changes.

Last rolled out: 2026-10-15 (Phase 1 of `homelab-k3s/plans/retire-spegel-plan.md`:
Spegel taken out of the pull path, `harbor-mgmt` added as fallback for `"*"`).
Before that: 2026-09-19 (Phase 4 of the Harbor HA mirror plan in
`homelab-k3s/plans/archive/harbor-ha-mirror-and-otel-queue-bounding-plan.md`).

## How a pull resolves

containerd tries the endpoints for a mirror **in order, per request**
(manifest, config, every layer), falling through on a miss or error. After the
mirrors it still tries the real upstream registry (k3s keeps the default
endpoint), except for `harbor.homecluster.co`, which has no upstream.

| Image host | 1st | 2nd |
|---|---|---|
| `harbor.homecluster.co` (management) | `harbor-mgmt` | `harbor` (workload) |
| `harbor.homecluster.co` (workload) | `harbor` (workload) | `harbor-mgmt` |
| `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `mcr.microsoft.com` | workload Harbor `<x>_cache` | `harbor-mgmt` `<x>_cache` |
| anything else (`"*"`) | workload Harbor `docker_cache` | `harbor-mgmt` `docker_cache` |

- **No Spegel.** The in-cluster P2P mirror (`http://localhost:30021`) used to be
  first for the public registries and last for `harbor.homecluster.co`. It was
  removed from every list on 2026-10-15: its hits only saved a LAN fetch from a
  warm Harbor, its misses added a lookup to every pull, it served stale mutable
  tags, and its both-Harbors-down fallback was never used. See the retire-Spegel
  plan for the numbers.
- **Each Harbor is the other's fallback.** They run in separate failure domains
  (workload VMs on Unraid vs k3s-8), replicate the hosted projects both ways
  (`util-image`, `finplanner`, `gymbuddy`, `closet`, so either answers with the
  same digests), and carry proxy-cache projects with identical names. For
  `harbor.homecluster.co` each cluster prefers its local Harbor.
- **Both names resolve without DNS.** The `prereq` role pins
  `harbor.homecluster.co` and `harbor-mgmt.homecluster.co` in `/etc/hosts`
  (`static_hosts`), so a Pi-hole outage can't take out both endpoints at once.
  It also disables cloud-init, which on the Pis rebuilt `/etc/hosts` at boot.
- The mirror's proxy caches are the **second** endpoint for public registries
  (behind the workload Harbor's warm LAN copy) because they are internet-backed
  over a ~36 Mbit/s link.
- **Both Harbors down:** images already on a node keep working
  (`IfNotPresent`), public images fall through to the real registry, and only
  Harbor-hosted images missing from a node can't be pulled.
- `configs."*"` sets `insecure_skip_verify` for every endpoint, including
  `harbor-mgmt.homecluster.co`. The `"localhost"` key is a Spegel leftover
  (harmless; removed with the rest of Spegel).

## Rollout

`setup-custom-registries.yml` only writes the file; containerd re-reads
`registries.yaml` on k3s restart only. Use `upgrade-k3s.yml` (serial: 1,
restarts k3s only on nodes whose registries actually changed). It is not
`--limit`-safe — run it per inventory. `--check` first, **never `--diff`**
(blockinfile would print the file). `--skip-tags addons` keeps the run to the
node baseline. Management first, verify, then workload
(`-e k3s_upgrade_drain=false` there — see the playbook header).

**Management: k3s-8 can't be drained.** harbor-mgmt's `longhorn-local` volumes are
1-replica `strict-local` there, and Longhorn's `node-drain-policy`
(`block-for-eviction-if-contains-last-replica`) holds its instance-manager PDB at 0. A
drain cordons k3s-8, evicts harbor-mgmt (which can only run there), times out, and fails
the run *before* the restart and the uncordon, leaving harbor-mgmt down (2026-10-15). So
when a run will restart k3s-8, use `-e k3s_upgrade_drain=false` on management too:
`KillMode=process` keeps every pod running through a k3s restart. If it happens anyway:
`kubectl --context homelab uncordon k3s-8`, then re-run with drain off.

```bash
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini --check -e k3s_upgrade_etcd_snapshot=false --skip-tags addons -e k3s_upgrade_drain=false
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini --skip-tags addons -e k3s_upgrade_drain=false
ansible-playbook upgrade-k3s.yml -i inventory/workload-cluster/hosts.ini --check -e k3s_upgrade_etcd_snapshot=false --skip-tags addons -e k3s_upgrade_drain=false
ansible-playbook upgrade-k3s.yml -i inventory/workload-cluster/hosts.ini --skip-tags addons -e k3s_upgrade_drain=false
```

(`-e k3s_upgrade_etcd_snapshot=false` is needed for `--check` only: the snapshot
command doesn't run in check mode, so its "file exists" assertion fails.)

The restart gate in `upgrade-k3s.yml` fires when the role's `blockinfile`
reports a change **or** when `registries.yaml`'s mtime is newer than the k3s
unit's `ActiveEnterTimestamp` (`tasks/reconcile-node.yml`). The second check
is what makes an interrupted run, or a file written by other means, converge
on the next run. Both were added on 2026-09-19 after the first Phase 4 run
wrote the file on all four management nodes without restarting anything: the
old gate registered the result of an `include_role`, which never carries the
included tasks' `changed` state.

Verify on a node (no secrets in either file):

```bash
sudo cat /etc/rancher/k3s/registries.yaml
ls /var/lib/rancher/k3s/agent/etc/containerd/certs.d/
sudo cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/harbor.homecluster.co/hosts.toml   # endpoint order must match
sudo k3s crictl pull harbor.homecluster.co/util-image/util-image:e101806
```

To prove *which* Harbor answered, compare the artifact's `pull_time` on both
(public project, anonymous API):

```bash
for h in harbor.homecluster.co harbor-mgmt.homecluster.co; do
  printf "%s " $h; curl -sk "https://$h/api/v2.0/projects/util-image/repositories/util-image/artifacts/e101806?with_tag=false" | jq -r .pull_time
done
```

2026-09-19 rollout result: management k3s-7 pulled via `harbor-mgmt`, workload
k3s-w1 via `harbor`, same digest on both; all seven nodes restarted one at a
time and came back Ready with no failures.

## Management cluster — `inventory/homelab-cluster/group_vars/all.yml`

```yaml
custom_registries_yaml: |
  mirrors:
    harbor.homecluster.co:
      endpoint:
        - "https://harbor-mgmt.homecluster.co"
        - "https://harbor.homecluster.co"
    docker.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/docker_cache"
        - "https://harbor-mgmt.homecluster.co/v2/docker_cache"
    ghcr.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/ghcr_cache"
        - "https://harbor-mgmt.homecluster.co/v2/ghcr_cache"
    quay.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/quay_cache"
        - "https://harbor-mgmt.homecluster.co/v2/quay_cache"
    registry.k8s.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/k8s_cache"
        - "https://harbor-mgmt.homecluster.co/v2/k8s_cache"
    mcr.microsoft.com:
      endpoint:
        - "https://harbor.homecluster.co/v2/mcr_cache"
        - "https://harbor-mgmt.homecluster.co/v2/mcr_cache"
    "*":
      endpoint:
        - "https://harbor.homecluster.co/v2/docker_cache"
        - "https://harbor-mgmt.homecluster.co/v2/docker_cache"
  configs:
    "docker.io":
    "ghcr.io":
    "quay.io":
    "localhost":
    "*":
      tls:
        insecure_skip_verify: true
```

## Workload cluster — `inventory/workload-cluster/group_vars/all.yml`

```yaml
custom_registries_yaml: |
  mirrors:
    harbor.homecluster.co:
      endpoint:
        - "https://harbor.homecluster.co"
        - "https://harbor-mgmt.homecluster.co"
    docker.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/docker_cache"
        - "https://harbor-mgmt.homecluster.co/v2/docker_cache"
    ghcr.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/ghcr_cache"
        - "https://harbor-mgmt.homecluster.co/v2/ghcr_cache"
    quay.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/quay_cache"
        - "https://harbor-mgmt.homecluster.co/v2/quay_cache"
    registry.k8s.io:
      endpoint:
        - "https://harbor.homecluster.co/v2/k8s_cache"
        - "https://harbor-mgmt.homecluster.co/v2/k8s_cache"
    mcr.microsoft.com:
      endpoint:
        - "https://harbor.homecluster.co/v2/mcr_cache"
        - "https://harbor-mgmt.homecluster.co/v2/mcr_cache"
    "*":
      endpoint:
        - "https://harbor.homecluster.co/v2/docker_cache"
        - "https://harbor-mgmt.homecluster.co/v2/docker_cache"
  configs:
    "docker.io":
    "ghcr.io":
    "quay.io":
    "localhost":
    "*":
      tls:
        insecure_skip_verify: true
```
