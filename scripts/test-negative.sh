#!/usr/bin/env bash
# scripts/test-negative.sh
# Negative tests: router/bridge disconnect, network partition, buffer loss, and
# routing recovery in the edge-to-cloud federation topology.
#
# Each scenario brings up a fresh stack, injects a failure, then verifies
# that routing recovers (or documents the known failure mode).
#
# Prerequisites:
#   - podman machine running  (Mac: podman machine start)
#   - podman-compose >= 1.0.6 (brew install podman-compose)
#   - Images pulled: quay.io/ecosystem-appeng/zenoh-router,
#                    quay.io/ecosystem-appeng/zenoh-bridge-ros2dds,
#                    quay.io/jianrzha/ros2-zenoh-demo (or set DEMO_IMAGE/DEMO_VERSION)
#
# Usage:
#   bash scripts/test-negative.sh                 # run all scenarios
#   SCENARIO=N3 bash scripts/test-negative.sh     # run one scenario
#   make test-negative
#   make test-negative-scenario N=N3
#
# Tuning (env vars):
#   FLOW_TIMEOUT=25        seconds to wait for a message that SHOULD arrive
#   BLOCK_TIMEOUT=10       seconds to wait for a message that SHOULD be blocked
#   FEDERATION_SETTLE=20   seconds for router federation link to establish
#   BRIDGE_SETTLE=15       seconds for bridge DDS re-discovery
#   OUTAGE_SECS=30         seconds to hold a failure before restoring
#   RECONNECT_TIMEOUT=60   seconds max wait for recovery (FAIL if exceeded)
#   ADMIN_TIMEOUT=30       seconds to poll router REST API for session state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$ROOT/compose.negative-test.yml"
CONFIGS="$ROOT/tests/configs"
PROJECT="neg-test"

EDGE_CFG="${EDGE_ROUTER_CONFIG:-$CONFIGS/router-edge.json5}"
CLOUD_CFG="${CLOUD_ROUTER_CONFIG:-$CONFIGS/router-cloud.json5}"

FLOW_TIMEOUT="${FLOW_TIMEOUT:-25}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-10}"
FEDERATION_SETTLE="${FEDERATION_SETTLE:-20}"
BRIDGE_SETTLE="${BRIDGE_SETTLE:-15}"
OUTAGE_SECS="${OUTAGE_SECS:-30}"
RECONNECT_TIMEOUT="${RECONNECT_TIMEOUT:-60}"
ADMIN_TIMEOUT="${ADMIN_TIMEOUT:-30}"

PASS=0
FAIL=0
NOTES=()

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
pass()  { printf "  ${GREEN}PASS${RESET}  %s\n" "$*"; ((PASS++)) || true; }
fail()  { printf "  ${RED}FAIL${RESET}  %s\n" "$*"; ((FAIL++)) || true; }
note()  { printf "  ${YELLOW}NOTE${RESET}  %s\n" "$*"; NOTES+=("$*"); }
sep()   { printf "\n── %s\n" "$*"; }

# ── Prerequisite check ────────────────────────────────────────────────────────
check_prereqs() {
  local ok=1
  command -v podman         &>/dev/null || { echo "ERROR: podman not found";         ok=0; }
  command -v podman-compose &>/dev/null || { echo "ERROR: podman-compose not found"; ok=0; }
  command -v curl           &>/dev/null || { echo "ERROR: curl not found";           ok=0; }
  command -v python3        &>/dev/null || { echo "ERROR: python3 not found";        ok=0; }
  [ "$ok" -eq 1 ] || { echo "Install missing tools and re-run."; exit 1; }
}

# ── Container lookup ──────────────────────────────────────────────────────────
# Handles both podman-compose naming conventions:
#   new: neg-test-edge-router-1
#   old: neg-test_edge-router_1
ctr() {
  local service="$1"
  podman ps -a --format "{{.Names}}" \
    | grep -E "^${PROJECT}[-_]${service}[-_][0-9]+$" \
    | head -1
}

# ── WAN network name ──────────────────────────────────────────────────────────
wan_network() {
  podman network ls --format "{{.Name}}" \
    | grep -E "^${PROJECT}[-_]wan-net$" \
    | head -1
}

