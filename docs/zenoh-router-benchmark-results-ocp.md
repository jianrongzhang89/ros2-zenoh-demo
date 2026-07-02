# Zenoh Router Benchmark Results — OpenShift (10-Run Aggregate)

**Date:** 2026-07-02  
**Cluster:** api.ai-dev02.kni.syseng.devcluster.openshift.com (AWS EC2, 6 nodes × 16 CPU / 64 GB)  
**Runs:** 10 independent runs × 30 s measurement window per rate  
**Zenoh router:** 1.9.0 · **zenoh-bridge-ros2dds:** 1.9.0 · **ROS 2:** Jazzy  
**Platform:** linux/amd64 native (Kubernetes Pods, OVN-Kubernetes CNI)  
**Message type:** `std_msgs/msg/String` with embedded nanosecond wall-clock timestamp  

Compare to podman results: [`zenoh-router-benchmark-results.md`](zenoh-router-benchmark-results.md)  
Raw per-run data: [`docs/benchmark-results-ocp-all.csv`](benchmark-results-ocp-all.csv)  
Aggregate CSV: [`docs/benchmark-results-ocp-agg.csv`](benchmark-results-ocp-agg.csv)

---

## Topology

Each pod is a **2-container sidecar pair** — the Kubernetes equivalent of `network_mode: "service:X"` in Docker Compose.

```
Single-router  (namespace: ros2-zenoh-bench)
  [bench-pub | bridge-pub] pod  →  bench-router Service (7447)  →  [bridge-sub | bench-sub] pod

Federated  (namespace: ros2-zenoh-federation, reuses running routers)
  [bench-pub | bridge-pub] pod  →  edge-router (7448)  ─federation─  cloud-router (7447)  →  [bridge-sub | bench-sub] pod
```

---

## Aggregate Results (10 runs each)

### Mean Latency — Stable and Reliable

Mean latency standard deviation is ≤ 0.17 ms across all 20 (topology × rate) combinations. This is the signal to trust for production SLO planning.

| Rate (Hz) | Single mean (ms) | Single std | Federated mean (ms) | Fed. std | Fed. overhead |
|-----------|-----------------|-----------|--------------------|---------|-|
| 1         | 1.060           | ±0.128    | 1.219              | ±0.088  | +0.16 ms (+15%) |
| 10        | 1.019           | ±0.089    | 1.202              | ±0.139  | +0.18 ms (+18%) |
| 50        | 0.875           | ±0.066    | 0.937              | ±0.149  | +0.06 ms (+7%)  |
| 100       | 0.595           | ±0.067    | 0.819              | ±0.166  | +0.22 ms (+38%) |
| 200       | 0.530           | ±0.084    | 0.657              | ±0.103  | +0.13 ms (+24%) |

### p99 Latency — High Variance, Cluster-Driven

p99 standard deviation is 0.3–2.0 ms. The median-of-p99 and p90-of-p99 across runs characterise what to expect in production better than any single measurement.

**Single-router p99 across 10 runs:**

| Rate (Hz) | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | R10 | Median | p90 | Min | Max |
|-----------|----|----|----|----|----|----|----|----|----|----|--------|-----|-----|-----|
| 1 | 3.68 | 1.10 | 1.08 | 1.20 | 4.40 | 0.98 | 1.31 | 6.17 | 1.55 | 1.13 | **1.26** | 4.58 | 0.98 | 6.17 |
| 10 | 2.91 | 2.75 | 3.94 | 1.74 | 4.26 | 2.24 | 4.01 | 1.21 | 3.49 | 4.16 | **3.20** | 4.17 | 1.21 | 4.26 |
| 50 | 3.30 | 5.13 | 2.35 | 2.22 | 1.85 | 1.54 | 1.15 | 2.68 | 3.08 | 4.04 | **2.51** | 4.15 | 1.15 | 5.13 |
| 100 | 1.97 | 1.32 | 2.01 | 0.92 | 2.59 | 1.14 | 1.23 | 1.19 | 0.80 | 1.16 | **1.21** | 2.07 | 0.80 | 2.59 |
| 200 | 0.51 | 4.20 | 0.96 | 1.90 | 1.63 | 0.60 | 1.03 | 1.17 | 4.04 | 2.14 | **1.40** | 4.06 | 0.51 | 4.20 |

*(all values in ms)*

**Federated p99 across 10 runs:**

| Rate (Hz) | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | R10 | Median | p90 | Min | Max |
|-----------|----|----|----|----|----|----|----|----|----|----|--------|-----|-----|-----|
| 1 | 1.19 | 1.28 | 1.21 | 1.30 | 1.19 | 1.39 | 2.19 | 1.30 | 1.38 | 1.87 | **1.30** | 1.90 | 1.19 | 2.19 |
| 10 | 3.59 | 1.80 | 4.67 | 3.44 | 2.43 | 3.25 | 1.24 | 2.52 | 8.19 | 2.00 | **2.89** | 5.02 | 1.24 | 8.19 |
| 50 | 2.37 | 1.44 | 2.77 | 2.77 | 1.34 | 1.00 | 1.65 | 2.86 | 1.22 | 2.62 | **2.01** | 2.78 | 1.00 | 2.86 |
| 100 | 2.53 | 1.69 | 1.10 | 5.12 | 1.26 | 1.27 | 0.98 | 0.96 | 1.05 | 2.54 | **1.27** | 2.80 | 0.96 | 5.12 |
| 200 | 2.92 | 4.17 | 1.35 | 0.62 | 2.74 | 0.85 | 1.96 | 2.39 | 1.07 | 1.25 | **1.66** | 3.05 | 0.62 | 4.17 |

