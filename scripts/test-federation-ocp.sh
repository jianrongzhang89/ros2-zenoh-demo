#!/usr/bin/env bash
# scripts/test-federation-ocp.sh
# Validates Zenoh router federation in a tiered edge-to-cloud topology on OpenShift/Kubernetes.
# Mirrors the logic of scripts/test-federation.sh, adapted for kubectl instead of podman-compose.
#
# Prerequisites:
#   - kubectl (or oc) configured and pointing at the target cluster
#   - Namespace ros2-zenoh-federation created (or set NAMESPACE env var)
#   - Images accessible from the cluster:
#       docker.io/eclipse/zenoh:latest
#       docker.io/eclipse/zenoh-bridge-ros2dds:latest
#       quay.io/jianrzha/ros2-zenoh-demo:latest
#
# Usage:
#   bash scripts/test-federation-ocp.sh           # run F1 + F2
#   SCENARIO=F1 bash scripts/test-federation-ocp.sh
#   SCENARIO=F2 bash scripts/test-federation-ocp.sh
#   SCENARIO=F3 bash scripts/test-federation-ocp.sh
#
# Tuning:
#   NAMESPACE=ros2-zenoh-federation  target namespace
#   FLOW_TIMEOUT=30                  seconds to wait for a message that SHOULD arrive
#   BLOCK_TIMEOUT=12                 seconds to wait for a message that SHOULD be blocked
#   ROLLOUT_TIMEOUT=180              seconds for kubectl rollout status
#   SETTLE=20                        seconds after rollout for bridge DDS discovery
#   ADMIN_TIMEOUT=20                 seconds to poll router REST APIs via port-forward

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS="$ROOT/k8s/federation"

NAMESPACE="${NAMESPACE:-ros2-zenoh-federation}"
FLOW_TIMEOUT="${FLOW_TIMEOUT:-30}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-12}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180}"
SETTLE="${SETTLE:-20}"
ADMIN_TIMEOUT="${ADMIN_TIMEOUT:-20}"

PASS=0
FAIL=0
NOTES=()
PF_PIDS=()   # background port-forward PIDs to kill on exit

cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
pass()  { printf "  ${GREEN}PASS${RESET}  %s\n" "$*"; ((PASS++)) || true; }
fail()  { printf "  ${RED}FAIL${RESET}  %s\n" "$*"; ((FAIL++)) || true; }
note()  { printf "  ${YELLOW}NOTE${RESET}  %s\n" "$*"; NOTES+=("$*"); }
sep()   { printf "\n── %s\n" "$*"; }

# ── Prerequisite check ──────────────────────────────────────────────────────
check_prereqs() {
  local ok=1
  command -v kubectl &>/dev/null || { echo "ERROR: kubectl not found"; ok=0; }
  command -v curl    &>/dev/null || { echo "ERROR: curl not found";    ok=0; }
  [ "$ok" -eq 1 ] || { echo "Install missing tools and re-run."; exit 1; }

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "ERROR: namespace '$NAMESPACE' does not exist."
    echo "       Run:  kubectl apply -f $MANIFESTS/namespace.yaml"
    exit 1
  fi
}

