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
|         1 |       25 |       25 |    0.0 |      0.94 |     0.93 |     1.07 |     1.07 |     1.07 |    0 |
|        10 |      250 |      250 |    0.0 |      1.04 |     1.00 |     1.07 |     2.06 |     5.76 |    0 |
|        50 |     1250 |     1250 |    0.0 |      0.61 |     0.59 |     0.80 |     0.90 |     3.21 |    0 |
|       100 |     2500 |     2500 |    0.0 |      0.59 |     0.51 |     0.89 |     2.43 |    11.81 |    0 |
|       200 |     4999 |     5000 |    0.0 |      0.51 |     0.49 |     0.58 |     0.64 |     8.41 |    0 |
### Federated Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|         1 |       22 |       22 |    0.0 |      1.24 |     1.24 |     1.32 |     1.33 |     1.33 |    0 |
|        10 |      220 |      220 |    0.0 |      1.16 |     1.12 |     1.20 |     1.50 |     5.57 |    0 |
|        50 |     1100 |     1100 |    0.0 |      0.80 |     0.78 |     0.95 |     1.05 |     6.85 |    0 |
|       100 |     2200 |     2200 |    0.0 |      0.72 |     0.71 |     0.84 |     0.97 |     3.66 |    0 |
|       200 |     4400 |     4400 |    0.0 |      0.55 |     0.50 |     0.73 |     0.84 |    12.72 |    0 |

### Overhead: Federated vs Single-Router

| Rate (Hz) | Single mean | Fed mean | Mean ratio | Single p95 | Fed p95 | p95 ratio | Single p99 | Fed p99 | p99 ratio |
|-----------|------------|---------|------------|-----------|--------|----------|-----------|--------|----------|
|         1 |        0.94 ms |    1.24 ms |      1.32x |      1.07 ms |   1.32 ms |     1.23x |      1.07 ms |   1.33 ms |     1.24x |
|        10 |        1.04 ms |    1.16 ms |      1.12x |      1.07 ms |   1.20 ms |     1.12x |      2.06 ms |   1.50 ms |     0.73x |
|        50 |        0.61 ms |    0.80 ms |      1.31x |      0.80 ms |   0.95 ms |     1.19x |      0.90 ms |   1.05 ms |     1.17x |
|       100 |        0.59 ms |    0.72 ms |      1.22x |      0.89 ms |   0.84 ms |     0.94x |      2.43 ms |   0.97 ms |     0.40x |
|       200 |        0.51 ms |    0.55 ms |      1.08x |      0.58 ms |   0.73 ms |     1.26x |      0.64 ms |   0.84 ms |     1.31x |

