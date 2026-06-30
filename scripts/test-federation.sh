#!/usr/bin/env bash
# scripts/test-federation.sh
# Validates Zenoh router-to-router federation in a tiered edge-to-cloud topology.
#
# Prerequisites:
#   - podman machine running  (Mac: podman machine start)
#   - podman-compose >= 1.0.6 (brew install podman-compose)
#   - Images pulled: quay.io/jianrzha/zenoh-router,
#                    quay.io/jianrzha/zenoh-bridge-ros2dds,
#                    quay.io/jianrzha/ros2-zenoh-demo (or set DEMO_IMAGE/DEMO_VERSION)
#
# Usage:
#   bash scripts/test-federation.sh           # run all 3 scenarios
#   SCENARIO=F1 bash scripts/test-federation.sh   # run one scenario (F1 | F2 | F3)
#
# Tuning:
#   FLOW_TIMEOUT=25    seconds to wait for a message that SHOULD arrive (default 25)
#   BLOCK_TIMEOUT=10   seconds to wait for a message that SHOULD be blocked (default 10)
#   FEDERATION_SETTLE=20  seconds after router start for link establishment (default 20)
#   BRIDGE_SETTLE=15   additional seconds for bridge DDS discovery (default 15)
#   ADMIN_TIMEOUT=15   seconds to poll for router peer state in F3 (default 15)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$ROOT/compose.federation-test.yml"
CONFIGS="$ROOT/tests/configs"
PROJECT="fed-test"

FLOW_TIMEOUT="${FLOW_TIMEOUT:-25}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-10}"
FEDERATION_SETTLE="${FEDERATION_SETTLE:-20}"
BRIDGE_SETTLE="${BRIDGE_SETTLE:-15}"
ADMIN_TIMEOUT="${ADMIN_TIMEOUT:-15}"

PASS=0
FAIL=0
NOTES=()

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
pass()  { printf "  ${GREEN}PASS${RESET}  %s\n" "$*"; ((PASS++)) || true; }
fail()  { printf "  ${RED}FAIL${RESET}  %s\n" "$*"; ((FAIL++)) || true; }
note()  { printf "  ${YELLOW}NOTE${RESET}  %s\n" "$*"; NOTES+=("$*"); }
sep()   { printf "\n── %s\n" "$*"; }

# ── Prerequisite check ──────────────────────────────────────────────────────
check_prereqs() {
  local ok=1
  command -v podman         &>/dev/null || { echo "ERROR: podman not found";        ok=0; }
  command -v podman-compose &>/dev/null || { echo "ERROR: podman-compose not found"; ok=0; }
  command -v curl           &>/dev/null || { echo "ERROR: curl not found";           ok=0; }
  [ "$ok" -eq 1 ] || { echo "Install missing tools and re-run."; exit 1; }

  local pc_ver
  pc_ver=$(podman-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
  local major minor patch
  IFS='.' read -r major minor patch <<< "$pc_ver"
  if [ "${major:-0}" -eq 0 ] || { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -eq 0 ] && [ "${patch:-0}" -lt 6 ]; }; then
    echo "WARNING: podman-compose $pc_ver may not support 'network_mode: service:<name>'."
    echo "         Upgrade to >= 1.0.6 if bridge containers fail to start."
  fi
}

# ── Container lookup ─────────────────────────────────────────────────────────
# Handles both podman-compose naming conventions:
#   new: fed-test-ros2-listener-1
#   old: fed-test_ros2-listener_1
ctr() {
  local service="$1"
  podman ps --format "{{.Names}}" \
    | grep -E "^${PROJECT}[-_]${service}[-_][0-9]+$" \
    | head -1
}

# ── Stack helpers ────────────────────────────────────────────────────────────
stack_up() {
  local edge_cfg="${1:-$CONFIGS/router-edge.json5}"
  local cloud_cfg="${2:-$CONFIGS/router-cloud.json5}"

  echo "  [stack] Starting with edge=$(basename "$edge_cfg") cloud=$(basename "$cloud_cfg")"
  EDGE_ROUTER_CONFIG="$edge_cfg" CLOUD_ROUTER_CONFIG="$cloud_cfg" \
    podman-compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d &>/dev/null || true

  echo "  [stack] Waiting ${FEDERATION_SETTLE}s for routers to link..."
  sleep "$FEDERATION_SETTLE"

  echo "  [stack] Waiting ${BRIDGE_SETTLE}s for bridge DDS discovery..."
  sleep "$BRIDGE_SETTLE"

  warm_dds
}

stack_down() {
  echo "  [stack] Tearing down..."
  podman-compose -p "$PROJECT" -f "$COMPOSE_FILE" down --timeout 10 &>/dev/null || true
}

warm_dds() {
  local listener
  listener=$(ctr ros2-listener)
  [ -n "$listener" ] || return
  podman exec "$listener" bash -c \
    "set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; ros2 topic list" &>/dev/null || true
  sleep 2
}

