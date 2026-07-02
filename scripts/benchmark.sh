#!/usr/bin/env bash
# scripts/benchmark.sh
# End-to-end latency benchmarks: single-router vs. federated Zenoh router topology.
#
# Topology A — single-router:
#   bench-pub → bridge-pub → zenoh-router → bridge-sub → bench-sub
#
# Topology B — federated:
#   bench-pub → bridge-pub → edge-router ─── cloud-router → bridge-sub → bench-sub
#
# Usage:
#   bash scripts/benchmark.sh                   # all topologies, all rates
#   TOPOLOGY=single bash scripts/benchmark.sh   # single topology only
#   RATES="10 100" bash scripts/benchmark.sh    # override rate list
#   DRY_RUN=1 bash scripts/benchmark.sh         # print commands without running
#
# Output:
#   docs/benchmark-results.csv   — raw data
#   docs/benchmark-results.md    — markdown summary (appended each run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Tunables ────────────────────────────────────────────────────────────────
RATES="${RATES:-1 10 50 100 200}"
MEASURE_DURATION="${MEASURE_DURATION:-30}"   # seconds of actual measurement
WARMUP_SECS_SINGLE="${WARMUP_SECS_SINGLE:-5}"
WARMUP_SECS_FED="${WARMUP_SECS_FED:-8}"
DRY_RUN="${DRY_RUN:-0}"

# Container wait timeout: sleep + warmup + measure + 20s buffer
# single: 20 + 5 + 30 + 20 = 75
# fed:    35 + 8 + 30 + 20 = 93
WAIT_TIMEOUT_SINGLE=$(( 20 + WARMUP_SECS_SINGLE + MEASURE_DURATION + 20 ))
WAIT_TIMEOUT_FED=$(( 35 + WARMUP_SECS_FED + MEASURE_DURATION + 20 ))

CSV="$ROOT/docs/benchmark-results.csv"
MD_REPORT="$ROOT/docs/benchmark-results.md"

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
info()  { printf "  ${CYAN}INFO${RESET}  %s\n" "$*" >&2; }
ok()    { printf "  ${GREEN} OK ${RESET}  %s\n" "$*" >&2; }
warn()  { printf "  ${YELLOW}WARN${RESET}  %s\n" "$*" >&2; }
err()   { printf "  ${RED}ERR ${RESET}  %s\n" "$*" >&2; }
sep()   { printf "\n${CYAN}── %s${RESET}\n" "$*" >&2; }

# ── Container helper ─────────────────────────────────────────────────────────
# Returns the full container name for <project> + <service>.
# Handles both podman-compose naming conventions:
#   new (>=1.1): <project>-<service>-<N>
#   old:         <project>_<service>_<N>
find_ctr() {
  local project="$1" service="$2"
  podman ps -a --format "{{.Names}}" \
    | grep -E "^${project}[-_]${service}[-_][0-9]+$" \
    | head -1
}

# Wait for a container to reach "exited" state.
# Returns 0 with the container name on success, 1 on timeout.
wait_for_exit() {
  local project="$1" service="$2" timeout="$3"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local ctr
    ctr=$(find_ctr "$project" "$service") || true
    if [ -n "$ctr" ]; then
      local status
      status=$(podman inspect --format "{{.State.Status}}" "$ctr" 2>/dev/null || echo "unknown")
      if [ "$status" = "exited" ]; then
        echo "$ctr"
        return 0
      fi
    fi
    sleep 3
  done
  err "Timed out waiting for $service to exit (${timeout}s)"
  return 1
}

# ── Stack helpers ─────────────────────────────────────────────────────────────
stack_up() {
  local project="$1" compose_file="$2"
  shift 2
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] podman-compose -p $project -f $compose_file up -d  env: $*"
    return
  fi
  env "$@" podman-compose -p "$project" -f "$compose_file" up -d >/dev/null 2>&1
}

stack_down() {
  local project="$1" compose_file="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] podman-compose -p $project down"
    return
  fi
  podman-compose -p "$project" -f "$compose_file" down --timeout 15 >/dev/null 2>&1 || true
}

# ── Parse JSON stat from bench-sub logs ──────────────────────────────────────
parse_stat() {
  local ctr="$1" key="$2"
  podman logs "$ctr" 2>/dev/null \
    | grep '^{' \
    | tail -1 \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$key', 'N/A'))" 2>/dev/null \
    || echo "N/A"
}

get_full_stats() {
  local ctr="$1"
  podman logs "$ctr" 2>/dev/null | grep '^{' | tail -1
}

