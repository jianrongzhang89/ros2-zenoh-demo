#!/usr/bin/env bash
# bench_run_pub.sh — reads benchmark parameters from container environment,
# then launches bench_pub.py. Avoids compose-level variable substitution
# issues by deferring all expansion to bash inside the container.
set +u
source /opt/ros/jazzy/setup.bash
set -u

sleep "${PUB_SLEEP:-10}"
exec python3 /tests/bench_pub.py \
  --rate     "${RATE_HZ:-10}" \
  --duration "${PUB_DURATION:-80}" \
  --topic    /bench
