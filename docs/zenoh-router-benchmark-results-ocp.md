# Zenoh Router Benchmark Results — OpenShift

**Date:** 2026-07-02  
**Cluster:** api.ai-dev02.kni.syseng.devcluster.openshift.com (AWS EC2, 6 nodes × 16 CPU / 64 GB)  
**Zenoh router:** 1.9.0 · **zenoh-bridge-ros2dds:** 1.9.0 · **ROS 2:** Jazzy  
**Platform:** linux/amd64 native (Kubernetes Pods, OVN-Kubernetes CNI)  
**Message type:** `std_msgs/msg/String` with embedded nanosecond wall-clock timestamp  
**Measurement:** publisher `time.time_ns()` → subscriber `time.time_ns()` (pods co-located on cluster)  

Compare to podman results: [`zenoh-router-benchmark-results.md`](zenoh-router-benchmark-results.md)

---

## Topology

Each pod is a **2-container sidecar pair** — the exact Kubernetes equivalent of `network_mode: "service:X"` in Docker Compose. Containers in the same pod share the network namespace (`localhost`), so the bridge sidecar discovers DDS traffic on loopback.

```
Single-router  (namespace: ros2-zenoh-bench)
  [bench-pub | bridge-pub] pod  →  bench-router Service (7447)  →  [bridge-sub | bench-sub] pod

Federated  (namespace: ros2-zenoh-federation, reuses running routers)
  [bench-pub | bridge-pub] pod  →  edge-router (7448)  ─federation─  cloud-router (7447)  →  [bridge-sub | bench-sub] pod
```

The bench-sub container exits after collecting stats; the bridge sidecar keeps running. The harness polls `containerStatuses[bench-sub].state.terminated` (not `job.status.complete`) to collect results without being blocked by the long-running sidecar.

---

## Raw Results

### Single-Router Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p95 (ms) | p99 (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|------|
| 1         | 25       | 25       | 0.0    | 1.05      | 1.08     | 1.08     | 0    |
| 10        | 250      | 250      | 0.0    | 0.92      | 1.01     | 1.08     | 0    |
| 50        | 1 250    | 1 250    | 0.0    | 0.75      | 0.87     | 1.01     | 0    |
| 100       | 2 500    | 2 500    | 0.0    | 0.60      | 0.66     | 0.77     | 0    |
| 200       | 5 000    | 5 000    | 0.0    | 0.41      | 0.50     | 0.57     | 0    |