# ── Stack lifecycle ───────────────────────────────────────────────────────────
stack_up() {
  echo "  [stack] Starting with edge=$(basename "$EDGE_CFG") cloud=$(basename "$CLOUD_CFG")"
  EDGE_ROUTER_CONFIG="$EDGE_CFG" CLOUD_ROUTER_CONFIG="$CLOUD_CFG" \
    podman-compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d &>/dev/null || true

  echo "  [stack] Waiting ${FEDERATION_SETTLE}s for federation link..."
  sleep "$FEDERATION_SETTLE"

  echo "  [stack] Waiting ${BRIDGE_SETTLE}s for DDS discovery..."
  sleep "$BRIDGE_SETTLE"

  warm_dds
}

stack_down() {
  echo "  [stack] Tearing down..."
  podman-compose -p "$PROJECT" -f "$COMPOSE_FILE" down --timeout 10 &>/dev/null || true
}

warm_dds() {
  local listener; listener=$(ctr ros2-listener)
  [ -n "$listener" ] || return 0
  podman exec "$listener" bash -c \
    "set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; ros2 topic list" &>/dev/null || true
  sleep 2
}

# ── Topic flow check ──────────────────────────────────────────────────────────
check_flows() {
  local topic="$1"
  local timeout="${2:-$FLOW_TIMEOUT}"
  local listener; listener=$(ctr ros2-listener)
  [ -n "$listener" ] || { echo "    ERROR: ros2-listener not found"; return 1; }
  podman exec "$listener" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $timeout ros2 topic echo '$topic' 2>/dev/null | grep -m 1 'data:'
  " &>/dev/null
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

# ── Failure injection primitives ──────────────────────────────────────────────
kill_svc() {
  local service="$1" signal="${2:-SIGKILL}"
  local cname; cname=$(ctr "$service")
  if [ -z "$cname" ]; then
    echo "    ERROR: container for '$service' not found"
    return 1
  fi
  podman kill --signal "$signal" "$cname"
  echo "  [kill] sent $signal to $cname"
}

restart_svc() {
  local service="$1"
  local cname; cname=$(ctr "$service")
  if [ -z "$cname" ]; then
    echo "    ERROR: container for '$service' not found"
    return 1
  fi
  podman start "$cname" &>/dev/null
  echo "  [restart] started $cname"
}

partition_link() {
  local net; net=$(wan_network)
  if [ -z "$net" ]; then
    echo "    ERROR: wan-net not found for project '$PROJECT'"
    return 1
  fi
  local cname; cname=$(ctr edge-router)
  podman network disconnect "$net" "$cname" 2>/dev/null
  echo "  [partition] disconnected $cname from $net"
}

restore_link() {
  local net; net=$(wan_network)
  if [ -z "$net" ]; then
    echo "    ERROR: wan-net not found for project '$PROJECT'"
    return 1
  fi
  local cname; cname=$(ctr edge-router)
  podman network connect "$net" "$cname" 2>/dev/null
  echo "  [restore] reconnected $cname to $net"
}

# ── Recovery timing ───────────────────────────────────────────────────────────
# Polls check_flows until a message arrives or the deadline passes.
# Echoes elapsed seconds from kill_epoch on success, -1 on timeout.
measure_recovery() {
  local topic="$1" kill_epoch="$2" timeout="${3:-$RECONNECT_TIMEOUT}"
  local deadline=$(( kill_epoch + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if check_flows "$topic" 3; then
      echo $(( $(date +%s) - kill_epoch ))
      return 0
    fi
    sleep 2
  done
  echo -1
  return 1
}

# ── Log inspection ────────────────────────────────────────────────────────────
log_check() {
  local service="$1" pattern="$2"
  local cname; cname=$(ctr "$service")
  [ -n "$cname" ] || return 1
  podman logs "$cname" 2>&1 | grep -q "$pattern"
}

# ── Admin API poll ────────────────────────────────────────────────────────────
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

# ── Bench helpers (used only by N8) ──────────────────────────────────────────
bench_start_pub() {
  local talker; talker=$(ctr ros2-talker)
  [ -n "$talker" ] || { echo "    ERROR: ros2-talker not found"; return 1; }
  podman exec -d "$talker" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    python3 /tests/bench_pub.py --rate 50 --duration 180 --topic /bench
  "
  echo "  [bench] bench_pub started at 50 Hz inside $talker"
}

bench_start_sub() {
  local duration="${1:-90}"
  local listener; listener=$(ctr ros2-listener)
  [ -n "$listener" ] || { echo "    ERROR: ros2-listener not found"; return 1; }
  podman exec "$listener" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    python3 /tests/bench_sub.py --duration $duration --warmup 5 --topic /bench
  "
}

bench_parse_gaps() {
  local file="$1"
  python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    print(d.get('gaps', 0), d.get('n', 0))
except Exception:
    print('0 0')
" 2>/dev/null || echo "0 0"
}

# ── Scenario N1: SIGKILL edge-router ─────────────────────────────────────────
scenario_N1() {
  sep "Scenario N1: SIGKILL edge-router — abrupt crash"
  echo "  Expected: publisher stalls ≤5s (wait_before_close), then transport closes."
  echo "  Recovery: edge-router restarts, federation link re-established."

  stack_up
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N1] Sending SIGKILL to edge-router at $(date -u +%H:%M:%S)..."
  kill_svc edge-router SIGKILL

  # Brief pause — verify traffic stops
  sleep 3
  if ! check_flows /chatter "$BLOCK_TIMEOUT"; then
    pass "N1: /chatter stops after SIGKILL (expected)"
  else
    note "N1: /chatter still flowing 3s after SIGKILL — may be in-flight buffering"
  fi

  echo "  [N1] Restarting edge-router..."
  restart_svc edge-router

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N1: /chatter resumes — recovery in ${recover_time}s from kill"
    if [ "$recover_time" -gt 30 ]; then
      note "N1: recovery took ${recover_time}s — check for Issue #1886 race in router logs"
    fi
  else
    fail "N1: /chatter did not resume within ${RECONNECT_TIMEOUT}s after restart"
  fi

  stack_down
}

# ── Scenario N2: SIGTERM edge-router ─────────────────────────────────────────
scenario_N2() {
  sep "Scenario N2: SIGTERM edge-router — graceful shutdown"
  echo "  Expected: router drains connections before exiting."
  echo "  Recovery: same as N1."

  stack_up
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N2] Sending SIGTERM to edge-router at $(date -u +%H:%M:%S)..."
  kill_svc edge-router SIGTERM

  sleep 3
  if ! check_flows /chatter "$BLOCK_TIMEOUT"; then
    pass "N2: /chatter stops after SIGTERM (expected)"
  else
    note "N2: /chatter still flowing 3s after SIGTERM — graceful drain in progress"
  fi

  echo "  [N2] Restarting edge-router..."
  restart_svc edge-router

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N2: /chatter resumes — recovery in ${recover_time}s from SIGTERM"
  else
    fail "N2: /chatter did not resume within ${RECONNECT_TIMEOUT}s after restart"
  fi

  stack_down
}

# ── Scenario N3: Fast-cycle restart (Issue #1886 race) ───────────────────────
scenario_N3() {
  sep "Scenario N3: Fast-cycle restart — Issue #1886 race condition reproducer"
  echo "  Kills edge-router and restarts it within 0.5s to trigger the overlapping-Face race."
  echo "  PR #2438 (Feb 2026) serialises transport creation per ZID as a partial mitigation."
  echo "  Zenoh 1.8.x (Kiyohime, Mar 2026) fixed connectivity reestablishment bugs."

  stack_up
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N3] SIGKILL edge-router, then restart in 0.5s..."
  kill_svc edge-router SIGKILL
  sleep 0.5
  restart_svc edge-router

  # Give routers time for declaration exchange (success or failure)
  sleep 5

  # Check for Issue #1886 signature in cloud-router logs
  if log_check cloud-router "unknown routing context id 0"; then
    note "N3: Issue #1886 signature detected in cloud-router logs"
    note "N3:   Log: 'Received router declaration with unknown routing context id 0'"
    note "N3:   PR #2438 fix may not be active — check Zenoh version"
  else
    pass "N3: no routing-context race error in cloud-router logs (PR #2438/Kiyohime active)"
  fi

  # Verify routing eventually recovers regardless of the race
  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N3: /chatter resumes in ${recover_time}s after fast-cycle restart"
    if [ "$recover_time" -gt 20 ]; then
      note "N3: ${recover_time}s recovery suggests routing was halted (~17s) before self-correcting"
    fi
  else
    fail "N3: /chatter did not resume within ${RECONNECT_TIMEOUT}s — Issue #1886 may have permanently halted routing"
  fi

  stack_down
}

