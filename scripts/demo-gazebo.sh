#!/usr/bin/env bash
# Live-stream the Gazebo + ros_gz_bridge + zenoh-bridge-ros2dds pipeline.
# Shows Gazebo sim output, bridge topic activity, and Zenoh router status.
# Press Ctrl-C to stop.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ros2-zenoh-gazebo}"

cleanup() { kill 0 2>/dev/null || true; }
trap cleanup INT TERM EXIT

echo "=== Gazebo Harmonic + ros_gz_bridge + zenoh-bridge Demo ==="
printf "    Namespace : %s\n" "$NAMESPACE"
echo "    Press Ctrl-C to stop."
echo
echo "    Data flow:"
echo "      [gz-sim   ]  Gazebo physics + DiffDrive plugin (publishes /odom, /tf)"
echo "      [gz-bridge ]  ros_gz_bridge: gz-transport → ROS 2 DDS"
echo "      [zenoh     ]  zenoh-bridge-ros2dds: DDS → Zenoh TCP → router"
echo "      [router    ]  Zenoh router: forwards to any connected rmw_zenoh_cpp client"
echo
echo "    To send a drive command to the robot:"
echo "      kubectl exec -n $NAMESPACE deploy/gazebo-sim -c ros-gz-bridge -- bash -c \\"
echo "        'source /opt/ros/jazzy/setup.bash && \\"
echo "         ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \\"
echo "           \"{linear: {x: 0.5}, angular: {z: 0.3}}\"'"
echo

kubectl logs -n "$NAMESPACE" -l app=zenoh-router --follow --tail=0 2>/dev/null \
    | awk '{ print "[router   ] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=gazebo-sim -c gazebo-sim --follow --tail=0 2>/dev/null \
    | awk '{ print "[gz-sim   ] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=gazebo-sim -c ros-gz-bridge --follow --tail=0 2>/dev/null \
    | awk '{ print "[gz-bridge] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=gazebo-sim -c zenoh-bridge --follow --tail=0 2>/dev/null \
    | awk '{ print "[zenoh    ] " $0; fflush() }' &

wait
