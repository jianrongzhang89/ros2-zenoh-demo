# Zenoh Performance and Reliability for Large-Scale Robotic Fleets

**Research method:** Multi-source adversarial verification — 103 agents, 20 sources fetched, 91 claims extracted, 25 verified with 3-vote adversarial review, 6 confirmed, 19 killed.

**Date:** 2026-06-16

---

## Executive Summary

Zenoh shows genuine promise for large-scale robotic fleet communication but is not a clear-cut replacement for DDS in all scenarios. Its architectural advantages in dynamic, wireless, and heterogeneous networks are real and peer-reviewed. However, several headline performance claims circulating in vendor material did not survive adversarial verification, and two practical limitations — default single-host scope and incompatibility between its two ROS 2 integration paths — create meaningful operational risk for fleet operators.

---

## Confirmed Findings

### 1. Latency: CycloneDDS leads on single-machine; Zenoh-pico leads all

**Confidence: Medium | Adversarial vote: 3-0**

On a single machine with 64-byte payloads (Zenoh v0.7.0-rc, 2023):

| Implementation | Latency |
|---|---|
| Zenoh-pico | **5 µs** |
| CycloneDDS | 8 µs |
| Zenoh P2P | 10 µs |

CycloneDDS's advantage over full Zenoh is due to UDP multicast, which Zenoh lacked at that version. Zenoh's Dragonite (Oct 2023) and Firesong/1.1.0 (Dec 2024) releases added multicast support — the gap may have since closed. No post-2024 systematic benchmark survived verification.

