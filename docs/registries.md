# Container registry mirrors (`/etc/rancher/k3s/registries.yaml`)

The `custom_registries_yaml` block in `inventory/<cluster>/group_vars/all.yml`
is what `roles/k3s_custom_registries` writes (verbatim, via `blockinfile`) to
`/etc/rancher/k3s/registries.yaml` on every node. Both inventories are
**gitignored**, so the canonical copy of the block is recorded here. It holds
no auth — every in-cluster pull is anonymous from public Harbor projects — so
it is safe to keep in git. Keep this file in sync when the block changes.

Last rolled out: 2026-09-19 (Phase 4 of the Harbor HA mirror plan in
`homelab-k3s/plans/harbor-ha-mirror-and-otel-queue-bounding-plan.md`).

## How a pull resolves

containerd tries the endpoints for a mirror **in order, per request**
(manifest, config, every layer), falling through on a miss or error:

| Image host | 1st | 2nd | 3rd |
|---|---|---|---|
| `harbor.homecluster.co` (management) | `harbor-mgmt` | `harbor` (workload) | Spegel |
| `harbor.homecluster.co` (workload) | `harbor` (workload) | `harbor-mgmt` | Spegel |
| `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `mcr.microsoft.com` | Spegel | workload Harbor `<x>_cache` | `harbor-mgmt` `<x>_cache` |
| anything else (`"*"`) | Spegel | workload Harbor `docker_cache` | (containerd default: the real registry) |

- **Spegel** (`http://localhost:30021`) is the in-cluster P2P layer cache. It never
  pulls from anywhere: it only re-serves blobs that already exist in some node's
  containerd store, and 404s fast otherwise. It runs `containerdMirrorAdd: false`
  and mirrors `docker.io`, `ghcr.io`, `registry.k8s.io`, `harbor.homecluster.co`
  (not `quay.io`/`mcr.microsoft.com` — those always miss straight through). On the
  management cluster it runs only on Pi nodes, so on k3s-8 it always fails fast.
- **Spegel stays first for the public registries** on purpose: anything already in
  the cluster pulls node-to-node without touching Harbor/Longhorn/Unraid (the
  2026-09-17 root cause), which is what gets nodes back quickly after an outage.
  Verified 2026-09-19 that containerd's fall-through Spegel → Harbor works
  (images landed in the workload `docker_cache` the moment k3s-8 pulled them on a
  Spegel miss), so putting Harbor first would gain nothing and add Harbor
  timeouts to every request exactly when Harbor is sick.
- **Harbor is first for `harbor.homecluster.co`** because Spegel resolves a tag to
  whatever digest *some peer* holds — it serves stale mutable tags (`:latest`,
  or any re-pushed tag). The two Harbors replicate the hosted projects both ways
  (`util-image`, `finplanner`, `gymbuddy`, `closet`), so either answers with the
  same digests; each cluster prefers its local one. Spegel is the both-Harbors-
  down fallback. Prefer immutable per-build tags (e.g. the commit SHA) anyway.
- The mirror's proxy caches are the **third** endpoint everywhere (behind the
  workload Harbor's warm LAN copy) because they are internet-backed over a
  30 Mbit/s link.
- `configs."*"` sets `insecure_skip_verify` for every endpoint, including
  `harbor-mgmt.homecluster.co`.

## Rollout

`setup-custom-registries.yml` only writes the file; containerd re-reads
`registries.yaml` on k3s restart only. Use `upgrade-k3s.yml` (serial: 1,
restarts k3s only on nodes whose registries actually changed). It is not
`--limit`-safe — run it per inventory. `--check` first, **never `--diff`**
(blockinfile would print the file). `--skip-tags addons` keeps the run to the
node baseline. Management first, verify, then workload
(`-e k3s_upgrade_drain=false` there — see the playbook header).

```bash
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini --check -e k3s_upgrade_etcd_snapshot=false --skip-tags addons
ansible-playbook upgrade-k3s.yml -i inventory/homelab-cluster/hosts.ini --skip-tags addons
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
        - "http://localhost:30021"
    docker.io:
      endpoint:
        - "http://localhost:30021"
        - "https://harbor.homecluster.co/v2/docker_cache"
        - "https://harbor-mgmt.homecluster.co/v2/docker_cache"
    ghcr.io:
      endpoint:
        - "http://localhost:30021"
        - "https://harbor.homecluster.co/v2/ghcr_cache"
        - "https://harbor-mgmt.homecluster.co/v2/ghcr_cache"
    quay.io:
      endpoint:
        - "http://localhost:30021"
        - "https://harbor.homecluster.co/v2/quay_cache"
        - "https://harbor-mgmt.homecluster.co/v2/quay_cache"
    registry.k8s.io:
      endpoint:
        - "http://localhost:30021"
        - "https://harbor.homecluster.co/v2/k8s_cache"
        - "https://harbor-mgmt.homecluster.co/v2/k8s_cache"
    mcr.microsoft.com:
      endpoint:
        - "http://localhost:30021"
        - "https://harbor.homecluster.co/v2/mcr_cache"
        - "https://harbor-mgmt.homecluster.co/v2/mcr_cache"
    "*":
      endpoint:
        - "http://localhost:30021"
        - "https://harbor.homecluster.co/v2/docker_cache"
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

Identical to the management block except the `harbor.homecluster.co` entry,
which prefers the local (workload) Harbor:

```yaml
    harbor.homecluster.co:
      endpoint:
        - "https://harbor.homecluster.co"
        - "https://harbor-mgmt.homecluster.co"
        - "http://localhost:30021"
```
