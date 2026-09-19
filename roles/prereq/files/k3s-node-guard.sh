#!/usr/bin/env bash
# k3s-node-guard: hourly node hygiene that must keep working when the cluster
# itself is unhealthy (no kubectl, no SigNoz, no Harbor needed).
#
# Added after the 2026-09-17/18 workload-cluster outage, where etcd fsync
# latency crash-looped k3s ~50x/day; every k3s restart killed containerd
# mid-pull, leaving hundreds of dangling leases that pinned superseded image
# layers (12-27G/node the CRI no longer knew about), which together with an
# unbounded otel-agent hostPath queue and an uncapped rsyslog filled the 60G
# root disks and cascaded into Longhorn/Harbor/collector failures.
#
# 1. Always: remove containerd leases older than LEASE_MAX_AGE_H. containerd has
#    no config knob for this (the transfer service hard-codes 24h, CRI pull
#    leases have no expiry at all). Removing a lease triggers containerd's GC.
# 2. Always: delete orphaned file_storage compaction temp files (tempdb*) that
#    a mid-compaction kill leaves behind in the otel queue dirs. Since the
#    agent queue moved to an emptyDir (2026-09-19) PURGE_DIRS is a glob under
#    /var/lib/kubelet/pods -- expanded unquoted on purpose.
# 3. Only when the root fs is at/over DISK_PRESSURE_PCT: purge the disposable
#    dirs in PURGE_DIRS (restarting the otel-agent container so it releases its
#    open queue file) and vacuum the journal. The threshold sits just below
#    kubelet's soft-eviction line (nodefs.available < 10%) so hostPath data --
#    which kubelet can't see or attribute -- is cleared before kubelet starts
#    evicting pods that won't free anything.
#
# Deliberately NOT done: image pruning. kubelet's image GC already removes
# unused images LRU-first once the disk passes 85% (imageGCHighThresholdPercent),
# and the cached images are what Spegel serves to peers -- the lease sweep only
# removes leftovers of interrupted pulls, never complete images.
#
# Thresholds come from /etc/default/k3s-node-guard (templated by ansible).

set -Eeuo pipefail

LEASE_MAX_AGE_H="${LEASE_MAX_AGE_H:-2}"
DISK_PRESSURE_PCT="${DISK_PRESSURE_PCT:-88}"
PURGE_DIRS="${PURGE_DIRS:-/var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir/otel-agent-queue}"  # unquoted expansion below: globs work
JOURNAL_VACUUM_SIZE="${JOURNAL_VACUUM_SIZE:-300M}"
TEMPDB_MAX_AGE_MIN="${TEMPDB_MAX_AGE_MIN:-60}"

CTR=(k3s ctr -n k8s.io)
CRICTL=(k3s crictl)

log() { logger -t k3s-node-guard -- "$*"; printf '%s\n' "$*"; }
root_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }
root_free() { df --output=avail -h / | tail -1 | tr -d ' '; }

# --- 1. stale containerd leases -------------------------------------------
now=$(date +%s)
removed=0
skipped=0
while read -r id created _; do
  [ -n "$id" ] || continue
  if ! ts=$(date -d "$created" +%s 2>/dev/null); then
    skipped=$((skipped + 1))
    continue
  fi
  if (( now - ts > LEASE_MAX_AGE_H * 3600 )); then
    if "${CTR[@]}" leases rm "$id" >/dev/null 2>&1; then
      removed=$((removed + 1))
    else
      skipped=$((skipped + 1))
    fi
  fi
done < <("${CTR[@]}" leases ls 2>/dev/null | tail -n +2)
(( removed > 0 || skipped > 0 )) && log "leases: removed=$removed (older than ${LEASE_MAX_AGE_H}h) skipped=$skipped"

# --- 2. orphaned otel file_storage compaction temp files ------------------
for d in $PURGE_DIRS; do
  [ -d "$d" ] || continue
  n=$(find "$d" -maxdepth 1 -type f -name 'tempdb*' -mmin "+${TEMPDB_MAX_AGE_MIN}" -print -delete | wc -l)
  (( n > 0 )) && log "orphaned tempdb files removed from $d: $n"
done

# --- 3. disk-pressure response ---------------------------------------------
pct=$(root_pct)
if (( pct >= DISK_PRESSURE_PCT )); then
  log "root fs at ${pct}% (>= ${DISK_PRESSURE_PCT}%, $(root_free) free): purging disposable data"

  for d in $PURGE_DIRS; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -delete
    log "purged $d"
  done
  # The otel agent keeps its queue file open; the space only comes back once
  # the container restarts. kubelet restarts it immediately.
  "${CRICTL[@]}" ps -q --name 'k8s-infra-otel-agent' 2>/dev/null \
    | xargs -r "${CRICTL[@]}" stop >/dev/null 2>&1 || true

  journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" >/dev/null 2>&1 || true

  log "after purge: root fs at $(root_pct)% ($(root_free) free)"
fi
