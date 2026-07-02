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
|         1 |       25 |       25 |    0.0 |      1.05 |     1.05 |     1.08 |     1.08 |     1.08 |    0 |
|        10 |      250 |      250 |    0.0 |      0.92 |     0.92 |     1.01 |     1.08 |     1.09 |    0 |
|        50 |     1250 |     1250 |    0.0 |      0.75 |     0.71 |     0.87 |     1.01 |     9.04 |    0 |
|       100 |     2500 |     2500 |    0.0 |      0.60 |     0.58 |     0.66 |     0.77 |     6.57 |    0 |
|       200 |     5000 |     5000 |    0.0 |      0.41 |     0.40 |     0.50 |     0.57 |     6.54 |    0 |
### Federated Topology

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|         1 |       22 |       22 |    0.0 |      0.91 |     0.89 |     0.96 |     1.17 |     1.23 |    0 |
|        10 |      220 |      220 |    0.0 |      1.20 |     1.13 |     1.22 |     3.39 |     6.54 |    0 |
|        50 |     1100 |     1100 |    0.0 |      0.93 |     0.89 |     1.04 |     2.89 |     7.90 |    0 |
|       100 |     2200 |     2200 |    0.0 |      0.95 |     0.93 |     1.08 |     1.21 |     6.29 |    0 |
|       200 |     4400 |     4400 |    0.0 |      0.60 |     0.59 |     0.68 |     0.75 |    11.61 |    0 |

### Overhead: Federated vs Single-Router

| Rate (Hz) | Single mean | Fed mean | Mean ratio | Single p95 | Fed p95 | p95 ratio | Single p99 | Fed p99 | p99 ratio |
|-----------|------------|---------|------------|-----------|--------|----------|-----------|--------|----------|
|         1 |        1.05 ms |    0.91 ms |      0.87x |      1.08 ms |   0.96 ms |     0.89x |      1.08 ms |   1.17 ms |     1.08x |
|        10 |        0.92 ms |    1.20 ms |      1.30x |      1.01 ms |   1.22 ms |     1.21x |      1.08 ms |   3.39 ms |     3.14x |
|        50 |        0.75 ms |    0.93 ms |      1.24x |      0.87 ms |   1.04 ms |     1.20x |      1.01 ms |   2.89 ms |     2.86x |
|       100 |        0.60 ms |    0.95 ms |      1.58x |      0.66 ms |   1.08 ms |     1.64x |      0.77 ms |   1.21 ms |     1.57x |
|       200 |        0.41 ms |    0.60 ms |      1.46x |      0.50 ms |   0.68 ms |     1.36x |      0.57 ms |   0.75 ms |     1.32x |

