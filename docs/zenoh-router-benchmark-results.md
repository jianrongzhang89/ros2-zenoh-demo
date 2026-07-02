# Zenoh Router Benchmark Results: Single-Router vs. Federated Latency

**Date:** 2026-07-02  
**Platform:** linux/arm64 containerized (podman + libkrun, 6 GB VM, macOS Apple Silicon)  
**Zenoh router:** 1.9.0 · **zenoh-bridge-ros2dds:** 1.9.0 · **ROS 2:** Jazzy  
**Message type:** `std_msgs/msg/String` with embedded nanosecond wall-clock timestamp  
**Measurement:** publisher `time.time_ns()` → subscriber `time.time_ns()` (shared host clock, no sync needed)  
**Warmup:** 5 s (single), 8 s (federated) discarded before counting  
**Measurement window:** 25 s (single), 22 s (federated) per rate  

---

## Topology

```
Single-router
  bench-pub → (DDS/lo) → bridge-pub → Zenoh → zenoh-router → Zenoh → bridge-sub → (DDS/lo) → bench-sub

Federated (two router hops)
  bench-pub → (DDS/lo) → bridge-pub → Zenoh → edge-router ─(WAN)─ cloud-router → Zenoh → bridge-sub → (DDS/lo) → bench-sub
```

All containers run on the same host inside isolated Docker networks.

---

## Raw Results

### Single-Router Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|------|
| 1         | 25       | 25       | 0.0    | 5.02      | —        | 7.75     | 8.45     | 0    |
| 10        | 250      | 250      | 0.0    | 4.75      | —        | 7.45     | 12.77    | 0    |
| 50        | 1 250    | 1 250    | 0.0    | 1.93      | —        | 2.57     | 3.18     | 0    |
| 100       | 2 500    | 2 500    | 0.0    | 1.51      | —        | 1.93     | 2.60     | 0    |
| 200       | 4 989    | 5 000    | 0.2    | 1.43      | —        | 2.03     | 3.33     | 0    |

### Federated Topology (Two Hops: edge-router → cloud-router)

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|------|
| 1         | 22       | 22       | 0.0    | 5.25      | —        | 8.50     | 8.99     | 0    |
| 10        | 219      | 220      | 0.5    | 4.72      | —        | 8.57     | 13.11    | 0    |
| 50        | 1 099    | 1 100    | 0.1    | 3.14      | —        | 4.82     | 5.61     | 0    |
| 100       | 2 200    | 2 200    | 0.0    | 2.04      | —        | 3.95     | 4.75     | 0    |
| 200       | 4 393    | 4 400    | 0.2    | 1.86      | —        | 3.32     | 6.89     | 0    |

---

## Federation Overhead

| Rate (Hz) | Single mean | Fed. mean | Mean ratio | Single p95 | Fed. p95 | p95 ratio | Single p99 | Fed. p99 | p99 ratio |
|-----------|------------|-----------|------------|------------|----------|-----------|------------|----------|-----------|
| 1         | 5.02 ms    | 5.25 ms   | **1.05×**  | 7.75 ms    | 8.50 ms  | **1.10×** | 8.45 ms    | 8.99 ms  | **1.06×** |
| 10        | 4.75 ms    | 4.72 ms   | **1.00×**  | 7.45 ms    | 8.57 ms  | **1.15×** | 12.77 ms   | 13.11 ms | **1.03×** |
| 50        | 1.93 ms    | 3.14 ms   | **1.63×**  | 2.57 ms    | 4.82 ms  | **1.88×** | 3.18 ms    | 5.61 ms  | **1.76×** |
| 100       | 1.51 ms    | 2.04 ms   | **1.35×**  | 1.93 ms    | 3.95 ms  | **2.05×** | 2.60 ms    | 4.75 ms  | **1.83×** |
| 200       | 1.43 ms    | 1.86 ms   | **1.30×**  | 2.03 ms    | 3.32 ms  | **1.64×** | 3.33 ms    | 6.89 ms  | **2.07×** |

---

## Analysis

### Finding 1 — Latency drops sharply as message rate increases

Both topologies show a clear inverse relationship between publish rate and latency:

| Topology | 1 Hz mean | 200 Hz mean | Improvement |
|----------|-----------|-------------|-------------|
| Single   | 5.02 ms   | 1.43 ms     | 3.5×        |
| Federated | 5.25 ms  | 1.86 ms     | 2.8×        |