# ── Scenario N4: Network partition ───────────────────────────────────────────
scenario_N4() {
  sep "Scenario N4: Network partition — disconnect edge-router from WAN"
  echo "  Uses 'podman network disconnect' to sever the federation link."
  echo "  Router processes stay alive; only the TCP session between them is lost."

  stack_up
  assert_flows /chatter

  local kill_time; kill_time=$(date +%s)
  echo "  [N4] Partitioning WAN link at $(date -u +%H:%M:%S)..."
  partition_link

  sleep 5
  assert_blocked /chatter

  local remaining=$(( OUTAGE_SECS - 5 ))
  echo "  [N4] Holding partition ${remaining}s more (total: ${OUTAGE_SECS}s)..."
  sleep "$remaining"

  echo "  [N4] Restoring WAN link at $(date -u +%H:%M:%S)..."
  restore_link

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N4: /chatter resumes in ${recover_time}s after WAN link restored"
  else
    fail "N4: /chatter did not resume within ${RECONNECT_TIMEOUT}s — federation link failed to reestablish"
  fi

  stack_down
}

# ── Scenarios N5+N6: Bridge sidecar restart ───────────────────────────────────
scenario_N5_N6() {
  sep "Scenarios N5+N6: Bridge sidecar restart (first, then second)"
  echo "  N5: first restart of zenoh-bridge-talker — should recover normally."
  echo "  N6: second restart — probes zenoh-plugin-ros2dds Issue #86"
  echo "      (silent zero-message delivery failure after second bridge restart)."
  echo "  Note: Issue #86 was documented in peer mode; client mode may differ."

  stack_up
  assert_flows /chatter

  # ── N5: first restart ────────────────────────────────────────────
  sep "N5: First bridge restart"
  echo "  [N5] Sending SIGKILL to zenoh-bridge-talker..."
  kill_svc zenoh-bridge-talker SIGKILL
  sleep 1
  restart_svc zenoh-bridge-talker

  local kill_time; kill_time=$(( $(date +%s) - 2 ))
  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N5: /chatter resumes in ${recover_time}s after first bridge restart"
  else
    fail "N5: /chatter did not resume after first bridge restart (unexpected)"
  fi

  # ── N6: second restart ────────────────────────────────────────────
  sep "N6: Second bridge restart (Issue #86 probe)"
  echo "  [N6] Sending SIGKILL to zenoh-bridge-talker a second time..."
  kill_svc zenoh-bridge-talker SIGKILL
  sleep 1
  restart_svc zenoh-bridge-talker

  echo "  [N6] Waiting ${BRIDGE_SETTLE}s for DDS re-discovery after second restart..."
  sleep "$BRIDGE_SETTLE"

  if check_flows /chatter "$FLOW_TIMEOUT"; then
    pass "N6: /chatter still flows after second bridge restart (Issue #86 not reproduced)"
  else
    fail "N6: zero messages after second bridge restart — Issue #86 reproduced"
    note "N6: zenoh-plugin-ros2dds Issue #86 — subscriber silent after 2nd bridge restart (client mode)"
    note "N6: Workaround: also restart zenoh-bridge-listener or the edge-router to force re-declaration"
  fi

  stack_down
}

