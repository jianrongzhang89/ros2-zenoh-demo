#!/usr/bin/env bash
# scripts/test-negative-ocp.sh
# Negative tests: router/bridge disconnect, network partition, and routing recovery
# on an OpenShift/Kubernetes cluster running the ros2-zenoh-federation topology.
#
# Mirrors scripts/test-negative.sh, adapted for kubectl instead of podman-compose.
# Each scenario uses the already-deployed federation stack (cloud-router, edge-router,
# edge-talker, cloud-listener) and injects failures via kubectl primitives:
#   - Router crash: kubectl exec -- kill -9/-15 1 (container auto-restarts)
#   - WAN partition: apply/delete k8s/federation/np-partition-edge.yaml (NetworkPolicy)
#   - Bridge restart: kubectl exec -c zenoh-bridge -- kill -9 1
#
# Prerequisites:
#   - kubectl configured against the target cluster
#   - Namespace ros2-zenoh-federation with all 4 deployments Running (make deploy-federation)
#
# Usage:
#   bash scripts/test-negative-ocp.sh               # all scenarios
#   SCENARIO=N1 bash scripts/test-negative-ocp.sh   # one scenario
#   make test-negative-ocp
#   make test-negative-ocp-scenario N=N3
#
# Tuning (env vars):
#   NAMESPACE=ros2-zenoh-federation
#   FLOW_TIMEOUT=30       seconds to wait for a message that SHOULD arrive
#   BLOCK_TIMEOUT=12      seconds to wait for a message that SHOULD be blocked
#   ROLLOUT_TIMEOUT=120   seconds for kubectl rollout status
#   SETTLE=20             seconds after rollout for bridge DDS re-discovery
#   OUTAGE_SECS=30        seconds to hold a failure before restoring
#   RECONNECT_TIMEOUT=90  seconds max wait for recovery (FAIL if exceeded)
#   ADMIN_TIMEOUT=30      seconds to poll router REST APIs via port-forward

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS="$ROOT/k8s/federation"
NP_PARTITION="$MANIFESTS/np-partition-edge.yaml"

NAMESPACE="${NAMESPACE:-ros2-zenoh-federation}"
FLOW_TIMEOUT="${FLOW_TIMEOUT:-30}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-12}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120}"
SETTLE="${SETTLE:-20}"
OUTAGE_SECS="${OUTAGE_SECS:-30}"
RECONNECT_TIMEOUT="${RECONNECT_TIMEOUT:-180}"
ADMIN_TIMEOUT="${ADMIN_TIMEOUT:-30}"

PASS=0
FAIL=0
NOTES=()
PF_PIDS=()

cleanup() {
  stop_port_forwards
  restore_link 2>/dev/null || true
}
trap cleanup EXIT

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
pass()  { printf "  ${GREEN}PASS${RESET}  %s\n" "$*"; ((PASS++)) || true; }
fail()  { printf "  ${RED}FAIL${RESET}  %s\n" "$*"; ((FAIL++)) || true; }
note()  { printf "  ${YELLOW}NOTE${RESET}  %s\n" "$*"; NOTES+=("$*"); }
sep()   { printf "\n── %s\n" "$*"; }

# ── Prerequisite check ────────────────────────────────────────────────────────
check_prereqs() {
  local ok=1
  command -v kubectl &>/dev/null || { echo "ERROR: kubectl not found"; ok=0; }
  command -v curl    &>/dev/null || { echo "ERROR: curl not found";    ok=0; }
  [ "$ok" -eq 1 ] || { echo "Install missing tools and re-run."; exit 1; }

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "ERROR: namespace '$NAMESPACE' does not exist. Run: make deploy-federation"
    exit 1
  fi
}