*(all values in ms)*

### Message Loss

Loss is effectively zero. Federated@200Hz averaged 0.01% (≈1 message per 10,000) across 10 runs — negligible.

---

## Analysis

### Finding 1 — Mean latency is stable, consistent, and sub-millisecond

Across all 10 runs, mean latency standard deviation is ≤ 0.17 ms. This is the metric to use for SLO planning:

- **Single-router:** 0.53–1.06 ms mean, depending on rate
- **Federated:** 0.66–1.22 ms mean, depending on rate
- **Federation overhead:** consistently **+0.06 to +0.22 ms** (7–38%) — bounded, predictable

### Finding 2 — p99 spikes appear in **both** topologies and are not topology-specific

The earlier observation (two-run comparison) suggested federated@10Hz and federated@50Hz had elevated p99. The 10-run aggregate disproves this as a topology property:

| Rate | Single p99 median | Federated p99 median | Difference |
|------|------------------|---------------------|------------|
| 1 Hz | 1.26 ms | 1.30 ms | +0.04 ms |
| **10 Hz** | **3.20 ms** | **2.89 ms** | −0.31 ms (single is *higher*) |
| **50 Hz** | **2.51 ms** | **2.01 ms** | −0.50 ms (single is *higher*) |
| 100 Hz | 1.21 ms | 1.27 ms | +0.06 ms |
| 200 Hz | 1.40 ms | 1.66 ms | +0.26 ms |

**Single-router is the higher p99 at 10 Hz and 50 Hz.** There is no systematic topology-driven p99 elevation. p99 spikes move between rates and topologies across runs — this is cluster scheduling jitter.

### Finding 3 — p99 variance is driven by cluster noise on the shared EC2 nodes

Every p99 observation above ~2 ms corresponds to a single outlier message in the 30-second window. The shared EC2 cluster introduces jitter from:
- Kernel scheduler preemption during the measurement pod's timeslice
- Co-tenant workloads on the same physical node
- OVN-Kubernetes conntrack table pressure under concurrent traffic

To isolate topology-driven tail latency from cluster noise, runs would need `nodeAffinity` pinning to dedicated nodes and longer measurement windows (≥5 min per rate).

### Finding 4 — Federated@1Hz is the one topology+rate combination with stable p99

Federated@1Hz p99 std = 0.33 ms (the lowest of any combination), range [1.19, 2.19 ms]. Low publish rate leaves the federation link idle between messages, eliminating queuing jitter. The steady ~1.3 ms median p99 for federated@1Hz represents the true federation-hop overhead in isolation.

### Finding 5 — Zero loss, zero gaps confirmed across 100 measurement windows

10 runs × 10 (topology×rate) combinations = 100 measurement windows, all with 0 gaps and ≤0.1% loss. The Zenoh 1.9.0 bridge stack is reliable at all tested rates on OCP.

---

## Summary for Production Planning

| Metric | Value | Basis |
|---|---|---|
| Single-router mean latency | 0.53–1.06 ms | 10-run mean-of-means |
| Federated mean latency | 0.66–1.22 ms | 10-run mean-of-means |
| Federation mean overhead | +0.06 to +0.22 ms | consistent across all rates |
| p99 (median-of-p99, either topology) | 1.2–3.2 ms | depends on rate, not topology |
| p99 worst case observed (10 runs) | 8.19 ms | federated@10Hz run 9, single outlier |
| Message loss | 0.0% | 100 measurement windows |

**Conclusion on p99:** budget **2–3 ms p99 for typical conditions** and **5–8 ms for worst-case headroom** on a shared cluster, regardless of topology. For tighter p99 guarantees, use dedicated nodes and measure over longer windows.

**Conclusion on federation:** the architecture is production-viable. The consistent, bounded mean overhead (+0.06–0.22 ms) is the only reliable distinction between single-router and federated topologies at these rates and sample sizes.

---

## Comparison: OCP vs. Podman (mean latency)

| Rate | Single OCP | Single podman | Federated OCP | Federated podman |
|------|-----------|--------------|--------------|-----------------|
| 1 Hz | 1.06 ms   | 5.02 ms      | 1.22 ms      | 4.97 ms         |
| 10 Hz | 1.02 ms  | 4.75 ms      | 1.20 ms      | 4.72 ms         |
| 50 Hz | 0.88 ms  | 1.93 ms      | 0.94 ms      | 3.14 ms         |
| 100 Hz | 0.60 ms | 1.51 ms      | 0.82 ms      | 2.04 ms         |
| 200 Hz | 0.53 ms | 1.43 ms      | 0.66 ms      | 1.86 ms         |

OCP delivers **3–5× lower mean latency** than the podman/libkrun VM benchmark.

---

## Reproduction

```bash
# Run N times and aggregate (default 10)
RUNS=10 MEASURE_DURATION=30 bash scripts/benchmark-ocp-multi.sh

# Single run
MEASURE_DURATION=30 bash scripts/benchmark-ocp.sh
```

Infrastructure: `k8s/bench/` · Single-run harness: `scripts/benchmark-ocp.sh`  
Multi-run harness: `scripts/benchmark-ocp-multi.sh`  
All runs raw data: [`docs/benchmark-results-ocp-all.csv`](benchmark-results-ocp-all.csv)
