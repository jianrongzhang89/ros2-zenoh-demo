# Zenoh Router Scaling: Load Balancing vs. Federation

**Research method:** Multi-source adversarial verification — 102 agents, 20 sources fetched, 89 claims extracted, 25 verified with 3-vote adversarial review, 10 confirmed, 15 killed.

**Date:** 2026-06-30

---

## Executive Summary

A single Zenoh router cannot be transparently load-balanced across multiple pods. Zenoh sessions are stateful: every client-mode application maintains exactly one session with one router at a time, requiring a full Open/Accept and declaration re-exchange after any router switch or failure. Federation — interconnecting multiple routers via explicit `connect/endpoints` configuration — is the correct HA and scaling model, and is the topology Zenoh's own deployment documentation describes for geographic and fault-tolerance scenarios.

However, federation imposes its own constraints: HA gateways for a given south region must all reside in the same north region, and the default hop-to-hop reliability means data can be lost during topology changes or router failover. No published benchmark exists for federated multi-router topologies under increasing ROS 2 message load; the only quantified routing overhead data compares a single broker to peer-to-peer mode, showing approximately 2–2.5x higher latency when traffic transits a router.

**Recommendation:** Run zenoh-router and zenoh-bridge-ros2dds as stateful workloads with stable endpoints (StatefulSet or fixed Service), configure inter-router federation links explicitly, and treat router pods as pets rather than cattle. Horizontal Pod Autoscaling behind a TCP load balancer is architecturally incompatible with Zenoh's session model.

---

## Confirmed Findings

### 1. Zenoh Sessions Are Stateful — Load Balancing Is Architecturally Incompatible

**Confidence: High | Adversarial vote: 3-0**

Every Zenoh client maintains exactly one session with one router at a time. Session setup requires a negotiated Open/Accept handshake plus declaration exchange and interest propagation. If a router pod disappears or is replaced (e.g., by a TCP load balancer routing to a different backend), the client must perform a full re-establishment cycle — there is no transparent failover.

The Zenoh 1.0 spec lists Open/Accept, Declarations, and Interests as session-layer responsibilities. The official deployment docs state verbatim: *"the application will maintain, at any given time, a single session with another process (typically a Zenoh daemon: zenohd)."*

This is a hard protocol constraint, not an implementation limitation. A load balancer in front of multiple zenoh-router pods will break session continuity for any client whose connection is handed to a different pod after establishment.

