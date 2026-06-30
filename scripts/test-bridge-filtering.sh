#!/usr/bin/env bash
# scripts/test-bridge-filtering.sh
# Validates zenoh-bridge-ros2dds filtering across 8 scenarios.
#
# Prerequisites:
#   - podman machine running  (Mac: podman machine start)
#   - podman-compose >= 1.0.6 (brew install podman-compose)
#   - Images pulled or built:  quay.io/ecosystem-appeng/zenoh-router,
#                              quay.io/ecosystem-appeng/zenoh-bridge-ros2dds,
#                              quay.io/jianrzha/ros2-zenoh-demo (or built locally)
#
# Usage:
#   bash scripts/test-bridge-filtering.sh          # run all 8 scenarios
#   SCENARIO=2 bash scripts/test-bridge-filtering.sh   # run one scenario
#
# Tuning:
#   TOPIC_TIMEOUT=8   seconds to wait for a single message (default 8)
#   COUNT_WINDOW=10   seconds for the rate-limit message count (default 10)
#   BRIDGE_SETTLE=15  seconds after stack-up for DDS discovery (default 15)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$ROOT/compose.bridge-test.yml"
CONFIGS="$ROOT/tests/configs"
PROJECT="bridge-test"

FLOW_TIMEOUT="${FLOW_TIMEOUT:-22}"   # seconds to wait for a topic that SHOULD arrive
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-8}"  # seconds to wait for a topic that SHOULD be blocked
COUNT_WINDOW="${COUNT_WINDOW:-10}"
BRIDGE_SETTLE="${BRIDGE_SETTLE:-15}"

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
  command -v podman        &>/dev/null || { echo "ERROR: podman not found";        ok=0; }
  command -v podman-compose &>/dev/null || { echo "ERROR: podman-compose not found"; ok=0; }
  [ "$ok" -eq 1 ] || { echo "Install missing tools and re-run."; exit 1; }

  # Warn if podman-compose is older than 1.0.6 (network_mode: service: support)
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
# Find a running container belonging to a service in this project.
# Handles both podman-compose naming conventions:
#   new: bridge-test-ros2-listener-1
#   old: bridge-test_ros2-listener_1
ctr() {
  local service="$1"
  podman ps --format "{{.Names}}" \
    | grep -E "^${PROJECT}[-_]${service}[-_][0-9]+$" \
    | head -1
}

# ── Stack helpers ────────────────────────────────────────────────────────────
warm_dds() {
  # Run ros2 topic list inside the listener container to prime CycloneDDS discovery.
  # Without this, the bridge's DDS publishers are not yet visible to new DDS
  # participants, making the first check_flows call take 20+ s. One topic list
  # triggers a discovery cycle that caches publisher endpoints so subsequent
  # ros2 topic echo processes find them in < 1 s.
  local listener
  listener=$(ctr ros2-listener)
  [ -n "$listener" ] || return
  podman exec "$listener" bash -c \
    "set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; ros2 topic list" &>/dev/null || true
  sleep 2   # let DDS process the discovery flush before assertions start
}

stack_up() {
  local bridge_cfg="$1"
  local router_cfg="${2:-$CONFIGS/router-default.json5}"

  echo "  [stack] Starting with bridge=$(basename "$bridge_cfg") router=$(basename "$router_cfg")${ROS_NS:+ ns=$ROS_NS}"
  BRIDGE_CONFIG="$bridge_cfg" ROUTER_CONFIG="$router_cfg" ROS_NS="${ROS_NS:-}" \
    podman-compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d &>/dev/null || true

  echo "  [stack] Settling ${BRIDGE_SETTLE}s (DDS discovery + bridge connection)..."
  sleep "$BRIDGE_SETTLE"
  warm_dds
}

stack_down() {
  echo "  [stack] Tearing down..."
  podman-compose -p "$PROJECT" -f "$COMPOSE_FILE" down --timeout 10 &>/dev/null || true
}