Sources: [arXiv:2303.09419](https://arxiv.org/abs/2303.09419), [zenoh.io blog](https://zenoh.io/blog/2023-03-21-zenoh-vs-mqtt-kafka-dds/)

---

### 2. Dynamic mesh networks: Zenoh wins where it matters for field robotics

**Confidence: High | Adversarial vote: 2-1**

A peer-reviewed Springer paper (Chovet et al., *Journal of Intelligent & Robotic Systems*, 111:18, 2024 — Best Paper, IEEE DistInSys/ISCC 2025) tested FastRTPS, CycloneDDS, and Zenoh as ROS 2 RMWs over a real dynamic mesh network simulating a lunar exploration scenario:

| Metric | Winner |
|---|---|
| Reachability | **Zenoh** |
| Delay | **Zenoh** |
| CPU usage | **Zenoh** |
| Data overhead (small/medium messages) | **Zenoh** |
| RAM usage | CycloneDDS |
| Data overhead (large messages) | Mixed |

The authors describe Zenoh as *"a potential solution for future applications"* — a directionally strong but hedged conclusion. The 2-1 adversarial vote reflects this: the result is not definitive for production deployments.

Source: [Springer JINT 10.1007/s10846-024-02211-2](https://link.springer.com/article/10.1007/s10846-024-02211-2)

---

### 3. rmw_zenoh and zenoh-plugin-ros2dds are mutually incompatible

**Confidence: High | Adversarial vote: 3-0**

The two Zenoh-based ROS 2 integration paths cannot interoperate:

- **rmw_zenoh**: native Zenoh RMW, maps ROS 2 concepts to Zenoh key expressions using its own convention
- **zenoh-plugin-ros2dds** (zenoh-bridge-ros2dds): bridges CycloneDDS over Zenoh using a different key-expression convention

The `ros2/rmw_zenoh` README explicitly states bridging is *"beyond the scope of rmw_zenoh."* GitHub issue #522 confirms no migration path as of mid-2025. Fleet operators must choose one path — no gradual migration between them is possible. This is an active, unresolved limitation.

**Implications for this project:** The `zenoh-bridge-ros2dds` approach used in Approach 2 of this repo is incompatible with `rmw_zenoh`. A future switch to native `rmw_zenoh` would require taking all nodes offline and migrating simultaneously.

Source: [github.com/ros2/rmw_zenoh](https://github.com/ros2/rmw_zenoh)

---

### 4. Cross-host communication is not enabled by default in rmw_zenoh

**Confidence: High | Adversarial vote: 3-0**

Out of the box, `rmw_zenoh` restricts all discovery and communication to a single host. The default `DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5` listens only on `tcp/localhost:0`; multicast scouting is disabled deliberately to prevent *"uncontrolled communication between robots in the same LAN."*

Any multi-machine deployment — including any fleet with 2+ robots on separate hosts — requires explicit configuration:

- Router-to-router federation
- Multicast re-enablement
- Client-mode remote router connection

This is not a startup default. It must be intentionally engineered and is directly relevant to 100+ robot fleet deployments.

Source: [github.com/ros2/rmw_zenoh](https://github.com/ros2/rmw_zenoh)

---

### 5. Zenoh's discovery architecture scales better than DDS for large fleets

**Confidence: Medium | Adversarial vote: 2-1**

Zenoh shares only subscriptions, not full participant state. The `--generalise-sub` flag can reduce an entire robot's topic subscription set to a single wildcard key expression. This is architecturally superior to DDS's SPDP/SEDP multicast protocol, which broadcasts full participant state to all nodes regardless of interest — O(n²) discovery traffic growth as fleet size increases.

**Caveat:** DDS has mitigations. Fast DDS Discovery Server v2 (available since ROS 2 Humble) breaks the fully-connected topology. The performance gap is deployment-configuration-dependent, not inherent. Operators who deploy DDS with Discovery Server may see a much smaller gap than the architectural comparison implies.

Sources: [OSRF TSC-RMW Report](https://osrf.github.io/TSC-RMW-Reports/humble/eclipse-cyclonedds-report.html), [zenoh.io discovery blog](https://zenoh.io/blog/2021-03-23-discovery/)

---

### 6. DDS's multicast dependency is a real operational problem in modern deployments

**Confidence: Medium | Adversarial vote: 2-1**

DDS's reliance on multicast UDP causes well-documented failures in:

- Wi-Fi networks (multicast suppressed or throttled by access points)
- Container environments (Docker, Kubernetes, OpenShift)
- WAN and cloud deployments

For a 100+ robot fleet spanning multiple network segments or running in a cloud-connected architecture, this is a concrete operational risk.

**Caveat:** The primary framing source is ZettaScale's CEO (the company behind Zenoh) writing in a trade publication — a conflicted source. The underlying technical facts are independently corroborated by ROS 2 official documentation and commercial vendor docs, but the severity is overstated in vendor material. Managed LAN environments with proper multicast routing function correctly with DDS.

Sources: [Electronic Design](https://www.electronicdesign.com/technologies/communications/article/55039208/zettascale-ros-2-communication-stack-exploring-the-improvements-brought-by-zenoh), [OSRF TSC-RMW Report](https://osrf.github.io/TSC-RMW-Reports/humble/eclipse-cyclonedds-report.html)

---

## Claims That Did Not Survive Verification

These circulate widely in blog posts and vendor articles but were killed (≥2/3 adversarial votes) for lack of independent corroboration:

| Claim | Vote | Origin |
|---|---|---|
| Zenoh achieves >4M msg/s vs CycloneDDS's ~2M | 0-3 killed | arXiv:2303.09419 |
| Zenoh 2.3× latency advantage over CycloneDDS on 100GbE | 1-2 killed | arXiv:2303.09419 |
| 97–99% reduction in DDS discovery traffic with Zenoh | 0-3 killed | Vendor trade article |
| Zenoh zero-copy/shared memory advantage over standard DDS | 0-3 killed | Vendor trade article |
| Zenoh 3.5× Wi-Fi latency advantage; CycloneDDS fails at 1MB over Wi-Fi | 0-3 killed | arXiv:2309.07496 |
| Zenoh achieves zero message loss where FastDDS drops 4MB Camera/Lidar messages | 0-3 killed | arXiv:2505.02734 |
| "DDS was designed for closed, wired systems and is unsuitable at scale" | 0-3 killed | Vendor trade article |
| Zenoh achieves latencies as low as 7 µs with 5-byte protocol overhead | 0-3 killed | Vendor trade article |

Many of these originate from the same arXiv preprint or vendor-authored articles. Throughput and multi-machine latency claims failed because verifiers could not independently confirm the exact figures from primary data.

---

## Caveats and Limitations

**Time sensitivity.** The most specific benchmark numbers (CycloneDDS 8 µs vs Zenoh 10 µs) are from Zenoh v0.7.0-rc (2023). Firesong/1.1.0 (Dec 2024) added multicast support and performance improvements — current numbers may differ materially.

**No empirical 100+ robot data.** No confirmed finding includes measurements from an actual fleet at that scale. Scalability claims are architectural or derived from small-scale mesh experiments (the planetary exploration study).

**DDS mitigations underrepresented.** Fast DDS Discovery Server v2 partially addresses the O(n²) discovery problem. Managed LAN environments handle multicast correctly. The performance gap relative to a well-configured DDS deployment is smaller than the raw architectural comparison suggests.

**Source quality asymmetry.** The most specific throughput and latency claims rely heavily on two arXiv preprints and vendor-authored trade articles. The confirmed findings rely on a peer-reviewed Springer journal paper and the official `ros2/rmw_zenoh` repository.

**Incompatibility is active and unresolved.** The `rmw_zenoh` / `zenoh-plugin-ros2dds` incompatibility has no announced resolution path as of mid-2025.

---

## Open Questions

1. How do Zenoh Dragonite/Firesong latency and throughput compare to CycloneDDS post-multicast-support addition — the gap that defined the 2023 results?
2. Is there empirical data from 50–100+ robot deployments measuring discovery convergence time, steady-state bandwidth, and fault recovery latency when robots dynamically join and leave?
3. What is the realistic migration path between `rmw_zenoh` and `zenoh-plugin-ros2dds` for a mixed fleet, and is one planned?
4. How does `rmw_zenoh` behave when a Zenoh router becomes unreachable mid-operation — graceful degradation or hard failure requiring manual reconfiguration?

---

## Recommended Reading

| Source | Type | Why |
|---|---|---|
| [Chovet et al., JINT 2024](https://link.springer.com/article/10.1007/s10846-024-02211-2) | Peer-reviewed | Best available empirical comparison on dynamic mesh / multi-robot |
| [arXiv:2303.09419](https://arxiv.org/abs/2303.09419) | Preprint | Latency/throughput benchmark (treat specific numbers as 2023 baselines) |
| [ros2/rmw_zenoh README](https://github.com/ros2/rmw_zenoh) | Primary | Authoritative source on cross-host config, incompatibility, design decisions |
| [OSRF TSC-RMW Report (Humble)](https://osrf.github.io/TSC-RMW-Reports/humble/eclipse-cyclonedds-report.html) | Independent | Non-vendor analysis of Zenoh's discovery architecture vs DDS |