# ── Pod helpers ───────────────────────────────────────────────────────────────
pod_for() {
  kubectl get pods -n "$NAMESPACE" -l "app=$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

wait_rollout() {
  local dep="$1"
  echo "  [rollout] Waiting for $dep ..."
  # Show rollout status output so failures are visible; || true so set -e doesn't exit.
  kubectl rollout status deployment/"$dep" -n "$NAMESPACE" \
    --timeout="${ROLLOUT_TIMEOUT}s" || {
    echo "  [rollout] WARNING: rollout status for $dep returned non-zero — checking pod state..."
    kubectl get pods -n "$NAMESPACE" -l "app=$dep" --no-headers 2>/dev/null || true
    return 0   # treat as non-fatal; check_flows will detect actual message failures
  }
}

wait_pod_ready() {
  local app="$1" timeout="${2:-$RECONNECT_TIMEOUT}"
  kubectl wait pod -n "$NAMESPACE" -l "app=$app" \
    --for=condition=Ready --timeout="${timeout}s" &>/dev/null || true
}

# ── Stack baseline ────────────────────────────────────────────────────────────
# ensure_base does NOT apply manifests — the cluster is pre-deployed via
# "make deploy-federation" which uses the correct image tags. Re-applying the
# manifests from disk would change :1.9.0 → :latest and trigger a broken rollout.
# Instead, we only clean up test artifacts (NetworkPolicy) and wait for all
# deployments to be healthy before each scenario.
ensure_base() {
  echo "  [base] Ensuring federation deployments are healthy..."
  kubectl delete networkpolicy partition-edge-to-cloud \
    -n "$NAMESPACE" --ignore-not-found &>/dev/null || true
  for dep in cloud-router edge-router edge-talker cloud-listener; do
    wait_rollout "$dep"
  done
  echo "  [settle] Waiting ${SETTLE}s for bridge DDS discovery..."
  sleep "$SETTLE"
}

# ── Failure injection primitives ──────────────────────────────────────────────
# Kill a pod or app in a Kubernetes-native way.
#
# OCP's restricted SCC seccomp profile blocks kill(2) targeting PID 1 inside
# a container, so 'kubectl exec -- sh -c "kill -9 1"' is silently ignored.
# The reliable OCP-native equivalent is:
#   SIGKILL → kubectl delete pod --force --grace-period=0 (pod gone in < 1s)
#   SIGTERM → kubectl delete pod                           (sends SIGTERM, 30s grace)
#
# For sidecar containers: OCP also blocks in-pod PID 1 signals to the
# container's own PID 1, so we delete the whole pod (both containers restart).
# N5/N6 documents this difference from the local test in its output.
kill_svc() {
  local app="$1" signal="${2:-SIGKILL}" container="${3:-}"
  local pod; pod=$(pod_for "$app")
  if [ -z "$pod" ]; then
    echo "    ERROR: no Running pod found for app=$app"
    return 1
  fi

  case "$signal" in
    SIGKILL|9)
      kubectl delete pod -n "$NAMESPACE" "$pod" \
        --grace-period=0 --force &>/dev/null || true
      ;;
    SIGTERM|15)
      kubectl delete pod -n "$NAMESPACE" "$pod" &>/dev/null || true
      ;;
  esac
  echo "  [kill] $signal pod/$pod${container:+ (sidecar=$container, whole-pod delete)}"
}

# Wait until a new Running pod for app appears (used after kill_svc).
wait_new_pod() {
  local app="$1" timeout="${2:-60}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local p; p=$(pod_for "$app")
    [ -n "$p" ] && return 0
    sleep 2
  done
  echo "    WARNING: no Running pod for app=$app within ${timeout}s"
  return 1
}

partition_link() {
  kubectl apply -f "$NP_PARTITION" -n "$NAMESPACE" &>/dev/null
  echo "  [partition] applied NetworkPolicy partition-edge-to-cloud"
}

restore_link() {
  kubectl delete -f "$NP_PARTITION" -n "$NAMESPACE" --ignore-not-found &>/dev/null || true
  echo "  [restore] deleted NetworkPolicy partition-edge-to-cloud"
}

# ── Topic flow check ──────────────────────────────────────────────────────────
check_flows() {
  local topic="$1"
  local timeout="${2:-$FLOW_TIMEOUT}"
  local pod; pod=$(pod_for cloud-listener)
  [ -n "$pod" ] || { echo "    ERROR: cloud-listener not running"; return 1; }
  kubectl exec -n "$NAMESPACE" "$pod" -c ros2-listener -- bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $timeout ros2 topic echo '$topic' 2>/dev/null | grep -m 1 'data:'
  " &>/dev/null   # suppress grep output so it never contaminates $() captures
}

assert_flows() {
  local topic="$1"
  if check_flows "$topic" "$FLOW_TIMEOUT"; then
    pass "$topic flows (baseline confirmed)"
  else
    fail "$topic expected to flow — no message in ${FLOW_TIMEOUT}s"
  fi
}

