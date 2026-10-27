#!/usr/bin/env bash
# Read-only cluster health check — run after a reboot (drained or not), an
# upgrade, or whenever something feels off. Changes nothing.
#
#   ./cluster-health.sh                  # homelab cluster (kube context "homelab")
#   ./cluster-health.sh workload         # workload cluster
#   ./cluster-health.sh homelab --no-ssh # API-side checks only
#
# Checks: API /readyz (incl. etcd), nodes (Ready, cordoned, pressure, version
# skew), workload controllers (deploy/sts/ds fully ready), bad pods
# (CrashLoop/ImagePull/Pending), leftover Failed pods, PVCs, LoadBalancer IPs
# (MetalLB; on homelab also a warning for any Cluster-policy LB), Longhorn
# (nodes, volume robustness, CSI driver registered on every
# node), ArgoCD app health/sync, recently failed Jobs. With SSH (default, user
# k3s): k3s service, failed systemd units, NTP sync, root disk, iscsid,
# reboot-required, uptime.
#
# Exit code: 0 = all OK, 1 = warnings only, 2 = at least one failure.
# Needs: kubectl, jq (and ssh for the node checks). Compatible with macOS bash 3.2.

set -uo pipefail

CONTEXT="homelab"
SSH_CHECKS=true
SSH_USER="${SSH_USER:-k3s}"
# Jobs that failed longer ago than this are history, not a post-reboot problem.
JOB_LOOKBACK_HOURS="${JOB_LOOKBACK_HOURS:-6}"

for arg in "$@"; do
  case "$arg" in
    --no-ssh) SSH_CHECKS=false ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    homelab|homelab-cluster) CONTEXT="homelab" ;;
    workload|workload-cluster) CONTEXT="workload" ;;
    -*) echo "unknown option: $arg" >&2; exit 64 ;;
    *) CONTEXT="$arg" ;;
  esac
done

for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 64; }
done

if [ -t 1 ]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; YEL=""; GRN=""; DIM=""; BLD=""; RST=""
fi

FAILS=0
WARNS=0
ok()      { printf '  %sOK%s    %s\n' "$GRN" "$RST" "$*"; }
warn()    { printf '  %sWARN%s  %s\n' "$YEL" "$RST" "$*"; WARNS=$((WARNS + 1)); }
fail()    { printf '  %sFAIL%s  %s\n' "$RED" "$RST" "$*"; FAILS=$((FAILS + 1)); }
detail()  { [ -n "$*" ] && printf '%s\n' "$*" | sed "s/^/        ${DIM}/; s/\$/${RST}/"; }
section() { printf '\n%s== %s ==%s\n' "$BLD" "$*" "$RST"; }

kc() { kubectl --context "$CONTEXT" --request-timeout=20s "$@"; }

# Fetch an object list as JSON; empty list if the resource type doesn't exist
# (e.g. no Longhorn or ArgoCD on this cluster).
kjson() { kc get "$@" -o json 2>/dev/null || echo '{"items":[]}'; }

printf '%sCluster health: context "%s" — %s%s\n' "$BLD" "$CONTEXT" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$RST"

# --- API server -------------------------------------------------------------
section "API server"
if readyz=$(kc get --raw='/readyz?verbose' 2>&1); then
  ok "/readyz passed ($(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null))"
  if printf '%s\n' "$readyz" | grep -q '^\[+\]etcd ok'; then ok "etcd readiness check ok"; fi
else
  fail "/readyz failed — nothing below can be trusted"
  detail "$(printf '%s\n' "$readyz" | grep -v '^\[+\]' | tail -15)"
  exit 2
fi

