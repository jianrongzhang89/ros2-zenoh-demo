#!/usr/bin/env bash
# scripts/measure-sidecar-resources.sh
#
# Measures CPU and memory of the zenoh-bridge-ros2dds sidecar container under
# idle (connected, no DDS traffic) and active (4 topics, 10 Hz) conditions.
#
# Prerequisites:
#   - podman (>= 4.0) with a running podman machine, OR docker
#   - podman-compose or docker compose
#   - Images pulled: quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:1.9.0
#                    quay.io/ecosystem-appeng/zenoh-router:1.9.0
#                    quay.io/jianrzha/ros2-zenoh-demo:0.0.7 (arm64)
#
# Usage:
#   cd /path/to/ros2-zenoh
#   bash scripts/measure-sidecar-resources.sh [--samples N] [--output FILE]
#
# Output: tab-separated table of phase, timestamp, CPU%, MemMB written to stdout
#         (and optionally to FILE).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ──────────────────────────────────────────────────────────────
BRIDGE_TAG="${ECLIPSE_TAG:-1.9.0}"
ROUTER_TAG="${ECLIPSE_TAG:-1.9.0}"
DEMO_TAG="${DEMO_VERSION:-0.0.7}"
QUAY_ORG="${QUAY_ORG:-ecosystem-appeng}"
DEMO_ORG="${DEMO_ORG:-jianrzha}"

SAMPLES="${1:-8}"
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --samples) SAMPLES="$2"; shift 2 ;;
    --output)  OUTPUT_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

COMPOSE_FILE="$(mktemp /tmp/bridge-measure-XXXX.yml)"
PROJECT="bridgemeasure"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
COMPOSE_CMD="${COMPOSE_CMD:-podman-compose}"

cleanup() {
  echo "[cleanup] Stopping containers..."
  $COMPOSE_CMD -p "$PROJECT" -f "$COMPOSE_FILE" down 2>/dev/null || true
  rm -f "$COMPOSE_FILE"
}
trap cleanup EXIT

# ── Generate temporary compose file ───────────────────────────────────────────
cat > "$COMPOSE_FILE" << COMPOSE
services:
  zenoh-router:
    image: quay.io/${QUAY_ORG}/zenoh-router:${ROUTER_TAG}
    networks:
      - measure-net

  ros2-talker:
    image: quay.io/${DEMO_ORG}/ros2-zenoh-demo:${DEMO_TAG}
    platform: linux/arm64
    environment:
      ROS_AUTOMATIC_DISCOVERY_RANGE: LOCALHOST
      ROS_HOME: /tmp
    command: >
      bash -c "
        set +u && source /opt/ros/jazzy/setup.bash && set -u &&
        sleep 20 &&
        exec bash /tests/multi-pub.sh
      "
    volumes:
      - ${REPO_ROOT}/tests:/tests:ro
    depends_on:
      - zenoh-router
    networks:
      - measure-net

  zenoh-bridge-talker:
    image: quay.io/${QUAY_ORG}/zenoh-bridge-ros2dds:${BRIDGE_TAG}
    network_mode: "service:ros2-talker"
    environment:
      ROS_AUTOMATIC_DISCOVERY_RANGE: LOCALHOST
    command: ["client", "--connect", "tcp/zenoh-router:7447", "--no-multicast-scouting"]
    depends_on:
      - ros2-talker

  ros2-listener:
    image: quay.io/${DEMO_ORG}/ros2-zenoh-demo:${DEMO_TAG}
    platform: linux/arm64
    environment:
      ROS_AUTOMATIC_DISCOVERY_RANGE: LOCALHOST
      ROS_HOME: /tmp
    command: >
      bash -c "
        set +u && source /opt/ros/jazzy/setup.bash && set -u &&
        sleep 25 &&
        exec ros2 run demo_nodes_cpp listener
      "
    depends_on:
      - zenoh-router
    networks:
      - measure-net

  zenoh-bridge-listener:
    image: quay.io/${QUAY_ORG}/zenoh-bridge-ros2dds:${BRIDGE_TAG}
    network_mode: "service:ros2-listener"
    environment:
      ROS_AUTOMATIC_DISCOVERY_RANGE: LOCALHOST
    command: ["client", "--connect", "tcp/zenoh-router:7447", "--no-multicast-scouting"]
    depends_on:
      - ros2-listener

networks:
  measure-net:
    driver: bridge
COMPOSE