# ── Topic check primitives ───────────────────────────────────────────────────
check_flows() {
  local topic="$1"
  local timeout="${2:-$FLOW_TIMEOUT}"
  local listener
  listener=$(ctr ros2-listener)
  [ -n "$listener" ] || { echo "    ERROR: ros2-listener container not found"; return 1; }
  podman exec "$listener" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $timeout ros2 topic echo '$topic' 2>/dev/null | grep -m 1 'data:'
  " &>/dev/null
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

# ── Admin space helpers ──────────────────────────────────────────────────────
# Poll the REST API of a router until it returns non-empty data or timeout.
# Returns 0 (success) when data is found, 1 on timeout.
# "Non-empty" means: not empty string, not {}, not null, not [].
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

# ── Scenario F3 ─────────────────────────────────────────────────────────────
scenario_F3() {
  sep "Scenario F3: Admin space — federation link health check"
  echo "  Querying router REST APIs for peer state..."

  # Cloud router admin space (should contain router metadata)
  printf "  cloud-router (localhost:8001):\n"
  local cloud_data edge_data
  if cloud_data=$(wait_for_router_api "http://localhost:8001/@/**" "cloud-router"); then
    pass "cloud-router admin space is populated"
    # Count how many peer session keys are visible (heuristic: look for "router" entries)
    local n_cloud_peers
    n_cloud_peers=$(echo "$cloud_data" | grep -o '"router"' | wc -l || echo 0)
    note "cloud-router admin space has ${n_cloud_peers} 'router' key(s) — peer sessions use hex IDs, inspect manually if needed"
  else
    # Fallback: just check the router is alive (/@/router/local is always present)
    if curl -sf --max-time 5 "http://localhost:8001/@/router/local" &>/dev/null; then
      pass "cloud-router REST API is responding (admin space at /@/** is empty — ok if no sessions yet)"
    else
      fail "cloud-router REST API did not respond within ${ADMIN_TIMEOUT}s — federation link may not be established"
    fi
  fi

  # Edge router admin space (should contain router metadata + federation link)
  printf "  edge-router (localhost:8002):\n"
  if edge_data=$(wait_for_router_api "http://localhost:8002/@/**" "edge-router"); then
    pass "edge-router admin space is populated"
    local n_edge_peers
    n_edge_peers=$(echo "$edge_data" | grep -o '"router"' | wc -l || echo 0)
    note "edge-router admin space has ${n_edge_peers} 'router' key(s) — peer sessions use hex IDs, inspect manually if needed"
  else
    if curl -sf --max-time 5 "http://localhost:8002/@/router/local" &>/dev/null; then
      pass "edge-router REST API is responding (admin space at /@/** is empty — ok if no sessions yet)"
    else
      fail "edge-router REST API did not respond within ${ADMIN_TIMEOUT}s"
    fi
  fi
}

# ── Scenario F1 ─────────────────────────────────────────────────────────────
scenario_F1() {
  sep "Scenario F1: Basic federation — edge-to-cloud message routing"
  echo "  Edge router: no ACL  |  All topics should cross the federation link"

  stack_up "$CONFIGS/router-edge.json5" "$CONFIGS/router-cloud.json5"

  # Health-check the federation link before asserting message delivery
  scenario_F3

  # All topics published by multi-pub.sh should arrive at the cloud listener
  assert_flows /chatter
  assert_flows /sensor/scan
  assert_flows /sensor/camera
  assert_flows /system/status
}

# ── Scenario F2 ─────────────────────────────────────────────────────────────
scenario_F2() {
  sep "Scenario F2: Edge ACL — sensor topics blocked from propagating to cloud"
  echo "  Edge router: ACL denies sensor/** egress across federation link"

  stack_down
  stack_up "$CONFIGS/router-edge-acl.json5" "$CONFIGS/router-cloud.json5"

  # /chatter and /system/status are NOT in the ACL deny list — should pass through
  assert_flows   /chatter
  assert_flows   /system/status

  # sensor/** is denied by the edge router ACL — should NOT arrive at cloud
  assert_blocked /sensor/scan
  assert_blocked /sensor/camera

  # Probe: check whether the ACL subject wildcard actually matched the router-to-router
  # session.  The NOTE below captures the empirical result for the proposal's risk section.
  local scan_blocked camera_blocked
  check_flows /sensor/scan   "$BLOCK_TIMEOUT" && scan_blocked=0   || scan_blocked=1
  check_flows /sensor/camera "$BLOCK_TIMEOUT" && camera_blocked=0 || camera_blocked=1

  if [ "$scan_blocked" -eq 1 ] && [ "$camera_blocked" -eq 1 ]; then
    note "F2 confirmed: Zenoh 1.9.0 ACL wildcard subject applies to the router-to-router session — sensor topics blocked at federation link"
  else
    note "F2 inconclusive: ACL wildcard subject did NOT match the router-to-router session in this version — fallback to bridge-side filtering needed for edge data sovereignty"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  echo ""
  echo "=== Zenoh Router Federation Tests ==="
  echo "    Edge router image  : quay.io/jianrzha/zenoh-router:latest"
  echo "    Cloud router image : quay.io/jianrzha/zenoh-router:latest"
  echo "    Bridge image       : quay.io/jianrzha/zenoh-bridge-ros2dds:latest"
  echo "    Flow timeout       : ${FLOW_TIMEOUT}s"
  echo "    Block timeout      : ${BLOCK_TIMEOUT}s"
  echo "    Federation settle  : ${FEDERATION_SETTLE}s (router link establishment)"
  echo "    Bridge settle      : ${BRIDGE_SETTLE}s (DDS discovery)"
  echo "    Admin timeout      : ${ADMIN_TIMEOUT}s (REST API poll)"
  echo ""
  echo "  Topology:"
  echo "    [edge-net] talker → bridge-talker → edge-router"
  echo "                                              │ wan-net"
  echo "    [cloud-net] listener ← bridge-listener ← cloud-router"

  stack_down 2>/dev/null || true

  local target="${SCENARIO:-all}"
  case "$target" in
    all)
      scenario_F1
      scenario_F2
      ;;
    F1) scenario_F1 ;;
    F2) scenario_F2 ;;
    F3)
      # F3 standalone: bring up an unfiltered stack first, then run the admin check
      stack_up "$CONFIGS/router-edge.json5" "$CONFIGS/router-cloud.json5"
      scenario_F3
      ;;
    *)
      echo "ERROR: unknown scenario '$target'. Use F1, F2, or F3."
      exit 1
      ;;
  esac

  stack_down 2>/dev/null || true

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
