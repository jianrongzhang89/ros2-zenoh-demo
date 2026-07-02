#!/usr/bin/env bash
# bench_run_sub.sh — reads benchmark parameters from container environment,
# then launches bench_sub.py. Avoids compose-level variable substitution
# issues by deferring all expansion to bash inside the container.
set +u
source /opt/ros/jazzy/setup.bash
set -u

sleep "${SUB_SLEEP:-20}"
exec python3 /tests/bench_sub.py \
  --duration "${MEASURE_DURATION:-30}" \
  --warmup   "${WARMUP_SECS:-5}" \
  --topic    /bench
