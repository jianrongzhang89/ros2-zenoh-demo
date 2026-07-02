#!/usr/bin/env bash
# scripts/benchmark-ocp-multi.sh
# Runs benchmark-ocp.sh N times and produces aggregate statistics.
#
# Usage:
#   bash scripts/benchmark-ocp-multi.sh              # 10 runs (default)
#   RUNS=5 bash scripts/benchmark-ocp-multi.sh
#   MEASURE_DURATION=30 RUNS=10 bash scripts/benchmark-ocp-multi.sh
#
# Output:
#   docs/benchmark-results-ocp-all.csv      — raw rows from every run (with run_id)
#   docs/benchmark-results-ocp-agg.csv      — per-(topology,rate) aggregate stats
#   docs/benchmark-results-ocp-agg.md       — markdown summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNS="${RUNS:-10}"
MEASURE_DURATION="${MEASURE_DURATION:-30}"

ALL_CSV="$ROOT/docs/benchmark-results-ocp-all.csv"
AGG_CSV="$ROOT/docs/benchmark-results-ocp-agg.csv"
AGG_MD="$ROOT/docs/benchmark-results-ocp-agg.md"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RESET='\033[0m'
sep() { printf "\n${CYAN}── %s${RESET}\n" "$*" >&2; }
ok()  { printf "  ${GREEN} OK ${RESET}  %s\n" "$*" >&2; }

mkdir -p "$ROOT/docs"

# Write aggregate CSV header (run_id prepended)
echo "run_id,topology,rate_hz,n_received,n_expected,loss_pct,mean_ms,p50_ms,p95_ms,p99_ms,max_ms,min_ms,gaps" \
  > "$ALL_CSV"

for run in $(seq 1 "$RUNS"); do
  sep "Run ${run} / ${RUNS}"
  MEASURE_DURATION="$MEASURE_DURATION" bash "$SCRIPT_DIR/benchmark-ocp.sh" 2>&1

  # Append this run's data rows (skip the header line) with run_id prepended
  tail -n +2 "$ROOT/docs/benchmark-results-ocp.csv" \
    | sed "s/^/${run},/" >> "$ALL_CSV"

  ok "Run ${run} appended to $ALL_CSV"
done

sep "Generating aggregate statistics"

python3 - <<'PYEOF'
import csv, os, math, statistics, datetime

root       = os.environ.get('ROOT', '.')
all_csv    = os.path.join(root, 'docs', 'benchmark-results-ocp-all.csv')
agg_csv    = os.path.join(root, 'docs', 'benchmark-results-ocp-agg.csv')
agg_md     = os.path.join(root, 'docs', 'benchmark-results-ocp-agg.md')

rows = []
with open(all_csv) as f:
    for r in csv.DictReader(f):
        if r['mean_ms'] in ('N/A', 'ERROR'):
            continue
        rows.append(r)

# Group by (topology, rate_hz)
from collections import defaultdict
groups = defaultdict(list)
for r in rows:
    groups[(r['topology'], r['rate_hz'])].append(r)

def pct(data, p):
    if not data: return 0.0
    s = sorted(data)
    k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k)+1, len(s)-1)
    return s[lo] + (s[hi]-s[lo])*(k-lo)

def fmt(v, d=3):
    return f"{v:.{d}f}"

agg_fields = [
    'topology','rate_hz','n_runs',
    'mean_mean','mean_std','mean_min','mean_max',
    'p95_mean','p95_std',
    'p99_mean','p99_std','p99_median','p99_p90','p99_min','p99_max',
    'loss_mean'
]