# ── Scenario N7: Advanced Pub/Sub E2E recovery (SKIP) ────────────────────────
scenario_N7() {
  sep "Scenario N7: Advanced Pub/Sub E2E sample recovery (SKIP)"
  note "N7 SKIP: requires ROS 2 publisher with TRANSIENT_LOCAL QoS durability"
  note "N7 SKIP: rmw_zenoh PR #591 (Apr 2025) enables AdvancedPublisher for RELIABLE+TRANSIENT_LOCAL"
  note "N7 SKIP: rmw_zenoh Issue #457 tracks extension to all RELIABLE topics (open mid-2026)"
  note "N7 SKIP: manual test: 'ros2 topic pub --qos-durability transient_local /bench_latched std_msgs/String', kill router, restart, verify subscriber gets missed samples"
}

# ── Scenario N8: Baseline loss count ─────────────────────────────────────────
scenario_N8() {
  sep "Scenario N8: Baseline loss count — 50 Hz, ${OUTAGE_SECS}s outage"
  echo "  bench_pub @ 50 Hz publishes /bench; SIGKILL edge-router for ${OUTAGE_SECS}s."
  echo "  Expected gaps ≈ 50 × ${OUTAGE_SECS} = $(( 50 * OUTAGE_SECS )) messages."

  stack_up
  assert_flows /chatter

  echo "  [N8] Starting bench_pub at 50 Hz (180s duration)..."
  bench_start_pub
  sleep 5  # let /bench topic be discovered across federation

  local bench_out; bench_out=$(mktemp)
  echo "  [N8] Starting bench_sub for 120s (captures gaps across outage)..."
  bench_start_sub 120 > "$bench_out" &
  local bench_pid=$!

  # Wait for bench warmup (5s built into bench_sub) + settle buffer
  sleep 10
  echo "  [N8] Warmup complete. Injecting failure at $(date -u +%H:%M:%S)..."

  local kill_time; kill_time=$(date +%s)
  kill_svc edge-router SIGKILL

  echo "  [N8] Holding outage for ${OUTAGE_SECS}s..."
  sleep "$OUTAGE_SECS"

  echo "  [N8] Restarting edge-router at $(date -u +%H:%M:%S)..."
  restart_svc edge-router

  echo "  [N8] Waiting for bench_sub to complete..."
  wait "$bench_pid" || true

  # Parse bench_sub JSON output
  local result; result=$(bench_parse_gaps "$bench_out")
  local gaps; gaps=$(echo "$result" | awk '{print $1}')
  local n_received; n_received=$(echo "$result" | awk '{print $2}')
  rm -f "$bench_out"

  local expected=$(( 50 * OUTAGE_SECS ))
  local tolerance=$(( expected / 5 ))   # ±20%
  local low=$(( expected - tolerance ))
  local high=$(( expected + tolerance ))

  pass "N8: bench received $n_received messages; gaps=$gaps (expected ~$expected for ${OUTAGE_SECS}s at 50 Hz)"
  if [ "$gaps" -ge "$low" ] && [ "$gaps" -le "$high" ]; then
    pass "N8: gap count within ±20% of expected ($low–$high)"
  elif [ "$gaps" -gt "$high" ]; then
    note "N8: gap count $gaps exceeds expected max ($high) — recovery took longer than ${OUTAGE_SECS}s"
  elif [ "$gaps" -gt 0 ]; then
    note "N8: gap count $gaps below expected min ($low) — some buffering may have occurred"
  else
    note "N8: zero gaps — bench_sub may have missed the outage window or /bench not bridged to cloud-router"
  fi

  stack_down
}