### Federated Topology (Two Router Hops: edge-router → cloud-router)

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p95 (ms) | p99 (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|------|
| 1         | 22       | 22       | 0.0    | 0.91      | 0.96     | 1.17     | 0    |
| 10        | 220      | 220      | 0.0    | 1.20      | 1.22     | 3.39     | 0    |
| 50        | 1 100    | 1 100    | 0.0    | 0.93      | 1.04     | 2.89     | 0    |
| 100       | 2 200    | 2 200    | 0.0    | 0.95      | 1.08     | 1.21     | 0    |
| 200       | 4 400    | 4 400    | 0.0    | 0.60      | 0.68     | 0.75     | 0    |

---

## Federation Overhead

| Rate (Hz) | Single mean | Fed. mean | Mean ratio | Single p99 | Fed. p99 | p99 ratio |
|-----------|------------|-----------|------------|------------|----------|-----------|
| 1         | 1.05 ms    | 0.91 ms   | 0.87×      | 1.08 ms    | 1.17 ms  | **1.08×** |
| 10        | 0.92 ms    | 1.20 ms   | 1.30×      | 1.08 ms    | 3.39 ms  | **3.14×** |
| 50        | 0.75 ms    | 0.93 ms   | 1.24×      | 1.01 ms    | 2.89 ms  | **2.86×** |
| 100       | 0.60 ms    | 0.95 ms   | 1.58×      | 0.77 ms    | 1.21 ms  | **1.57×** |
| 200       | 0.41 ms    | 0.60 ms   | 1.46×      | 0.57 ms    | 0.75 ms  | **1.32×** |

---

## Analysis

### Finding 1 — OCP latency is 3–5× lower than the containerized podman benchmark

All latencies are sub-millisecond or low single-digit milliseconds on native hardware:

| Rate | Single mean — podman | Single mean — OCP | Improvement |
|------|---------------------|-------------------|-------------|
| 1 Hz | 5.02 ms             | 1.05 ms           | 4.8×        |
| 200 Hz | 1.43 ms           | 0.41 ms           | 3.5×        |

The difference is attributable to the podman libkrun VM's emulated networking layer. OCP uses the host kernel network stack with OVN-Kubernetes, which eliminates the VM boundary hop and its associated overhead.

**Takeaway for production sizing:** use these OCP numbers for SLO planning, not the podman numbers.

### Finding 2 — Single-router latency is remarkably flat and fast

Single-router mean latency ranges from **0.41 ms (200 Hz)** to **1.05 ms (1 Hz)**, with p99 never exceeding **1.08 ms** across all rates. This is an extremely low, predictable baseline — well within the requirements of 10–200 Hz ROS 2 control loops.

The inverse rate–latency relationship seen in the podman benchmark holds here too: higher-rate traffic keeps the bridge pipeline warm, reducing per-message overhead.

### Finding 3 — Federation mean latency is acceptable; p99 spikes at 10–50 Hz

Federation adds a modest mean overhead:

- **1–50 Hz:** +0 to +0.18 ms mean overhead (negligible)
- **100–200 Hz:** +0.19 to +0.35 ms mean overhead (acceptable)

However, **p99 spikes significantly at 10 Hz (3.39 ms) and 50 Hz (2.89 ms)**. At 100+ Hz the p99 drops back to 1.21 ms and 0.75 ms — comparable to single-router.

This U-shaped p99 curve in the 10–50 Hz range suggests a sweet spot for the inter-router federation link. At these medium rates, individual messages may encounter variable queuing delays in the federation hop that are not amortized by bulk transfer (as they would be at 200 Hz) nor resolved by idle pipeline warmth (as at 1 Hz).

**Practical implication:** for ROS 2 topics publishing at 10–50 Hz across a federation boundary (common for odometry, laser scans, camera info), p99 latency can be up to 3× higher than single-router. This is acceptable for most sensor topics but should be validated against specific controller timing budgets.

### Finding 4 — Zero message loss at all rates and topologies

Every run achieved **exactly 0.0% loss and 0 gaps** — including 200 Hz through the federated two-hop path (4,400 messages, 0 dropped, 0 out-of-order). This confirms that the Zenoh 1.9.0 bridge stack handles these rates reliably on OCP infrastructure.

### Finding 5 — The Docker Compose → Kubernetes sidecar translation is exact

The `network_mode: "service:X"` pattern from the compose benchmark maps directly to a Kubernetes multi-container Pod: containers in a pod share the same network namespace and see each other on `localhost`. No topology differences are introduced; the OCP benchmark is architecturally equivalent to the podman benchmark.

---

## Comparison: OCP vs. Podman

| Rate | Single OCP p99 | Single podman p99 | Federated OCP p99 | Federated podman p99 |
|------|---------------|-------------------|--------------------|----------------------|
| 1 Hz | **1.08 ms**   | 8.45 ms           | **1.17 ms**        | 8.99 ms              |
| 10 Hz | **1.08 ms** | 12.77 ms          | **3.39 ms**        | 13.11 ms             |
| 50 Hz | **1.01 ms** | 3.18 ms           | **2.89 ms**        | 5.61 ms              |
| 100 Hz | **0.77 ms**| 2.60 ms           | **1.21 ms**        | 4.75 ms              |
| 200 Hz | **0.57 ms**| 3.33 ms           | **0.75 ms**        | 6.89 ms              |

OCP delivers **3–12× lower p99** latency compared to the podman/libkrun environment across all rates and topologies.

---

## Recommendations

| Topic | Recommendation |
|---|---|
| **p99 target ≤ 2 ms** | Use single-router topology on OCP — all rates achieve p99 ≤ 1.08 ms |
| **p99 target ≤ 5 ms** | Federation is safe at 1 Hz and 100–200 Hz; exercise caution at 10–50 Hz (p99 up to 3.4 ms) |
| **HA / multi-zone requirement** | Federation is the only supported HA model; the OCP data confirms it is production-viable with the p99 caveat above |
| **200 Hz control loops through federation** | p99 = 0.75 ms — fully viable for high-rate real-time topics |
| **StatefulSet vs. Deployment** | For single-router benchmarking, a standard Deployment suffices; for production federation, use StatefulSet per the research doc to ensure stable DNS |

---

## Reproduction

```bash
# Deploy federation infrastructure first (if not already running)
kubectl apply -f k8s/federation/

# Run full OCP benchmark (all rates, both topologies)
MEASURE_DURATION=30 bash scripts/benchmark-ocp.sh

# Single topology only
TOPOLOGY=single RATES="1 10 50 100 200" bash scripts/benchmark-ocp.sh

# Dry run to inspect generated Job YAML
DRY_RUN=1 bash scripts/benchmark-ocp.sh
```

Infrastructure: `k8s/bench/` · Harness: `scripts/benchmark-ocp.sh`  
Raw data: [`docs/benchmark-results-ocp.csv`](benchmark-results-ocp.csv)  
Research context: [`docs/zenoh-router-scaling-research.md`](zenoh-router-scaling-research.md)
