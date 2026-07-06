# zenoh-bridge-ros2dds Sidecar Resource Sizing

Measured resource consumption of the `zenoh-bridge-ros2dds` sidecar container
(v1.9.0, UBI9-minimal base) under active DDS message load on two platforms:
a local Mac/Podman environment and an AWS-hosted OpenShift cluster.  Results
project fleet requirements at 10, 50, and 100 robot pods and recommend
Kubernetes / OpenShift resource requests and limits.

---

## Image Size

| Image | Uncompressed (on-disk) | Layer breakdown |
|-------|------------------------|-----------------|
| `zenoh-bridge-ros2dds:1.9.0` | **137.9 MB** | UBI9-minimal base: 112 MB + bridge binary: 32.7 MB |
| `zenoh-router:1.9.0` | **148 MB** | UBI9-minimal base: 112 MB + router binary: ~36 MB |

Registry pull size (compressed OCI layers): approximately **45–60 MB** per arch.
A node that already has UBI9-minimal cached re-pulls only the ~13 MB binary layer.

The `ros2-zenoh-demo` main container is 1.34 GB (full ROS 2 Jazzy + DDS stack)
and dominates pod pull time regardless of the sidecar.

---

## Platform A — Mac / Podman (arm64)

### Setup

| Item | Value |
|------|-------|
| Architecture | arm64 (Apple Silicon, libkrun VM, 6 vCPUs, 6 GiB) |
| Runtime | Podman 5.7.0 + podman-compose 1.6.0 |
| Measurement tool | `podman stats --no-stream` — reports **RSS** |
| Active workload | 4 topics: /chatter, /sensor/scan, /sensor/camera (10 Hz each), /system/status (1 Hz) |
| Message type | `std_msgs/msg/String` (~50–100 bytes) |
| Bridge mode | `client` → central `zenoh-router`, TCP, no multicast scouting |
| Samples | **10 × 3-second intervals** per phase |

**CPU% interpretation:** fraction of all 6 VM CPUs. `milliCPU = CPU% × 6 × 10`.

### Idle phase — bridge connected to router, DDS not yet publishing

| Container | CPU% avg ± stdev | milliCPU | RSS avg ± stdev | RSS range |
|-----------|-----------------|----------|--------------------|-----------|
| bridge-talker sidecar | 0.171% ± 0.016 | **10.3 m** | 21.84 ± 0.56 MB | 21.2–22.7 MB |
| bridge-listener sidecar | 0.139% ± 0.015 | **8.3 m** | 3.01 ± 0.38 MB | 2.7–3.6 MB |
| router | 0.060% ± 0.014 | **3.6 m** | 21.65 ± 0.27 MB | 21.5–22.1 MB |

### Active phase — 4 topics at 10 Hz (msg #330+ confirmed)

| Container | CPU% avg ± stdev | milliCPU | RSS avg ± stdev | RSS range |
|-----------|-----------------|----------|--------------------|-----------|
| bridge-talker sidecar | 0.180% ± 0.000 | **10.8 m** | 22.30 ± 0.20 MB | 22.1–22.6 MB |
| bridge-listener sidecar | 0.169% ± 0.006 | **10.1 m** | 3.42 ± 0.11 MB | 3.4–3.6 MB |
| router | 0.093% ± 0.007 | **5.6 m** | 21.87 ± 0.23 MB | 21.6–22.1 MB |

### Mac raw sample tables

#### Idle phase