assert_blocked() {
  local topic="$1"
  if ! check_flows "$topic" "$BLOCK_TIMEOUT"; then
    pass "$topic not flowing as expected"
  else
    fail "$topic still flowing unexpectedly"
  fi
}

# ── Recovery timing ───────────────────────────────────────────────────────────
# Polls check_flows every 5s until a message arrives or the deadline.
# Echoes elapsed seconds from kill_epoch on success, -1 on timeout.
measure_recovery() {
  local topic="$1" kill_epoch="$2" timeout="${3:-$RECONNECT_TIMEOUT}"
  local deadline=$(( kill_epoch + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if check_flows "$topic" 8; then
      echo $(( $(date +%s) - kill_epoch ))
      return 0
    fi
    sleep 5
  done
  echo -1
  return 1
}

# ── Log inspection ────────────────────────────────────────────────────────────
log_check() {
  local app="$1" pattern="$2"
  kubectl logs -n "$NAMESPACE" -l "app=$app" --tail=200 2>/dev/null | grep -q "$pattern"
}

# ── Port-forward helpers ──────────────────────────────────────────────────────
start_port_forwards() {
  kubectl port-forward -n "$NAMESPACE" service/cloud-router 8001:8001 &>/dev/null &
  PF_PIDS+=($!)
  kubectl port-forward -n "$NAMESPACE" service/edge-router  8002:8002 &>/dev/null &
  PF_PIDS+=($!)
  sleep 3
}

stop_port_forwards() {
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  PF_PIDS=()
}

wait_for_router_api() {
  local url="$1" label="$2"
  local deadline=$(( $(date +%s) + ADMIN_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local body
    body=$(curl -sf --max-time 3 "$url" 2>/dev/null || true)
    if [ -n "$body" ] && [ "$body" != "{}" ] && [ "$body" != "null" ] && [ "$body" != "[]" ]; then
      echo "$body"
      return 0
    fi
    sleep 2
  done
  echo "    TIMEOUT: $label not responding within ${ADMIN_TIMEOUT}s"
  return 1
}

# ── Scenario N1: SIGKILL edge-router ─────────────────────────────────────────
scenario_N1() {
  sep "Scenario N1: SIGKILL edge-router — abrupt crash"
  echo "  Container exits; Deployment controller restarts it automatically."

  ensure_base
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N1] Sending SIGKILL to edge-router at $(date -u +%H:%M:%S)..."
  kill_svc edge-router SIGKILL

  sleep 8  # allow bridge-talker wait_before_close(5s) buffer to drain
  if ! check_flows /chatter "$BLOCK_TIMEOUT"; then
    pass "N1: /chatter stops after pod deletion (expected)"
  else
    note "N1: /chatter still flowing 8s after pod deletion — extended buffering"
  fi

  # Don't wait for pod readiness explicitly — measure_recovery polls check_flows
  # directly, which naturally waits for the new pod, bridge reconnect, and DDS
  # re-discovery.  OCP pod startup can take 60-90s (image scheduling + pull).
  echo "  [N1] Polling for /chatter recovery (up to ${RECONNECT_TIMEOUT}s)..."
  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N1: /chatter resumes in ${recover_time}s after pod deletion"
    if [ "$recover_time" -gt 60 ]; then
      note "N1: ${recover_time}s recovery — OCP image scheduling or pull delay"
    fi
  else
    fail "N1: /chatter did not resume within ${RECONNECT_TIMEOUT}s"
  fi
}

# ── Scenario N2: SIGTERM edge-router ─────────────────────────────────────────
scenario_N2() {
  sep "Scenario N2: SIGTERM edge-router — graceful shutdown"

  ensure_base
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N2] Sending SIGTERM to edge-router at $(date -u +%H:%M:%S)..."
  kill_svc edge-router SIGTERM

  sleep 15  # SIGTERM + 30s grace: data may still flow during graceful drain
  if ! check_flows /chatter "$BLOCK_TIMEOUT"; then
    pass "N2: /chatter stops after pod graceful termination"
  else
    note "N2: /chatter still flowing during grace period — graceful drain in progress"
  fi

  echo "  [N2] Polling for /chatter recovery (up to ${RECONNECT_TIMEOUT}s)..."
  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N2: /chatter resumes in ${recover_time}s after graceful shutdown + pod restart"
  else
    fail "N2: /chatter did not resume within ${RECONNECT_TIMEOUT}s"
  fi
}

# ── Scenario N3: Fast-cycle restart (Issue #1886 race) ────────────────────────
scenario_N3() {
  sep "Scenario N3: Fast-cycle restart — Issue #1886 race condition reproducer"
  echo "  SIGKILL edge-router then rollout restart 0.5s later."
  echo "  Kubernetes restarts the container immediately; rollout restart creates a"
  echo "  new pod while the old container is still tearing down — same race as the"
  echo "  0.5s local test. PR #2438 / Zenoh 1.9.0 should prevent the routing halt."

  ensure_base
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N3] kubectl rollout restart edge-router (new pod starts while old terminates)..."
  # In OCP, kubectl rollout restart is the direct equivalent of the local fast-cycle:
  # it creates a new pod (new ZID) while the old pod is still in the Terminating
  # phase, producing the same race window as SIGKILL + 0.5s + restart locally.
  kubectl rollout restart deployment/edge-router -n "$NAMESPACE" &>/dev/null

  sleep 10  # let both pods coexist briefly, then declaration exchange complete or fail

  if log_check cloud-router "unknown routing context id 0"; then
    note "N3: Issue #1886 signature detected in cloud-router logs"
    note "N3:   PR #2438 / Kiyohime fix may not be active for this topology"
  else
    pass "N3: no routing-context race error in cloud-router logs (fix effective)"
  fi

  echo "  [N3] Polling for /chatter recovery (up to ${RECONNECT_TIMEOUT}s)..."
  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N3: /chatter resumes in ${recover_time}s after rollout restart"
  else
    fail "N3: /chatter did not resume within ${RECONNECT_TIMEOUT}s"
    note "N3: worst case — full namespace redeployment may be required"
  fi
}

# ── Scenario N4: Network partition ───────────────────────────────────────────
scenario_N4() {
  sep "Scenario N4: Network partition — NetworkPolicy blocks edge-router egress to cloud"
  echo "  Applies np-partition-edge.yaml to sever the WAN federation link."
  echo "  OVN-Kubernetes enforces NetworkPolicy synchronously — no propagation lag."

  ensure_base
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N4] Applying WAN partition NetworkPolicy at $(date -u +%H:%M:%S)..."
  partition_link

  sleep 5
  assert_blocked /chatter

  local remaining=$(( OUTAGE_SECS - 5 ))
  echo "  [N4] Holding partition ${remaining}s more (total: ${OUTAGE_SECS}s)..."
  sleep "$remaining"

  echo "  [N4] Removing NetworkPolicy at $(date -u +%H:%M:%S)..."
  restore_link

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N4: /chatter resumes in ${recover_time}s after WAN link restored (self-healing)"
  else
    fail "N4: /chatter did not resume within ${RECONNECT_TIMEOUT}s"
  fi
}

