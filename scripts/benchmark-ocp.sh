#!/usr/bin/env bash
# scripts/benchmark-ocp.sh
# End-to-end latency benchmarks on OpenShift/Kubernetes.
#
# Topology A — single-router (namespace: ros2-zenoh-bench):
#   bench-pub pod → bridge-pub sidecar → bench-router Service → bridge-sub sidecar → bench-sub pod
#
# Topology B — federated (namespace: ros2-zenoh-federation, reuses running routers):
#   bench-pub pod → bridge-pub sidecar → edge-router → cloud-router → bridge-sub sidecar → bench-sub pod
#
# Usage:
#   bash scripts/benchmark-ocp.sh                    # all topologies, all rates
#   TOPOLOGY=single bash scripts/benchmark-ocp.sh    # single topology only
#   RATES="10 50" bash scripts/benchmark-ocp.sh      # override rates
#   DRY_RUN=1 bash scripts/benchmark-ocp.sh          # print manifests, no apply
#
# Prerequisites:
#   oc / kubectl configured and logged in
#   Images accessible from cluster:
#     quay.io/jianrzha/ros2-zenoh-demo:0.0.7
#     quay.io/ecosystem-appeng/zenoh-router:1.9.0
#     quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:1.9.0
#
# Output:
#   docs/benchmark-results-ocp.csv
#   docs/benchmark-results-ocp.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Tunables ─────────────────────────────────────────────────────────────────
RATES="${RATES:-1 10 50 100 200}"
MEASURE_DURATION="${MEASURE_DURATION:-30}"
WARMUP_SINGLE="${WARMUP_SINGLE:-5}"
WARMUP_FED="${WARMUP_FED:-8}"

# OCP infra is already up, so shorter sleeps than the compose benchmark.
PUB_SLEEP_SINGLE="${PUB_SLEEP_SINGLE:-5}"
SUB_SLEEP_SINGLE="${SUB_SLEEP_SINGLE:-15}"
PUB_SLEEP_FED="${PUB_SLEEP_FED:-5}"
SUB_SLEEP_FED="${SUB_SLEEP_FED:-20}"

NS_SINGLE="ros2-zenoh-bench"
NS_FED="ros2-zenoh-federation"
MANIFESTS="$ROOT/k8s/bench"

# Job activeDeadlineSeconds: sub_sleep + warmup + measure + 30s buffer
DEADLINE_SINGLE=$(( SUB_SLEEP_SINGLE + WARMUP_SINGLE + MEASURE_DURATION + 30 ))
DEADLINE_FED=$(( SUB_SLEEP_FED + WARMUP_FED + MEASURE_DURATION + 30 ))

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"
JOB_WAIT_TIMEOUT="${JOB_WAIT_TIMEOUT:-180s}"

DRY_RUN="${DRY_RUN:-0}"
KUBECTL="${KUBECTL:-oc}"

CSV="$ROOT/docs/benchmark-results-ocp.csv"
MD="$ROOT/docs/benchmark-results-ocp.md"

DEMO_IMAGE="quay.io/jianrzha/ros2-zenoh-demo:0.0.7"
ROUTER_IMAGE="quay.io/ecosystem-appeng/zenoh-router:1.9.0"
BRIDGE_IMAGE="quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:1.9.0"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
info() { printf "  ${CYAN}INFO${RESET}  %s\n" "$*" >&2; }
ok()   { printf "  ${GREEN} OK ${RESET}  %s\n" "$*" >&2; }
warn() { printf "  ${YELLOW}WARN${RESET}  %s\n" "$*" >&2; }
err()  { printf "  ${RED}ERR ${RESET}  %s\n" "$*" >&2; }
sep()  { printf "\n${CYAN}── %s${RESET}\n" "$*" >&2; }

kapply() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $KUBECTL apply" >&2
    cat >&2
  else
    $KUBECTL apply -f -
  fi
}

# ── Prerequisite check ────────────────────────────────────────────────────────
check_prereqs() {
  command -v "$KUBECTL" &>/dev/null || { err "$KUBECTL not found"; exit 1; }
  $KUBECTL whoami &>/dev/null       || { err "Not logged in to a cluster"; exit 1; }
  command -v python3 &>/dev/null    || { err "python3 not found (needed to parse stats)"; exit 1; }
}