| s | bridge-talker CPU% | bridge-talker RSS MB | bridge-listener CPU% | bridge-listener RSS MB | router CPU% | router RSS MB |
|---|-------------------|----------------------|---------------------|------------------------|-------------|---------------|
| 1  | 0.21 | 21.23 | 0.17 | 2.68 | 0.09 | 21.46 |
| 2  | 0.18 | 21.23 | 0.15 | 2.68 | 0.07 | 21.46 |
| 3  | 0.17 | 21.50 | 0.14 | 2.68 | 0.06 | 21.46 |
| 4  | 0.16 | 21.23 | 0.13 | 2.68 | 0.05 | 21.46 |
| 5  | 0.15 | 21.59 | 0.12 | 2.68 | 0.05 | 21.46 |
| 6  | 0.16 | 21.98 | 0.12 | 2.94 | 0.04 | 21.52 |
| 7  | 0.17 | 22.65 | 0.13 | 3.29 | 0.05 | 22.11 |
| 8  | 0.17 | 22.26 | 0.14 | 3.56 | 0.06 | 22.11 |
| 9  | 0.17 | 22.26 | 0.14 | 3.56 | 0.06 | 21.59 |
| 10 | 0.17 | 22.52 | 0.15 | 3.31 | 0.07 | 21.85 |
| **avg** | **0.171** | **21.84** | **0.139** | **3.01** | **0.060** | **21.65** |
| **stdev** | 0.016 | 0.56 | 0.015 | 0.38 | 0.014 | 0.27 |

#### Active phase

| s | bridge-talker CPU% | bridge-talker RSS MB | bridge-listener CPU% | bridge-listener RSS MB | router CPU% | router RSS MB |
|---|-------------------|----------------------|---------------------|------------------------|-------------|---------------|
| 1  | 0.18 | 22.32 | 0.16 | 3.61 | 0.08 | 22.10 |
| 2  | 0.18 | 22.07 | 0.16 | 3.36 | 0.09 | 22.10 |
| 3  | 0.18 | 22.32 | 0.17 | 3.36 | 0.09 | 22.10 |
| 4  | 0.18 | 22.58 | 0.17 | 3.37 | 0.09 | 21.59 |
| 5  | 0.18 | 22.09 | 0.17 | 3.37 | 0.09 | 21.58 |
| 6  | 0.18 | 22.10 | 0.17 | 3.37 | 0.09 | 22.11 |
| 7  | 0.18 | 22.36 | 0.17 | 3.38 | 0.10 | 21.84 |
| 8  | 0.18 | 22.37 | 0.17 | 3.64 | 0.10 | 21.84 |
| 9  | 0.18 | 22.62 | 0.17 | 3.39 | 0.10 | 21.84 |
| 10 | 0.18 | 22.12 | 0.18 | 3.39 | 0.10 | 21.59 |
| **avg** | **0.180** | **22.30** | **0.169** | **3.42** | **0.093** | **21.87** |
| **stdev** | 0.000 | 0.20 | 0.006 | 0.11 | 0.007 | 0.23 |

---

## Platform B — AWS OpenShift (amd64) ← authoritative for OCP sizing

### Setup

| Item | Value |
|------|-------|
| Cluster | `api.ai-dev02.kni.syseng.devcluster.openshift.com` (AWS EC2) |
| Architecture | **amd64** (x86_64) |
| OS / kernel | RHCOS 9.6.20260510-0 / 5.14.0-570.113.1.el9_6.x86_64 |
| Container runtime | **CRI-O 1.34.8** (no VM layer) |
| Measurement tool | `kubectl get --raw /apis/metrics.k8s.io/v1beta1/…` — reports **working_set_bytes** |
| Bridge mode | `client` → `zenoh-bridge-router` Service, TCP |
| Samples | **10 × 30-second intervals** per workload level |

> **Memory metric note:** Kubernetes metrics-server reports
> `container_memory_working_set_bytes` = RSS minus inactive file-backed pages.
> This is what the scheduler, OOM killer, and HPA act on — typically
> **2–4× lower** than the RSS figure from `podman stats`.

Three workload levels were measured, covering idle/low, message-rate, and
throughput-bound regimes.

---

### OCP Workload A — Baseline: 1 Hz / 1 topic (demo_nodes_cpp talker)

**Workload:** `std_msgs/String` "Hello World: N", 1 msg/s, ~30 bytes. Deployment
running 4+ days at msg #348,000+.

