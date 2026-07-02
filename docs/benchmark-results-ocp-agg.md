# Zenoh Router OCP Benchmark — Aggregate Results (10 runs)

**Date:** 2026-07-02  
**Runs:** 10 × MEASURE_DURATION=30s  
**Cluster:** api.ai-dev02.kni.syseng.devcluster.openshift.com  
**Zenoh:** 1.9.0 · **Bridge:** 1.9.0 · **ROS 2:** Jazzy  

## Summary — Mean Latency and p99 Statistics Across All Runs

### All Topologies and Rates

| Rate (Hz) | Topology | Mean mean (ms) | Mean std | p99 median | p99 p90 | p99 min | p99 max |
|---|---|---|---|---|---|---|---|
|         1 | federated  |          1.219 |    0.088 |      1.300 |   1.902 |   1.190 |   2.190 |
|        10 | federated  |          1.202 |    0.139 |      2.885 |   5.022 |   1.240 |   8.190 |
|        50 | federated  |          0.937 |    0.149 |      2.010 |   2.779 |   1.000 |   2.860 |
|       100 | federated  |          0.819 |    0.166 |      1.265 |   2.798 |   0.960 |   5.120 |
|       200 | federated  |          0.657 |    0.103 |      1.655 |   3.045 |   0.620 |   4.170 |
|         1 | single     |          1.060 |    0.128 |      1.255 |   4.577 |   0.980 |   6.170 |
|        10 | single     |          1.019 |    0.089 |      3.200 |   4.170 |   1.210 |   4.260 |
|        50 | single     |          0.875 |    0.066 |      2.515 |   4.149 |   1.150 |   5.130 |
|       100 | single     |          0.595 |    0.067 |      1.210 |   2.068 |   0.800 |   2.590 |
|       200 | single     |          0.530 |    0.084 |      1.400 |   4.056 |   0.510 |   4.200 |

## Per-Run p99 Detail

### Single-Router — p99 per run

| Rate (Hz) | Run 1 p99 | Run 2 p99 | Run 3 p99 | Run 4 p99 | Run 5 p99 | Run 6 p99 | Run 7 p99 | Run 8 p99 | Run 9 p99 | Run 10 p99 | Mean p99 | Std p99 | p90 p99 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
|         1 Hz | 3.68 ms | 1.10 ms | 1.08 ms | 1.20 ms | 4.40 ms | 0.98 ms | 1.31 ms | 6.17 ms | 1.55 ms | 1.13 ms | 2.260 ms | 1.828 ms | 4.577 ms |
|        10 Hz | 2.91 ms | 2.75 ms | 3.94 ms | 1.74 ms | 4.26 ms | 2.24 ms | 4.01 ms | 1.21 ms | 3.49 ms | 4.16 ms | 3.071 ms | 1.078 ms | 4.170 ms |
|        50 Hz | 3.30 ms | 5.13 ms | 2.35 ms | 2.22 ms | 1.85 ms | 1.54 ms | 1.15 ms | 2.68 ms | 3.08 ms | 4.04 ms | 2.734 ms | 1.203 ms | 4.149 ms |
|       100 Hz | 1.97 ms | 1.32 ms | 2.01 ms | 0.92 ms | 2.59 ms | 1.14 ms | 1.23 ms | 1.19 ms | 0.80 ms | 1.16 ms | 1.433 ms | 0.567 ms | 2.068 ms |
|       200 Hz | 0.51 ms | 4.20 ms | 0.96 ms | 1.90 ms | 1.63 ms | 0.60 ms | 1.03 ms | 1.17 ms | 4.04 ms | 2.14 ms | 1.818 ms | 1.322 ms | 4.056 ms |

### Federated — p99 per run

| Rate (Hz) | Run 1 p99 | Run 2 p99 | Run 3 p99 | Run 4 p99 | Run 5 p99 | Run 6 p99 | Run 7 p99 | Run 8 p99 | Run 9 p99 | Run 10 p99 | Mean p99 | Std p99 | p90 p99 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
|         1 Hz | 1.19 ms | 1.28 ms | 1.21 ms | 1.30 ms | 1.19 ms | 1.39 ms | 2.19 ms | 1.30 ms | 1.38 ms | 1.87 ms | 1.430 ms | 0.333 ms | 1.902 ms |
|        10 Hz | 3.59 ms | 1.80 ms | 4.67 ms | 3.44 ms | 2.43 ms | 3.25 ms | 1.24 ms | 2.52 ms | 8.19 ms | 2.00 ms | 3.313 ms | 1.984 ms | 5.022 ms |
|        50 Hz | 2.37 ms | 1.44 ms | 2.77 ms | 2.77 ms | 1.34 ms | 1.00 ms | 1.65 ms | 2.86 ms | 1.22 ms | 2.62 ms | 2.004 ms | 0.740 ms | 2.779 ms |
|       100 Hz | 2.53 ms | 1.69 ms | 1.10 ms | 5.12 ms | 1.26 ms | 1.27 ms | 0.98 ms | 0.96 ms | 1.05 ms | 2.54 ms | 1.850 ms | 1.295 ms | 2.798 ms |
|       200 Hz | 2.92 ms | 4.17 ms | 1.35 ms | 0.62 ms | 2.74 ms | 0.85 ms | 1.96 ms | 2.39 ms | 1.07 ms | 1.25 ms | 1.932 ms | 1.120 ms | 3.045 ms |