# --- Nodes ------------------------------------------------------------------
section "Nodes"
NODES=$(kjson nodes)
# Node rows are "|"-separated: read collapses runs of whitespace IFS (tabs), so
# an empty field would shift every column after it.
printf '%s' "$NODES" | jq -r '.items[] |
  [ .metadata.name,
    ((.status.conditions[] | select(.type=="Ready") | .status) // "Unknown"),
    (if .spec.unschedulable then "cordoned" else "-" end),
    .status.nodeInfo.kubeletVersion,
    # k3s adds positive conditions (EtcdIsVoter) — only flag the bad ones.
    ([.status.conditions[] | select((.type | test("Pressure$|NetworkUnavailable")) and .status=="True") | .type] | join(",")),
    ((.status.addresses[] | select(.type=="InternalIP") | .address) // "?"),
    (if .metadata.labels["node-role.kubernetes.io/control-plane"] then "server" else "agent" end)
  ] | join("|")' >"${TMPDIR:-/tmp}/cluster-health-nodes.$$"
trap 'rm -f "${TMPDIR:-/tmp}/cluster-health-nodes.$$"' EXIT

versions=""
while IFS='|' read -r name ready cordon version pressure ip role; do
  versions="$versions $version"
  if [ "$ready" != "True" ]; then fail "$name ($ip) NotReady (Ready=$ready)"; continue; fi
  msg="$name ($ip, $role) Ready, $version"
  if [ "$cordon" = "cordoned" ]; then warn "$msg — still CORDONED (kubectl uncordon $name)"
  elif [ -n "$pressure" ]; then warn "$msg — conditions: $pressure"
  else ok "$msg"
  fi
done <"${TMPDIR:-/tmp}/cluster-health-nodes.$$"
nver=$(printf '%s\n' $versions | sort -u | wc -l | tr -d ' ')
[ "$nver" -gt 1 ] && warn "kubelet version skew across nodes:$(printf ' %s' $(printf '%s\n' $versions | sort -u))"

# --- Workload controllers ---------------------------------------------------
section "Workloads"
bad=$(kjson deployments,statefulsets -A | jq -r '.items[]
  | select((.spec.replicas // 1) > 0)
  | select((.status.readyReplicas // 0) < (.spec.replicas // 1)
           or (.status.updatedReplicas // 0) < (.spec.replicas // 1))
  | "\(.kind)/\(.metadata.namespace)/\(.metadata.name) ready \(.status.readyReplicas // 0)/\(.spec.replicas // 1)"')
total=$(kjson deployments,statefulsets -A | jq '.items | length')
if [ -z "$bad" ]; then ok "all $total deployments/statefulsets fully ready"
else fail "$(printf '%s\n' "$bad" | wc -l | tr -d ' ') deployment(s)/statefulset(s) not fully ready"; detail "$bad"; fi

bad=$(kjson daemonsets -A | jq -r '.items[]
  | select((.status.numberReady // 0) < .status.desiredNumberScheduled
           or (.status.numberMisscheduled // 0) > 0)
  | "DaemonSet/\(.metadata.namespace)/\(.metadata.name) ready \(.status.numberReady // 0)/\(.status.desiredNumberScheduled)"')
if [ -z "$bad" ]; then ok "all daemonsets fully ready"
else fail "daemonset(s) not fully ready"; detail "$bad"; fi

# --- Pods -------------------------------------------------------------------
section "Pods"
PODS=$(kjson pods -A)
bad=$(printf '%s' "$PODS" | jq -r '.items[]
  | select(.status.phase=="Running" or .status.phase=="Pending")
  | . as $p
  | ([(.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[]]
     | map(.state.waiting.reason // empty)
     | map(select(test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainer|InvalidImageName|RunContainerError")))
     | first) as $r
  | select($r != null)
  | "\($p.metadata.namespace)/\($p.metadata.name) \($r)"')
if [ -z "$bad" ]; then ok "no pods crash-looping or failing image pulls"
else fail "pods in a failing state"; detail "$bad"; fi

bad=$(printf '%s' "$PODS" | jq -r '.items[]
  | select(.status.phase=="Pending")
  | "\(.metadata.namespace)/\(.metadata.name) Pending since \(.metadata.creationTimestamp) \((.status.conditions // [] | map(select(.status=="False") | .reason // empty) | join(",")))"')
if [ -z "$bad" ]; then ok "no Pending pods"
else warn "Pending pods (normal for a minute or two after a reboot)"; detail "$bad"; fi

bad=$(printf '%s' "$PODS" | jq -r '.items[]
  | select(.status.phase=="Running")
  | select([.status.containerStatuses[]? | .ready] | any(. == false))
  | "\(.metadata.namespace)/\(.metadata.name)"')
if [ -z "$bad" ]; then ok "all Running pods have every container ready"
else warn "Running pods with unready containers"; detail "$bad"; fi

# Pods killed by a non-drained shutdown are left in phase Failed (shown as
# "Error") with a live replacement elsewhere — harmless clutter, not an outage.
nfailed=$(printf '%s' "$PODS" | jq '[.items[] | select(.status.phase=="Failed")
  | select((.metadata.ownerReferences // [])[0].kind != "Job")] | length')
if [ "$nfailed" -gt 0 ]; then
  ok "$nfailed leftover Failed/Error non-Job pod(s) — replaced, safe to clean up:"
  detail "kubectl --context $CONTEXT delete pods -A --field-selector=status.phase=Failed"
fi

# --- Jobs -------------------------------------------------------------------
cutoff=$(( $(date +%s) - JOB_LOOKBACK_HOURS * 3600 ))
bad=$(kjson jobs -A | jq -r --argjson cutoff "$cutoff" '.items[]
  | select(any(.status.conditions[]?; .type=="Failed" and .status=="True"))
  | select((.metadata.creationTimestamp | fromdateiso8601) > $cutoff)
  | "\(.metadata.namespace)/\(.metadata.name) (created \(.metadata.creationTimestamp)) \((.status.conditions[] | select(.type=="Failed") | .reason) // "")"')
if [ -z "$bad" ]; then ok "no Jobs failed in the last ${JOB_LOOKBACK_HOURS}h"
else warn "Jobs failed in the last ${JOB_LOOKBACK_HOURS}h (often a cron run that landed mid-reboot)"; detail "$bad"; fi

# --- Storage & networking ---------------------------------------------------
section "Storage & networking"
bad=$(kjson pvc -A | jq -r '.items[] | select(.status.phase!="Bound") | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"')
if [ -z "$bad" ]; then ok "all PVCs Bound"; else fail "PVCs not Bound"; detail "$bad"; fi

bad=$(kjson svc -A | jq -r '.items[] | select(.spec.type=="LoadBalancer")
  | select((.status.loadBalancer.ingress // []) | length == 0)
  | "\(.metadata.namespace)/\(.metadata.name)"')
nlb=$(kjson svc -A | jq '[.items[] | select(.spec.type=="LoadBalancer")] | length')
if [ -z "$bad" ]; then ok "all $nlb LoadBalancer services have an external IP (MetalLB)"
else fail "LoadBalancer services without an external IP"; detail "$bad"; fi

# Management only: the kitchen agent k3s-9 runs a MetalLB speaker but only
# kitchen pods. In L2 mode a Cluster-policy Service can be announced from any
# speaker node -- including k3s-9 -- so every management LB must be Local.
if [ "$CONTEXT" = "homelab" ]; then
  bad=$(kjson svc -A | jq -r '.items[] | select(.spec.type=="LoadBalancer")
    | select((.spec.externalTrafficPolicy // "Cluster") == "Cluster")
    | "\(.metadata.namespace)/\(.metadata.name)"')
  if [ -z "$bad" ]; then ok "all LoadBalancer services use externalTrafficPolicy Local"
  else warn "LoadBalancer services with externalTrafficPolicy Cluster (may be announced from the kitchen node)"; detail "$bad"; fi
fi

# --- Longhorn ---------------------------------------------------------------
LH_NODES=$(kjson nodes.longhorn.io -n longhorn-system)
if [ "$(printf '%s' "$LH_NODES" | jq '.items | length')" -gt 0 ]; then
  section "Longhorn"
  bad=$(printf '%s' "$LH_NODES" | jq -r '.items[]
    | . as $n
    | [.status.conditions[]? | select((.type=="Ready" or .type=="Schedulable") and .status!="True") | "\(.type)=\(.status) \(.message // "")"]
    | select(length > 0)
    | "\($n.metadata.name): \(join("; "))"')
  if [ -z "$bad" ]; then ok "all Longhorn nodes Ready and Schedulable"
  else fail "Longhorn node problems"; detail "$bad"; fi

  # The CSI node plugin must re-register with kubelet after a reboot; until it
  # does, every Longhorn mount on that node fails ("driver name
  # driver.longhorn.io not found in the list of registered CSI drivers").
  missing=$(kjson csinodes | jq -r '.items[]
    | select([.spec.drivers[]?.name] | index("driver.longhorn.io") | not) | .metadata.name')
  if [ -z "$missing" ]; then ok "Longhorn CSI driver registered on every node"
  else fail "Longhorn CSI driver NOT registered on: $(echo $missing)"; fi

  VOLS=$(kjson volumes.longhorn.io -n longhorn-system)
  summary=$(printf '%s' "$VOLS" | jq -r '[.items[] | "\(.status.state)/\(.status.robustness)"]
    | group_by(.) | map("\(length) \(.[0])") | join(", ")')
  faulted=$(printf '%s' "$VOLS" | jq -r '.items[] | select(.status.robustness=="faulted") | .metadata.name')
  degraded=$(printf '%s' "$VOLS" | jq -r '.items[] | select(.status.robustness=="degraded")
    | "\(.metadata.name) (\(.status.kubernetesStatus.namespace // "-")/\(.status.kubernetesStatus.pvcName // "-"))"')
  if [ -n "$faulted" ]; then fail "faulted Longhorn volume(s) — data unavailable"; detail "$faulted"; fi
  if [ -n "$degraded" ]; then warn "degraded Longhorn volume(s) — replicas rebuilding, recheck shortly"; detail "$degraded"; fi
  [ -z "$faulted" ] && [ -z "$degraded" ] && ok "volumes: $summary"

  # Engines stuck attaching are the classic symptom of a non-drained reboot.
  stuck=$(printf '%s' "$VOLS" | jq -r '.items[] | select(.status.state=="attaching" or .status.state=="detaching")
    | "\(.metadata.name) \(.status.state) on \(.status.currentNodeID // "?")"')
  [ -n "$stuck" ] && { warn "volumes mid attach/detach"; detail "$stuck"; }
fi

# --- ArgoCD -----------------------------------------------------------------
APPS=$(kjson applications.argoproj.io -A)
if [ "$(printf '%s' "$APPS" | jq '.items | length')" -gt 0 ]; then
  section "ArgoCD"
  napps=$(printf '%s' "$APPS" | jq '.items | length')
  bad=$(printf '%s' "$APPS" | jq -r '.items[]
    | select(.status.health.status!="Healthy" or .status.sync.status!="Synced")
    | "\(.metadata.name): \(.status.sync.status // "?")/\(.status.health.status // "?")"
      + ([.status.resources[]? | select((.health.status // "Healthy") != "Healthy")
          | "\n  \(.kind)/\(.namespace // "")/\(.name) \(.health.status) \(.health.message // "")"] | join(""))')
  if [ -z "$bad" ]; then ok "all $napps applications Synced/Healthy"
  else warn "applications not Synced/Healthy (Degraded with no resource listed is usually a CronJob whose last run failed)"; detail "$bad"; fi
fi

# --- Per-node (SSH) ---------------------------------------------------------
if $SSH_CHECKS; then
  section "Node OS (ssh $SSH_USER@)"
  while IFS='|' read -r name _ _ _ _ ip role; do
    unit=k3s; [ "$role" = "agent" ] && unit=k3s-node
    # shellcheck disable=SC2016  # expanded on the node, not here
    out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$ip" '
      echo "svc=$(systemctl is-active '"$unit"')"
      echo "failed=$(systemctl --failed --no-legend --plain | awk "{print \$1}" | paste -sd, -)"
      echo "ntp=$(timedatectl show -p NTPSynchronized --value)"
      echo "disk=$(df --output=pcent / | tail -1 | tr -d " %")"
      echo "iscsid=$(systemctl is-active iscsid 2>/dev/null)"
      echo "reboot=$([ -f /var/run/reboot-required ] && echo yes || echo no)"
      echo "up=$(uptime -p | sed "s/^up //")"' 2>&1) || { fail "$name ($ip): ssh failed — $(printf '%s' "$out" | tail -1)"; continue; }
    get() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
    problems=""; warnings=""
    [ "$(get svc)" = "active" ] || problems="$problems $unit=$(get svc);"
    [ "$(get ntp)" = "yes" ] || problems="$problems clock NOT NTP-synced (etcd/TLS risk);"
    [ "$(get disk)" -ge 90 ] 2>/dev/null && problems="$problems root disk $(get disk)%;"
    [ "$(get disk)" -ge 80 ] 2>/dev/null && [ "$(get disk)" -lt 90 ] && warnings="$warnings root disk $(get disk)%;"
    [ -n "$(get failed)" ] && warnings="$warnings failed units: $(get failed);"
    [ "$(get iscsid)" = "active" ] || warnings="$warnings iscsid=$(get iscsid);"
    [ "$(get reboot)" = "yes" ] && warnings="$warnings reboot-required;"
    base="$name: $unit active, up $(get up), disk $(get disk)%"
    if [ -n "$problems" ]; then fail "$name:$problems$warnings"
    elif [ -n "$warnings" ]; then warn "$base —$warnings"
    else ok "$base"
    fi
  done <"${TMPDIR:-/tmp}/cluster-health-nodes.$$"
fi

# --- Summary ----------------------------------------------------------------
section "Summary"
if [ "$FAILS" -gt 0 ]; then
  printf '  %s%d failure(s), %d warning(s)%s\n' "$RED" "$FAILS" "$WARNS" "$RST"; exit 2
elif [ "$WARNS" -gt 0 ]; then
  printf '  %s0 failures, %d warning(s)%s\n' "$YEL" "$WARNS" "$RST"; exit 1
else
  printf '  %sAll checks passed%s\n' "$GRN" "$RST"; exit 0
fi
