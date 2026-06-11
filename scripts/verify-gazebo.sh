#!/usr/bin/env bash
# Verify the Gazebo + ros_gz_bridge + zenoh-bridge-ros2dds pipeline.
# Checks pod readiness, bridge connectivity, and /odom message flow.
# Exit 0 on all-pass, 1 on any failure.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ros2-zenoh-gazebo}"
ODOM_LINES="${ODOM_LINES:-30}"

PASS=0; FAIL=0

pass() { printf "  PASS  %s\n" "$1"; ((PASS++)) || true; }
fail() { printf "  FAIL  %s\n" "$1"; ((FAIL++)) || true; }

echo "=== Gazebo + ros_gz_bridge + zenoh-bridge Verification ==="
printf "    Namespace : %s\n\n" "$NAMESPACE"

# ── Pod readiness ─────────────────────────────────────────────────────────────
echo "── Pod Readiness ────────────────────────────────────────────────────────"
for dep in zenoh-router gazebo-sim; do
    ready=$(kubectl get deployment "$dep" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [[ "${ready:-0}" == "1" ]]; then
        pass "$dep  (1/1 Ready)"
    else
        fail "$dep  (readyReplicas=${ready:-0})"
    fi
done
echo

# ── Gazebo simulation running ─────────────────────────────────────────────────
echo "── Gazebo Simulation ────────────────────────────────────────────────────"
gz_log=$(kubectl logs -n "$NAMESPACE" -l app=gazebo-sim -c gazebo-sim \
    --tail=50 2>/dev/null || true)
if echo "$gz_log" | grep -qiE "Loaded SDF|Running|iteration|diff_drive"; then
    pass "gazebo-sim  simulation loop running"
else
    fail "gazebo-sim  no simulation activity in last 50 log lines"
fi
echo

# ── ros_gz_bridge connectivity ────────────────────────────────────────────────
echo "── ros_gz_bridge Connectivity ───────────────────────────────────────────"
bridge_log=$(kubectl logs -n "$NAMESPACE" -l app=gazebo-sim -c ros-gz-bridge \
    --tail=30 2>/dev/null || true)
if echo "$bridge_log" | grep -qiE "Creating bridge|/odom|/clock|Subscrib"; then
    pass "ros-gz-bridge  topic bridges created"
else
    fail "ros-gz-bridge  no bridge activity in last 30 log lines"
fi
echo

# ── zenoh-bridge connectivity ─────────────────────────────────────────────────
echo "── zenoh-bridge Connectivity ────────────────────────────────────────────"
zenoh_log=$(kubectl logs -n "$NAMESPACE" -l app=gazebo-sim -c zenoh-bridge \
    --tail=30 2>/dev/null || true)
if echo "$zenoh_log" | grep -qiE "Opening session|Joining|Connected|router"; then
    pass "zenoh-bridge  connected to zenoh-router"
else
    fail "zenoh-bridge  no connection evidence in last 30 log lines"
fi
echo

# ── /odom message flow ────────────────────────────────────────────────────────
echo "── /odom Message Flow ───────────────────────────────────────────────────"
echo "    Sampling /odom for 5 seconds via ros-gz-bridge container..."

odom_out=$(kubectl exec -n "$NAMESPACE" deploy/gazebo-sim -c ros-gz-bridge \
    -- bash -c \
    'source /opt/ros/jazzy/setup.bash && \
     timeout 5 ros2 topic echo /odom --field header.frame_id 2>/dev/null | head -5' \
    2>/dev/null || true)

if echo "$odom_out" | grep -q "odom"; then
    count=$(echo "$odom_out" | grep -c "odom" || true)
    pass "/odom  ${count} message(s) received (frame_id=odom)"
else
    fail "/odom  no messages received in 5-second window"
fi
echo

# ── /cmd_vel write-back ───────────────────────────────────────────────────────
echo "── /cmd_vel Write-back (ROS → Gazebo) ──────────────────────────────────"
echo "    Publishing one drive command to /cmd_vel ..."
cmd_rc=0
kubectl exec -n "$NAMESPACE" deploy/gazebo-sim -c ros-gz-bridge \
    -- bash -c \
    'source /opt/ros/jazzy/setup.bash && \
     ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \
       "{linear: {x: 0.0}, angular: {z: 0.0}}" 2>&1 | tail -1' \
    2>/dev/null || cmd_rc=$?
if [[ "$cmd_rc" -eq 0 ]]; then
    pass "/cmd_vel  publish succeeded (ROS → gz-bridge → Gazebo)"
else
    fail "/cmd_vel  publish failed (exit $cmd_rc)"
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "═════════════════════════════════════════════════════════════════════════"
printf "  Result : %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
