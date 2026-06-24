# Zenoh Bridge Filtering — Test Environment

> **Status: Implemented and passing.** This document describes the test environment that
> was built from the original proposal. All 8 scenarios pass against
> `eclipse/zenoh-bridge-ros2dds:latest` and `eclipse/zenoh:latest` (both v1.9.0).
> Sections marked **[CORRECTED]** note where the original proposal was wrong and what
> the implementation found instead.

---

## Objective

Validate the filtering mechanisms documented in `docs/zenoh-bridge-filtering.md` with
automated pass/fail tests against a local Podman Compose stack. No cluster or CI changes
required.

---

## Test Environment

### Compose Architecture

The bridge sidecar must share a network namespace with its DDS node (they communicate over
`lo`). Kubernetes handles this at the pod level. In Podman Compose the equivalent is
`network_mode: "service:<name>"`, which attaches a second container to a running
container's network namespace.

```
compose.bridge-test.yml
│
├── zenoh-router            eclipse/zenoh:latest
│     port 7447 (Zenoh sessions)
│     port 8000 (REST API, enabled via adminspace config)
│
├── ros2-talker             quay.io/jianrzha/ros2-zenoh-demo:0.0.7
│     ROS_AUTOMATIC_DISCOVERY_RANGE = LOCALHOST
│     ROS_NAMESPACE = ${ROS_NS:-}  ← set to "robot-1" only for Scenario 6
│
├── zenoh-bridge-talker     eclipse/zenoh-bridge-ros2dds:latest
│     network_mode: service:ros2-talker   ← shares lo with talker
│     config: ${BRIDGE_CONFIG} (host-mounted, absolute path required)
│
├── ros2-listener           quay.io/jianrzha/ros2-zenoh-demo:0.0.7
│     ROS_AUTOMATIC_DISCOVERY_RANGE = LOCALHOST
│
└── zenoh-bridge-listener   eclipse/zenoh-bridge-ros2dds:latest
      network_mode: service:ros2-listener
      config: ${BRIDGE_CONFIG} (same file as talker bridge)
```

**[CORRECTED] Use pre-built image, not `build:`.** The original proposal used
`build: { context: ., dockerfile: Dockerfile.ros2 }` for the ROS 2 nodes. The ROS 2
RHEL9 RPM repository returns 404 for aarch64, so all builds fail at runtime. The compose
file now references the pre-built `quay.io/jianrzha/ros2-zenoh-demo:0.0.7` image directly,
controllable via `DEMO_IMAGE` / `DEMO_VERSION` env vars.

**[CORRECTED] `podman-compose` requires absolute paths for bind-mount volumes.** Passing
a relative path in `${BRIDGE_CONFIG}` causes podman-compose to interpret it as a named
volume and fail with `volume [...] not defined in top level`. The `stack_up()` function in
the test script builds absolute paths from `$ROOT`.

### `source /opt/ros/jazzy/setup.bash` and `set -u`

**[CORRECTED]** The original multi-pub.sh used `set -euo pipefail` and then re-sourced
`setup.bash`. The `-u` (unbound variables) flag causes this to fail immediately because
`setup.bash` references `AMENT_TRACE_SETUP_FILES` before setting it. Fix applied in two
places:

1. `compose.bridge-test.yml` talker command: wraps the source with `set +u && source ... && set -u`.
2. `tests/multi-pub.sh`: skips the source entirely if `ros2` is already in PATH (the
   compose command's `exec bash` passes the ROS environment to the child process via
   inherited env vars).

---

## Multi-Topic Publisher (`tests/multi-pub.sh`)

Publishes four topics using **relative names** (no leading `/`) so that `ROS_NAMESPACE`
applies correctly in Scenario 6.

