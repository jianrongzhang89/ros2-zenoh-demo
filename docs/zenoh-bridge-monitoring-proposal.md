# ROS2 + Zenoh DDS Bridge: Monitoring Proposal

> Research basis: 102 agents, 19 sources, 25 adversarially-verified claims (17 confirmed, 8 killed).
> Sources include official Zenoh docs, zenoh-plugin-ros2dds README, rmw_zenoh README, Datadog integration docs, OpenShift monitoring docs, Vulcanexus Fast DDS tutorial, and peer-reviewed arXiv benchmarks.

## Key Architectural Constraint

**rmw_zenoh and zenoh-bridge-ros2dds are mutually exclusive** — they use incompatible Zenoh key expression schemes and cannot coexist in the same system. The monitoring architecture must match which integration is deployed. This document focuses on **zenoh-bridge-ros2dds**.

---

## Layer 1 — Bridge Discovery & Route State (zenoh-bridge-ros2dds Admin Space)

The bridge exposes its internal state via Zenoh's admin space. Enable with `--rest-http-port 8000`:

| Admin Key | What It Shows |
|---|---|
| `@/local/ros2/node/**` | Discovered ROS2 nodes |
| `@/local/ros2/dds/**` | DDS Readers/Writers (connection state) |
| `@/local/ros2/route/**` | Active bridge routes (ROS ↔ Zenoh) |

```bash
# Query all active bridge routes
curl http://<bridge-pod-IP>:8000/@/local/ros2/route/**

# Query discovered nodes
curl http://<bridge-pod-IP>:8000/@/local/ros2/node/**
```

**Caveat:** The bridge admin space reflects *discovery and routing state only* — it does not expose latency, throughput, or per-topic queue depth natively. Route disappearance can signal a disconnection event.

---

## Layer 2 — Zenoh Router Transport Metrics (Prometheus / OpenMetrics)

Zenoh routers expose an OpenMetrics-compatible endpoint **only if built with the `stats` Cargo feature**:

```
Admin key: @/{zid}/{whatami}/metrics
HTTP:      http://<router>:8000/@/local/metrics   (via REST plugin)
```

**Confirmed metrics:**

| Metric | Description |
|---|---|
| `zenoh.router.rx_n_msgs` | Received message count |
| `zenoh.router.tx_n_msgs` | Transmitted message count |
| `zenoh.router.rx_n_dropped` | **Dropped messages** (key health signal) |
| `zenoh.router.tx_n_dropped` | Dropped on transmit |
| `zenoh.router.rx_z_bytes` | Bytes received |
| `zenoh.router.tx_z_bytes` | Bytes transmitted |
| `zenoh.router.sessions` | Active session count (reconnect detection) |

**Critical prerequisite:** Verify `stats` feature is compiled in. Binary packages from repos may omit it. Check: `curl http://<router>:8000/@/local/metrics` — if only build-info is returned, the feature is absent and a custom build is required.

**Version note:** Admin space key format changed between Zenoh versions — `v0.6.x` used `@/router/<id>`, current `1.x` uses `@/<id>/router` and `@/{zid}/{whatami}/metrics`. Verify against the installed version.

---

## Layer 3 — Fast DDS Statistics (DDS-Side Latency & Throughput)

Since zenoh-bridge-ros2dds bridges DDS-to-Zenoh, Fast DDS statistics expose latency and throughput at the DDS boundary. Fast DDS >= v2.9.0 (Humble+) includes this by default:

```bash
export FASTDDS_STATISTICS="HISTORY_LATENCY_TOPIC;PUBLICATION_THROUGHPUT_TOPIC"
# Then launch ROS2 nodes — statistics topics become live
```

Vulcanexus provides a Prometheus exporter for these topics. This is the primary path for **per-topic latency and throughput** that the Zenoh admin space doesn't expose.

> Note: `PHYSICAL_DATA_TOPIC` reports host/process metadata, not performance metrics. This mechanism applies only to zenoh-bridge-ros2dds (which sits atop DDS); it has no relevance to rmw_zenoh deployments, which bypass DDS entirely.