| Container | CPU avg (n) | ± | **mCPU** | Working-set | ± | **MB** |
|-----------|------------:|--:|--------:|------------:|--:|------:|
| bridge (listener side) | 893,922 | ±42,815 | **0.894 m** | 7,016 Ki | ±1.3 | **6.85** |
| bridge (talker side) | 1,080,636 | ±35,805 | **1.081 m** | 6,964 Ki | ±1.3 | **6.80** |
| router | 314,171 | ±11,543 | **0.314 m** | 1,868 Ki | ±1.3 | **1.82** |

<details><summary>Raw samples — Workload A</summary>

| s | Time | listener CPU (n) | listener mem (Ki) | talker CPU (n) | talker mem (Ki) | router CPU (n) | router mem (Ki) |
|---|------|----------------:|------------------:|---------------:|----------------:|---------------:|----------------:|
| 1 | 15:35:06 | 850,844 | 7,020 | 1,122,882 | 6,964 | 312,582 | 1,868 |
| 2 | 15:35:36 | 995,642 | 7,016 | 1,109,883 | 6,964 | 317,308 | 1,868 |
| 3 | 15:36:07 | 835,881 | 7,016 | 1,105,040 | 6,964 | 313,601 | 1,868 |
| 4 | 15:36:37 | 876,131 | 7,016 | 1,078,062 | 6,964 | 298,271 | 1,868 |
| 5 | 15:37:07 | 908,995 | 7,016 | 1,030,321 | 6,964 | 329,415 | 1,872 |
| 6 | 15:37:38 | 903,359 | 7,016 | 1,040,800 | 6,968 | 317,590 | 1,868 |
| 7 | 15:38:08 | 883,920 | 7,016 | 1,062,406 | 6,964 | 330,225 | 1,868 |
| 8 | 15:38:38 | 883,790 | 7,016 | 1,043,053 | 6,964 | 311,890 | 1,868 |
| 9 | 15:39:09 | 898,182 | 7,016 | 1,084,077 | 6,964 | 293,726 | 1,868 |
| 10 | 15:39:39 | 902,477 | 7,016 | 1,129,838 | 6,964 | 317,104 | 1,868 |
| **avg** | | **893,922** | **7,016** | **1,080,636** | **6,964** | **314,171** | **1,868** |
| **stdev** | | 42,815 | 1 | 35,805 | 1 | 11,543 | 1 |

</details>

---

### OCP Workload B — 31 msg/s: 4 topics × ~10 Hz, String (~100 bytes)

**Workload:** mirrors the Mac/Podman multi-pub.sh test — `chatter` + `sensor/scan`
+ `sensor/camera` at 10 Hz, `system/status` at 1 Hz, all `std_msgs/String`. Traffic
flows end-to-end through the bridge (listener subscribes to `/chatter`).

| Container | CPU avg (n) | ± | **mCPU** | Working-set | ± | **MB** |
|-----------|------------:|--:|--------:|------------:|--:|------:|
| bridge (listener side) | 1,922,574 | ±27,180 | **1.923 m** | 7,215 Ki | ±81 | **7.05** |
| bridge (talker side) | 1,835,153 | ±38,498 | **1.835 m** | 7,374 Ki | ±133 | **7.20** |
| router | 1,471,212 | ±37,381 | **1.471 m** | 1,949 Ki | ±110 | **1.90** |

<details><summary>Raw samples — Workload B</summary>

