#!/usr/bin/env bash
# Live-stream all three pods with labeled prefixes to show the message pipeline.
# Press Ctrl-C to stop.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ros2-zenoh}"

cleanup() { kill 0 2>/dev/null || true; }
trap cleanup INT TERM EXIT

echo "=== ROS2 + Zenoh Live Message Pipeline ==="
printf "    Namespace : %s\n" "$NAMESPACE"
echo "    Press Ctrl-C to stop."
echo
echo "    What to watch:"
echo "      [talker  ]  Publishing: 'Hello World: N'"
echo "      [listener]  I heard: [Hello World: N]   ← same N, ~1 ms later"
echo "      [router  ]  zenoh router operational output"
echo

kubectl logs -n "$NAMESPACE" -l app=zenoh-router  --follow --tail=0 2>/dev/null \
    | awk '{ print "[router  ] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=ros2-talker   --follow --tail=0 2>/dev/null \
    | awk '{ print "[talker  ] " $0; fflush() }' &

kubectl logs -n "$NAMESPACE" -l app=ros2-listener --follow --tail=0 2>/dev/null \
    | awk '{ print "[listener] " $0; fflush() }' &

wait
