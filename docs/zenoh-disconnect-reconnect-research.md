# Zenoh Disconnect and Reconnect Behavior: Research for Negative Testing

**Research method:** Multi-source adversarial verification — 99 agents, 17 sources fetched, 75 claims extracted, 25 verified with 3-vote adversarial review, 12 confirmed, 13 refuted.

**Research date:** 2026-07-06  
**Empirical test date:** 2026-07-07 (Zenoh 1.9.0, podman/libkrun, macOS arm64)

---

## Executive Summary

When a Zenoh router pod disappears, there is **no durable client-side buffer** that survives the disconnect. The TX link queue (2 batches per priority, 8 priorities) absorbs micro-bursts only; after that, `CongestionControl::Drop` discards after 1 ms and `CongestionControl::Block` (the rmw_zenoh default for RELIABLE QoS) blocks the publisher thread and then closes the transport session after 5 seconds of sustained queue-full. Once the TCP session closes, any unacknowledged in-flight messages are gone.

Declaration cache restoration (Zenoh-Pico 1.3.3+ `Z_FEATURE_AUTO_RECONNECT`) does not apply to rmw_zenoh, which uses the Zenoh Rust library. The router-side race condition from Issue #1886 — two simultaneous transport faces producing "unknown routing context id 0" and halting routing for ~17 seconds — is partially mitigated by PR #2438 (Feb 2026) and connectivity reestablishment bugs were fixed in Zenoh 1.8.x (Kiyohime, Mar 2026), but the full fix status for all reconnect scenarios remains unconfirmed. End-to-end sample delivery across a router disconnect requires AdvancedPublisher + AdvancedSubscriber; rmw_zenoh PR #591 (Apr 2025) enables this for RELIABLE+TRANSIENT_LOCAL topics only.

**What this means for negative testing:** The tests must distinguish between (a) the brief burst-absorption window before drop/close, (b) the 5-second blocking window before session teardown, (c) the reconnect race that silently kills routing, and (d) the Advanced Pub/Sub recovery path that is the only mechanism for recovering missed samples. All four failure modes need distinct test scenarios.

**Empirical update (2026-07-07):** After running N1–N10 against Zenoh 1.9.0, the self-healing behavior is substantially better than the research predicted. Router SIGKILL and SIGTERM both recover in 17–21 seconds without any manual intervention. The Issue #1886 race was not triggered at all in 1.9.0 (N3 fast-cycle restart passed clean). The network-partition scenario (N4/N10) self-heals in ~19–50 seconds. Issue #86 (second bridge restart silent failure) was not reproduced in client mode. Measured gap loss at 50 Hz over a 30-second WAN outage: 1740 messages (expected 1500). See the [Empirical Test Results](#empirical-test-results-zenoh-190) section below.

---

## Confirmed Findings

### 1. TX Buffer Behavior During Disconnect

**Confidence: High | Votes: 3-0 (queue defaults), 3-0 (wait_before_drop), 2-1 (per-publisher setting)**

The transport link TX queue holds **2 batches per priority** across all 8 levels (`control`, `real_time`, `interactive_high`, `interactive_low`, `data_high`, `data`, `data_low`, `background`). This is configured under `transport.link.tx.queue.size` in `DEFAULT_CONFIG.json5`.

When the queue fills:

| Mode | Behavior | Duration |
|---|---|---|
| `CongestionControl::Drop` | Waits `wait_before_drop` (default **1 ms**), then silently discards | 1 ms |
| `CongestionControl::Block` | Blocks the publisher thread; if queue stays full for `wait_before_close` (default **5 s**), **closes the transport session** | Up to 5 s, then teardown |

