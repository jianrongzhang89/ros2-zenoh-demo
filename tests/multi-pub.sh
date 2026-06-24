#!/usr/bin/env bash
# tests/multi-pub.sh
# Publishes four test topics from within the ros2-talker container.
# Sourced /opt/ros/jazzy/setup.bash must already be set in the environment,
# or this script sources it here.
#
# Topics and rates:
#   /chatter         10 Hz  — primary "allowed" topic (replaces demo_nodes_cpp talker)
#   /sensor/scan     10 Hz  — simulated lidar; blocked in most filter scenarios
#   /sensor/camera   10 Hz  — simulated camera; blocked in most filter scenarios
#   /system/status    1 Hz  — low-rate heartbeat; selectively allowed

set -eo pipefail

# Source ROS 2 environment only if not already set up (e.g. when run standalone).
# The compose command's exec chain already exports the ROS env; re-sourcing with
# set -u active fails because setup.bash references AMENT_TRACE_SETUP_FILES before
# setting it.
if ! command -v ros2 &>/dev/null && [ -f /opt/ros/jazzy/setup.bash ]; then
  set +u
  # shellcheck disable=SC1091
  source /opt/ros/jazzy/setup.bash
  set -u
fi

echo "[multi-pub] Starting publishers..."

# Use relative topic names (no leading /) so that ROS_NAMESPACE is respected.
# In the default namespace (ROS_NAMESPACE unset or "/"):
#   chatter -> /chatter,  sensor/scan -> /sensor/scan, etc.
# When ROS_NAMESPACE=robot-1 (Scenario 6):
#   chatter -> /robot-1/chatter, sensor/scan -> /robot-1/sensor/scan, etc.
ros2 topic pub chatter        std_msgs/msg/String "{data: chatter}"  --rate 10 &
PID_CHATTER=$!

ros2 topic pub sensor/scan    std_msgs/msg/String "{data: scan}"     --rate 10 &
PID_SCAN=$!

ros2 topic pub sensor/camera  std_msgs/msg/String "{data: camera}"   --rate 10 &
PID_CAMERA=$!

ros2 topic pub system/status  std_msgs/msg/String "{data: status}"   --rate 1  &
PID_STATUS=$!

NS_LABEL="${ROS_NAMESPACE:+${ROS_NAMESPACE}/}"
echo "[multi-pub] Publishing on ${NS_LABEL}chatter (10 Hz), ${NS_LABEL}sensor/scan (10 Hz), ${NS_LABEL}sensor/camera (10 Hz), ${NS_LABEL}system/status (1 Hz)"

# Forward SIGTERM/SIGINT to all background publishers
trap "kill $PID_CHATTER $PID_SCAN $PID_CAMERA $PID_STATUS 2>/dev/null; exit 0" SIGTERM SIGINT

wait $PID_CHATTER $PID_SCAN $PID_CAMERA $PID_STATUS
