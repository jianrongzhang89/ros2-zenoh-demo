# Zenoh Router Latency Benchmark Results

**Date:** 2026-07-01  
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

### Federated Topology (two hops)

| Rate (Hz) | Received | Expected | Loss % | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Gaps |
|-----------|----------|----------|--------|-----------|----------|----------|----------|----------|------|
|       100 |      250 |     2000 |   87.5 |      4.63 |     4.65 |     7.73 |    10.74 |    17.90 |    0 |