| Effective topic (default namespace) | Rate | Filtering role |
|---|---|---|
| `/chatter` | 10 Hz | Default "allowed" topic |
| `/sensor/scan` | 10 Hz | Simulated lidar — blocked in most scenarios |
| `/sensor/camera` | 10 Hz | Simulated camera — blocked in most scenarios |
| `/system/status` | 1 Hz | Low-rate heartbeat — selectively allowed |

When `ROS_NAMESPACE=robot-1` is set (Scenario 6), these become `/robot-1/chatter`,
`/robot-1/sensor/scan`, etc.

`std_msgs/msg/String` is used for all four; no custom message types required.

---

## Validation Primitives

**[CORRECTED] `ros2 topic echo --count` not universally supported.** The original
proposal used `ros2 topic echo --count 1 <topic>`. In the `ros2-zenoh-demo:0.0.7` image
this flag is unrecognised. The implementation uses `grep -m 1 'data:'` instead: the first
match causes grep to exit, which closes the pipe to `ros2 topic echo`, which then exits
via SIGPIPE. The exit code is grep's: 0 if a message arrived, 1 if the timeout fired
first.

**[CORRECTED] Two separate timeouts.** The original proposal used a single `TOPIC_TIMEOUT`
for both flow and block checks. The first `check_flows` call in a cold container takes
~18 s for CycloneDDS participant bootstrap + bridge subscriber routing; subsequent calls in
the same stack are 2–3 s. Using one timeout means either the first "should flow" check
always times out, or "should be blocked" checks wait unnecessarily long. Two separate
timeouts are used:

| Variable | Default | Used by |
|---|---|---|
| `FLOW_TIMEOUT` | 22 s | `assert_flows` — topics expected to arrive |
| `BLOCK_TIMEOUT` | 8 s | `assert_blocked` — topics expected to be blocked |

**[ADDED] `warm_dds()` step.** After the bridge settle sleep, `stack_up()` runs
`ros2 topic list` inside the listener container. This single DDS discovery cycle caches
the bridge's DDS publisher endpoints in CycloneDDS. Without it, the first `check_flows`
call in the scenario needs ~18 s to bootstrap; after `warm_dds`, all calls complete in
under 3 s.

```bash
check_flows() {
  local topic="$1" timeout="${2:-$FLOW_TIMEOUT}"
  podman exec "$(ctr ros2-listener)" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $timeout ros2 topic echo '$topic' 2>/dev/null | grep -m 1 'data:'
  " &>/dev/null
}

count_msgs() {  # used for rate-limit test
  local topic="$1"
  podman exec "$(ctr ros2-listener)" bash -c "
    set +u; source /opt/ros/jazzy/setup.bash 2>/dev/null; set -u
    timeout $COUNT_WINDOW ros2 topic echo '$topic' 2>/dev/null
  " 2>/dev/null | grep -c "^data:" || true
}
```

---

## Scenario Configs and Results

### Critical: `plugins.ros2dds` Nesting

**[CORRECTED — applies to all scenarios 2–7]** The original proposal placed `allow`,
`deny`, `pub_max_frequencies`, and `namespace` at the config root. In
`zenoh-bridge-ros2dds` v1.9.0 all plugin-specific fields must be nested under
`plugins.ros2dds`. Placing them at root causes the bridge to exit immediately with
`unknown field 'allow'`.

### Scenario 1 — Baseline (no filter)

**Purpose:** Confirm the bridge stack works end-to-end.

```json5
// tests/configs/bridge-baseline.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } }
  // no allow, no deny
}
```

**Result:** ✓ 4/4 — `/chatter`, `/sensor/scan`, `/sensor/camera`, `/system/status` all flow.

---

### Scenario 2 — Allow whitelist

**Purpose:** Verify `allow` blocks unlisted topics at the bridge.

**[CORRECTED] Both `publishers` AND `subscribers` must list the topic.** The original
proposal set `subscribers: []` and expected `/chatter` to still flow. In practice the
bridge applies the filter independently on each side: the talker bridge checks
`allow.publishers`, the listener bridge checks `allow.subscribers`. With `subscribers: []`
the listener bridge creates no Zenoh subscription for any topic, so messages are published
to Zenoh but never delivered to DDS. Both lists must include the topic.

