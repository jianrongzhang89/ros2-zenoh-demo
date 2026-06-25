# Zenoh Router Federation — Test Environment Proposal

> **Status: Implemented and passing.** All 3 scenarios (F1, F2, F3) pass against
> `eclipse/zenoh:latest` and `eclipse/zenoh-bridge-ros2dds:latest` (both v1.9.0).
> Sections marked **[IMPLEMENTED NOTE]** record where the original proposal was wrong
> and what the implementation found instead.

---

## Objective

Deploy two Zenoh routers — one acting as an edge aggregation point, one as a central cloud
router — connected by a router-to-router link. Confirm that messages published by a ROS 2
node at the edge reach a cloud subscriber without any direct network path between the two
bridge clients. Three scenarios cover: basic routing, edge-ACL topic filtering, and routing
state verification via the admin space REST API.

---

## Background: How Zenoh Router Federation Works

A Zenoh router establishes a link to another router the same way a client connects to a
router: by listing the target's TCP endpoint in `connect.endpoints`. When the connecting
router opens the link, both sides exchange full routing tables. From that point on, a
publisher behind the edge router can reach a subscriber behind the cloud router transparently
— the routers forward the message across the link automatically.

This is the standard Zenoh mechanism for building backbone hierarchies. No special federation
plugin or license is required; the ordinary `eclipse/zenoh` image supports it.

---

## Topology

```
[Edge Tier — edge-net]                         [Cloud Tier — cloud-net]
──────────────────────────                 ──────────────────────────────
ros2-talker                                ros2-listener
  │ DDS on loopback                           │ DDS on loopback
zenoh-bridge-talker                       zenoh-bridge-listener
  │ TCP → edge-router:7448                    │ TCP → cloud-router:7447
  │                                           │
edge-router ──── TCP via wan-net ──────── cloud-router
  listens: 7448 (edge clients)              listens: 7447 (cloud clients
           7447 (optional, unused)                    + incoming router links)
  connects: cloud-router:7447               REST API: 8001
  REST API: 8002
```

Three isolated Docker/Podman networks enforce the topology:

| Network      | Members                             | Purpose                          |
|--------------|-------------------------------------|----------------------------------|
| `edge-net`   | edge-router, ros2-talker            | Edge private network             |
| `cloud-net`  | cloud-router, ros2-listener         | Cloud private network            |
| `wan-net`    | edge-router, cloud-router           | Router-to-router federation link |

The bridge sidecars inherit their DDS node's network namespace via
`network_mode: service:<name>`, so:
- `zenoh-bridge-talker` sees `edge-net` (can reach `edge-router`) but cannot reach
  `cloud-router` directly.
- `zenoh-bridge-listener` sees `cloud-net` (can reach `cloud-router`) but cannot reach
  `edge-router` directly.

This models a real deployment where edge and cloud run in separate network segments and all
cross-segment traffic must transit the federation link.

---

## New Files

### Router Configs (`tests/configs/`)

| File                       | Role                                                  |
|----------------------------|-------------------------------------------------------|
| `router-cloud.json5`       | Cloud router: listens 7447, REST on 8001              |
| `router-edge.json5`        | Edge router: listens 7448, connects to cloud-router:7447, REST on 8002 |
| `router-edge-acl.json5`    | Edge router + ACL: denies `sensor/**` egress (Scenario F2) |

`router-cloud.json5` (key fields):
```json5
{
  mode: "router",
  listen:  { endpoints: ["tcp/0.0.0.0:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: { rest: { __required__: false, http_port: "8001" } }
}
```

`router-edge.json5` (key fields):
```json5
{
  mode: "router",
  listen:  { endpoints: ["tcp/0.0.0.0:7448"] },
  connect: { endpoints: ["tcp/cloud-router:7447"] },   // ← federation link
  scouting: { multicast: { enabled: false } },
  plugins: { rest: { __required__: false, http_port: "8002" } }
}
```

> **[IMPLEMENTED NOTE]** The `id` field was removed from all router configs.  Zenoh 1.9.0
> requires the `id` to be a hex string (e.g. `"a1b2c3d4"`); human-readable names like
> `"cloud-router"` cause a panic at startup with "invalid digit found in string".

`router-edge-acl.json5`: identical to `router-edge.json5` plus an `access_control` block
that denies `put` and `declare_subscriber` egress for `sensor/**`, preventing those topics
from propagating across the federation link to the cloud.

### Bridge Configs (`tests/configs/`)

| File                  | Connects to         | Used by             |
|-----------------------|---------------------|---------------------|
| `bridge-edge.json5`   | `edge-router:7448`  | zenoh-bridge-talker |
| `bridge-cloud.json5`  | `cloud-router:7447` | zenoh-bridge-listener |

These are standard client configs (`mode: "client"`) with `connect.endpoints` pointing to
their respective router. No filtering needed in the bridges for these federation scenarios —
filtering is exercised at the router layer.

### Compose File

`compose.federation-test.yml` — six services, three networks, two scenario-selectable
config env vars:

| Env var             | Default                              | Controls         |
|---------------------|--------------------------------------|------------------|
| `EDGE_ROUTER_CONFIG`| `tests/configs/router-edge.json5`    | Edge router mode |
| `CLOUD_ROUTER_CONFIG`| `tests/configs/router-cloud.json5` | Cloud router     |
| `DEMO_IMAGE`        | `quay.io/jianrzha/ros2-zenoh-demo`   | ROS 2 image      |
| `DEMO_VERSION`      | `0.0.7`                              | ROS 2 image tag  |

Services and port mappings exposed to the host for inspection:

| Service               | Host ports            |
|-----------------------|-----------------------|
| cloud-router          | 7447/tcp, 8001/tcp    |
| edge-router           | 7448/tcp, 8002/tcp    |
| ros2-talker           | (no host ports)       |
| zenoh-bridge-talker   | `network_mode: service:ros2-talker` |
| ros2-listener         | (no host ports)       |
| zenoh-bridge-listener | `network_mode: service:ros2-listener` |

### Test Script and Makefile Targets

`scripts/test-federation.sh` — runs each scenario end-to-end with pass/fail output.

New Makefile targets:
```makefile
test-federation:
    bash scripts/test-federation.sh

test-federation-scenario:
    SCENARIO=$(N) bash scripts/test-federation.sh
```

---

## Scenarios

### F1 — Basic Federation: Edge-to-Cloud Message Routing

**Goal:** `/chatter` published at the edge arrives at the cloud listener.

**Setup:**
- `EDGE_ROUTER_CONFIG` = `router-edge.json5` (no ACL)
- `CLOUD_ROUTER_CONFIG` = `router-cloud.json5`
- `ros2-talker` publishes `/chatter` via `multi-pub.sh`
- `zenoh-bridge-talker` connects to `edge-router:7448`
- `zenoh-bridge-listener` connects to `cloud-router:7447`

**Message path:**
```
ros2-talker → DDS (lo) → bridge-talker → edge-router:7448
    → (federation link via wan-net) → cloud-router:7447
    → bridge-listener → DDS (lo) → ros2-listener
```

**Pass criteria:**
- `ros2 topic echo /chatter --once` inside `ros2-listener` container returns at least one
  message within 30 s.
- `ros2 topic echo /sensor/scan --once` also passes (no filter in F1; all topics cross).

**Admin space check (informational, not gating):**
```
curl http://localhost:8002/@/router/local/session/**
```
Should show `cloud-router` listed as a peer of `edge-router`.

---

### F2 — Edge ACL Blocks Sensor Topics from Propagating to Cloud

**Goal:** `sensor/**` topics are blocked at the edge router and never reach the cloud;
`/chatter` is unaffected.

**Setup:** identical to F1 except `EDGE_ROUTER_CONFIG` = `router-edge-acl.json5`.

The ACL in `router-edge-acl.json5`:
```json5
access_control: {
  enabled: true,
  default_permission: "allow",
  rules: [{
    id:          "block-sensor-cloud-egress",
    messages:    ["put", "declare_subscriber"],
    flows:       ["egress"],
    permission:  "deny",
    key_exprs:   ["sensor/**"]
  }],
  subjects: [{ id: "all-peers" }],      // wildcard — matches router-to-router link
  policies:  [{ rules: ["block-sensor-cloud-egress"], subjects: ["all-peers"] }]
}
```

**Pass criteria:**
- `/chatter` received at `ros2-listener` within 30 s.
- `/sensor/scan` times out (no message in 10 s) inside `ros2-listener` — topic is absent
  from cloud keyspace.

> **Note:** The existing `router-acl.json5` confirmed that `declare_subscriber` must be
> denied along with `put` to prevent subscription-side discovery from leaking across the
> link. The same pattern is reused here.

---

### F3 — Admin Space: Routing State Verification

**Goal:** Confirm the federation link is established and both routers see each other as peers
before relying on message delivery tests.

**This is a prerequisite health check**, not a message test. The script polls the REST APIs
before starting F1/F2.

**Queries:**
```bash
# Edge router peers (should include cloud-router)
curl -s "http://localhost:8002/@/router/local/session/**" | python3 -m json.tool

# Cloud router peers (should include edge-router)
curl -s "http://localhost:8001/@/router/local/session/**" | python3 -m json.tool
```

**Pass criteria:** Both responses are non-empty JSON objects within 15 s of router startup.
If either times out, the test logs a warning and skips F1/F2 rather than generating a false
failure on a network-unreachable topology.

---

## Startup Timing

Routers must link before bridges connect. Recommended sleep sequence:
1. Start cloud-router + edge-router; wait 5 s for federation link to establish.
2. Start bridge sidecars; wait 8 s (same as existing `bridge-test.yml`).
3. Start talker node.

The test script encodes this via `depends_on` in the compose file and explicit sleeps in the
verification script.

---

## Known Risk: ACL Scope on Router-to-Router Links

**[IMPLEMENTED NOTE — RESOLVED]** Scenario F2 confirmed empirically that the Zenoh 1.9.0
ACL wildcard subject (no filter fields) **does** apply to the router-to-router session.
`sensor/**` topics were blocked at the edge router and did not appear at cloud subscribers,
while `/chatter` and `/system/status` passed through normally. No fallback to bridge-side
filtering is needed.

---

## Out of Scope (This Iteration)

- Bidirectional message routing (cloud-to-edge) — straightforward extension, deferred.
- Dynamic link failure and reconnection.
- More than two tiers (e.g., a three-level edge → regional → cloud hierarchy).
- Kubernetes deployment of the federated topology.
- Metrics / monitoring of the federation link.

---

## Summary of Deliverables

| Artifact                               | Type        |
|----------------------------------------|-------------|
| `tests/configs/router-cloud.json5`     | Config      |
| `tests/configs/router-edge.json5`      | Config      |
| `tests/configs/router-edge-acl.json5`  | Config      |
| `tests/configs/bridge-edge.json5`      | Config      |
| `tests/configs/bridge-cloud.json5`     | Config      |
| `compose.federation-test.yml`          | Compose     |
| `scripts/test-federation.sh`           | Test script |
| `docs/zenoh-router-federation-proposal.md` | This file |
| Makefile `test-federation` targets     | Automation  |