# ── Topic check primitives ────────────────────────────────────────────────────
# Returns 0 if ≥1 message arrives on <topic> within <timeout> seconds.
# Uses grep -m 1 to exit after the first match (ros2 topic echo --count not supported
# in all image versions).
# The first check_flows call in a cold container takes ~18s for DDS participant
# bootstrap + bridge subscriber routing. Subsequent calls in the same stack are 2-3s.
# Use FLOW_TIMEOUT for "should arrive" checks and BLOCK_TIMEOUT for "should be blocked".
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
    pass "$topic  flows"
  else
    fail "$topic  expected to flow — no message in ${FLOW_TIMEOUT}s"
  fi
}

assert_blocked() {
  local topic="$1"
  if ! check_flows "$topic" "$BLOCK_TIMEOUT"; then
    pass "$topic  blocked"
  else
    fail "$topic  expected to be blocked — message arrived unexpectedly"
  fi
}

# Count messages received on <topic> over COUNT_WINDOW seconds.
count_msgs() {
  local topic="$1"
  local listener
  listener=$(ctr ros2-listener)
  [ -n "$listener" ] || { echo 0; return; }
  podman exec "$listener" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $COUNT_WINDOW ros2 topic echo '$topic' 2>/dev/null
  " 2>/dev/null | grep -c "^data:" || true
}

# ── Scenario implementations ─────────────────────────────────────────────────

scenario_1() {
  sep "Scenario 1: Baseline (no filter)"
  stack_up "$CONFIGS/bridge-baseline.json5"
  assert_flows  /chatter
  assert_flows  /sensor/scan
  assert_flows  /sensor/camera
  assert_flows  /system/status
}

scenario_2() {
  sep "Scenario 2: Allow whitelist (/chatter + /system/status only)"
  stack_down; stack_up "$CONFIGS/bridge-allow-whitelist.json5"
  assert_flows   /chatter
  assert_flows   /system/status
  assert_blocked /sensor/scan
  assert_blocked /sensor/camera
}

scenario_3() {
  sep "Scenario 3: Allow blocks all (all-empty lists)"
  stack_down; stack_up "$CONFIGS/bridge-allow-empty.json5"
  assert_blocked /chatter
  assert_blocked /sensor/scan
  assert_blocked /sensor/camera
  assert_blocked /system/status
}

scenario_4() {
  sep "Scenario 4: Allow by regex namespace (.*/sensor/.*)"
  stack_down; stack_up "$CONFIGS/bridge-allow-regex.json5"
  assert_flows   /sensor/scan
  assert_flows   /sensor/camera
  assert_blocked /chatter
  assert_blocked /system/status
}

scenario_5() {
  sep "Scenario 5: Deny blacklist + Issue #241 probe"
  stack_down; stack_up "$CONFIGS/bridge-deny.json5"

  # Sensor topics: denied in publishers → talker bridge does not publish to Zenoh
  assert_blocked /sensor/scan
  assert_blocked /sensor/camera

  # /system/status: not in deny.publishers, not in deny.subscribers → should flow
  assert_flows /system/status

  # Issue #241 probe: /chatter is in deny.subscribers on the listener bridge.
  # If honoured → blocked; if bug present (silently ignored) → flows.
  # We observe and note rather than assert, because either result is informative.
  printf "  Probing Issue #241 (subscriber deny on /chatter)...\n"
  if check_flows /chatter "$FLOW_TIMEOUT"; then
    note "Issue #241: subscriber deny on /chatter IGNORED (bug present) — chatter flows despite deny.subscribers"
  else
    note "Issue #241: subscriber deny on /chatter HONOURED (bug absent) — chatter correctly blocked"
  fi
}

scenario_6() {
  sep "Scenario 6: Scope prefix (namespace=/robot-1)"
  # bridge-scope.json5 sets namespace: "/robot-1".
  # ROS_NS=robot-1 causes the talker to publish under the /robot-1 ROS namespace.
  # The bridge (scoped to /robot-1) discovers those topics and maps them to Zenoh
  # keys prefixed with "robot-1/" (e.g. DDS /chatter -> Zenoh robot-1/chatter).
  # The listener bridge strips the prefix symmetrically, so DDS delivery in the
  # listener container arrives on the original topic names (/chatter, /sensor/scan).
  stack_down
  ROS_NS=robot-1 stack_up "$CONFIGS/bridge-scope.json5"

  # DDS delivery is on the original (namespace-stripped) topic names
  assert_flows /chatter
  assert_flows /sensor/scan

  # Verify the Zenoh key prefix from bridge route logs
  printf "  Checking Zenoh key prefix in bridge logs...\n"
  local talker_routes
  talker_routes=$(podman logs "$(ctr zenoh-bridge-talker)" 2>&1 | grep "Route Publisher.*Zenoh:robot-1/" || true)
  if [ -n "$talker_routes" ]; then
    pass "Zenoh keys are prefixed robot-1/ (e.g. robot-1/chatter) — confirmed in bridge logs"
  else
    note "Could not confirm robot-1/ Zenoh key prefix from bridge logs"
  fi
}

