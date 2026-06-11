#!/usr/bin/env bash
# Live-stream the zenoh-bridge-ros2dds message pipeline with labeled prefixes.
# Shows: Zenoh router, talker ROS 2 node, listener ROS 2 node.
# Press Ctrl-C to stop.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ros2-zenoh-bridge}"

cleanup() { kill 0 2>/dev/null || true; }
trap cleanup INT TERM EXIT

echo "=== ROS 2 + zenoh-bridge-ros2dds Live Message Pipeline ==="
printf "    Namespace : %s\n" "$NAMESPACE"
echo "    Press Ctrl-C to stop."
echo
echo "    What to watch:"
echo "      [talker  ]  Publishing: 'Hello World: N'         (DDS → bridge sidecar)"
echo "      [listener]  I heard: [Hello World: N]            (bridge sidecar → DDS)"
echo "      [router  ]  Zenoh routing daemon operational output"
echo "    To inspect bridge sidecar logs:"
echo "      kubectl logs -n $NAMESPACE -l app=ros2-dds-talker   -c zenoh-bridge -f"
echo "      kubectl logs -n $NAMESPACE -l app=ros2-dds-listener -c zenoh-bridge -f"
echo

kubectl logs -n "$NAMESPACE" -l app=zenoh-bridge-router --follow --tail=0 2>/dev/null \
    | awk '{ print "[router  ] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=ros2-dds-talker -c ros2-talker --follow --tail=0 2>/dev/null \
    | awk '{ print "[talker  ] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=ros2-dds-listener -c ros2-listener --follow --tail=0 2>/dev/null \
    | awk '{ print "[listener] " $0; fflush() }' &

wait