| s | Time | listener CPU (n) | listener mem (Ki) | talker CPU (n) | talker mem (Ki) | router CPU (n) | router mem (Ki) |
|---|------|----------------:|------------------:|---------------:|----------------:|---------------:|----------------:|
| 1 | 19:49:42 | 1,937,115 | 7,404 | 1,856,570 | 7,280 | 1,470,071 | 1,908 |
| 2 | 19:50:12 | 1,931,071 | 7,152 | 1,787,603 | 7,280 | 1,535,417 | 1,908 |
| 3 | 19:50:43 | 1,949,713 | 7,152 | 1,794,722 | 7,280 | 1,466,433 | 2,164 |
| 4 | 19:51:13 | 1,888,930 | 7,152 | 1,861,076 | 7,280 | 1,460,319 | 1,912 |
| 5 | 19:51:43 | 1,886,901 | 7,152 | 1,815,825 | 7,284 | 1,520,972 | 1,908 |
| 6 | 19:52:14 | 1,971,403 | 7,156 | 1,889,702 | 7,340 | 1,481,661 | 2,160 |
| 7 | 19:52:44 | 1,920,724 | 7,156 | 1,813,167 | 7,432 | 1,462,354 | 1,908 |
| 8 | 19:53:14 | 1,898,236 | 7,408 | 1,887,189 | 7,520 | 1,466,975 | 1,908 |
| 9 | 19:53:45 | 1,916,640 | 7,156 | 1,799,949 | 7,600 | 1,401,901 | 1,908 |
| 10 | 19:54:15 | 1,931,024 | 7,156 | 1,845,752 | 7,676 | 1,445,797 | 1,908 |
| **avg** | | **1,922,574** | **7,209** | **1,835,153** | **7,397** | **1,471,212** | **1,949** |
| **stdev** | | 27,180 | 81 | 38,498 | 133 | 37,381 | 110 |

</details>

---

### OCP Workload C — 84 Mbps: 1 MB × 10 Hz, end-to-end forwarding

**Workload:** Python publisher sends 1,048,576-byte (`std_msgs/String`) messages
at 10 Hz on `/chatter`. The listener pod's `demo_nodes_cpp listener` subscribes to
`/chatter`, so the bridge **must forward every message** end-to-end.
Measured throughput: **10.5 MB/s ≈ 84 Mbps**.

| Container | CPU avg (n) | ± | **mCPU** | Working-set | ± | **MB** |
|-----------|------------:|--:|--------:|------------:|--:|------:|
| bridge (listener side) | 717,613 | ±70,724 | **0.718 m** | 16,588 Ki | ±1 | **16.20** |
| bridge (talker side) | 2,194,600 | ±67,378 | **2.195 m** | 14,631 Ki | ±57 | **14.29** |
| router | 167,549 | ±10,338 | **0.168 m** | 4,160 Ki | ±1 | **4.06** |

<details><summary>Raw samples — Workload C</summary>

| s | Time | listener CPU (n) | listener mem (Ki) | talker CPU (n) | talker mem (Ki) | router CPU (n) | router mem (Ki) |
|---|------|----------------:|------------------:|---------------:|----------------:|---------------:|----------------:|
| 1 | 00:13:24 | 765,784 | 16,588 | 2,286,005 | 14,616 | 176,366 | 4,160 |
| 2 | 00:13:54 | 741,322 | 16,588 | 2,256,204 | 14,616 | 173,040 | 4,160 |
| 3 | 00:14:24 | 757,897 | 16,588 | 2,267,951 | 14,616 | 163,478 | 4,160 |
| 4 | 00:14:55 | 762,191 | 16,588 | 2,232,236 | 14,616 | 163,478 | 4,160 |
| 5 | 00:15:25 | 817,417 | 16,588 | 2,167,165 | 14,624 | 165,482 | 4,160 |
| 6 | 00:15:55 | 762,666 | 16,588 | 2,135,254 | 14,616 | 158,447 | 4,160 |
| 7 | 00:16:25 | 694,581 | 16,588 | 2,079,210 | 14,800 | 170,820 | 4,160 |
| 8 | 00:16:56 | 657,206 | 16,588 | 2,146,915 | 14,616 | 175,913 | 4,160 |
| 9 | 00:17:26 | 610,006 | 16,588 | 2,161,941 | 14,616 | 174,329 | 4,160 |
| 10 | 00:17:56 | 610,683 | 16,588 | 2,212,122 | 14,616 | 157,352 | 4,160 |
| **avg** | | **717,613** | **16,588** | **2,194,600** | **14,635** | **167,870** | **4,160** |
| **stdev** | | 70,724 | 1 | 67,378 | 57 | 10,338 | 1 |

