#!/usr/bin/env bash
# scripts/run-negative-repeat.sh
# Runs all negative test scenarios REPEAT times and captures a TSV summary.
#
# Usage:
#   bash scripts/run-negative-repeat.sh [REPEAT]      (default: 10)
#
# Output:
#   tests/neg-repeat-<timestamp>/
#     summary.tsv          — one row per scenario × run
#     N1_run1.log  ...     — full output from each individual run

REPEAT="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TS=$(date +%Y%m%d_%H%M%S)
LOGDIR="$ROOT/tests/neg-repeat-$TS"
mkdir -p "$LOGDIR"
TSV="$LOGDIR/summary.tsv"

echo "================================================"
echo "  Negative test repeat run"
echo "  Scenarios : N1 N2 N3 N4 N5 N7 N8 N9 N10"
echo "  Repeat    : $REPEAT"
echo "  Logs      : $LOGDIR"
echo "  Started   : $(date -u)"
echo "================================================"

printf 'scenario\trun\tpass\tfail\tnotes\tduration_s\trecovery_s\tgaps\n' > "$TSV"

for run in $(seq 1 "$REPEAT"); do
  echo ""
  echo "━━━ Run $run / $REPEAT  ($(date -u +%H:%M:%S)) ━━━"

  for scenario in N1 N2 N3 N4 N5 N7 N8 N9 N10; do
    logfile="$LOGDIR/${scenario}_run${run}.log"
    printf "  %-4s ... " "$scenario"

    t0=$(date +%s)
    SCENARIO="$scenario" bash "$SCRIPT_DIR/test-negative.sh" > "$logfile" 2>&1 || true
    t1=$(date +%s)
    duration=$(( t1 - t0 ))

    # Strip ANSI colour codes for parsing (perl is available on macOS)
    plain=$(perl -pe 's/\e\[[0-9;]*m//g' < "$logfile" 2>/dev/null || cat "$logfile")

    pass=$(echo "$plain" | grep -c '^\s*PASS'  2>/dev/null || echo 0)
    fail=$(echo "$plain" | grep -c '^\s*FAIL'  2>/dev/null || echo 0)
    notes=$(echo "$plain" | grep -c '^\s*NOTE' 2>/dev/null || echo 0)

    # Recovery time: first number before 's' on a 'self-healed in Xs' or 'resumes in Xs' line
    recovery=$(echo "$plain" \
      | grep -Eo '(self-healed|resumes|recovery) in [0-9]+s' \
      | grep -Eo '[0-9]+' | head -1 || true)

    # Gap count: 'gaps=NNN' line (N8 only)
    gaps=$(echo "$plain" \
      | grep -Eo 'gaps=[0-9]+' \
      | grep -Eo '[0-9]+' | head -1 || true)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario" "$run" "$pass" "$fail" "$notes" \
      "$duration" "${recovery:-}" "${gaps:-}" >> "$TSV"

    status_sym="PASS"
    [ "$fail" -gt 0 ] && status_sym="FAIL"
    printf "%-4s  pass=%-2s fail=%-2s dur=%-3ss recovery=%-4s gaps=%s\n" \
      "$status_sym" "$pass" "$fail" "$duration" \
      "${recovery:-N/A}" "${gaps:-N/A}"
  done
done

echo ""
echo "================================================"
echo "  Completed : $(date -u)"
echo "  Results   : $TSV"
echo "================================================"
echo ""
cat "$TSV"