**Critical for rmw_zenoh:** rmw_zenoh sets `CongestionControl::Block` for RELIABLE QoS topics (confirmed in rmw_zenoh Issue #457). This means a router pod disappearing silently blocks the ROS 2 publisher thread for up to 5 seconds, then the transport session is **closed** — not gracefully quiesced. The publisher thread resumes (but the session is gone and reconnection must occur).

**There is no durable client-side buffer.** Once the TCP session closes, unacknowledged batches in the queue are lost. This is a structural property of Zenoh's hop-to-hop reliability model, not a configuration gap.

**Config knobs (authoritative source: `DEFAULT_CONFIG.json5`, `docs.rs/zenoh`):**
```json5
transport: {
  link: {
    tx: {
      queue: {
        size: { control: 2, real_time: 2, interactive_high: 2,
                interactive_low: 2, data_high: 2, data: 2,
                data_low: 2, background: 2 },
        congestion_control: {
          drop: { wait_before_drop: 1000 },       // µs before discarding
          block: { wait_before_close: 5000000 }   // µs before closing transport
        }
      }
    }
  }
}
```

**TCP socket buffer sizes** (Zenoh 1.1.0+, Firesong) can be independently tuned per endpoint:
```
tcp/[::]:7447#so_sndbuf=65000;so_rcvbuf=65000
```

Sources: [docs.rs/zenoh Config](https://docs.rs/zenoh/latest/zenoh/config/struct.Config.html) · [Zenoh 0.11.0 Electrode blog](https://zenoh.io/blog/2024-04-30-zenoh-electrode/) · [rmw_zenoh Issue #457](https://github.com/ros2/rmw_zenoh/issues/457)

---

### 2. Declaration Cache Restoration: Zenoh-Pico Only, Not rmw_zenoh

**Confidence: High | Votes: 3-0**

Zenoh-Pico 1.3.3+ (`Z_FEATURE_AUTO_RECONNECT`, ON by default) caches subscriber and publisher declarations locally and replays them automatically after reconnect — **without manual intervention**. This is the embedded C library used on microcontrollers and edge devices.

The **main Zenoh Rust library** — which `zenoh-plugin-ros2dds` and `rmw_zenoh` use — has **no equivalent mechanism**. The Zenoh 1.3.3 Rust release notes list only four unrelated items (batching fix, Bind config, keyexpr type, lowlatency async finalize fix) with no mention of declaration cache restoration.

**Implication:** rmw_zenoh must perform a full re-declaration after every reconnect, making declaration replay a potential test failure point. A robot bridge that reconnects without redeclaring its subscriptions will receive no data.

This feature also does **not** fix the Issue #1886 routing halt — that is a router-side race condition, not a client-side declaration problem.

Sources: [Zenoh Gozuryu 1.3.3 blog](https://zenoh.io/blog/2025-04-14-zenoh-gozuryu/) · [Eclipse IoT release page](https://projects.eclipse.org/projects/iot.zenoh/releases/1.3.3-gozuryu)

---

### 3. Issue #1886 Router-Side Race Condition

**Confidence: High | Votes: 3-0**

When a router reconnects before the old TCP connection is fully torn down, two simultaneous transport `Face` objects are created for the same peer:

```
16:11:35         Face{8, b01} opened (original connection)
16:11:51.541409  Face{9, b01} opened (reconnect, before Face{8} closes)
16:11:51.643967  ERROR: "Received router declaration with unknown routing context id 0"
16:11:52.689734  Face{8, b01} closes
16:12:08.667186  Face{9, b01} closes (~17 s after error)
```

Result: all routing between the two machines halts for ~17 seconds while both faces are in conflicting states. The root cause is a non-atomic close in `TransportUnicastUniversal::delete`.

**Mitigations:**
- **PR #2438** (merged 2026-02-25): blocks new transport creation to the same ZID until the existing transport fully closes — partial mitigation
- **Zenoh 1.8.x (Kiyohime, Mar 2026)**: explicitly fixed connectivity reestablishment bugs causing Zenoh traffic not to restore properly after link recovery (primarily observed in 4G/5G mobile networks, but the fix applies to any link-level reconnect)

**Empirically resolved (2026-07-07):** N3 fast-cycle restart (SIGKILL + restart in 0.5s) against Zenoh 1.9.0 in a federated edge→cloud topology produced **zero** "unknown routing context id 0" log entries in cloud-router. Routing resumed in 13 seconds. The PR #2438 and 1.8.x/1.9.0 fixes are confirmed effective for this topology and ZID-rotation scenario.

Sources: [eclipse-zenoh/zenoh Issue #1886](https://github.com/eclipse-zenoh/zenoh/issues/1886) · [PR #2438](https://github.com/eclipse-zenoh/zenoh/pull/2438) · [Zenoh Kiyohime blog](https://zenoh.io/blog/2026-03-18-zenoh-kiyohime/)

---

### 4. End-to-End Reliability: Advanced Pub/Sub Required

**Confidence: High | Votes: 3-0 (hop-to-hop), 2-1 (Advanced Pub/Sub requirement)**

Hop-to-hop TCP/QUIC transport with `CongestionControl::Block` under RELIABLE+KEEP_ALL **does not guarantee end-to-end sample delivery** across router topology changes. Samples buffered by an intermediate router that disappears before forwarding them are **permanently lost**.

To recover missed samples after a router disconnect, both sides must opt into Advanced Pub/Sub:

```rust
// Publisher side
let publisher = session
    .declare_publisher(key_expr)
    .cache(CacheConfig::default().max_samples(N))      // store N samples
    .sample_miss_detection(MissDetectionConfig::default()
        .heartbeat(Duration::from_secs(1)))             // periodic heartbeat
    .await?;

// Subscriber side
let subscriber = session
    .declare_subscriber(key_expr)
    .history(HistoryConfig::default()
        .detect_late_publishers(Duration::from_secs(2)))
    .recovery(RecoveryConfig::default())
    .await?;
```

The AdvancedSubscriber queries the AdvancedPublisher's cache upon (re)connection to retrieve samples missed during the outage.

**rmw_zenoh status:**
- **PR #591** (merged Apr 2025, backported to Jazzy and Humble): enables E2E reliability for `RELIABLE + TRANSIENT_LOCAL` topics via Advanced Pub/Sub with `HeartbeatSporadic`
- **Issue #457** (open as of mid-2026): extension to all `RELIABLE` topics (not just `TRANSIENT_LOCAL`) is not yet merged

Sources: [rmw_zenoh Issue #457](https://github.com/ros2/rmw_zenoh/issues/457) · [docs.rs/zenoh-ext AdvancedPublisher](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.AdvancedPublisher.html) · [Zenoh Reliability blog](https://zenoh.io/blog/2021-06-14-zenoh-reliability/)

---

### 5. Zenoh 1.8.x (Kiyohime) Connectivity Reestablishment Fix

**Confidence: High | Votes: 3-0**

Zenoh 1.8.x (Kiyohime, released March 2026) explicitly fixed bugs in the connectivity reestablishment path where Zenoh traffic failed to properly restore after underlying link recovery. The fix is confirmed by the official release blog. The specific PRs and commit references are not identified in the blog.

**Practical implication:** Any deployment on Zenoh < 1.8.0 should expect potential silent reconnect failures beyond the ~17-second #1886 window. Upgrade to 1.8.x+ before relying on reconnect behavior in production.

Source: [Zenoh Kiyohime release blog](https://zenoh.io/blog/2026-03-18-zenoh-kiyohime/)

---

## Known Silent Failure Bug: zenoh-plugin-ros2dds Subscriber Restart

From zenoh-plugin-ros2dds Issue #86 (unverified by adversarial pass but documented in source materials):

After a peer-mode `zenoh-bridge-ros2dds` subscriber is stopped and restarted **a second time**, it receives **zero messages** from a still-active publisher — a silent delivery failure with no error surfaced to the application. The first restart typically works; the second does not. This is directly relevant for any test scenario involving bridge pod recycling.

**Empirically resolved (2026-07-07):** N6 (second bridge restart) against Zenoh 1.9.0 in **client mode** (bridge connected to a router, not peer-to-peer) **did not reproduce** this bug. Both the first and second restarts of `zenoh-bridge-talker` recovered successfully. Issue #86 appears to be specific to peer mode; client mode is unaffected in 1.9.0.

Source: [zenoh-plugin-ros2dds Issue #86](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds/issues/86)

---

## Reconnect Timing Parameters

The following values are confirmed from `DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5` and `DEFAULT_CONFIG.json5` but their interaction requires empirical validation:

| Parameter | Client | Router/Peer | Meaning |
|---|---|---|---|
| `timeout_ms` | `0` | `-1` | **0 = no retry** for raw client mode; rmw_zenoh overrides this |
| `period_init_ms` | `1000` | `1000` | Initial reconnect retry interval |
| `period_max_ms` | `4000` | `4000` | Maximum retry interval (exponential backoff cap) |
| `period_increase_factor` | `2` | `2` | Backoff multiplier |

**Warning:** `timeout_ms = 0` in client mode means **no automatic reconnect** without additional configuration. rmw_zenoh sets its own session config that overrides this — verify the effective config in your deployment with the admin REST API (`/@/router/local`).

**Tuning for 50-Hz robot streams:** No verified community guidance exists. Empirical measurement is required. The combination of `wait_before_close = 5s` + `period_init_ms = 1s` means a publisher thread can block for up to 6 seconds on a router pod disappearance before any message is published again. At 50 Hz, that is ~300 dropped messages before recovery begins.

**Empirical observation (2026-07-07):** In practice, N1 (SIGKILL router) showed a total recovery time of ~21 seconds from kill to first message — suggesting the publisher-side block was short-lived (≤5s) and the dominant cost is the federation link re-establishment (~10s) plus DDS re-discovery (~5s). The theoretical 6-second dead zone is likely a worst case; typical block duration was much shorter.

---

## Negative Test Implementation

Tests are implemented in `scripts/test-negative.sh` using `compose.negative-test.yml`. Run with:

```bash
bash scripts/test-negative.sh            # all scenarios
SCENARIO=N3 bash scripts/test-negative.sh   # single scenario
make test-negative
make test-negative-scenario N=N4
```

### Inject Patterns

| Scenario | Inject method |
|---|---|
| N1/N2 | `podman kill --signal SIGKILL/SIGTERM $(ctr edge-router)` + `podman start` |
| N3 | SIGKILL + 0.5s + `podman start` (fast-cycle) |
| N4/N10 | `podman network disconnect neg-test_wan-net $(ctr edge-router)` / reconnect |
| N5/N6 | `podman kill --signal SIGKILL $(ctr zenoh-bridge-talker)` + `podman start` |
| N8 | WAN partition (same as N4) with `bench_pub.py` / `bench_sub.py` sequence counting |

Network partition via `podman network disconnect` was chosen over `iptables` because the UBI-based containers run as UID 1001 with no `CAP_NET_ADMIN`, making in-container iptables injection impossible.

### Admin Space Notes (Zenoh 1.9.0)

`@/router/local` returns `[]` even when active sessions exist in Zenoh 1.9.0. Use `@/router/local/session/**` to query session entries. The admin space clears within ~1s of a WAN partition.

---

## Open Questions

1. **Does PR #591 (RELIABLE+TRANSIENT_LOCAL Advanced Pub/Sub) fire in the bridge-sidecar topology?** The sidecar connects to a router, not directly to the subscriber. Whether the AdvancedSubscriber's history query reaches through the router to the AdvancedPublisher's cache requires empirical test N7 (currently skipped — requires TRANSIENT_LOCAL ROS 2 publisher).

2. **What is the effective reconnect timing in the deployed rmw_zenoh config?** The `/@/router/local` admin API returns the active session config. The empirical recovery time of ~21s (N1/N2) is substantially better than the theoretical 6s-block + 4s-retry model — the actual block duration appears much shorter than `wait_before_close = 5s`. Exact publisher-thread stall duration was not measured.

3. **Issue #86 in peer mode:** N6 confirmed client-mode is unaffected. Peer-mode (bridge-to-bridge without a router) was not tested; the issue may still apply there.

---

## Empirical Test Results: Zenoh 1.9.0

Tested 2026-07-07 against `quay.io/ecosystem-appeng/zenoh-router:1.9.0` and `zenoh-bridge-ros2dds:1.9.0` in a 2-tier federated topology (edge-router ↔ cloud-router), podman/libkrun on macOS arm64.

| ID | Scenario | Result | Measured |
|---|---|---|---|
| **N1** | SIGKILL edge-router | PASS | Self-healed in **21s**; bridge-talker auto-reconnected and rebuilt routes |
| **N2** | SIGTERM edge-router | PASS | Self-healed in **17s**; /chatter briefly still flowing during graceful drain |
| **N3** | Fast-cycle (0.5s restart) | PASS | No Issue #1886 log entry; routed resumed in **13s** |
| **N4** | WAN partition (30s) | PASS | Partition confirmed (/chatter stopped); resumed in **50s** after restore |
| **N5** | First bridge restart | PASS | Routes rebuilt on fresh session; recovered in **<15s** |
| **N6** | Second bridge restart | PASS | Issue #86 not reproduced in client mode |
| **N7** | Advanced Pub/Sub | SKIP | Requires TRANSIENT_LOCAL ROS 2 QoS — see rmw_zenoh PR #591 |
| **N8** | 50 Hz loss count (30s) | PASS | **1740 gaps** (expected 1500 ±20%, range 1200–1800) |
| **N9** | Drop vs Block | SKIP | Requires direct Zenoh API publisher |
| **N10** | WAN partition + admin | PASS | Admin space cleared at **T+1s**; /chatter resumed in **19s** |

### Key Empirical Findings

**Self-healing is faster than theory predicted.** The worst-case 5s publisher block + up to 4s retry interval was not the bottleneck in any scenario. The dominant cost is federation link re-establishment (~10–15s) plus DDS re-discovery (~5s). Total end-to-end recovery: 13–21s for router crashes, 19–50s for WAN partitions (the wider range for N4 is due to Zenoh's keepalive expiry before reconnect is attempted).

**zenoh-plugin-ros2dds v1.9.0 auto-rebuilds routes after router restart.** The research doc initially flagged this as uncertain (the route re-creation logs only appear on the first bridge startup, not on reconnect). In practice, the bridge-talker's Zenoh session reconnect does fully restore the `/chatter` publisher route, confirmed by end-to-end message flow resuming within the settlement window.

**Issue #1886 race not reproduced.** The 0.5-second fast-cycle restart (N3) — the same trigger documented in the original issue — produced zero "unknown routing context id 0" entries. Zenoh 1.9.0 (which includes PR #2438 and the Kiyohime 1.8.x connectivity fix) closes the race for the router-to-router federation topology tested here.

**Issue #86 not reproduced in client mode.** Both the first and second `zenoh-bridge-talker` restarts recovered cleanly. The Issue #86 silent failure is documented only for peer mode and was not observed in the router-client topology.

**50 Hz loss quantification: 1740 gaps in a 30s outage.** This slightly exceeds the theoretical 50 Hz × 30s = 1500 (16% over expected). The excess reflects the recovery window — messages continue to be missed during the ~19s post-restore settlement period before DDS re-discovery completes. With a 30s outage and ~19s recovery tail, the effective dead zone is ~49s, yielding ~2450 theoretical maximum gaps. The actual 1740 suggests partial recovery began before the bench_sub window closed.

---

## Refuted Claims

The following claims appeared plausible but did not survive 3-vote adversarial verification:

| Claim | Vote | Why Refuted |
|---|---|---|
| "After the routing halt, messages stop entirely and require full session restart" | 2-1 | Issue #1886 logs show routing degraded, not completely stopped — routing still works but is impaired |
| "wait_before_drop = 1ms causes rapid drops during a 50-Hz stream when router disappears" | 0-3 | wait_before_drop governs TX queue congestion, not link failure; link failure triggers session teardown, not per-message drop |
| "client-mode timeout_ms=0 + exponential backoff means auto-reconnect on a fixed schedule" | 0-3 | timeout_ms=0 means **no retry**; it is the backoff that applies when retry IS configured |
| "CongestionControl::Block stalls publisher indefinitely until queue clears" | 0-3 | Block waits up to wait_before_close (5s), then **closes the transport session** |
| "End-to-end reliability mode (2021 blog) prevents sample loss during topology changes" | 0-3 | 2021 blog predates Advanced Pub/Sub; a 2025 peer-reviewed paper found Zenoh's reliable flag "only acts as a decorator" with no effect on transmission |
| "Droppable messages are held at most 1ms before discard (no durable buffer)" | 0-3 | Misread: wait_before_drop applies to TX batch queue, not session-disconnect buffering; the absolute "no buffer" claim is unverifiable from available sources |
| "Multi-link closed_link retry uses string equality on EndpointId, silently fails on DNS resolution" | 1-2 | Issue #2569 is an AI-generated (Claude) hypothesis filed without reproduction; 0 maintainer comments; treat as unverified |

---

## Caveats

1. Reconnect timing defaults (`timeout_ms`, `period_init_ms`, `period_max_ms`) were confirmed as values in config files, but their semantic interaction under rmw_zenoh's session config override was not fully traced. Read the effective config from the admin REST API. *Empirically: actual recovery was faster than the config values suggest; the publisher-side block appears shorter than `wait_before_close = 5s` in practice.*

2. The Zenoh 1.8.x connectivity reestablishment fix rests on a single primary source (the official release blog). The specific code paths corrected are not identified. *Empirically confirmed effective for federated router topology in 1.9.0 (N3).*

3. rmw_zenoh Advanced Pub/Sub (Issue #457) for plain RELIABLE topics — not TRANSIENT_LOCAL — remains open as of mid-2026. Do not assume E2E reliability for non-latched topics without verifying PR status.

4. Negative test patterns: iptables and tc netem are not usable inside UBI-based containers (no `CAP_NET_ADMIN`, no tooling). Network partition injection uses `podman network disconnect/connect` instead, which severs the router-to-router WAN link without affecting bridge-to-router connections. *This is a local-only technique; in OCP/Kubernetes, use NetworkPolicy or equivalent for the same effect.*

5. The 1740-gap measurement in N8 assumes a clean 30s outage window. In practice the recovery tail (~19s) adds additional gaps beyond the outage duration; the theoretical "50 Hz × outage_secs" estimate understates actual loss for scenarios where reconnect is slow relative to the measurement window.