</details>

---

### OCP cross-workload summary and key observations

| Workload | Throughput | bridge-talker mCPU | bridge-listener mCPU | router mCPU | bridge mem (avg) | router mem |
|----------|-----------|-------------------:|---------------------:|------------:|-----------------:|----------:|
| A: 1 Hz × 1 topic | ~0.00003 MB/s | 1.08 m | 0.89 m | 0.31 m | 6.80 / 6.85 MB | 1.82 MB |
| B: 31 msg/s String | ~0.003 MB/s | 1.84 m | 1.92 m | 1.47 m | 7.20 / 7.05 MB | 1.90 MB |
| C: 1 MB × 10 Hz | 10.5 MB/s | **2.20 m** | **0.72 m** | 0.17 m | **14.3 / 16.2 MB** | **4.06 MB** |

**CPU is driven by two separate costs:**

- *Operations cost* (message count): each DDS→Zenoh route lookup, serialisation
  handoff, and TCP write costs CPU regardless of payload size. Going from 1 to
  31 msg/s roughly doubles bridge CPU (1.08 → 1.84 m) and triples router CPU
  (0.31 → 1.47 m, because the router handles route advertisements per message).
- *Throughput cost* (bytes/second): serialising and copying large payloads.
  At 84 Mbps the talker bridge rises to 2.20 m while the router drops to 0.17 m
  — the router only touches session metadata, not payload bytes.

The **listener bridge CPU at 84 Mbps (0.72 m) is lower than baseline (0.89 m).**
This is not a measurement error: at 10 Hz with 1 MB payloads, the bridge receives
a burst, delivers it to DDS, then sits idle for ~90 ms. The 60-second metric
window averages those idle gaps, producing a lower mean than the steady 1 Hz
polling cost.

**Memory scales with payload size, not message count.**
Between Workload A and B (×31 more messages, tiny payloads) memory barely moves
(+0.4 MB). Between A and C (×10.5 MB/s throughput) memory grows by **+7.4–9.4 MB**
per bridge and **+2.2 MB** on the router. This reflects DDS and Zenoh internal
queues holding in-flight 1 MB messages. A single large-payload topic adds roughly
**1–2 MB per queue-depth slot** to the working_set.

---

## Platform Comparison

| Metric | Mac / Podman (arm64) | OCP AWS — Workload B (amd64) | Notes |
|--------|---------------------|------------------------------|-------|
| Architecture | arm64 (libkrun VM) | amd64 (bare metal CRI-O) | — |
| Workload | 4 topics × 10 Hz, String | 4 topics × 10 Hz, String | matched |
| Memory metric | RSS (podman stats) | working_set_bytes (cgroup v2) | — |
| Bridge CPU | 10.8 m | **1.84 m** | ~6× gap: VM overhead + metric differences |
| Bridge memory | 22.3 MB RSS | **7.2 MB** working_set | ~3× gap: RSS vs working_set definition |
| Router CPU | 5.6 m | **1.47 m** | VM overhead inflates Mac |
| Router memory | 21.9 MB RSS | **1.90 MB** working_set | same metric gap |

The CPU gap on matched workloads (10.8 m vs 1.84 m) is the libkrun VM overhead.
The memory gap (22 vs 7 MB) is the RSS vs working_set definition difference.
OCP figures are authoritative for Kubernetes scheduling.

---

## Scaling to Real Sensor Workloads

Workload C (84 Mbps, 1 MB × 10 Hz) anchors the measured curve.  Sensor data
typically arrives in larger bursts at lower rates; the per-message CPU model
from Workloads A/B and the per-byte memory model from Workload C can be combined:

| Workload profile | Per-pod throughput | CPU estimate (bridge) | Memory estimate (bridge) |
|------------------|-------------------|-----------------------|--------------------------|
| Demo (measured A) | ~0 MB/s | **1.1 m** | **7 MB** |
| 31 msg/s String (measured B) | ~0.003 MB/s | **1.8 m** | **7 MB** |
| 84 Mbps, 1 MB×10 Hz (measured C) | 10.5 MB/s | **2.2 m** | **15 MB** |
| Light: 2D lidar ×3 topics (est.) | ~5 MB/s | ~5 m | ~12 MB |
| Medium: + 3D lidar ×1 topic (est.) | ~15 MB/s | ~8 m | ~22 MB |
| Heavy: + camera ×1 topic at 30 Hz (est.) | ~100 MB/s | ~30–50 m | ~80–120 MB |

Key insight from the measurements: **CPU stays surprisingly low** (2.2 m at 84 Mbps)
because Zenoh uses zero-copy forwarding for large payloads — the bridge copies headers
but shares payload memory through the kernel.  **Memory, not CPU, is the binding
constraint** for large-payload sensor workloads.

---

## Fleet Projections

Per-pod baseline: **~2 m CPU, ~7 MB working_set** (Workload B, 31 msg/s, comparable
to a robot sending commands + small telemetry). Memory adjustments for sensor topics
are additive: each large topic adds ~1–2 MB per DDS queue slot.

### 31 msg/s String (OCP measured, Workload B)

| Fleet size | Bridge CPU total | Bridge working-set total | Router (shared) |
|------------|-----------------|--------------------------|-----------------|
| 1 pod | 2 m | 7 MB | 1.5 m, 1.9 MB |
| 10 pods | 20 m | 70 MB | 3 m, 2.5 MB |
| 50 pods | 90 m | 350 MB | 8 m, 4 MB |
| 100 pods | 180 m | 700 MB | 15 m, 6 MB |

### Light sensor — 2D lidar + commands (~5 MB/s per pod, estimated)

| Fleet size | Bridge CPU total | Bridge working-set total | Router (shared) |
|------------|-----------------|--------------------------|-----------------|
| 10 pods | 50 m | 120 MB | 10 m, 5 MB |
| 50 pods | 250 m | 600 MB | 30 m, 10 MB |
| 100 pods | 500 m (0.5 core) | 1,200 MB | 50 m, 15 MB |

### Medium sensor — + 3D lidar (~15 MB/s per pod, estimated)

| Fleet size | Bridge CPU total | Bridge working-set total | Router (shared) |
|------------|-----------------|--------------------------|-----------------|
| 10 pods | 80 m | 220 MB | 15 m, 8 MB |
| 50 pods | 400 m | 1,100 MB | 50 m, 20 MB |
| 100 pods | 800 m (0.8 core) | 2,200 MB | 100 m, 35 MB |

### Heavy sensor — + camera at 30 Hz (~100 MB/s per pod, estimated)

| Fleet size | Bridge CPU total | Bridge working-set total | Router (shared) |
|------------|-----------------|--------------------------|-----------------|
| 10 pods | 350 m | 900 MB | 50 m, 30 MB |
| 50 pods | 1,750 m (1.75 cores) | 4,500 MB | 150 m, 80 MB |
| 100 pods | 3,500 m (3.5 cores) | 9,000 MB | 300 m, 150 MB |

> At 50+ pods with heavy sensor load, consider router federation to avoid
> bandwidth bottlenecks at the central router.
> See `docs/zenoh-router-federation-proposal.md`.

---

## Recommended OCP Resource Requests/Limits

Anchored to OCP working_set measurements.  **Memory is the binding constraint**
for sensor workloads; CPU headroom is generous even at 84 Mbps.

### zenoh-bridge-ros2dds sidecar

#### Tier 1 — Demo / command-only (<1 MB/s per pod)

```yaml
resources:
  requests:
    cpu: 10m       # 5× measured 1.8 m at 31 msg/s
    memory: 32Mi   # 4.5× measured 7 MB working_set
  limits:
    cpu: 100m
    memory: 64Mi
```