# ── Scenarios N5+N6: Bridge sidecar restart ───────────────────────────────────
scenario_N5_N6() {
  sep "Scenarios N5+N6: Bridge sidecar restart (first, then second)"
  echo "  OCP NOTE: OCP seccomp blocks in-pod kill of PID 1, so we delete the"
  echo "  entire edge-talker pod (both ros2-talker + zenoh-bridge restart together)."
  echo "  The initContainer (wait-for-edge-router) runs before bridge starts."
  echo "  N5: first pod restart — routes rebuilt on fresh session."
  echo "  N6: second pod restart — probes Issue #86 (silent delivery failure)."

  ensure_base
  assert_flows /chatter

  # N5: first restart
  sep "N5: First edge-talker pod restart"
  echo "  [N5] Deleting edge-talker pod (both containers restart via Deployment)..."
  local kill_time_n5; kill_time_n5=$(date +%s)
  kill_svc edge-talker SIGKILL

  echo "  [N5] Polling for /chatter recovery (up to ${RECONNECT_TIMEOUT}s)..."
  local recover_n5
  recover_n5=$(measure_recovery /chatter "$kill_time_n5" "$RECONNECT_TIMEOUT") || recover_n5=-1

  if [ "$recover_n5" -ge 0 ] 2>/dev/null; then
    pass "N5: /chatter resumes in ${recover_n5}s after first edge-talker pod restart"
  else
    fail "N5: /chatter did not resume after first pod restart (unexpected)"
  fi

  # N6: second restart
  sep "N6: Second edge-talker pod restart (Issue #86 probe)"
  echo "  [N6] Deleting edge-talker pod a second time..."
  local kill_time_n6; kill_time_n6=$(date +%s)
  kill_svc edge-talker SIGKILL

  echo "  [N6] Polling for /chatter recovery (up to ${RECONNECT_TIMEOUT}s)..."

  local recover_n6
  recover_n6=$(measure_recovery /chatter "$kill_time_n6" "$RECONNECT_TIMEOUT") || recover_n6=-1

  if [ "$recover_n6" -ge 0 ] 2>/dev/null; then
    pass "N6: /chatter still flows after second pod restart (Issue #86 not reproduced)"
  else
    fail "N6: zero messages after second pod restart — potential Issue #86 or init timing"
    note "N6: if failure is consistent, check zenoh-bridge reconnect after initContainer"
  fi
}