---

## Layer 4 — ROS2 Native CLI Observability

For message-rate anomaly detection at the ROS2 topic level:

```bash
ros2 topic hz /your/topic        # Publish rate (detects drops/stalls)
ros2 topic bw /your/topic        # Bandwidth (detects throughput degradation)
ros2 topic delay /your/topic     # End-to-end message delay
```

**ros2doctor** is *not* a performance tool — it only checks environment/config health (QoS mismatches, network config). Do not use it for runtime performance metrics.

For callback-level timing (sub-millisecond), **ros2_tracing** with LTTng captures callback durations at ~0.003 ms average overhead. Use for diagnosing CPU-side bottlenecks, not for continuous production monitoring.

---

## Layer 5 — OpenShift/Kubernetes Integration

### Enable User Workload Monitoring

```yaml
# openshift-monitoring namespace
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

This deploys `prometheus-user-workload` in `openshift-user-workload-monitoring`.

### PodMonitor for Bridge Pod (no Service required)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: zenoh-bridge-monitor
spec:
  selector:
    matchLabels:
      app: zenoh-bridge-ros2dds
  podMetricsEndpoints:
  - port: metrics        # sidecar exporter port
    path: /metrics
    interval: 15s
```

### Sidecar Exporter Pattern

The bridge REST admin space does not emit a standard `/metrics` path with per-route counters. A **sidecar container** that polls `/@/local/ros2/route/**` and `/@/local/metrics`, then re-exposes as Prometheus format on `/metrics:9090`, is the practical integration path.

> No community-maintained Prometheus exporter specifically for zenoh-bridge-ros2dds was confirmed by research — custom development is required for per-route/per-topic granularity beyond router-level counters.

---

## Layer 6 — Alerting Strategies

| Condition | Signal | Alert |
|---|---|---|
| **Message drops** | `zenoh.router.rx_n_dropped` or `tx_n_dropped` rate > 0 | Alert after N drops/minute |
| **Bridge disconnection** | `zenoh.router.sessions` drops to 0 or route count in `@/local/ros2/route/**` goes to 0 | Alert immediately |
| **Topic rate anomaly** | `ros2 topic hz` deviation > threshold | Scraped via custom exporter |
| **Throughput degradation** | `zenoh.router.rx_z_bytes` rate drops > 50% from baseline | Alert on sustained drop |
| **Bridge pod crash/restart** | Kubernetes restart count | Standard k8s alert |
| **DDS discovery loss** | `@/local/ros2/node/**` returns empty | Alert on empty result |

Recommended Prometheus alert rules:

```yaml
groups:
- name: zenoh-bridge
  rules:
  - alert: ZenohBridgeMessageDrops
    expr: rate(zenoh_router_rx_n_dropped[5m]) > 0
    for: 1m
    annotations:
      summary: "Zenoh bridge dropping messages"

  - alert: ZenohBridgeNoSessions
    expr: zenoh_router_sessions == 0
    for: 30s
    annotations:
      summary: "Zenoh bridge has no active sessions"

  - alert: ZenohBridgeThroughputDrop
    expr: rate(zenoh_router_rx_z_bytes[5m]) < (avg_over_time(rate(zenoh_router_rx_z_bytes[5m])[1h:5m]) * 0.5)
    for: 5m
    annotations:
      summary: "Zenoh bridge throughput dropped >50% from 1h baseline"
```

---

## Proposed Monitoring Architecture