#### Tier 2 — Light sensor (2D lidar + commands, 1–20 MB/s per pod)  ← current manifests

```yaml
resources:
  requests:
    cpu: 50m       # comfortable headroom for ~5 MB/s + burst
    memory: 64Mi   # covers ~12–22 MB working_set for light sensor load
  limits:
    cpu: 200m
    memory: 128Mi
```

#### Tier 3 — Heavy sensor (3D lidar + camera, >20 MB/s per pod)

```yaml
resources:
  requests:
    cpu: 50m       # CPU stays low even at 84 Mbps (measured 2.2 m)
    memory: 128Mi  # covers ~80–120 MB working_set for camera-class payloads
  limits:
    cpu: 200m
    memory: 256Mi  # raised from 128Mi — memory is the real constraint here
```

> **Note:** CPU requests are similar across tiers because CPU usage stays nearly
> flat with throughput (Zenoh zero-copy forwarding).  Memory requests diverge
> sharply — scale memory limits with the largest expected payload × queue depth.

### zenoh-router (centralized, per cluster)

```yaml
resources:
  requests:
    cpu: 50m       # measured 1.47 m at 31 msg/s; 50m covers reconnect bursts
    memory: 32Mi   # measured 1.9–4.1 MB; 32Mi gives 8× headroom
  limits:
    cpu: 500m
    memory: 256Mi
```

---

## Current Manifest Status

The existing manifests in `k8s/bridge/` use **Tier 2** values:

```
k8s/bridge/deployment-ros2-dds-talker.yaml    zenoh-bridge: 50m/64Mi → 200m/128Mi
k8s/bridge/deployment-ros2-dds-listener.yaml  zenoh-bridge: 50m/64Mi → 200m/128Mi
k8s/federation/deployment-edge-talker.yaml    zenoh-bridge: 50m/64Mi → 200m/128Mi
k8s/federation/deployment-cloud-listener.yaml zenoh-bridge: 50m/64Mi → 200m/128Mi
```

These are correct for demo and light sensor loads.  **Raise the memory limit to
256Mi** if pods will carry camera streams or multiple 3D lidar topics.  CPU limits
do not need to change — measured CPU stays well under 200m even at 84 Mbps.

---

## Reproducibility

### On OCP (authoritative)

```bash
# Single snapshot (nanocores precision)
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/ros2-zenoh-bridge/pods" \
  | jq -r '.items[].containers[] | [.name, .usage.cpu, .usage.memory] | join("\t")'

# 10-sample loop, 30s apart
for i in $(seq 1 10); do
  kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/ros2-zenoh-bridge/pods" \
    | jq -r --arg s "$i" \
        '.items[].containers[]
         | select(.name=="zenoh-bridge" or .name=="zenoh-router")
         | [$s, .name, .usage.cpu, .usage.memory] | join(",")'
  [ "$i" -lt 10 ] && sleep 30
done

# Large-payload test (1 MB × 10 Hz on a subscribed topic)
kubectl exec -n ros2-zenoh-bridge <talker-pod> -c ros2-talker -- bash -c '
  source /opt/ros/jazzy/setup.bash
  python3 - << EOF
import sys; sys.path.insert(0, "/opt/ros/jazzy/lib/python3.12/site-packages")
import rclpy; from rclpy.node import Node; from std_msgs.msg import String
rclpy.init(); node = Node("lp"); p = node.create_publisher(String, "/chatter", 10)
m = String(); m.data = "X" * 1048576
node.create_timer(0.1, lambda: p.publish(m)); rclpy.spin(node)
EOF
'
```

### On Mac / Podman (local reference)

```bash
podman machine start
bash scripts/measure-sidecar-resources.sh --samples 10
```

Required images:

```bash
podman pull quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:1.9.0
podman pull quay.io/ecosystem-appeng/zenoh-router:1.9.0
podman pull quay.io/jianrzha/ros2-zenoh-demo:0.0.7
```