# ── Single-router infrastructure ──────────────────────────────────────────────
apply_single_infra() {
  info "Applying single-router infrastructure in $NS_SINGLE"
  $KUBECTL apply -f "$MANIFESTS/namespace.yaml"
  $KUBECTL apply -f "$MANIFESTS/configmap-bench.yaml"
  $KUBECTL apply -f "$MANIFESTS/deployment-bench-router.yaml"
  $KUBECTL apply -f "$MANIFESTS/service-bench-router.yaml"

  info "Syncing benchmark scripts ConfigMap"
  $KUBECTL create configmap bench-scripts \
    --from-file=bench_run_pub.sh="$ROOT/tests/bench_run_pub.sh" \
    --from-file=bench_run_sub.sh="$ROOT/tests/bench_run_sub.sh" \
    --from-file=bench_pub.py="$ROOT/tests/bench_pub.py" \
    --from-file=bench_sub.py="$ROOT/tests/bench_sub.py" \
    -n "$NS_SINGLE" --dry-run=client -o yaml | $KUBECTL apply -f -

  info "Waiting for bench-router rollout"
  $KUBECTL rollout status deployment/bench-router -n "$NS_SINGLE" --timeout="$ROLLOUT_TIMEOUT"
}

# ── Federated infrastructure: verify running routers ─────────────────────────
check_fed_infra() {
  info "Verifying federated routers in $NS_FED"
  local edge cloud
  edge=$($KUBECTL get deploy edge-router -n "$NS_FED" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  cloud=$($KUBECTL get deploy cloud-router -n "$NS_FED" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [ "${edge:-0}" -lt 1 ] || [ "${cloud:-0}" -lt 1 ]; then
    err "edge-router or cloud-router not ready in $NS_FED — deploy federation first:"
    err "  kubectl apply -f k8s/federation/"
    exit 1
  fi
  ok "edge-router=$edge cloud-router=$cloud ready"

  info "Syncing benchmark scripts ConfigMap into $NS_FED"
  $KUBECTL create configmap bench-scripts \
    --from-file=bench_run_pub.sh="$ROOT/tests/bench_run_pub.sh" \
    --from-file=bench_run_sub.sh="$ROOT/tests/bench_run_sub.sh" \
    --from-file=bench_pub.py="$ROOT/tests/bench_pub.py" \
    --from-file=bench_sub.py="$ROOT/tests/bench_sub.py" \
    -n "$NS_FED" --dry-run=client -o yaml | $KUBECTL apply -f -

  info "Syncing bench-configs ConfigMap into $NS_FED"
  # Recreate with the correct namespace — the static YAML has NS_SINGLE hardcoded.
  $KUBECTL create configmap bench-configs \
    --from-literal=bridge-edge.json5='{"mode":"client","connect":{"endpoints":["tcp/edge-router:7448"]},"scouting":{"multicast":{"enabled":false}}}' \
    --from-literal=bridge-cloud.json5='{"mode":"client","connect":{"endpoints":["tcp/cloud-router:7447"]},"scouting":{"multicast":{"enabled":false}}}' \
    -n "$NS_FED" --dry-run=client -o yaml | $KUBECTL apply -f -
}

# ── Job generation ────────────────────────────────────────────────────────────
# Generates a Job YAML for bench-pub or bench-sub.
# Args: role (pub|sub) namespace rate bridge_cfg_key pub_sleep sub_sleep warmup deadline
job_yaml() {
  local role="$1" ns="$2" rate="$3" bridge_key="$4"
  local pub_sleep="$5" sub_sleep="$6" warmup="$7" deadline="$8"
  local pub_duration=$(( sub_sleep + warmup + MEASURE_DURATION + 15 ))
  local name="bench-${role}-${rate}hz"

  if [ "$role" = "pub" ]; then
    local script="bench_run_pub.sh"
    local sleep_var="$pub_sleep"
    local extra_env="
            - name: RATE_HZ
              value: \"${rate}\"
            - name: PUB_SLEEP
              value: \"${sleep_var}\"
            - name: PUB_DURATION
              value: \"${pub_duration}\""
  else
    local script="bench_run_sub.sh"
    local sleep_var="$sub_sleep"
    local extra_env="
            - name: SUB_SLEEP
              value: \"${sleep_var}\"
            - name: MEASURE_DURATION
              value: \"${MEASURE_DURATION}\"
            - name: WARMUP_SECS
              value: \"${warmup}\""
  fi

  local deadline_line=""
  [ "$deadline" -gt 0 ] && deadline_line="  activeDeadlineSeconds: ${deadline}"

  cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    bench-role: ${role}
    bench-rate: "${rate}hz"
spec:
  backoffLimit: 0
${deadline_line}
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
      containers:
        - name: bench-${role}
          image: ${DEMO_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["bash", "/tests/${script}"]
          env:
            - name: ROS_AUTOMATIC_DISCOVERY_RANGE
              value: LOCALHOST
            - name: ROS_HOME
              value: /tmp${extra_env}
          volumeMounts:
            - name: bench-scripts
              mountPath: /tests
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi

        - name: zenoh-bridge
          image: ${BRIDGE_IMAGE}
          imagePullPolicy: IfNotPresent
          args: ["-c", "/etc/zenoh/bridge.json5"]
          env:
            - name: ROS_AUTOMATIC_DISCOVERY_RANGE
              value: LOCALHOST
          volumeMounts:
            - name: bench-configs
              mountPath: /etc/zenoh/bridge.json5
              subPath: ${bridge_key}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi

      volumes:
        - name: bench-scripts
          configMap:
            name: bench-scripts
            defaultMode: 0755
        - name: bench-configs
          configMap:
            name: bench-configs
YAML
}

# ── Wait for bench-sub CONTAINER to terminate (not the whole Job) ─────────────
# The bridge sidecar keeps running after bench-sub exits, so the Job never
# reaches Complete. We poll the container state directly instead.
# Returns the pod name on success.
wait_bench_sub_container() {
  local job="$1" ns="$2"
  local timeout_s="${3//s/}"   # strip trailing 's' if present (e.g. "180s" → 180)
  local deadline=$(( $(date +%s) + timeout_s ))
  local pod=""

  info "Waiting for bench-sub container in job/$job to terminate (${timeout_s}s)"

  # Wait for the pod to be scheduled
  while [ -z "$pod" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    pod=$($KUBECTL get pods -n "$ns" -l "job-name=$job" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -z "$pod" ] && sleep 2
  done

  if [ -z "$pod" ]; then
    err "Pod for job/$job never appeared within ${timeout_s}s"
    return 1
  fi

  # Poll until the bench-sub container reaches Terminated state
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local term
    term=$($KUBECTL get pod "$pod" -n "$ns" \
      -o jsonpath='{.status.containerStatuses[?(@.name=="bench-sub")].state.terminated}' \
      2>/dev/null || true)
    if [ -n "$term" ]; then
      echo "$pod"
      return 0
    fi
    sleep 3
  done

  err "bench-sub container in pod/$pod did not terminate within ${timeout_s}s"
  return 1
}

# ── Collect JSON stats from bench-sub container log ───────────────────────────
collect_stats() {
  local pod="$1" ns="$2"
  local raw
  raw=$($KUBECTL logs "$pod" -c bench-sub -n "$ns" 2>/dev/null \
        | grep '^{' | tail -1)
  echo "$raw"
}

# ── One benchmark run ─────────────────────────────────────────────────────────
run_one() {
  local topology="$1" rate="$2"
  local ns pub_bridge sub_bridge pub_sleep sub_sleep warmup deadline

  if [ "$topology" = "single" ]; then
    ns="$NS_SINGLE"; pub_bridge="bridge-single.json5"; sub_bridge="bridge-single.json5"
    pub_sleep=$PUB_SLEEP_SINGLE; sub_sleep=$SUB_SLEEP_SINGLE
    warmup=$WARMUP_SINGLE; deadline=$DEADLINE_SINGLE
  else
    ns="$NS_FED"; pub_bridge="bridge-edge.json5"; sub_bridge="bridge-cloud.json5"
    pub_sleep=$PUB_SLEEP_FED; sub_sleep=$SUB_SLEEP_FED
    warmup=$WARMUP_FED; deadline=$DEADLINE_FED
  fi

  local meas_window=$(( MEASURE_DURATION - warmup ))
  local expected=$(( rate * meas_window ))

  info "Starting: topology=$topology rate=${rate}Hz expected=${expected} msgs"

  # Clean up any leftover jobs from a previous run
  $KUBECTL delete job "bench-pub-${rate}hz" "bench-sub-${rate}hz" \
    -n "$ns" --ignore-not-found >/dev/null 2>&1 || true

  if [ "$DRY_RUN" = "1" ]; then
    job_yaml pub "$ns" "$rate" "$pub_bridge" "$pub_sleep" "$sub_sleep" "$warmup" "$deadline" >&2
    job_yaml sub "$ns" "$rate" "$sub_bridge" "$pub_sleep" "$sub_sleep" "$warmup" 0 >&2
    echo "${topology},${rate},DRY_RUN,${expected},N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
    return 0
  fi

  # Deploy both Jobs simultaneously.
  # bench-pub gets activeDeadlineSeconds to auto-terminate after its run.
  # bench-sub has NO deadline — we kill it explicitly after collecting logs.
  job_yaml pub "$ns" "$rate" "$pub_bridge" "$pub_sleep" "$sub_sleep" "$warmup" "$deadline" \
    | $KUBECTL apply -f - >/dev/null
  job_yaml sub "$ns" "$rate" "$sub_bridge" "$pub_sleep" "$sub_sleep" "$warmup" 0 \
    | $KUBECTL apply -f - >/dev/null

  # Wait for bench-sub CONTAINER to terminate (not the whole Job — bridge keeps running).
  local sub_pod
  if ! sub_pod=$(wait_bench_sub_container "bench-sub-${rate}hz" "$ns" "$JOB_WAIT_TIMEOUT"); then
    $KUBECTL delete job "bench-pub-${rate}hz" "bench-sub-${rate}hz" \
      -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
    echo "${topology},${rate},ERROR,${expected},N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
    return 1
  fi

  local raw_stats
  raw_stats=$(collect_stats "$sub_pod" "$ns")

  if [ -z "$raw_stats" ]; then
    err "No JSON stats from bench-sub for ${topology}@${rate}Hz"
    $KUBECTL delete job "bench-pub-${rate}hz" "bench-sub-${rate}hz" \
      -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
    echo "${topology},${rate},ERROR,${expected},N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
    return 1
  fi

  local n mean p50 p95 p99 max_ms min_ms gaps
  n=$(     echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['n'])")
  mean=$(  echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['mean_ms']:.2f}\")")
  p50=$(   echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['p50_ms']:.2f}\")")
  p95=$(   echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['p95_ms']:.2f}\")")
  p99=$(   echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['p99_ms']:.2f}\")")
  max_ms=$(echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['max_ms']:.2f}\")")
  min_ms=$(echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['min_ms']:.2f}\")")
  gaps=$(  echo "$raw_stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['gaps'])")

  local loss_pct="0.0"
  if [ "$expected" -gt 0 ]; then
    loss_pct=$(python3 -c "print(f\"{max(0, ($expected - $n) / $expected * 100):.1f}\")")
  fi

  ok "${topology}@${rate}Hz  n=${n}/${expected}  mean=${mean}ms  p95=${p95}ms  p99=${p99}ms  loss=${loss_pct}%  gaps=${gaps}"

  # Clean up Jobs; TTL will auto-clean too but be explicit
  $KUBECTL delete job "bench-pub-${rate}hz" "bench-sub-${rate}hz" \
    -n "$ns" --ignore-not-found >/dev/null 2>&1 || true

  echo "${topology},${rate},${n},${expected},${loss_pct},${mean},${p50},${p95},${p99},${max_ms},${min_ms},${gaps}"
}