# ── Scenario N7: Advanced Pub/Sub E2E recovery (SKIP) ────────────────────────
scenario_N7() {
  sep "Scenario N7: Advanced Pub/Sub E2E sample recovery (SKIP)"
  note "N7 SKIP: requires ROS 2 publisher with TRANSIENT_LOCAL QoS durability"
  note "N7 SKIP: rmw_zenoh PR #591 (Apr 2025) enables AdvancedPublisher for RELIABLE+TRANSIENT_LOCAL"
  note "N7 SKIP: rmw_zenoh Issue #457 tracks extension to all RELIABLE topics (open mid-2026)"
}

# ── Scenario N8: Baseline loss estimate ──────────────────────────────────────
scenario_N8() {
  sep "Scenario N8: Baseline loss estimate — 30s WAN outage at 10 Hz (/chatter)"
  echo "  multi-pub.sh publishes /chatter at 10 Hz. Partition WAN for ${OUTAGE_SECS}s."
  echo "  Expected gaps ≈ 10 Hz × (${OUTAGE_SECS}s outage + reconnect_tail) messages."
  echo "  NOTE: bench_pub/sub (50 Hz, precise gap count) requires adding scripts to"
  echo "        configmap-federation.yaml and mounting into talker/listener pods."

  ensure_base
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N8] Partitioning WAN at $(date -u +%H:%M:%S) (outage: ${OUTAGE_SECS}s)..."
  partition_link
  sleep 3
  assert_blocked /chatter

  local remaining=$(( OUTAGE_SECS - 3 ))
  echo "  [N8] Holding partition ${remaining}s more..."
  sleep "$remaining"

  echo "  [N8] Restoring WAN at $(date -u +%H:%M:%S)..."
  restore_link

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N8: /chatter resumes in ${recover_time}s"
    local outage_actual=$(( recover_time ))
    local reconnect_tail=$(( outage_actual - OUTAGE_SECS ))
    local estimated_gaps=$(( 10 * outage_actual ))
    pass "N8: estimated gaps ≈ 10 Hz × ${outage_actual}s = ~${estimated_gaps} messages (outage ${OUTAGE_SECS}s + ~${reconnect_tail}s tail)"
  else
    fail "N8: /chatter did not resume within ${RECONNECT_TIMEOUT}s"
  fi
}

# ── Scenario N9: Drop vs Block (SKIP) ────────────────────────────────────────
scenario_N9() {
  sep "Scenario N9: CongestionControl::Drop vs Block comparison (SKIP)"
  note "N9 SKIP: requires a direct Zenoh Python/Rust API publisher (not ROS 2 middleware)"
  note "N9 SKIP: Block (rmw_zenoh RELIABLE default): publisher blocks up to wait_before_close=5s"
  note "N9 SKIP: Drop (best-effort): messages discarded after wait_before_drop=1ms"
  note "N9 SKIP: See DEFAULT_CONFIG.json5: transport.link.tx.queue.congestion_control"
}

