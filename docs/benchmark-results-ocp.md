# Zenoh Router Benchmark Results — OpenShift

**Date:** 2026-07-02  
**Cluster:** https://api.ai-dev02.kni.syseng.devcluster.openshift.com:6443  
**Zenoh router:** 1.9.0 · **zenoh-bridge-ros2dds:** 1.9.0 · **ROS 2:** Jazzy  

## Topology

**Single-router** (`ros2-zenoh-bench`):
```
bench-pub + bridge-pub → bench-router Service → bridge-sub + bench-sub
```

**Federated** (`ros2-zenoh-federation`, reuses running routers):
```
bench-pub + bridge-pub → edge-router ─(federation link)─ cloud-router → bridge-sub + bench-sub
```

## Results

### Single-Router Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|         1 |       25 |       25 |    0.0 |      1.01 |     1.02 |     1.12 |     1.13 |     1.13 |    0 |
|        10 |      250 |      250 |    0.0 |      0.95 |     0.89 |     0.97 |     4.16 |     5.56 |    0 |
|        50 |     1250 |     1250 |    0.0 |      0.90 |     0.82 |     0.95 |     4.04 |     8.39 |    0 |
|       100 |     2500 |     2500 |    0.0 |      0.52 |     0.49 |     0.63 |     1.16 |     7.14 |    0 |
|       200 |     4999 |     5000 |    0.0 |      0.54 |     0.50 |     0.58 |     2.14 |     9.61 |    0 |
### Federated Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|         1 |       22 |       22 |    0.0 |      1.38 |     1.35 |     1.45 |     1.87 |     1.99 |    0 |
|        10 |      220 |      220 |    0.0 |      1.34 |     1.32 |     1.45 |     2.00 |     2.81 |    0 |
|        50 |     1100 |     1100 |    0.0 |      0.90 |     0.86 |     0.98 |     2.62 |     5.63 |    0 |
|       100 |     2200 |     2200 |    0.0 |      0.97 |     0.92 |     1.10 |     2.54 |     9.43 |    0 |
|       200 |     4399 |     4400 |    0.0 |      0.69 |     0.67 |     0.79 |     1.25 |     7.54 |    0 |

### Overhead: Federated vs Single-Router

| Rate (Hz) | Single mean | Fed mean | Mean ratio | Single p95 | Fed p95 | p95 ratio | Single p99 | Fed p99 | p99 ratio |
|-----------|------------|---------|------------|-----------|--------|----------|-----------|--------|----------|
|         1 |        1.01 ms |    1.38 ms |      1.37x |      1.12 ms |   1.45 ms |     1.29x |      1.13 ms |   1.87 ms |     1.65x |
|        10 |        0.95 ms |    1.34 ms |      1.41x |      0.97 ms |   1.45 ms |     1.49x |      4.16 ms |   2.00 ms |     0.48x |
|        50 |        0.90 ms |    0.90 ms |      1.00x |      0.95 ms |   0.98 ms |     1.03x |      4.04 ms |   2.62 ms |     0.65x |
|       100 |        0.52 ms |    0.97 ms |      1.87x |      0.63 ms |   1.10 ms |     1.75x |      1.16 ms |   2.54 ms |     2.19x |
|       200 |        0.54 ms |    0.69 ms |      1.28x |      0.58 ms |   0.79 ms |     1.36x |      2.14 ms |   1.25 ms |     0.58x |