# ── Pod helpers ──────────────────────────────────────────────────────────────
pod_for() {
  kubectl get pods -n "$NAMESPACE" -l "app=$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Wait for a deployment to be fully ready.
wait_rollout() {
  local dep="$1"
  echo "  [rollout] Waiting for $dep ..."
  kubectl rollout status deployment/"$dep" -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
}

# ── Stack helpers ────────────────────────────────────────────────────────────
apply_base() {
  echo "  [apply] Applying base federation manifests..."
  kubectl apply -f "$MANIFESTS/namespace.yaml"
  kubectl apply -f "$MANIFESTS/"
  wait_rollout cloud-router
  wait_rollout edge-router
  wait_rollout edge-talker
  wait_rollout cloud-listener
  echo "  [settle] Waiting ${SETTLE}s for bridge DDS discovery..."
  sleep "$SETTLE"
}

apply_acl() {
  echo "  [apply] Switching edge-router to ACL config..."
  kubectl apply -f "$MANIFESTS/acl/deployment-edge-router-acl.yaml"
  kubectl rollout status deployment/edge-router -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
  echo "  [settle] Waiting ${SETTLE}s for bridge DDS re-discovery..."
  sleep "$SETTLE"
}

restore_base_edge() {
  echo "  [restore] Restoring edge-router to base config..."
  kubectl apply -f "$MANIFESTS/deployment-edge-router.yaml"
  kubectl rollout status deployment/edge-router -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
}

# ── Port-forward helpers ─────────────────────────────────────────────────────
start_port_forwards() {
  kubectl port-forward -n "$NAMESPACE" service/cloud-router 8001:8001 &>/dev/null &
  PF_PIDS+=($!)
  kubectl port-forward -n "$NAMESPACE" service/edge-router  8002:8002 &>/dev/null &
  PF_PIDS+=($!)
  sleep 3   # let port-forwards bind
}

stop_port_forwards() {
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  PF_PIDS=()
}

wait_for_router_api() {
  local url="$1"
  local label="$2"
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
  echo "    TIMEOUT: $label REST API at $url not responding within ${ADMIN_TIMEOUT}s"
  return 1
}

# ── Topic check primitives ───────────────────────────────────────────────────
check_flows() {
  local topic="$1"
  local timeout="${2:-$FLOW_TIMEOUT}"
  local pod
  pod=$(pod_for cloud-listener)
  if [ -z "$pod" ]; then
    echo "    ERROR: cloud-listener pod not found (Running)"
    return 1
  fi
  kubectl exec -n "$NAMESPACE" "$pod" -c ros2-listener -- bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $timeout ros2 topic echo '$topic' 2>/dev/null | grep -m 1 'data:'
  " 2>/dev/null
}

assert_flows() {
  local topic="$1"
  if check_flows "$topic" "$FLOW_TIMEOUT"; then
    pass "$topic  flows  (edge → federation link → cloud)"
  else
    fail "$topic  expected to flow — no message in ${FLOW_TIMEOUT}s"
  fi
}

assert_blocked() {
  local topic="$1"
  if ! check_flows "$topic" "$BLOCK_TIMEOUT"; then
    pass "$topic  blocked by edge ACL — not visible at cloud"
  else
    fail "$topic  expected to be blocked by edge ACL — message arrived unexpectedly"
  fi
}

# ── Scenario F3 ──────────────────────────────────────────────────────────────
scenario_F3() {
  sep "Scenario F3: Admin space — federation link health check"
  echo "  Opening port-forwards to router REST APIs..."
  start_port_forwards

  printf "  cloud-router (localhost:8001):\n"
  local cloud_data
  if cloud_data=$(wait_for_router_api "http://localhost:8001/@/**" "cloud-router"); then
    pass "cloud-router admin space is populated"
    local n
    n=$(echo "$cloud_data" | grep -o '"router"' | wc -l || echo 0)
    note "cloud-router admin space has ${n} 'router' key(s) — peer sessions use hex IDs"
  else
    if curl -sf --max-time 5 "http://localhost:8001/@/router/local" &>/dev/null; then
      pass "cloud-router REST API responding (admin space empty — ok before bridge sessions)"
    else
      fail "cloud-router REST API not reachable via port-forward (port 8001)"
    fi
  fi

  printf "  edge-router (localhost:8002):\n"
  local edge_data
  if edge_data=$(wait_for_router_api "http://localhost:8002/@/**" "edge-router"); then
    pass "edge-router admin space is populated"
    local n
    n=$(echo "$edge_data" | grep -o '"router"' | wc -l || echo 0)
    note "edge-router admin space has ${n} 'router' key(s) — peer sessions use hex IDs"
  else
    if curl -sf --max-time 5 "http://localhost:8002/@/router/local" &>/dev/null; then
      pass "edge-router REST API responding (admin space empty — ok before bridge sessions)"
    else
      fail "edge-router REST API not reachable via port-forward (port 8002)"
    fi
  fi

  stop_port_forwards
}

# ── Scenario F1 ──────────────────────────────────────────────────────────────
scenario_F1() {
  sep "Scenario F1: Basic federation — edge-to-cloud message routing"
  echo "  Edge router: no ACL  |  All topics should cross the federation link"

  apply_base
  scenario_F3

  assert_flows /chatter
  assert_flows /sensor/scan
  assert_flows /sensor/camera
  assert_flows /system/status
}

# ── Scenario F2 ──────────────────────────────────────────────────────────────
scenario_F2() {
  sep "Scenario F2: Edge ACL — sensor topics blocked from propagating to cloud"
  echo "  Edge router: ACL denies sensor/** egress across federation link"

  apply_acl

  assert_flows   /chatter
  assert_flows   /system/status
  assert_blocked /sensor/scan
  assert_blocked /sensor/camera

  local scan_blocked camera_blocked
  check_flows /sensor/scan   "$BLOCK_TIMEOUT" && scan_blocked=0   || scan_blocked=1
  check_flows /sensor/camera "$BLOCK_TIMEOUT" && camera_blocked=0 || camera_blocked=1
  if [ "$scan_blocked" -eq 1 ] && [ "$camera_blocked" -eq 1 ]; then
    note "F2 confirmed: ACL wildcard subject applies to router-to-router session on OCP"
  else
    note "F2 inconclusive: ACL did not block topics on OCP — investigate router logs"
  fi

  restore_base_edge
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  echo ""
  echo "=== Zenoh Router Federation Tests (OpenShift/Kubernetes) ==="
  echo "    Namespace     : $NAMESPACE"
  echo "    Manifests     : $MANIFESTS"
  echo "    Flow timeout  : ${FLOW_TIMEOUT}s"
  echo "    Block timeout : ${BLOCK_TIMEOUT}s"
  echo "    Rollout timeout: ${ROLLOUT_TIMEOUT}s"
  echo "    Settle        : ${SETTLE}s (bridge DDS discovery)"
  echo "    Admin timeout : ${ADMIN_TIMEOUT}s"
  echo ""
  echo "  Topology:"
  echo "    [edge pod] ros2-talker + bridge-talker → edge-router Service:7448"
  echo "                                                  │ federation link"
  echo "    [cloud pod] ros2-listener + bridge-listener ← cloud-router Service:7447"

  local target="${SCENARIO:-all}"
  case "$target" in
    all)
      scenario_F1
      scenario_F2
      ;;
    F1) scenario_F1 ;;
    F2)
      # F2 standalone: apply base first, then ACL, run checks, restore
      apply_base
      scenario_F2
      ;;
    F3)
      apply_base
      scenario_F3
      ;;
    *)
      echo "ERROR: unknown scenario '$target'. Use F1, F2, or F3."
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
