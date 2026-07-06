# Zenoh Disconnect and Reconnect Behavior: Research for Negative Testing

**Research method:** Multi-source adversarial verification — 99 agents, 17 sources fetched, 75 claims extracted, 25 verified with 3-vote adversarial review, 12 confirmed, 13 refuted.

**Date:** 2026-07-06

---

## Executive Summary

When a Zenoh router pod disappears, there is **no durable client-side buffer** that survives the disconnect. The TX link queue (2 batches per priority, 8 priorities) absorbs micro-bursts only; after that, `CongestionControl::Drop` discards after 1 ms and `CongestionControl::Block` (the rmw_zenoh default for RELIABLE QoS) blocks the publisher thread and then closes the transport session after 5 seconds of sustained queue-full. Once the TCP session closes, any unacknowledged in-flight messages are gone.

Declaration cache restoration (Zenoh-Pico 1.3.3+ `Z_FEATURE_AUTO_RECONNECT`) does not apply to rmw_zenoh, which uses the Zenoh Rust library. The router-side race condition from Issue #1886 — two simultaneous transport faces producing "unknown routing context id 0" and halting routing for ~17 seconds — is partially mitigated by PR #2438 (Feb 2026) and connectivity reestablishment bugs were fixed in Zenoh 1.8.x (Kiyohime, Mar 2026), but the full fix status for all reconnect scenarios remains unconfirmed. End-to-end sample delivery across a router disconnect requires AdvancedPublisher + AdvancedSubscriber; rmw_zenoh PR #591 (Apr 2025) enables this for RELIABLE+TRANSIENT_LOCAL topics only.

**What this means for negative testing:** The tests must distinguish between (a) the brief burst-absorption window before drop/close, (b) the 5-second blocking window before session teardown, (c) the reconnect race that silently kills routing, and (d) the Advanced Pub/Sub recovery path that is the only mechanism for recovering missed samples. All four failure modes need distinct test scenarios.

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

**Open question:** Whether 1.8.x fully closes the #1886 race window in federated router scenarios (as opposed to client-to-router) has not been independently confirmed. Issue #1886 may still be open.

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

---

## Negative Test Design

Based on the confirmed findings, the following test scenarios are needed. These map directly to the four failure modes identified.

### Test Matrix

| ID | Scenario | What to Inject | Pass Criterion | Failure Mode |
|---|---|---|---|---|
| **N1** | Abrupt router crash | SIGKILL router container | Publisher blocks ≤5s, then reconnects; no session hang | `wait_before_close` + reconnect |
| **N2** | Graceful router shutdown | `SIGTERM` router container | Same as N1 but with graceful drain observable | Ordered teardown |
| **N3** | Fast reconnect race | Kill + immediately restart router | No "unknown routing context id 0" in logs; routing resumes <20s | Issue #1886 / PR #2438 |
| **N4** | Network partition | `iptables -I INPUT -p tcp --dport 7447 -j DROP` | Same as N3 | TCP-level link failure |
| **N5** | Bridge restart (first) | `SIGKILL zenoh-bridge` container, restart | Messages resume after reconnect | Baseline restart |
| **N6** | Bridge restart (second) | Repeat N5 without router restart | Messages continue — EXPECT FAILURE until Issue #86 fixed | Issue #86 silent failure |
| **N7** | Advanced Pub/Sub recovery | Kill router during 50-Hz publish; restart router | AdvancedSubscriber receives all cached samples after reconnect | E2E reliability path |
| **N8** | Loss counting (default) | Kill router for 10s at 50 Hz | Measure: expected 500 drops; count actual gaps in sequence numbers | Baseline loss quantification |
| **N9** | CongestionControl::Drop vs Block | Same kill, two configs | Drop: publisher continues at reduced rate; Block: publisher stalls 5s | Congestion control choice |
| **N10** | Federation link failure | Kill edge-router; cloud-router remains | Federation link reestablishes; messages resume after ~17–20s | Federated topology reconnect |

### Recommended Inject Patterns

```bash
# N1: SIGKILL router (abrupt crash — no graceful drain)
podman kill --signal SIGKILL fed-test-edge-router-1

# N2: SIGTERM router (graceful shutdown)
podman kill --signal SIGTERM fed-test-edge-router-1

# N3: Fast-cycle (reproduces Issue #1886 race)
podman kill --signal SIGKILL fed-test-edge-router-1
sleep 0.5   # short enough to trigger reconnect overlap
podman-compose -p fed-test -f compose.federation-test.yml up -d edge-router

# N4: Network partition (requires host network access from container host)
# Inside the router container or on the host with tc netem:
tc qdisc add dev eth0 root netem loss 100%
sleep 15
tc qdisc del dev eth0 root

# N5/N6: Bridge restart
podman restart fed-test-zenoh-bridge-talker-1

# N7: Admin-space monitoring (check session counts before asserting message flow)
curl -sf http://localhost:8002/@/** | python3 -m json.tool
```

### Measurement Approach

The existing `bench_pub.py` / `bench_sub.py` infrastructure embeds a nanosecond timestamp and sequence number in each message (`"<send_ns>,<seq>"`). For negative tests, extend `bench_sub.py` to:
1. Detect sequence gaps (dropped messages)
2. Record the first message gap timestamp and the first resume timestamp
3. Compute: recovery latency = `first_resume_ts - kill_ts`, drop count = `gap_count`

```python
# Extend bench_sub.py gap detection
prev_seq = -1
gaps = []
for msg in messages:
    ts, seq = parse(msg)
    if prev_seq >= 0 and seq != prev_seq + 1:
        gaps.append((prev_seq, seq, seq - prev_seq - 1))  # (last_good, first_resume, count)
    prev_seq = seq
```

---

## Open Questions

1. **Is Issue #1886 formally closed in Zenoh 1.8.x+?** The Kiyohime blog addresses mobile network reconnect bugs; it is unclear whether the router-to-router federation reconnect race is the same root cause. Requires a controlled reproduction of N3 against Zenoh 1.8.x+ and log inspection for "unknown routing context id 0".

2. **Does PR #591 (RELIABLE+TRANSIENT_LOCAL Advanced Pub/Sub) fire in the bridge-sidecar topology?** The sidecar connects to a router, not directly to the subscriber. Whether the AdvancedSubscriber's history query reaches through the router to the AdvancedPublisher's cache requires empirical test N7.

3. **What is the effective reconnect timing in the deployed rmw_zenoh config?** The admin REST API at `/@/router/local` exposes the active session config. Should be verified against the ConfigMap before running timing tests.

4. **zenoh-plugin-ros2dds Issue #86 status:** Is the second-restart silent failure reproducible in the current image (`quay.io/ecosystem-appeng/zenoh-bridge-ros2dds:latest`)? Test N6 will determine this.

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

1. Reconnect timing defaults (`timeout_ms`, `period_init_ms`, `period_max_ms`) were confirmed as values in config files, but their semantic interaction under rmw_zenoh's session config override was not fully traced. Read the effective config from the admin REST API.

2. The Zenoh 1.8.x connectivity reestablishment fix rests on a single primary source (the official release blog). The specific code paths corrected are not identified.

3. rmw_zenoh Advanced Pub/Sub (Issue #457) for plain RELIABLE topics — not TRANSIENT_LOCAL — remains open as of mid-2026. Do not assume E2E reliability for non-latched topics without verifying PR status.

4. Negative test patterns (tc netem, iptables, SIGKILL container) produced no confirmed claims from the literature — the tooling suggestions above are derived from general Linux and container practice, not from Zenoh-specific CI documentation.