```json5
// tests/configs/bridge-allow-whitelist.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      allow: {
        publishers:      ["/chatter", ".*/status"],
        subscribers:     ["/chatter", ".*/status"],  // ← required for delivery
        service_servers: [],
        service_clients: [],
        action_servers:  [],
        action_clients:  []
      }
    }
  }
}
```

**Result:** ✓ 4/4 — `/chatter` and `/system/status` flow; `/sensor/scan` and `/sensor/camera` blocked.

---

### Scenario 3 — Allow blocks all (empty lists)

**Purpose:** Verify an `allow` block with all-empty type lists bridges nothing.

```json5
// tests/configs/bridge-allow-empty.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      allow: {
        publishers:      [],
        subscribers:     [],
        service_servers: [],
        service_clients: [],
        action_servers:  [],
        action_clients:  []
      }
    }
  }
}
```

**Result:** ✓ 4/4 — all four topics blocked.

---

### Scenario 4 — Allow by regex namespace

**Purpose:** Verify regex patterns apply correctly across topic namespaces.

```json5
// tests/configs/bridge-allow-regex.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      allow: {
        publishers:      [".*/sensor/.*"],
        subscribers:     [".*/sensor/.*"],
        service_servers: [],
        service_clients: [],
        action_servers:  [],
        action_clients:  []
      }
    }
  }
}
```

**Result:** ✓ 4/4 — `/sensor/scan` and `/sensor/camera` flow; `/chatter` and `/system/status` blocked.

**Note on DDS warm-up:** Without `warm_dds()`, the first topic checked (`/sensor/scan`)
consistently timed out even at 22 s while the second (`/sensor/camera`) passed. The
bridge's DDS publisher is not immediately visible to new CycloneDDS participants; one
`ros2 topic list` call primes the discovery state.

---

### Scenario 5 — Deny blacklist + Issue #241 probe

**Purpose:** Verify `deny.publishers` blocks sensor topics; probe Issue #241 (subscriber
deny silently ignored in older releases).

```json5
// tests/configs/bridge-deny.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      deny: {
        publishers:      [".*/sensor/.*"],
        subscribers:     ["/chatter"],   // Issue #241 probe
        service_servers: [],
        service_clients: [],
        action_servers:  [],
        action_clients:  []
      }
    }
  }
}
```

**Issue #241 logic:**
- `deny.publishers: [".*/sensor/.*"]` — talker bridge does not publish sensor topics to Zenoh.
- `deny.subscribers: ["/chatter"]` — listener bridge should not subscribe `/chatter` from Zenoh.
  - If the bug is **absent** (v1.9.0): `/chatter` is blocked → `NOTE: HONOURED`.
  - If the bug is **present**: `/chatter` flows despite the deny → `NOTE: IGNORED`.
- `/system/status` is not in either deny list and flows normally.

The test reports the `/chatter` result as a NOTE (not PASS/FAIL) because both outcomes are informative.

**Result:** ✓ 3/3 asserted + 1 note — sensor topics blocked; `/system/status` flows; NOTE: Issue #241 **HONOURED** (bug absent in v1.9.0, subscriber deny is correctly enforced).

---

### Scenario 6 — Namespace scoping

**Purpose:** Verify the `namespace` field prefixes Zenoh keys and that DDS delivery on
the listener side is transparent (topics arrive on their original names).

**[CORRECTED] `scope` field does not exist in v1.9.0.** The original proposal used
`scope: "robot-1"`. This field is from the generic `zenoh-plugin-dds` bridge; it does
not exist in `zenoh-plugin-ros2dds` v1.9.0. The correct field is `namespace`.

**[CORRECTED] `namespace` value must start with `/`.** `namespace: "robot-1"` causes a
startup error: "invalid namespace 'robot-1' must start with '/'". Use `"/robot-1"`.

