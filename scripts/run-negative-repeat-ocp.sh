#!/usr/bin/env bash
# scripts/run-negative-repeat-ocp.sh
# Runs all OCP negative test scenarios REPEAT times and captures a TSV summary.
#
# Usage:
#   bash scripts/run-negative-repeat-ocp.sh [REPEAT]           (default: 10)
#   NAMESPACE=ros2-zenoh-federation bash scripts/run-negative-repeat-ocp.sh 10
#
# Output:
#   tests/neg-repeat-ocp-<timestamp>/
#     summary.tsv        — one row per scenario × run
#     N1_run1.log ...    — full output from each individual run

REPEAT="${1:-10}"
NAMESPACE="${NAMESPACE:-ros2-zenoh-federation}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TS=$(date +%Y%m%d_%H%M%S)
LOGDIR="$ROOT/tests/neg-repeat-ocp-$TS"
mkdir -p "$LOGDIR"
TSV="$LOGDIR/summary.tsv"

echo "================================================"
echo "  OCP Negative test repeat run"
echo "  Namespace : $NAMESPACE"
echo "  Scenarios : N1 N2 N3 N4 N5 N7 N8 N9 N10"
echo "  Repeat    : $REPEAT"
echo "  Logs      : $LOGDIR"
echo "  Started   : $(date -u)"
echo "================================================"

printf 'scenario\trun\tpass\tfail\tnotes\tduration_s\trecovery_s\testimated_gaps\n' > "$TSV"

for run in $(seq 1 "$REPEAT"); do
  echo ""
  echo "━━━ Run $run / $REPEAT  ($(date -u +%H:%M:%S)) ━━━"

  for scenario in N1 N2 N3 N4 N5 N7 N8 N9 N10; do
    logfile="$LOGDIR/${scenario}_run${run}.log"
    printf "  %-4s ... " "$scenario"

    t0=$(date +%s)
    NAMESPACE="$NAMESPACE" SCENARIO="$scenario" \
      bash "$SCRIPT_DIR/test-negative-ocp.sh" > "$logfile" 2>&1 || true
    t1=$(date +%s)
    duration=$(( t1 - t0 ))

    # Strip ANSI colour codes for parsing
    plain=$(perl -pe 's/\e\[[0-9;]*m//g' < "$logfile" 2>/dev/null || cat "$logfile")

    pass=$(echo "$plain"  | grep -c '^\s*PASS'  2>/dev/null || echo 0)
    fail=$(echo "$plain"  | grep -c '^\s*FAIL'  2>/dev/null || echo 0)
    notes=$(echo "$plain" | grep -c '^\s*NOTE'  2>/dev/null || echo 0)

    # Recovery time: capture first 'resumes in Xs' or 'self-healed in Xs' value
    recovery=$(echo "$plain" \
      | grep -Eo '(self-healed|resumes|recovery) in [0-9]+s' \
      | grep -Eo '[0-9]+' | head -1 || true)

    # N8 estimated gaps: 'estimated gaps ≈ ... = ~NNN messages'
    estimated_gaps=$(echo "$plain" \
      | grep -Eo '~[0-9]+ messages' \
      | grep -Eo '[0-9]+' | head -1 || true)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario" "$run" "$pass" "$fail" "$notes" \
      "$duration" "${recovery:-}" "${estimated_gaps:-}" >> "$TSV"

    status_sym="PASS"
    [ "$fail" -gt 0 ] && status_sym="FAIL"
    printf "%-4s  pass=%-2s fail=%-2s dur=%-3ss recovery=%-4s est_gaps=%s\n" \
      "$status_sym" "$pass" "$fail" "$duration" \
      "${recovery:-N/A}" "${estimated_gaps:-N/A}"
  done
done

echo ""
echo "================================================"
echo "  Completed : $(date -u)"
echo "  Results   : $TSV"
echo "================================================"
echo ""
cat "$TSV"