# ── One benchmark run ─────────────────────────────────────────────────────────
run_one() {
  local topology="$1" rate="$2"
  local project="bench-${topology}-${rate}"

  if [ "$topology" = "single" ]; then
    local compose_file="$ROOT/compose.bench-single.yml"
    local wait_timeout=$WAIT_TIMEOUT_SINGLE
    local warmup=$WARMUP_SECS_SINGLE
    local pub_sleep=10 sub_sleep=20
  else
    local compose_file="$ROOT/compose.bench-federated.yml"
    local wait_timeout=$WAIT_TIMEOUT_FED
    local warmup=$WARMUP_SECS_FED
    local pub_sleep=20 sub_sleep=35
  fi

  local pub_duration=$(( MEASURE_DURATION + sub_sleep + warmup + 10 ))

  info "Starting stack: topology=$topology rate=${rate}Hz measure=${MEASURE_DURATION}s"

  stack_down "$project" "$compose_file"  # clean slate

  stack_up "$project" "$compose_file" \
    "RATE_HZ=$rate" \
    "MEASURE_DURATION=$MEASURE_DURATION" \
    "WARMUP_SECS=$warmup" \
    "PUB_SLEEP=$pub_sleep" \
    "SUB_SLEEP=$sub_sleep" \
    "PUB_DURATION=$pub_duration"

  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] would wait ${wait_timeout}s for bench-sub to exit"
    echo "N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
    return 0
  fi

  local sub_ctr
  if ! sub_ctr=$(wait_for_exit "$project" "bench-sub" "$wait_timeout"); then
    warn "bench-sub did not exit cleanly for ${topology}@${rate}Hz — collecting what we have"
    sub_ctr=$(find_ctr "$project" "bench-sub") || true
  fi

  if [ -z "$sub_ctr" ]; then
    err "Could not find bench-sub container for project $project"
    stack_down "$project" "$compose_file"
    echo "ERROR,0,0,0,0,0,0,0"
    return 1
  fi

  local raw_stats
  raw_stats=$(get_full_stats "$sub_ctr")

  if [ -z "$raw_stats" ]; then
    err "No JSON stats from bench-sub for ${topology}@${rate}Hz"
    stack_down "$project" "$compose_file"
    echo "ERROR,0,0,0,0,0,0,0"
    return 1
  fi

  local n mean p50 p95 p99 max_ms min_ms gaps
  n=$(echo "$raw_stats"       | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['n'])")
  mean=$(echo "$raw_stats"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['mean_ms']:.2f}\")")
  p50=$(echo "$raw_stats"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['p50_ms']:.2f}\")")
  p95=$(echo "$raw_stats"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['p95_ms']:.2f}\")")
  p99=$(echo "$raw_stats"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['p99_ms']:.2f}\")")
  max_ms=$(echo "$raw_stats"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['max_ms']:.2f}\")")
  min_ms=$(echo "$raw_stats"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['min_ms']:.2f}\")")
  gaps=$(echo "$raw_stats"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['gaps'])")

  # n_expected = messages published during the measurement window only (after warmup).
  local meas_window=$(( MEASURE_DURATION - warmup ))
  local expected=$(( rate * meas_window ))
  local loss_pct
  if [ "$expected" -gt 0 ] 2>/dev/null; then
    loss_pct=$(python3 -c "print(f\"{max(0, ($expected - $n) / $expected * 100):.1f}\")")
  else
    loss_pct="N/A"
  fi

  ok "${topology}@${rate}Hz  n=${n}/${expected}  mean=${mean}ms  p95=${p95}ms  p99=${p99}ms  loss=${loss_pct}%  gaps=${gaps}"

  stack_down "$project" "$compose_file"

  echo "${topology},${rate},${n},${expected},${loss_pct},${mean},${p50},${p95},${p99},${max_ms},${min_ms},${gaps}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local target_topology="${TOPOLOGY:-all}"

  sep "Zenoh Router Latency Benchmark"
  echo "  Measurement duration : ${MEASURE_DURATION}s per rate"
  echo "  Rates (Hz)           : ${RATES}"
  echo "  Topology             : ${target_topology}"
  echo "  Output CSV           : ${CSV}"
  echo ""
  echo "  Topology A – single-router:  bench-pub → bridge → router → bridge → bench-sub"
  echo "  Topology B – federated:      bench-pub → bridge → edge-router ─── cloud-router → bridge → bench-sub"
  echo ""

  # Ensure docs dir exists
  mkdir -p "$ROOT/docs"

  # CSV header
  echo "topology,rate_hz,n_received,n_expected,loss_pct,mean_ms,p50_ms,p95_ms,p99_ms,max_ms,min_ms,gaps" > "$CSV"

  declare -a TOPOLOGIES=()
  case "$target_topology" in
    all)    TOPOLOGIES=(single federated) ;;
    single) TOPOLOGIES=(single) ;;
    fed*)   TOPOLOGIES=(federated) ;;
    *)      echo "ERROR: unknown TOPOLOGY '$target_topology'. Use single, federated, or all."; exit 1 ;;
  esac

  for topo in "${TOPOLOGIES[@]}"; do
    sep "Topology: ${topo}"
    for rate in $RATES; do
      local result
      result=$(run_one "$topo" "$rate") || true
      echo "${result}" >> "$CSV"
    done
  done

  # Generate markdown summary
  python3 - <<'PYEOF'