# ── Scenario N10: Federation link + admin-space validation ───────────────────
scenario_N10() {
  sep "Scenario N10: Federation link failure — admin-space session monitoring"
  echo "  NetworkPolicy WAN partition + REST API polling via port-forward."

  ensure_base
  assert_flows /chatter

  # Open port-forwards for admin API queries
  start_port_forwards

  echo "  [N10] Checking cloud-router admin space before partition..."
  if wait_for_router_api 'http://localhost:8001/@/router/local/session/**' "cloud-router" >/dev/null 2>&1; then
    pass "N10: cloud-router admin space populated (federation session active)"
  else
    note "N10: cloud-router admin space appears empty before partition (may be sparse in v1.9.0)"
  fi

  local kill_time; kill_time=$(date +%s)
  echo "  [N10] Applying WAN partition NetworkPolicy at $(date -u +%H:%M:%S)..."
  partition_link

  # Poll admin space for session drop
  echo "  [N10] Polling admin space up to ${ADMIN_TIMEOUT}s for session drop..."
  local deadline=$(( $(date +%s) + ADMIN_TIMEOUT ))
  local session_dropped=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local cur_body
    cur_body=$(curl -sf --max-time 3 'http://localhost:8001/@/router/local' 2>/dev/null || echo "")
    if [ "$cur_body" = "[]" ] || [ -z "$cur_body" ]; then
      session_dropped=1
      local elapsed=$(( $(date +%s) - kill_time ))
      echo "    admin space cleared at T+${elapsed}s after partition"
      break
    fi
    sleep 3
  done

  if [ "$session_dropped" -eq 1 ]; then
    pass "N10: cloud-router admin space cleared after partition (session dropped)"
  else
    note "N10: session still visible ${ADMIN_TIMEOUT}s after partition — keepalive timeout > ADMIN_TIMEOUT"
    note "N10: increase ADMIN_TIMEOUT to observe; actual expiry ≈ lease(10s) + keepalive intervals"
  fi

  local remaining=$(( OUTAGE_SECS - ADMIN_TIMEOUT ))
  if [ "$remaining" -gt 0 ]; then
    echo "  [N10] Holding partition ${remaining}s more (total: ${OUTAGE_SECS}s)..."
    sleep "$remaining"
  fi

  echo "  [N10] Removing NetworkPolicy at $(date -u +%H:%M:%S)..."
  restore_link

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N10: /chatter resumes in ${recover_time}s after WAN link restored"
  else
    fail "N10: /chatter did not resume within ${RECONNECT_TIMEOUT}s"
  fi

  # Check admin space repopulated
  if wait_for_router_api 'http://localhost:8001/@/router/local/session/**' "cloud-router post-restore" >/dev/null 2>&1; then
    pass "N10: cloud-router admin space repopulated (federation session restored)"
  else
    note "N10: admin space not repopulated within ${ADMIN_TIMEOUT}s after restore"
  fi

  stop_port_forwards
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  echo ""
  echo "=== Zenoh Negative Tests — OpenShift/Kubernetes ==="
  echo "    Namespace          : $NAMESPACE"
  echo "    Flow timeout       : ${FLOW_TIMEOUT}s"
  echo "    Block timeout      : ${BLOCK_TIMEOUT}s"
  echo "    Reconnect timeout  : ${RECONNECT_TIMEOUT}s"
  echo "    Outage duration    : ${OUTAGE_SECS}s"
  echo "    Rollout timeout    : ${ROLLOUT_TIMEOUT}s"
  echo "    DDS settle         : ${SETTLE}s"
  echo ""
  echo "  Topology:"
  echo "    [edge] ros2-talker + zenoh-bridge → edge-router"
  echo "                                              │ (NetworkPolicy failure point N4,N10)"
  echo "    [cloud] ros2-listener + zenoh-bridge ← cloud-router"

  local target="${SCENARIO:-all}"
  case "$target" in
    all)
      scenario_N1
      scenario_N2
      scenario_N3
      scenario_N4
      scenario_N5_N6
      scenario_N7
      scenario_N8
      scenario_N9
      scenario_N10
      ;;
    N1)          scenario_N1 ;;
    N2)          scenario_N2 ;;
    N3)          scenario_N3 ;;
    N4)          scenario_N4 ;;
    N5|N6|N5N6)  scenario_N5_N6 ;;
    N7)          scenario_N7 ;;
    N8)          scenario_N8 ;;
    N9)          scenario_N9 ;;
    N10)         scenario_N10 ;;
    *)
      echo "ERROR: unknown scenario '$target'. Valid: N1 N2 N3 N4 N5 N6 N7 N8 N9 N10 all"
      exit 1
      ;;
  esac

  echo ""
  echo "═════════════════════════════════════════════════════════════════════════"
  printf "  Result : ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, %d noted\n" \
    "$PASS" "$FAIL" "${#NOTES[@]}"

  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo ""
    echo "  Notes:"
    for n in "${NOTES[@]}"; do
      echo "    - $n"
    done
  fi

  [ "$FAIL" -eq 0 ]
}

main "$@"