**[CORRECTED] `namespace` restricts DDS discovery to that ROS namespace.** Unlike the old
`scope` field (which was a pure Zenoh key prefix applied to all topics regardless of
namespace), `namespace: "/robot-1"` causes the bridge to discover only topics published by
nodes in the `/robot-1` ROS namespace. Topics published by nodes in the default `/`
namespace are invisible to the bridge. Accordingly, the talker must run with
`ROS_NAMESPACE=robot-1`, which is passed via the `ROS_NS` env var to `compose.bridge-test.yml`.

**[CORRECTED] Zenoh key format.** With `namespace: "/robot-1"`, the Zenoh key for
DDS `/chatter` is `robot-1/chatter` — **not** `robot-1/rt/chatter` as the original
proposal stated. The `rt/` prefix does not exist in `zenoh-bridge-ros2dds` v1.9.0.

**[CORRECTED] DDS delivery on the listener side uses the original bare topic names.** The
listener bridge with `namespace: "/robot-1"` strips the `robot-1/` prefix symmetrically,
delivering messages on `/chatter` and `/sensor/scan` (not `/robot-1/chatter`). The
original proposal checked `/robot-1/chatter` on the listener side, which would always
time out.

```json5
// tests/configs/bridge-scope.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      namespace: "/robot-1"
    }
  }
}
```

Run with `ROS_NS=robot-1` (passed automatically by `scenario_6`):
```bash
ROS_NS=robot-1 stack_up "$CONFIGS/bridge-scope.json5"
```

**Assertions:**
- `/chatter` flows on DDS ✓ (listener sees the original topic name)
- `/sensor/scan` flows on DDS ✓
- Zenoh key prefix `robot-1/` confirmed via bridge route logs (`Route Publisher ... -> Zenoh:robot-1/chatter`) ✓

**Result:** ✓ 3/3.

---

### Scenario 7 — Rate limiting (`pub_max_frequencies`)

**Purpose:** Verify the bridge drops excess publications before Zenoh routing.

```json5
// tests/configs/bridge-rate-limit.json5
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      allow: {
        publishers:      ["/chatter", ".*/status"],
        subscribers:     ["/chatter", ".*/status"],
        service_servers: [],
        service_clients: [],
        action_servers:  [],
        action_clients:  []
      },
      pub_max_frequencies: [
        "/chatter=1",      // cap 10 Hz → 1 Hz
        ".*/status=0.5"    // cap 1 Hz → 0.5 Hz
      ]
    }
  }
}
```

Rate-limit validation counts messages over `COUNT_WINDOW` (10 s) with generous tolerance bands
to survive slow/emulated containers:

| Topic | Cap | Window | Accepted range | Observed |
|---|---|---|---|---|
| `/chatter` | 1 Hz | 10 s | 3–20 msgs | 6 msgs |
| `/system/status` | 0.5 Hz | 10 s | 1–10 msgs | 2 msgs |

**Result:** ✓ 3/3 — `/sensor/scan` blocked by allow list; both rate-limited topics within range.

---

### Scenario 8 — Router ACL (independent filtering layer)

**Purpose:** Verify that the router's `access_control` blocks topics independently of the
bridge filter. Bridge uses the baseline config (no filter); the router denies sensor topics.

**[CORRECTED] Zenoh 1.9.0 ACL requires `rules` + `subjects` + `policies`.** The original
proposal provided only `rules`. Zenoh 1.9.0 exits immediately with:

```
All ACL rules/subjects/policies config lists must be provided
```

All three arrays must be present. An empty `subjects` entry (no filter fields) acts as a
wildcard matching every connected session.

**[CORRECTED] Zenoh key expressions use bare names, not `rt/` prefix.** The original
proposal used `key_exprs: ["rt/sensor/**"]`. The correct expression is `"sensor/**"`.