with open(agg_csv, 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=agg_fields)
    w.writeheader()
    for (topo, rate), rlist in sorted(groups.items(), key=lambda x: (x[0][0], int(x[0][1]))):
        means  = [float(r['mean_ms']) for r in rlist]
        p95s   = [float(r['p95_ms'])  for r in rlist]
        p99s   = [float(r['p99_ms'])  for r in rlist]
        losses = [float(r['loss_pct']) for r in rlist]
        std = lambda xs: statistics.stdev(xs) if len(xs) > 1 else 0.0
        w.writerow({
            'topology': topo, 'rate_hz': rate, 'n_runs': len(rlist),
            'mean_mean': fmt(statistics.mean(means)),
            'mean_std':  fmt(std(means)),
            'mean_min':  fmt(min(means)),
            'mean_max':  fmt(max(means)),
            'p95_mean':  fmt(statistics.mean(p95s)),
            'p95_std':   fmt(std(p95s)),
            'p99_mean':  fmt(statistics.mean(p99s)),
            'p99_std':   fmt(std(p99s)),
            'p99_median':fmt(pct(p99s, 50)),
            'p99_p90':   fmt(pct(p99s, 90)),
            'p99_min':   fmt(min(p99s)),
            'p99_max':   fmt(max(p99s)),
            'loss_mean': fmt(statistics.mean(losses)),
        })

# Build per-run p99 table for the markdown (transposed: rows=rates, cols=runs)
run_ids = sorted(set(r['run_id'] for r in rows), key=int)

def md_table(topo, title):
    rates = sorted(set(r['rate_hz'] for r in rows if r['topology']==topo), key=int)
    header = '| Rate (Hz) |' + ''.join(f' Run {rid} p99 |' for rid in run_ids) + ' Mean p99 | Std p99 | p90 p99 |'
    sep_   = '|---|' + '---|'*len(run_ids) + '---|---|---|'
    lines  = [f'\n### {title}\n', header, sep_]
    with open(agg_csv) as f:
        agg = {(r['topology'],r['rate_hz']): r for r in csv.DictReader(f)}
    for rate in rates:
        cell = []
        for rid in run_ids:
            val = next((r['p99_ms'] for r in rows
                        if r['topology']==topo and r['rate_hz']==rate and r['run_id']==rid), 'N/A')
            cell.append(f' {float(val):.2f} ms |' if val != 'N/A' else ' N/A |')
        a = agg.get((topo, rate), {})
        lines.append(f"| {rate:>9} Hz |{''.join(cell)}"
                     f" {a.get('p99_mean','?')} ms | {a.get('p99_std','?')} ms | {a.get('p99_p90','?')} ms |")
    return '\n'.join(lines)

def mean_table(title):
    header = '| Rate (Hz) | Topology | Mean mean (ms) | Mean std | p99 median | p99 p90 | p99 min | p99 max |'
    sep_   = '|---|---|---|---|---|---|---|---|'
    lines  = [f'\n### {title}\n', header, sep_]
    with open(agg_csv) as f:
        for r in csv.DictReader(f):
            lines.append(
                f"| {r['rate_hz']:>9} | {r['topology']:<10} "
                f"| {r['mean_mean']:>14} | {r['mean_std']:>8} "
                f"| {r['p99_median']:>10} | {r['p99_p90']:>7} "
                f"| {r['p99_min']:>7} | {r['p99_max']:>7} |"
            )
    return '\n'.join(lines)

n_runs = len(run_ids)
date_str = datetime.date.today().isoformat()

with open(agg_md, 'w') as f:
    f.write(f"# Zenoh Router OCP Benchmark — Aggregate Results ({n_runs} runs)\n\n")
    f.write(f"**Date:** {date_str}  \n")
    f.write(f"**Runs:** {n_runs} × MEASURE_DURATION={os.environ.get('MEASURE_DURATION','30')}s  \n")
    f.write(f"**Cluster:** api.ai-dev02.kni.syseng.devcluster.openshift.com  \n")
    f.write(f"**Zenoh:** 1.9.0 · **Bridge:** 1.9.0 · **ROS 2:** Jazzy  \n\n")
    f.write("## Summary — Mean Latency and p99 Statistics Across All Runs\n")
    f.write(mean_table("All Topologies and Rates"))
    f.write("\n\n## Per-Run p99 Detail\n")
    f.write(md_table('single',    'Single-Router — p99 per run'))
    f.write("\n")
    f.write(md_table('federated', 'Federated — p99 per run'))
    f.write("\n")

print(f"Aggregate CSV : {agg_csv}")
print(f"Aggregate MD  : {agg_md}")
PYEOF

sep "Multi-run benchmark complete"
echo "  All runs CSV : $ALL_CSV" >&2
echo "  Aggregate CSV: $AGG_CSV" >&2
echo "  Aggregate MD : $AGG_MD" >&2