At low rates (1–10 Hz) each message must re-warm the DDS discovery state and Zenoh's internal routing pipeline. At higher rates (50–200 Hz) the bridge pipeline stays warm between messages, reducing per-message overhead. This is consistent with Zenoh's design for high-throughput scenarios and with published benchmarks (arXiv:2303.09419, arXiv:2603.21600).

**Implication:** ROS 2 topics that publish at 50 Hz or higher traverse the bridge stack far more efficiently than infrequent telemetry or status topics.

### Finding 2 — Federation overhead is rate-dependent

At **low rates (1–10 Hz)** the extra router hop is nearly invisible: mean latency is identical to within 0.5 ms. Both routers are idle between messages and the marginal cost of the extra hop is absorbed by the existing pipeline latency.

At **higher rates (50–200 Hz)** the federation overhead becomes significant:

- **Mean latency:** 1.3–1.6× higher with federation
- **p95 latency:** 1.6–2.1× higher with federation
- **p99 latency:** 1.8–2.1× higher with federation

The tail latency divergence is the key risk for real-time ROS 2 use cases. At 200 Hz, p99 with a single router is 3.33 ms but with federation it is 6.89 ms — more than double.

### Finding 3 — Message loss is negligible across all rates and topologies

Loss stays at 0.0–0.5% even at 200 Hz through the federation link. No sequence gaps were observed at any rate, meaning messages that do arrive are delivered in publisher order. The Zenoh hop-to-hop reliability layer handles transient queue pressure without reordering.

**Caveat:** these tests run in a steady state with no router restarts. Loss behaviour during a router pod restart or rolling update is not captured here — the research document (`zenoh-router-scaling-research.md`, Issue #1886) addresses that separately.

### Finding 4 — Federated p99 at 200 Hz warrants attention

The federated p99 at 200 Hz is 6.89 ms versus 3.33 ms for a single router. For ROS 2 control loops running at 100–200 Hz (e.g. `/cmd_vel`, joint controllers), a p99 above 5 ms may violate loop-closure timing assumptions. This should be validated against the specific controller's deadline before committing to a federated topology for those topics.

---

## Recommended Scaling Strategy

| Scenario | Recommendation |
|---|---|
| Topics ≤ 10 Hz (status, telemetry, logging) | Federated topology safe — overhead is < 10% of mean latency |
| Topics 50–200 Hz (sensors, odometry) | Test p99 against loop deadline; federation adds ~2× tail latency |
| Topics with hard real-time deadlines (controllers) | Use single-router or keep publisher/subscriber on the same router node |
| HA requirement across zones | Federation is the only supported model; use Advanced Pub/Sub for end-to-end reliability on critical topics |
| Kubernetes scaling | StatefulSet per router with stable DNS; no HPA behind shared VIP (see `zenoh-router-scaling-research.md`) |

---

## Environment Caveats

1. **Containerized overhead.** These measurements include libkrun VM, Docker networking, and DDS-to-Zenoh bridge translation layers. Native Linux bare-metal latency will be significantly lower (published data: 21 µs brokered vs. 10 µs P2P at 64-byte payload on native Linux — arXiv:2303.09419). The **ratios** (single vs. federated) are the meaningful output; the **absolute values** are not production targets.

2. **Same-host containers.** Publisher and subscriber share the host kernel clock — no NTP jitter — and communicate through loopback + virtual bridge interfaces. A real deployment crosses physical NICs and switches, adding RTT that dominates over the router-hop overhead measured here.

3. **Steady-state only.** No router restarts, rolling updates, or failover events were tested. The reconnection race condition (Issue #1886) makes those scenarios lossy in ways not captured in these numbers.

---

## Reproduction

```bash
# Ensure podman machine has at least 4 GB (6 GB recommended for federated)
podman machine set --memory 6144
podman machine start

# Full benchmark (all rates, both topologies, 30s windows)
MEASURE_DURATION=30 bash scripts/benchmark.sh

# Single topology only
TOPOLOGY=single RATES="1 10 50 100 200" bash scripts/benchmark.sh

# Dry run
DRY_RUN=1 bash scripts/benchmark.sh
```

Raw data: [`docs/benchmark-results.csv`](benchmark-results.csv)  
Research context: [`docs/zenoh-router-scaling-research.md`](zenoh-router-scaling-research.md)