Sources: [Zenoh 1.0 Architecture Spec](https://spec.zenoh.io/spec/1.0.0/architecture/index.html) · [Zenoh Deployment Docs](https://zenoh.io/docs/getting-started/deployment/) · [GitHub Issue #1886](https://github.com/eclipse-zenoh/zenoh/issues/1886)

---

### 2. Federation Is the Correct HA and Scaling Model

**Confidence: High | Adversarial vote: 3-0**

Multiple Zenoh routers can be federated by listing remote router TCP endpoints in the `connect` section of the Zenoh config, enabling transparent message routing across the link:

```json
{
  "connect": {
    "endpoints": ["tcp/192.168.0.3:7447", "tcp/192.168.0.4:7447"]
  }
}
```

Key operational constraints:

- **Static configuration required.** There is no auto-connect or service-discovery-based federation. Bridge-to-bridge and router-to-router links must be explicitly configured.
- **`zenoh-bridge-ros2dds` defaults to router mode** since v0.11.0 but does not auto-connect to anything. From the plugin README: *"connectivity between bridges has to be statically configured."*
- **Co-location rule for HA gateways.** For load balancing and fault tolerance, multiple gateways may serve the same south region, but those gateways must be deployed in the same north region. Cross-region HA requires deeper tree hierarchy (see Zenoh 1.9.0 Longwang below).

Sources: [ros2/rmw_zenoh README](https://github.com/ros2/rmw_zenoh) · [zenoh-plugin-ros2dds README](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) · [Zenoh Deployment Docs](https://zenoh.io/docs/getting-started/deployment/)

---

### 3. Failover Is Lossy by Default

**Confidence: High | Adversarial vote: 2-1**

Zenoh uses hop-to-hop (link-by-link) reliability by default. The Zenoh reliability blog states directly:

> *"During the failover, data samples may be lost. With the default hop to hop reliability strategy data samples can be lost during topology changes. This is the price to pay for good scalability."*

Any Kubernetes scenario involving router pod restarts, rolling updates, or liveness-probe-triggered restarts will produce message loss under default configuration.

End-to-end reliability via **Advanced Pub/Sub** is available as an opt-in feature but has its own scalability trade-offs. It should be enabled selectively for topics where data loss is unacceptable (e.g., command topics), not applied globally.

Source: [Zenoh Reliability Blog](https://zenoh.io/blog/2021-06-14-zenoh-reliability/)

---

### 4. Active Bug: Reconnection Race Condition (Issue #1886)

**Confidence: High | Adversarial vote: 3-0**

GitHub Issue #1886 (Zenoh 1.3.1, filed April 2025) documents a race condition with direct impact on any Kubernetes deployment that relies on pod restarts or rolling updates.

**Trigger:** A client reconnects before the old TCP connection is fully torn down.

**Symptom:** Two `Face` objects are created for the same peer. Routing silently halts with the log message:
```
Received router declaration with unknown routing context id 0
```

**Reproducibility:** ~1 in 4 attempts in a simplified two-publisher, 50 Hz test setup; nearly every time in production environments.

Zenoh 1.3.3 added *auto-reconnect with declaration cache restoration* as a mitigation. However, the complete fix status in later Zenoh releases (1.3.3+) should be verified against your deployed version before relying on rolling updates being safe. The issue includes TCP packet captures, router logs, and a reproducible test script.

Source: [eclipse-zenoh/zenoh Issue #1886](https://github.com/eclipse-zenoh/zenoh/issues/1886)

---

### 5. Routing Overhead: ~2–2.5x Latency vs. Peer-to-Peer

**Confidence: High | Adversarial vote: 3-0 (benchmark existence) and 3-0 (federation gap)**

| Mode | Single-machine latency | Cross-machine latency |
|---|---|---|
| Peer-to-peer | 10 µs | 16 µs |
| Single router (brokered) | 21 µs | 41 µs |
| **Overhead** | **~2.1x** | **~2.6x** |

Payload: 64 bytes. Source: arXiv:2303.09419 (National Taiwan University, March 2023), corroborated by Zenoh's own comparative blog post.

Zenoh v1.1 (2025) claims >35% across-the-board performance improvement, so absolute numbers may have shifted — but the directional overhead of adding a router hop is structurally confirmed by the protocol architecture.

**Critical benchmark gap:** No published benchmark evaluates federated multi-router topologies. The 2026 benchmark survey (arXiv:2603.21600) also tested only single-router client/broker mode on single-node deployments, with no Kubernetes, federation, or load-balancing scenarios. The latency cost of a two-hop federated path (client → router A → router B → subscriber) under ROS 2 sensor message loads (50–200 Hz) is entirely absent from the literature and must be measured empirically.

Sources: [arXiv:2303.09419](https://arxiv.org/abs/2303.09419) · [Zenoh vs MQTT/Kafka/DDS blog](https://zenoh.io/blog/2023-03-21-zenoh-vs-mqtt-kafka-dds/) · [arXiv:2603.21600](https://arxiv.org/html/2603.21600v1)

---

### 6. Zenoh 1.9.0 Longwang — Deeper Region Trees (Partial Relief)

**Confidence: Medium | Adversarial vote: 2-1**

Zenoh 1.9.0 Longwang (released April 2026) introduced support for arbitrarily deep region trees in the federation topology. This could relax the co-location constraint for HA gateway sets in multi-region deployments, enabling true multi-region active-active federation through tree hierarchy rather than same-level gateway duplication.

However, the formal same-north-region co-location rule is retained in current deployment documentation. Whether Longwang fully removes this constraint in practice has not been independently verified and should be tested against your specific OCP multi-cluster topology.

Source: [Zenoh Longwang Release Blog](https://zenoh.io/blog/2026-04-16-zenoh-longwang/)

---

## Recommended Kubernetes/OpenShift Strategy

This recommendation is derived from confirmed protocol constraints. No official Zenoh or Red Hat Kubernetes deployment guide was found during research.

| Concern | Recommendation |
|---|---|
| **Pod type** | `StatefulSet` or `Deployment` with a fixed `ClusterIP Service` — **not** `HPA + shared VIP` |
| **Addressing** | Use stable pod DNS (`pod-0.svc.cluster.local`) or fixed Service IPs in federation endpoint lists |
| **Scaling** | Add router pods manually and configure explicit federation links in ConfigMaps; do not auto-scale |
| **Rolling updates** | Drain / quiesce connected clients before cycling router pods; verify Issue #1886 fix status first |
| **Message loss** | Enable Advanced Pub/Sub (end-to-end reliability) for command/critical topics |
| **Bridge layout** | One `zenoh-bridge-ros2dds` per robot or namespace; configure bridge-to-bridge links explicitly |
| **Monitoring** | Expose Zenoh router metrics and alert on session drops; a silent reconnection failure (Issue #1886) will look like a healthy pod with zero message throughput |

---

## Open Questions

1. **Is Issue #1886 fixed in the current deployed Zenoh version?** Verify that Zenoh 1.3.3+ declaration cache restoration fully closes the race window for pod restarts before enabling rolling updates.

2. **Does Longwang (1.9.0) region tree depth relax the co-location constraint** for multi-region active-active federation in your OCP topology?

3. **Two-hop federation latency** — no benchmark data exists. Empirical measurement under your sensor message loads (50–200 Hz) is required before the federated topology can be sized correctly.

4. **No official Zenoh K8s deployment guide exists.** Consider opening a GitHub discussion with the Zenoh upstream team to validate your StatefulSet + federation topology before committing to it in production.

---

## Refuted Claims

The following claims appeared in source materials but did not survive 3-vote adversarial verification and should not be relied upon:

| Claim | Source | Vote |
|---|---|---|
| Zenoh in brokered mode achieves ~34 Gbps on 100 GbE, ~32% less than P2P | arXiv:2303.09419 | 0-3 |
| A single Zenoh router enforces a MAX_LINKS connection cap causing cascading transport failures | zenoh-plugin-ros2dds #314 | 1-2 |
| Namespace-based federation is supported by configuring a unique namespace prefix per bridge | zenoh-plugin-ros2dds README | 0-3 |
| RMW Zenoh nodes operate in peer mode by default | rmw_zenoh README | 0-3 |
| Multiple Zenoh routers in the same peer subnetwork cause duplicate message delivery | zenoh/issues/409 | 0-3 |
| Self-connection creates a loopback routing path causing duplicated messages | zenoh/issues/1508 | 0-3 |

---

## Caveats

1. Benchmark data (Finding 5) is from a March 2023 paper. Zenoh v1.1 (2025) performance improvements may have changed absolute latency numbers, though the directional overhead of router-hop vs. P2P appears structurally unchanged.

2. The topological constraint on HA gateways (Finding 2) rests primarily on the Zenoh deployment docs with no independent corroboration. Longwang may relax this in practice even if docs retain the formal rule.

3. Issue #1886 was filed against Zenoh 1.3.1. Fix status in subsequent releases was not confirmed during research.

4. Several refuted claims involved potentially real phenomena (connection cap limits, bridge crashes under multi-bridge fan-out) that could not be verified from available sources. Their refutation reflects insufficient evidence found during this research pass, not confirmed non-existence.