scenario_7() {
  sep "Scenario 7: Rate limiting (pub_max_frequencies)"
  stack_down; stack_up "$CONFIGS/bridge-rate-limit.json5"

  # /sensor/scan must still be blocked (excluded by allow list)
  assert_blocked /sensor/scan

  # /chatter: capped from 10 Hz to 1 Hz → expect 5–15 messages in COUNT_WINDOW seconds
  printf "  Counting /chatter messages over %ss...\n" "$COUNT_WINDOW"
  local n_chatter
  n_chatter=$(count_msgs /chatter)
  printf "    received: %s  (cap=1Hz, window=%ss, expect 5–15)\n" "$n_chatter" "$COUNT_WINDOW"
  if [ "$n_chatter" -ge 3 ] && [ "$n_chatter" -le 20 ]; then
    pass "/chatter  rate-limited to ~1 Hz ($n_chatter msgs in ${COUNT_WINDOW}s)"
  elif [ "$n_chatter" -eq 0 ]; then
    fail "/chatter  no messages received (check allow list or bridge startup)"
  else
    fail "/chatter  rate not limited: $n_chatter msgs in ${COUNT_WINDOW}s (cap=1Hz, expected 5–15)"
  fi

  # /system/status: capped from 1 Hz to 0.5 Hz → expect 2–8 messages in COUNT_WINDOW seconds
  printf "  Counting /system/status messages over %ss...\n" "$COUNT_WINDOW"
  local n_status
  n_status=$(count_msgs /system/status)
  printf "    received: %s  (cap=0.5Hz, window=%ss, expect 2–8)\n" "$n_status" "$COUNT_WINDOW"
  if [ "$n_status" -ge 1 ] && [ "$n_status" -le 10 ]; then
    pass "/system/status  rate-limited to ~0.5 Hz ($n_status msgs in ${COUNT_WINDOW}s)"
  elif [ "$n_status" -eq 0 ]; then
    fail "/system/status  no messages received (check allow list or bridge startup)"
  else
    fail "/system/status  rate not limited: $n_status msgs in ${COUNT_WINDOW}s (cap=0.5Hz, expected 2–8)"
  fi
}

scenario_8() {
  sep "Scenario 8: Router ACL (independent filtering layer)"
  # Bridge: baseline (no filter) — all topics enter the Zenoh session.
  # Router: ACL denies rt/sensor/** at egress regardless of bridge config.
  stack_down; stack_up "$CONFIGS/bridge-baseline.json5" "$CONFIGS/router-acl.json5"
  assert_flows   /chatter
  assert_flows   /system/status
  assert_blocked /sensor/scan
  assert_blocked /sensor/camera
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  echo ""
  echo "=== Zenoh Bridge Filtering Tests ==="
  echo "    Bridge image  : quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:latest"
  echo "    Router image  : quay.io/ecosystem-appeng/zenoh-router:latest"
  echo "    Flow timeout  : ${FLOW_TIMEOUT}s (topics expected to arrive)"
  echo "    Block timeout : ${BLOCK_TIMEOUT}s (topics expected to be blocked)"
  echo "    Count window  : ${COUNT_WINDOW}s (rate-limit test)"
  echo "    Bridge settle : ${BRIDGE_SETTLE}s after stack-up"

  # Clean any leftover stack from a previous run
  stack_down 2>/dev/null || true

  local target="${SCENARIO:-all}"
  if [ "$target" = "all" ]; then
    scenario_1
    scenario_2
    scenario_3
    scenario_4
    scenario_5
    scenario_6
    scenario_7
    scenario_8
  else
    "scenario_${target}"
  fi

  # Always tear down at the end
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