# ── Markdown report ────────────────────────────────────────────────────────────
generate_report() {
  python3 - <<'PYEOF'
import csv, os, datetime

csv_path = os.path.join(os.environ['ROOT'], 'docs', 'benchmark-results-ocp.csv')
md_path  = os.path.join(os.environ['ROOT'], 'docs', 'benchmark-results-ocp.md')

rows = []
try:
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            rows.append(row)
except FileNotFoundError:
    print("No CSV data yet — skipping report generation")
    exit(0)

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

date_str = datetime.date.today().isoformat()
single_rows = [r for r in rows if r['topology'] == 'single']
fed_rows    = [r for r in rows if r['topology'] == 'federated']

with open(md_path, 'w') as f:
    f.write(f"# Zenoh Router Benchmark Results — OpenShift\n\n")
    f.write(f"**Date:** {date_str}  \n")
    f.write(f"**Cluster:** {os.environ.get('CLUSTER_SERVER', 'see oc whoami --show-server')}  \n")
    f.write(f"**Zenoh router:** 1.9.0 · **zenoh-bridge-ros2dds:** 1.9.0 · **ROS 2:** Jazzy  \n\n")
    f.write("## Topology\n\n")
    f.write("**Single-router** (`ros2-zenoh-bench`):\n```\nbench-pub + bridge-pub → bench-router Service → bridge-sub + bench-sub\n```\n\n")
    f.write("**Federated** (`ros2-zenoh-federation`, reuses running routers):\n```\nbench-pub + bridge-pub → edge-router ─(federation link)─ cloud-router → bridge-sub + bench-sub\n```\n\n")
    f.write("## Results\n")
    if single_rows:
        f.write(table(single_rows, "Single-Router Topology"))
    if fed_rows:
        f.write(table(fed_rows, "Federated Topology"))
    if single_rows and fed_rows:
        f.write("\n\n### Overhead: Federated vs Single-Router\n\n")
        f.write("| Rate (Hz) | Single mean | Fed mean | Mean ratio | Single p95 | Fed p95 | p95 ratio | Single p99 | Fed p99 | p99 ratio |\n")
        f.write("|-----------|------------|---------|------------|-----------|--------|----------|-----------|--------|----------|\n")
        sm = {r['rate_hz']: r for r in single_rows}
        for r in fed_rows:
            s = sm.get(r['rate_hz'])
            if s and 'ERROR' not in (s['mean_ms'], r['mean_ms'], 'N/A'):
                try:
                    mr = float(r['mean_ms']) / float(s['mean_ms'])
                    pr95 = float(r['p95_ms']) / float(s['p95_ms'])
                    pr99 = float(r['p99_ms']) / float(s['p99_ms'])
                    f.write(f"| {r['rate_hz']:>9} | {s['mean_ms']:>11} ms | {r['mean_ms']:>7} ms | {mr:>9.2f}x | {s['p95_ms']:>9} ms | {r['p95_ms']:>6} ms | {pr95:>8.2f}x | {s['p99_ms']:>9} ms | {r['p99_ms']:>6} ms | {pr99:>8.2f}x |\n")
                except (ValueError, ZeroDivisionError):
                    pass
    f.write("\n")

print(f"OCP report written to {md_path}")
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local target="${TOPOLOGY:-all}"

  sep "Zenoh Router Latency Benchmark — OpenShift"
  info "Cluster:  $($KUBECTL whoami --show-server 2>/dev/null || echo unknown)"
  info "Rates:    ${RATES}"
  info "Topology: ${target}"
  info "Measure:  ${MEASURE_DURATION}s window"
  echo "" >&2

  check_prereqs
  mkdir -p "$ROOT/docs"
  echo "topology,rate_hz,n_received,n_expected,loss_pct,mean_ms,p50_ms,p95_ms,p99_ms,max_ms,min_ms,gaps" > "$CSV"

  declare -a TOPOLOGIES=()
  case "$target" in
    all)       TOPOLOGIES=(single federated) ;;
    single)    TOPOLOGIES=(single) ;;
    fed*)      TOPOLOGIES=(federated) ;;
    *) err "Unknown TOPOLOGY '$target'"; exit 1 ;;
  esac

  for topo in "${TOPOLOGIES[@]}"; do
    sep "Topology: ${topo}"
    if [ "$topo" = "single" ]; then
      [ "$DRY_RUN" = "1" ] || apply_single_infra
    else
      [ "$DRY_RUN" = "1" ] || check_fed_infra
    fi

    for rate in $RATES; do
      local result
      result=$(run_one "$topo" "$rate") || true
      echo "$result" >> "$CSV"
    done
  done

  export ROOT CLUSTER_SERVER
  CLUSTER_SERVER=$($KUBECTL whoami --show-server 2>/dev/null || echo "")
  generate_report

  sep "Benchmark complete"
  info "CSV    : $CSV"
  info "Report : $MD"
}

main "$@"