```
┌─────────────────────────────────────────────────────────┐
│  OpenShift Cluster                                       │
│                                                          │
│  ┌─────────────────────┐   ┌───────────────────────┐    │
│  │ zenoh-bridge pod     │   │ Zenoh router pod       │    │
│  │                      │   │                        │    │
│  │  bridge process      │   │  zenohd                │    │
│  │  :8000 admin REST    │   │  :8000 REST plugin     │    │
│  │  @/local/ros2/**     │   │  @/local/metrics       │    │
│  │                      │   │  (stats feature req'd) │    │
│  │  sidecar exporter ───┼───┼──polls → /metrics:9090 │    │
│  └──────────┬──────────┘   └──────────┬─────────────┘    │
│             │                          │                   │
│  ┌──────────▼──────────────────────────▼────────────┐    │
│  │  PodMonitor / ServiceMonitor                      │    │
│  │  openshift-user-workload-monitoring               │    │
│  │  prometheus-user-workload                         │    │
│  └──────────────────────────┬────────────────────────┘    │
│                             │                             │
│  ┌──────────────────────────▼────────────────────────┐    │
│  │  Grafana                                          │    │
│  │  Dashboards: session count, drop rate, route map  │    │
│  │  Alerts: drops > 0, sessions == 0, bw drop        │    │
│  └──────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Open Questions (Unresolved)

1. **Per-route/per-topic drop counters** — `@/local/ros2/route/**` state is visible but it is unclear whether it includes drop or queue depth counters at per-topic granularity.
2. **Reconnection detection signal** — When the bridge loses and re-establishes an upstream router connection, the most reliable observable signal (session count delta vs. route disappearance vs. message gap) is not documented.
3. **No confirmed community exporter** — A Prometheus exporter specifically for zenoh-bridge-ros2dds bridging its REST admin space to `/metrics` does not appear to exist; custom development is required for per-route granularity.
4. **rmw_zenoh observability path** — For rmw_zenoh deployments, there is no documented admin space or metrics endpoint equivalent; the only confirmed path is Zenoh router-level metrics from the underlying `zenohd` process.

---

## Refuted Claims (Do Not Rely On)

These were adversarially verified and rejected (≥2/3 agents refuted):

- **SSE streaming support** — The REST API does *not* support `Accept: text/event-stream` for real-time push; polling is the confirmed approach.
- **ros2_tracing requires source rebuild** — Binary LTTng installations work; full source rebuild is not required.
- **ros2_tracing 0.0033 ms overhead is production-safe** — The overhead figure is from a research paper and should not be cited as a production guarantee.
- **Fast DDS Statistics Backend exports exactly `fastdds_latency` and `publication_throughput` named metrics** — The actual metric names are not confirmed to that exact form.

---

## Sources

| Source | Type | Used For |
|---|---|---|
| [Zenoh REST API docs](https://zenoh.io/docs/apis/rest/) | Primary | Admin space / REST API |
| [Zenoh abstractions](https://zenoh.io/docs/manual/abstractions/) | Primary | Admin key formats |
| [zenoh-plugin-ros2dds README](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) | Primary | Bridge admin space endpoints |
| [rmw_zenoh README](https://github.com/ros2/rmw_zenoh) | Primary | Incompatibility, rmw_zenoh observability |
| [Datadog Zenoh router integration](https://docs.datadoghq.com/integrations/zenoh-router/) | Secondary | Confirmed metric names |
| [Vulcanexus Fast DDS Prometheus tutorial](https://docs.vulcanexus.org/en/latest/rst/tutorials/tools/prometheus/prometheus.html) | Secondary | Fast DDS statistics env var |
| [ROS2 tracing docs](https://docs.ros.org/en/humble/Tutorials/Advanced/ROS2-Tracing-Trace-and-Analyze.html) | Primary | ros2_tracing / LTTng |
| [OpenShift user workload monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/html/monitoring/configuring-user-workload-monitoring) | Primary | ServiceMonitor / PodMonitor |
| [ros2doctor docs](https://docs.ros.org/en/foxy/Tutorials/Beginner-Client-Libraries/Getting-Started-With-Ros2doctor.html) | Primary | Scope of ros2doctor |
| [arXiv 2303.09419](https://arxiv.org/pdf/2303.09419) | Peer-reviewed | Zenoh benchmark methodology |
| [arXiv 2201.00393](https://arxiv.org/abs/2201.00393) | Peer-reviewed | ros2_tracing overhead |
| [deepwiki eclipse-zenoh/zenoh](https://deepwiki.com/eclipse-zenoh/zenoh) | Secondary | Zenoh internals / metrics endpoint |