# ── Image sizes ────────────────────────────────────────────────────────────────
echo "================================================================"
echo "zenoh-bridge-ros2dds sidecar resource measurement"
echo "Image: quay.io/${QUAY_ORG}/zenoh-bridge-ros2dds:${BRIDGE_TAG}"
echo "================================================================"
echo ""
echo "── Image Sizes ──────────────────────────────────────────────────"
$CONTAINER_RUNTIME image inspect \
    "quay.io/${QUAY_ORG}/zenoh-bridge-ros2dds:${BRIDGE_TAG}" \
    --format 'bridge   uncompressed={{.Size}} bytes' 2>/dev/null | \
  awk '{printf "%-8s %.1f MB (uncompressed on-disk)\n", "bridge", $NF/1024/1024}' || true
$CONTAINER_RUNTIME image inspect \
    "quay.io/${QUAY_ORG}/zenoh-router:${ROUTER_TAG}" \
    --format 'router   uncompressed={{.Size}} bytes' 2>/dev/null | \
  awk '{printf "%-8s %.1f MB (uncompressed on-disk)\n", "router", $NF/1024/1024}' || true
echo ""

# ── Collect stats helper ───────────────────────────────────────────────────────
collect_stats() {
  local phase="$1"
  local container="$2"
  local n="$3"
  local interval="${4:-3}"
  local cpu_sum=0 mem_sum=0 count=0

  for ((i=1; i<=n; i++)); do
    line=$($CONTAINER_RUNTIME stats --no-stream \
      --format "{{.CPUPerc}}\t{{.MemUsage}}" "$container" 2>/dev/null || echo "0%	0B / 0B")
    cpu=$(echo "$line" | awk '{gsub(/%/,""); print $1}')
    mem=$(echo "$line" | awk '{gsub(/[KMGT]?B/,""); split($1,a,"/"); print a[1]}')
    # Convert memory to MB
    mem_unit=$(echo "$line" | awk '{print $2}')
    case "$mem_unit" in
      kB|KB) mem_mb=$(echo "$mem / 1024" | bc -l 2>/dev/null || echo "0") ;;
      GB)    mem_mb=$(echo "$mem * 1024" | bc -l 2>/dev/null || echo "0") ;;
      *)     mem_mb="$mem" ;;  # assume MB
    esac

    # Re-parse using awk for portability
    raw=$($CONTAINER_RUNTIME stats --no-stream \
      --format "{{.CPUPerc}} {{.MemUsage}}" "$container" 2>/dev/null || echo "0% 0B / 0B")
    cpu=$(echo "$raw" | awk '{gsub(/%/,"",$1); print $1}')
    mem_raw=$(echo "$raw" | awk '{print $2}')
    mem_mb=$(echo "$mem_raw" | awk '
      {
        v=$1; u=$2
        if (u=="kB" || u=="KB") { printf "%.2f", v/1024 }
        else if (u=="GB")       { printf "%.2f", v*1024 }
        else if (u=="MB")       { printf "%.2f", v }
        else                    { printf "%.2f", v }
      }
    ')

    # Use podman-native format for reliability
    line2=$($CONTAINER_RUNTIME stats --no-stream \
      --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" "$container" 2>/dev/null || true)
    if [[ -n "$line2" ]]; then
      ts=$(date -u +%H:%M:%S)
      echo "$phase	$ts	$line2"
    fi

    cpu_sum=$(echo "$cpu_sum + ${cpu:-0}" | bc -l 2>/dev/null || echo "$cpu_sum")
    count=$((count + 1))
    [[ $i -lt $n ]] && sleep "$interval"
  done
}

# Simpler approach: collect raw podman stats lines
sample_stats() {
  local container="$1"
  $CONTAINER_RUNTIME stats --no-stream \
    --format "{{.CPUPerc}} {{.MemUsage}}" "$container" 2>/dev/null || echo "err"
}

# ── Start environment ──────────────────────────────────────────────────────────
echo "── Starting containers ──────────────────────────────────────────"
$COMPOSE_CMD -p "$PROJECT" -f "$COMPOSE_FILE" up -d 2>&1 | grep -E 'Creating|Starting|Up|Error' || true
echo ""

# Wait for bridges to connect to router
echo "Waiting 8s for bridges to connect to router..."
sleep 8

# ── Phase 1: Idle (connected, no DDS traffic) ─────────────────────────────────
echo "── Phase 1: IDLE (bridge connected, no DDS traffic) ────────────"
printf "%-15s %-12s %-12s\n" "Container" "CPU%" "MemMB"
printf "%-15s %-12s %-12s\n" "---------" "----" "-----"

declare -A idle_cpu idle_mem

for cname in "${PROJECT}_zenoh-bridge-talker_1" "${PROJECT}_zenoh-bridge-listener_1" "${PROJECT}_zenoh-router_1"; do
  cpu_acc=0; mem_acc=0; cnt=0
  for ((i=1; i<=$SAMPLES; i++)); do
    raw=$($CONTAINER_RUNTIME stats --no-stream \
      --format "{{.CPUPerc}} {{.MemUsage}}" "$cname" 2>/dev/null || echo "0% 0B / 0B")
    cpu=$(echo "$raw" | sed 's/%//' | awk '{print $1}')
    mem_str=$(echo "$raw" | awk '{print $2}')
    mem_mb=$(echo "$mem_str" | awk '{
      n=split($0,a,/[A-Za-z]/); v=a[1]
      if ($0 ~ /kB/) v=v/1024
      else if ($0 ~ /GB/) v=v*1024
      printf "%.1f", v
    }')
    cpu_acc=$(echo "$cpu_acc + $cpu" | bc -l 2>/dev/null || echo "$cpu_acc")
    mem_acc=$(echo "$mem_acc + $mem_mb" | bc -l 2>/dev/null || echo "$mem_acc")
    cnt=$((cnt+1))
    [[ $i -lt $SAMPLES ]] && sleep 2
  done
  avg_cpu=$(echo "scale=2; $cpu_acc / $cnt" | bc -l 2>/dev/null || echo "?")
  avg_mem=$(echo "scale=1; $mem_acc / $cnt" | bc -l 2>/dev/null || echo "?")
  label="${cname##*_}"
  label="${label%_1}"
  idle_cpu[$cname]="$avg_cpu"
  idle_mem[$cname]="$avg_mem"
  printf "%-35s avg_cpu=%6s%%  avg_mem=%6sMB\n" "$cname" "$avg_cpu" "$avg_mem"
done
echo ""

# ── Wait for DDS traffic ───────────────────────────────────────────────────────
echo "Waiting 15s for DDS publishers to start (multi-pub.sh sleeps 20s)..."
sleep 15
echo ""

# Verify DDS publishing started
talker_log=$($CONTAINER_RUNTIME logs "${PROJECT}_ros2-talker_1" 2>&1 | tail -5 || true)
if echo "$talker_log" | grep -q "publishing"; then
  echo "DDS publishing confirmed:"
  echo "$talker_log" | grep "publishing" | tail -3
else
  echo "Note: DDS publishing not yet detected in logs (may need more time)."
  sleep 8
fi
echo ""

# ── Phase 2: Active (DDS traffic flowing) ─────────────────────────────────────
echo "── Phase 2: ACTIVE (4 topics @ 10 Hz via DDS) ──────────────────"
printf "%-35s %-12s %-12s\n" "Container" "CPU%" "MemMB"
printf "%-35s %-12s %-12s\n" "---------" "----" "-----"

for cname in "${PROJECT}_zenoh-bridge-talker_1" "${PROJECT}_zenoh-bridge-listener_1" "${PROJECT}_zenoh-router_1"; do
  cpu_acc=0; mem_acc=0; cnt=0
  for ((i=1; i<=$SAMPLES; i++)); do
    raw=$($CONTAINER_RUNTIME stats --no-stream \
      --format "{{.CPUPerc}} {{.MemUsage}}" "$cname" 2>/dev/null || echo "0% 0B / 0B")
    cpu=$(echo "$raw" | sed 's/%//' | awk '{print $1}')
    mem_str=$(echo "$raw" | awk '{print $2}')
    mem_mb=$(echo "$mem_str" | awk '{
      n=split($0,a,/[A-Za-z]/); v=a[1]
      if ($0 ~ /kB/) v=v/1024
      else if ($0 ~ /GB/) v=v*1024
      printf "%.1f", v
    }')
    cpu_acc=$(echo "$cpu_acc + $cpu" | bc -l 2>/dev/null || echo "$cpu_acc")
    mem_acc=$(echo "$mem_acc + $mem_mb" | bc -l 2>/dev/null || echo "$mem_acc")
    cnt=$((cnt+1))
    [[ $i -lt $SAMPLES ]] && sleep 2
  done
  avg_cpu=$(echo "scale=2; $cpu_acc / $cnt" | bc -l 2>/dev/null || echo "?")
  avg_mem=$(echo "scale=1; $mem_acc / $cnt" | bc -l 2>/dev/null || echo "?")
  printf "%-35s avg_cpu=%6s%%  avg_mem=%6sMB\n" "$cname" "$avg_cpu" "$avg_mem"
done

echo ""
echo "================================================================"
echo "NOTE: CPU% is fraction of all VM CPUs combined."
echo "      Multiply by VM_CPU_COUNT * 1000 to get milliCPU."
echo "      Example: 0.25% × 6 CPUs = 15 milliCPU"
echo "================================================================"