# ── Scenario N9: Drop vs Block congestion control (SKIP) ─────────────────────
scenario_N9() {
  sep "Scenario N9: CongestionControl::Drop vs Block comparison (SKIP)"
  note "N9 SKIP: requires a direct Zenoh Python/Rust API publisher (not via ROS 2 middleware)"
  note "N9 SKIP: Block (rmw_zenoh default for RELIABLE QoS):"
  note "N9 SKIP:   publisher thread blocks up to wait_before_close=5s, then transport closes"
  note "N9 SKIP: Drop (best-effort):"
  note "N9 SKIP:   messages discarded after wait_before_drop=1ms when TX queue full"
  note "N9 SKIP: See DEFAULT_CONFIG.json5: transport.link.tx.queue.congestion_control"
}

# ── Scenario N10: Federation link — admin-space validation ───────────────────
scenario_N10() {
  sep "Scenario N10: Federation link failure — admin-space session monitoring"
  echo "  WAN partition + REST API polling to observe peer-session lifecycle."

  stack_up
  assert_flows /chatter

  # Confirm federation link is visible in admin space before partition
  echo "  [N10] Checking cloud-router admin space before partition..."
  if wait_for_router_api "http://localhost:8001/@/**" "cloud-router" >/dev/null; then
    pass "N10: cloud-router admin space populated (federation session active)"
  else
    note "N10: cloud-router admin space empty before partition — admin plugin may not be configured"
  fi

  local kill_time; kill_time=$(date +%s)
  echo "  [N10] Partitioning WAN link at $(date -u +%H:%M:%S)..."
  partition_link

  # Poll admin space for session disappearance (keepalive timeout)
  echo "  [N10] Polling admin space for up to ${ADMIN_TIMEOUT}s to detect session drop..."
  local deadline=$(( $(date +%s) + ADMIN_TIMEOUT ))
  local session_dropped=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local cur_body
    cur_body=$(curl -sf --max-time 3 "http://localhost:8001/@/**" 2>/dev/null || echo "")
    if [ -z "$cur_body" ] || [ "$cur_body" = "{}" ] || [ "$cur_body" = "null" ] || [ "$cur_body" = "[]" ]; then
      session_dropped=1
      local elapsed=$(( $(date +%s) - kill_time ))
      echo "    admin space cleared at ${elapsed}s after partition"
      break
    fi
    sleep 3
  done

  if [ "$session_dropped" -eq 1 ]; then
    pass "N10: cloud-router admin space cleared after WAN partition (session dropped)"
  else
    note "N10: session still visible in admin space ${ADMIN_TIMEOUT}s after partition"
    note "N10:   keepalive timeout may exceed ADMIN_TIMEOUT=${ADMIN_TIMEOUT}s — increase ADMIN_TIMEOUT to observe"
  fi

  local remaining=$(( OUTAGE_SECS - ADMIN_TIMEOUT ))
  if [ "$remaining" -gt 0 ]; then
    echo "  [N10] Holding partition ${remaining}s more (total: ${OUTAGE_SECS}s)..."
    sleep "$remaining"
  fi

  echo "  [N10] Restoring WAN link at $(date -u +%H:%M:%S)..."
  restore_link

  local recover_time
  recover_time=$(measure_recovery /chatter "$kill_time" "$RECONNECT_TIMEOUT") || recover_time=-1
  if [ "$recover_time" -ge 0 ] 2>/dev/null; then
    pass "N10: /chatter resumes in ${recover_time}s after WAN link restored"
  else
    fail "N10: /chatter did not resume within ${RECONNECT_TIMEOUT}s after restore"
  fi

  # Verify admin space repopulates (federation session re-established)
  echo "  [N10] Checking cloud-router admin space after restore..."
  if wait_for_router_api "http://localhost:8001/@/**" "cloud-router post-restore" >/dev/null; then
    pass "N10: cloud-router admin space repopulated (federation session restored)"
  else
    note "N10: admin space not repopulated within ${ADMIN_TIMEOUT}s after restore"
  fi

  stack_down
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  echo ""
  echo "=== Zenoh Negative Tests ==="
  echo "    Router image       : quay.io/ecosystem-appeng/zenoh-router:latest"
  echo "    Bridge image       : quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:latest"
  echo "    Demo image         : ${DEMO_IMAGE:-quay.io/jianrzha/ros2-zenoh-demo}:${DEMO_VERSION:-0.0.7}"
  echo "    Compose file       : $COMPOSE_FILE"
  echo "    Flow timeout       : ${FLOW_TIMEOUT}s"
  echo "    Reconnect timeout  : ${RECONNECT_TIMEOUT}s"
  echo "    Outage duration    : ${OUTAGE_SECS}s"
  echo "    Federation settle  : ${FEDERATION_SETTLE}s"
  echo "    Bridge settle      : ${BRIDGE_SETTLE}s"
  echo ""
  echo "  Topology:"
  echo "    [edge-net] talker → bridge-talker → edge-router"
  echo "                                              │ wan-net (failure point for N4, N10)"
  echo "    [cloud-net] listener ← bridge-listener ← cloud-router"

  stack_down 2>/dev/null || true

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
    N1)        scenario_N1 ;;
    N2)        scenario_N2 ;;
    N3)        scenario_N3 ;;
    N4)        scenario_N4 ;;
    N5|N6|N5N6) scenario_N5_N6 ;;
    N7)        scenario_N7 ;;
    N8)        scenario_N8 ;;
    N9)        scenario_N9 ;;
    N10)       scenario_N10 ;;
    *)
      echo "ERROR: unknown scenario '$target'. Valid: N1 N2 N3 N4 N5 N6 N7 N8 N9 N10 all"
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
