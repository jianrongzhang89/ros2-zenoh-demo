# Zenoh Router Latency Benchmark Results

**Date:** 2026-07-02  
**Platform:** linux/arm64 (podman, libkrun on macOS Apple Silicon)  
**Zenoh router:** 1.9.0  
**zenoh-bridge-ros2dds:** 1.9.0  
**Message type:** std_msgs/msg/String with embedded nanosecond timestamp  
**Latency measurement:** publisher wall-clock ns → subscriber wall-clock ns (shared host clock, no sync needed)  

## Topology

**Single-router:**
```
bench-pub → bridge-pub → zenoh-router → bridge-sub → bench-sub
```

**Federated:**
```
bench-pub → bridge-pub → edge-router ─(wan)─ cloud-router → bridge-sub → bench-sub
```

## Results

### Single-Router Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|         1 |       25 |       25 |    0.0 |      5.02 |     5.14 |     7.75 |     8.45 |     8.63 |    0 |
|        10 |      250 |      250 |    0.0 |      4.75 |     4.64 |     7.45 |    12.77 |    24.69 |    0 |
|        50 |     1250 |     1250 |    0.0 |      1.93 |     1.87 |     2.57 |     3.18 |     4.03 |    0 |
|       100 |     2500 |     2500 |    0.0 |      1.51 |     1.44 |     1.93 |     2.60 |    22.75 |    0 |
|       200 |     4989 |     5000 |    0.2 |      1.43 |     1.36 |     2.03 |     3.33 |    12.18 |    0 |
### Federated Topology (two hops)

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|         1 |       22 |       22 |    0.0 |      5.25 |     4.54 |     8.50 |     8.99 |     9.11 |    0 |
|        10 |      219 |      220 |    0.5 |      4.72 |     4.61 |     8.57 |    13.11 |    17.93 |    0 |
|        50 |     1099 |     1100 |    0.1 |      3.14 |     3.10 |     4.82 |     5.61 |     7.08 |    0 |
|       100 |     2200 |     2200 |    0.0 |      2.04 |     1.76 |     3.95 |     4.75 |     8.37 |    0 |
|       200 |     4393 |     4400 |    0.2 |      1.86 |     1.59 |     3.32 |     6.89 |    23.68 |    0 |

### Latency Overhead: Federated vs Single-Router

| Rate (Hz) | Single mean (ms) | Federated mean (ms) | Overhead factor |
|-----------|-----------------|---------------------|----------------|
|         1 |            5.02 |                5.25 |           1.05x |
|        10 |            4.75 |                4.72 |           0.99x |
|        50 |            1.93 |                3.14 |           1.63x |
|       100 |            1.51 |                2.04 |           1.35x |
|       200 |            1.43 |                1.86 |           1.30x |