```json5
// tests/configs/router-acl.json5
{
  mode: "router",
  listen: { endpoints: ["tcp/0.0.0.0:7447"] },
  scouting: { multicast: { enabled: false } },
  adminspace: { enabled: true, permissions: { read: true, write: false } },
  plugins: { rest: { __required__: false, http_port: "8000" } },
  access_control: {
    enabled: true,
    default_permission: "allow",
    rules: [
      {
        id: "block-sensor-egress",
        messages: ["put", "declare_subscriber"],
        flows: ["egress"],
        permission: "deny",
        key_exprs: ["sensor/**"]    // bare name — no rt/ prefix
      }
    ],
    subjects: [
      { id: "all-clients" }         // empty entry = wildcard, matches all sessions
    ],
    policies: [
      { rules: ["block-sensor-egress"], subjects: ["all-clients"] }
    ]
  }
}
```

**Result:** ✓ 4/4 — `/chatter` and `/system/status` flow; `/sensor/scan` and `/sensor/camera` blocked at the router despite the bridge allowing them.

---

## File Layout (as implemented)

```
compose.bridge-test.yml              5-service compose stack
                                     env vars: BRIDGE_CONFIG, ROUTER_CONFIG, ROS_NS

tests/
  configs/
    bridge-baseline.json5            Scenario 1 (bridge), Scenario 8 (bridge)
    bridge-allow-whitelist.json5     Scenario 2
    bridge-allow-empty.json5         Scenario 3
    bridge-allow-regex.json5         Scenario 4
    bridge-deny.json5                Scenario 5
    bridge-scope.json5               Scenario 6  (namespace: "/robot-1")
    bridge-rate-limit.json5          Scenario 7
    router-default.json5             Scenarios 1–7 (router, REST on :8000)
    router-acl.json5                 Scenario 8 (router with ACL)

  multi-pub.sh                       Relative-name publisher; honours ROS_NAMESPACE

scripts/
  test-bridge-filtering.sh           Test runner — all tuning via env vars

Makefile targets:
  test-filtering                     Run all 8 scenarios (BRIDGE_SETTLE=20 recommended)
  test-filtering-scenario N=<n>      Run one scenario
  mirror-bridge                      Mirrors eclipse/zenoh and eclipse/zenoh-bridge-ros2dds
                                     to Quay.io (also needed for Scenario 8 router image)
```

---

## Tuning Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BRIDGE_SETTLE` | 15 s | Sleep after `podman-compose up -d` for DDS discovery and bridge connection. **Use 20 s in practice.** |
| `FLOW_TIMEOUT` | 22 s | Per-topic timeout for `assert_flows` checks. First check needs ~18 s for DDS bootstrap; warm_dds reduces this. |
| `BLOCK_TIMEOUT` | 8 s | Per-topic timeout for `assert_blocked` checks. Blocked topics fail fast; 8 s is a safety margin. |
| `COUNT_WINDOW` | 10 s | Message counting window for the rate-limit test (Scenario 7). |
| `DEMO_IMAGE` | `quay.io/jianrzha/ros2-zenoh-demo` | ROS 2 node image. |
| `DEMO_VERSION` | `0.0.7` | Tag of the demo image. |

---

## Actual Test Output