import csv, sys, os

csv_path = os.path.join(os.environ.get('ROOT', '.'), 'docs', 'benchmark-results.csv')
md_path  = os.path.join(os.environ.get('ROOT', '.'), 'docs', 'benchmark-results.md')

rows = []
try:
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            rows.append(row)
except FileNotFoundError:
    sys.exit(0)

def table(topo_rows, title):
    lines = [f"\n### {title}\n"]
    lines.append("| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |")
    lines.append("|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|")
    for r in topo_rows:
        lines.append(
            f"| {r['rate_hz']:>9} "
            f"| {r['n_received']:>8} "
            f"| {r['n_expected']:>8} "
            f"| {r['loss_pct']:>6} "
            f"| {r['mean_ms']:>9} "
            f"| {r['p50_ms']:>8} "
            f"| {r['p95_ms']:>8} "
            f"| {r['p99_ms']:>8} "
            f"| {r['max_ms']:>8} "
            f"| {r['gaps']:>4} |"
        )
    return "\n".join(lines)

import datetime
date_str = datetime.date.today().isoformat()

single_rows = [r for r in rows if r['topology'] == 'single']
fed_rows    = [r for r in rows if r['topology'] == 'federated']

with open(md_path, 'w') as f:
    f.write(f"# Zenoh Router Latency Benchmark Results\n\n")
    f.write(f"**Date:** {date_str}  \n")
    f.write(f"**Platform:** linux/arm64 (podman, libkrun on macOS Apple Silicon)  \n")
    f.write(f"**Zenoh router:** 1.9.0  \n")
    f.write(f"**zenoh-bridge-ros2dds:** 1.9.0  \n")
    f.write(f"**Message type:** std_msgs/msg/String with embedded nanosecond timestamp  \n")
    f.write(f"**Latency measurement:** publisher wall-clock ns → subscriber wall-clock ns (shared host clock, no sync needed)  \n\n")
    f.write("## Topology\n\n")
    f.write("**Single-router:**\n```\nbench-pub → bridge-pub → zenoh-router → bridge-sub → bench-sub\n```\n\n")
    f.write("**Federated:**\n```\nbench-pub → bridge-pub → edge-router ─(wan)─ cloud-router → bridge-sub → bench-sub\n```\n\n")
    f.write("## Results\n")
    if single_rows:
        f.write(table(single_rows, "Single-Router Topology"))
    if fed_rows:
        f.write(table(fed_rows, "Federated Topology (two hops)"))
    if single_rows and fed_rows:
        f.write("\n\n### Latency Overhead: Federated vs Single-Router\n\n")
        f.write("| Rate (Hz) | Single mean (ms) | Federated mean (ms) | Overhead factor |\n")
        f.write("|-----------|-----------------|---------------------|----------------|\n")
        single_map = {r['rate_hz']: r for r in single_rows}
        for r in fed_rows:
            s = single_map.get(r['rate_hz'])
            if s and s['mean_ms'] not in ('N/A', 'ERROR') and r['mean_ms'] not in ('N/A', 'ERROR'):
                try:
                    factor = float(r['mean_ms']) / float(s['mean_ms'])
                    f.write(f"| {r['rate_hz']:>9} | {s['mean_ms']:>15} | {r['mean_ms']:>19} | {factor:>14.2f}x |\n")
                except ZeroDivisionError:
                    f.write(f"| {r['rate_hz']:>9} | {s['mean_ms']:>15} | {r['mean_ms']:>19} | N/A |\n")
    f.write("\n")

print(f"Markdown report written to {md_path}")
PYEOF

  sep "Benchmark complete"
  echo "  CSV    : $CSV"
  echo "  Report : $MD_REPORT"
}

export ROOT
main "$@"