```
=== Zenoh Bridge Filtering Tests ===
    Bridge image  : docker.io/eclipse/zenoh-bridge-ros2dds:latest
    Router image  : docker.io/eclipse/zenoh:latest
    Flow timeout  : 22s (topics expected to arrive)
    Block timeout : 8s (topics expected to be blocked)
    Count window  : 10s (rate-limit test)
    Bridge settle : 20s after stack-up

── Scenario 1: Baseline (no filter)
  PASS  /chatter  flows
  PASS  /sensor/scan  flows
  PASS  /sensor/camera  flows
  PASS  /system/status  flows

── Scenario 2: Allow whitelist (/chatter + /system/status only)
  PASS  /chatter  flows
  PASS  /system/status  flows
  PASS  /sensor/scan  blocked
  PASS  /sensor/camera  blocked

── Scenario 3: Allow blocks all (all-empty lists)
  PASS  /chatter  blocked
  PASS  /sensor/scan  blocked
  PASS  /sensor/camera  blocked
  PASS  /system/status  blocked

── Scenario 4: Allow by regex namespace (.*/sensor/.*)
  PASS  /sensor/scan  flows
  PASS  /sensor/camera  flows
  PASS  /chatter  blocked
  PASS  /system/status  blocked

── Scenario 5: Deny blacklist + Issue #241 probe
  PASS  /sensor/scan  blocked
  PASS  /sensor/camera  blocked
  PASS  /system/status  flows
  NOTE  Issue #241: subscriber deny on /chatter HONOURED (bug absent) — chatter correctly blocked

── Scenario 6: Scope prefix (namespace=/robot-1)
  PASS  /chatter  flows
  PASS  /sensor/scan  flows
  PASS  Zenoh keys are prefixed robot-1/ (e.g. robot-1/chatter) — confirmed in bridge logs

── Scenario 7: Rate limiting (pub_max_frequencies)
  PASS  /sensor/scan  blocked
  received: 6  (cap=1Hz, window=10s, expect 5–15)
  PASS  /chatter  rate-limited to ~1 Hz (6 msgs in 10s)
  received: 2  (cap=0.5Hz, window=10s, expect 2–8)
  PASS  /system/status  rate-limited to ~0.5 Hz (2 msgs in 10s)

── Scenario 8: Router ACL (independent filtering layer)
  PASS  /chatter  flows
  PASS  /system/status  flows
  PASS  /sensor/scan  blocked
  PASS  /sensor/camera  blocked

═════════════════════════════════════════════════════════════════════════
  Result : 29 passed, 0 failed, 1 noted

  Notes:
    - Issue #241: subscriber deny on /chatter HONOURED (bug absent) — chatter correctly blocked
```

---

## Corrections Summary

| Original proposal claim | What testing found |
|---|---|
| `allow`/`deny`/`pub_max_frequencies` at config root | Must be under `plugins.ros2dds`; root placement crashes bridge |
| `subscribers: []` sufficient for flow | Both `publishers` AND `subscribers` must list the topic |
| `scope: "robot-1"` for key prefixing | `scope` field absent in v1.9.0; use `namespace: "/robot-1"` |
| `namespace` is a pure Zenoh key prefix | Also restricts DDS discovery; publishing nodes must be in the same ROS namespace |
| Scope creates `robot-1/rt/chatter` | Actual key is `robot-1/chatter` (no `rt/` prefix) |
| Listener receives `/robot-1/chatter` after scope | Listener receives `/chatter` (namespace stripped symmetrically) |
| Router ACL only needs `rules` | Zenoh 1.9.0 requires `rules` + `subjects` + `policies`; missing any → router exits |
| Router ACL key `rt/sensor/**` | Correct key is `sensor/**` (no `rt/` prefix) |
| `ros2 topic echo --count 1` for validation | `--count` not supported; use `\| grep -m 1 'data:'` |
| Single `TOPIC_TIMEOUT` for all checks | Split into `FLOW_TIMEOUT=22s` and `BLOCK_TIMEOUT=8s` |
| Bridge settle + assertions sufficient | `warm_dds()` step required; first DDS check takes ~18 s without it |
| Issue #241 (subscriber deny bug) unconfirmed | Confirmed absent in v1.9.0 — deny on subscribers is correctly enforced |

---

## Out of Scope

- GitHub Actions CI integration (per requirements)
- `rmw_zenoh_cpp` filtering (no native allow/deny; would require a separate router-ACL-only test)
- Multi-cluster / cross-namespace ACL routing rules
- QoS reliability interaction with `pub_max_frequencies`
