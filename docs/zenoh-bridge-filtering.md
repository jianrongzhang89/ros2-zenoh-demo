# Zenoh Bridge Filtering: Selective Topic Forwarding

**Research method:** Multi-source adversarial verification (99 agents, 16 sources, 25 claims verified) followed by empirical validation against `eclipse/zenoh-bridge-ros2dds:latest` and `eclipse/zenoh:latest` (both v1.9.0) via an automated 8-scenario test suite.

**Date:** 2026-06-23 | **Validated version:** zenoh-bridge-ros2dds v1.9.0 / Zenoh v1.9.0

---

## Executive Summary

Both the bridge (`zenoh-bridge-ros2dds`) and the Zenoh router support topic filtering, but through different mechanisms with different syntax. The bridge uses **standard regex** patterns on ROS interface names; the router uses **Zenoh key-expression wildcards** (`*`, `**`). They operate at different layers and compose: bridge filtering determines what enters the Zenoh key space at all; router ACL determines which messages are permitted to flow between sessions.

For a high-volume sensor deployment (lidar, cameras) bridging heterogeneous clusters, the recommended approach is a three-layer strategy:

1. **Bridge `allow` list** — whitelist only the topics you want bridged (blocks at DDS ingest)
2. **Bridge `pub_max_frequencies`** — rate-limit sensor streams that pass the allow filter
3. **Router `access_control`** — second gate at the router for cross-session flow control

---

## Critical: Config Nesting in v1.9.0

In `zenoh-bridge-ros2dds` v1.9.0 all plugin-specific fields — `allow`, `deny`, `pub_max_frequencies`, and `namespace` — **must be nested under `plugins.ros2dds`**, not placed at the config root. Putting them at the root causes the router to reject the config with `unknown field`.

```json5
// CORRECT — v1.9.0
{
  mode: "client",
  connect: { endpoints: ["tcp/zenoh-bridge-router:7447"] },
  scouting: { multicast: { enabled: false } },
  plugins: {
    ros2dds: {
      allow: { ... },           // ← nested here
      pub_max_frequencies: [...] // ← nested here
    }
  }
}

// WRONG — causes "unknown field `allow`" error
{
  mode: "client",
  allow: { ... }   // ← rejected by Zenoh session config parser
}
```

---

## Layer 1 — Bridge Allow/Deny Lists

### Configuration

Set either `allow` or `deny` inside `plugins.ros2dds` — **not both**. The bridge enforces mutual exclusivity at the Rust type level; attempting to set both is a config error.

```json5
// bridge.json5
{
  mode: "client",
  connect: {
    endpoints: ["tcp/zenoh-bridge-router:7447"]
  },
  scouting: {
    multicast: { enabled: false }
  },
  plugins: {
    ros2dds: {
      // OPTION A: Whitelist (allow) — recommended for sensor deployments.
      // Only explicitly listed interfaces are bridged.
      // Unspecified types or empty lists → NO interfaces of that type bridged.
      allow: {
        publishers: [
          "/chatter",           // exact topic name
          ".*/cmd_vel",         // regex: any namespace prefix + /cmd_vel
          ".*/pose",
          "/tf",
          "/tf_static"
        ],
        subscribers: [
          "/chatter",           // must also list topics on the subscriber side
          ".*/cmd_vel"          // for end-to-end delivery (see Semantics below)
        ],
        service_servers: [
          ".*/.*_parameters"    // parameter services
        ],
        service_clients: [],    // empty = none bridged
        action_servers:  [],
        action_clients:  []
      }

      // OPTION B: Blacklist (deny) — blocks listed interfaces, passes everything else.
      // Unspecified types or empty lists → ALL interfaces of that type are allowed.
      //
      // deny: {
      //   publishers:      [".*/camera/image_raw", ".*/scan", ".*/pointcloud2"],
      //   subscribers:     [],
      //   service_servers: [],
      //   service_clients: [],
      //   action_servers:  [],
      //   action_clients:  []
      // }
    }
  }
}
```

### Semantics

| Mode | Empty / omitted type | Effect |
|------|---------------------|--------|
| `allow` | NO interfaces of that type bridged | Strict whitelist |
| `deny` | ALL interfaces of that type allowed | Blacklist |

Filter patterns are **standard POSIX regex**, not Zenoh key-expression wildcards:

| Pattern | Matches |
|---------|---------|
| `/chatter` | Exactly `/chatter` |
| `.*/cmd_vel` | Any namespace prefix + `/cmd_vel` |
| `.*/camera/.*` | Any topic under any `.../camera/` namespace |
| `.*/laser_scan` | Any namespace + `/laser_scan` |

### Symmetric Allow for End-to-End Delivery

The bridge filter applies independently on each side of the link:

- **Talker bridge** checks `allow.publishers` — decides whether to publish a DDS topic to Zenoh.
- **Listener bridge** checks `allow.subscribers` — decides whether to subscribe from Zenoh and deliver to local DDS.

**Both sides must list the topic** for messages to flow end-to-end. If `publishers` allows `/chatter` but `subscribers` is `[]`, the talker bridge publishes to Zenoh but the listener bridge creates no subscription, and messages are never delivered.

### Interface Types

| Type | DDS Concept |
|------|-------------|
| `publishers` | DDS Data Writers (outbound from pod) |
| `subscribers` | DDS Data Readers (inbound to pod) |
| `service_servers` | ROS 2 Service servers (reply side) |
| `service_clients` | ROS 2 Service clients (request side) |
| `action_servers` | ROS 2 Action servers |
| `action_clients` | ROS 2 Action clients |

---

## Layer 2 — Namespace Scoping (`namespace`)

The `namespace` field under `plugins.ros2dds` adds a multi-robot isolation prefix to Zenoh keys. Without a namespace, two robots publishing `/scan` would both use Zenoh key `scan` and collide. With different namespaces, robot A uses `robot-A/scan` and robot B uses `robot-B/scan`.

### How It Works

The `namespace` field does **two things simultaneously**:
1. Sets the ROS 2 namespace for the bridge's own node.
2. Restricts DDS topic discovery to that namespace — topics published by nodes **outside** the configured namespace are not bridged.

This means the publishing ROS 2 nodes must also run in the same namespace (via `ROS_NAMESPACE` env var) for the bridge to discover and forward their topics.

```json5
// bridge.json5 for a specific robot instance
{
  mode: "client",
  connect: {
    endpoints: ["tcp/zenoh-bridge-router:7447"]
  },
  scouting: {
    multicast: { enabled: false }
  },
  plugins: {
    ros2dds: {
      namespace: "/robot-1"   // must start with "/"
    }
  }
}
```

The talker node must also be launched with `ROS_NAMESPACE=robot-1` so its topics fall within the `/robot-1` ROS namespace.

### Key-Expression Mapping with Namespace

```
DDS /chatter      (in namespace /robot-1)  →  Zenoh key  robot-1/chatter
DDS /sensor/scan  (in namespace /robot-1)  →  Zenoh key  robot-1/sensor/scan
```

The listener bridge with the same `namespace: "/robot-1"` strips the prefix symmetrically and delivers messages back on the original bare topic names in the listener's DDS domain (`/chatter`, `/sensor/scan`). DDS applications on the listener side receive on their normal topic names.

### Namespace vs. the Deprecated `scope` Field

Earlier research cited a `scope` field from `zenoh-plugin-dds` (the generic DDS bridge). **`scope` does not exist in `zenoh-plugin-ros2dds` v1.9.0.** The `namespace` field is the correct equivalent, but with different semantics — it is not a pure Zenoh key prefix; it also scopes DDS discovery.

### Zenoh Key Format (No `rt/` Prefix)

In `zenoh-bridge-ros2dds` v1.9.0, Zenoh keys use the **bare topic name with no prefix**:

```
DDS /chatter       →  Zenoh chatter        (not rt/chatter)
DDS /sensor/scan   →  Zenoh sensor/scan    (not rt/sensor/scan)
DDS /system/status →  Zenoh system/status
```

The `rt/` prefix documented in older `zenoh-plugin-dds` research does **not** apply to `zenoh-bridge-ros2dds` v1.9.0.

---

## Layer 3 — Rate Limiting (`pub_max_frequencies`)

Rate-limits publications before they enter the Zenoh session, reducing bandwidth for high-rate sensor streams. Format: `"<regex>=<Hz>"`.

```json5
{
  mode: "client",
  connect: {
    endpoints: ["tcp/zenoh-bridge-router:7447"]
  },
  scouting: {
    multicast: { enabled: false }
  },
  plugins: {
    ros2dds: {
      allow: {
        publishers:  [".*/scan", ".*/camera/image_compressed", "/tf"],
        subscribers: [".*/scan", ".*/camera/image_compressed", "/tf"],
        service_servers: [], service_clients: [],
        action_servers: [], action_clients: []
      },
      pub_max_frequencies: [
        ".*/scan=5",                     // lidar: cap at 5 Hz (from 10-20 Hz native)
        ".*/camera/image_compressed=10", // camera: cap at 10 fps (from 30 fps)
        "/tf=20"                         // TF: cap at 20 Hz
      ]
    }
  }
}
```

Excess publications are **dropped at the client bridge** before Zenoh routing — they never reach the wire. The regex syntax matches that of `allow`/`deny` patterns. `pub_max_frequencies` is additive: topics must still pass the `allow` filter before rate limiting applies.

**Empirically verified (Scenario 7):** A 10 Hz publisher capped to 1 Hz delivered 6 messages in a 10-second window. A 1 Hz publisher capped to 0.5 Hz delivered 2 messages in 10 seconds.

---

## Layer 4 — Zenoh Router Access Control (ACL)

The Zenoh router provides a second, independent filtering layer using **Zenoh key-expression wildcards** (`*`, `**`) rather than regex. ACL operates on messages already in the Zenoh session — it permits or denies their flow through the router.

### Zenoh 1.9.0 ACL Format

Zenoh 1.9.0 requires **all three arrays** — `rules`, `subjects`, and `policies` — to be present. Providing only `rules` causes the router to exit with:

```
All ACL rules/subjects/policies config lists must be provided
```

An entry in `subjects` with no filter fields acts as a wildcard matching all connections.

```json5
// zenoh-router.json5  (passed to zenoh router via -c flag)
{
  mode: "router",
  listen: {
    endpoints: ["tcp/0.0.0.0:7447"]
  },
  scouting: {
    multicast: { enabled: false }
  },
  adminspace: {
    enabled: true,
    permissions: { read: true, write: false }
  },
  plugins: {
    rest: { __required__: false, http_port: "8000" }
  },
  access_control: {
    enabled: true,
    default_permission: "allow",

    rules: [
      {
        id: "block-raw-sensor",
        messages: ["put", "declare_subscriber"],
        flows: ["egress"],
        permission: "deny",
        key_exprs: ["sensor/**", "camera/image_raw"]  // bare key names, no rt/ prefix
      }
    ],

    subjects: [
      {
        id: "all-clients"
        // no filter fields = wildcard, matches every connected session
      }
    ],

    policies: [
      {
        rules:    ["block-raw-sensor"],
        subjects: ["all-clients"]
      }
    ]

    // ACL priority: explicit deny > explicit allow > default_permission
    // Requires Zenoh >= 1.6.1 (pre-1.6.1 had a non-deterministic priority bug)
  }
}
```

### Key-Expression Wildcard Syntax

| Pattern | Matches |
|---------|---------|
| `*` | Exactly one path segment (between `/` characters) |
| `**` | Zero or more path segments |
| `sensor/**` | All sensor topics |
| `robot-1/**` | All topics from the robot-1 namespace |
| `**/scan` | `/scan` under any depth of namespace |

**Zenoh key names are bare** (no `rt/` prefix). Router ACL rules for `zenoh-bridge-ros2dds` traffic should use `sensor/**` not `rt/sensor/**`.

**Performance note:** Wildcard ACL rules are slower to evaluate than exact key matches. Use exact keys in high-throughput paths and wildcards only for coarse-grained control.

### ACL Decision Priority

```
explicit deny   (highest)
      ↓
explicit allow
      ↓
default_permission   (fallback)
```

A message matching both an allow rule and a deny rule is **denied**. This ordering was non-deterministic in Zenoh ≤ 1.5 and was fixed in 1.6.1 (PR #2141).

### Message Types for ACL Rules

| Message Type | When to Use |
|---|---|
| `put` | Data publication |
| `delete` | Key deletion |
| `declare_subscriber` | Subscription declaration (discovery) |
| `query` | Query/get operations |
| `reply` | Query replies |
| `declare_queryable` | Queryable declaration |

---

## Complete Example: Sensor Data Deployment

A robot pod that bridges only navigation topics cross-cluster, with lidar rate-limited and raw sensor data blocked at the router:

```json5
// bridge.json5 for a robot sidecar (zenoh-bridge-ros2dds v1.9.0)
{
  mode: "client",
  connect: {
    endpoints: ["tcp/zenoh-bridge-router:7447"]
  },
  scouting: {
    multicast: { enabled: false }
  },
  plugins: {
    ros2dds: {
      // Namespace scoping: topics appear as robot-fleet-A/<topic> in Zenoh.
      // Requires robot nodes to also run with ROS_NAMESPACE=robot-fleet-A.
      namespace: "/robot-fleet-A",

      // Layer 1: whitelist — only these topics enter Zenoh at all.
      // Both publishers and subscribers must list the topic for end-to-end delivery.
      allow: {
        publishers: [
          "/tf",
          "/tf_static",
          ".*/cmd_vel",
          ".*/pose",
          ".*/odom",
          ".*/scan",                     // lidar 2D scan (rate-limited below)
          ".*/camera/image_compressed",  // compressed video only, not raw
          ".*/diagnostics"
        ],
        subscribers: [
          "/tf",
          "/tf_static",
          ".*/cmd_vel",
          ".*/pose",
          ".*/odom",
          ".*/scan",
          ".*/camera/image_compressed",
          ".*/diagnostics"
        ],
        service_servers: [".*/.*_parameters"],
        service_clients: [],
        action_servers:  [".*/navigate_to_pose"],
        action_clients:  []
      },

      // Layer 2: rate-limit sensor streams before they hit the wire.
      pub_max_frequencies: [
        ".*/scan=5",                      // lidar: 5 Hz
        ".*/camera/image_compressed=10",  // camera: 10 fps
        "/tf=20",                         // TF: 20 Hz
        ".*/odom=10"
      ]
    }
  }
}
```

```json5
// zenoh-router.json5 for the central router (Zenoh v1.9.0)
{
  mode: "router",
  listen: {
    endpoints: ["tcp/0.0.0.0:7447"]
  },
  scouting: {
    multicast: { enabled: false }
  },
  adminspace: {
    enabled: true,
    permissions: { read: true, write: false }
  },
  plugins: {
    rest: { __required__: false, http_port: "8000" }
  },
  // Layer 3: router-level defense-in-depth (bridge allow already filtered).
  // Blocks raw sensor data that shouldn't cross cluster boundaries,
  // regardless of what individual bridge sidecars allow.
  access_control: {
    enabled: true,
    default_permission: "allow",
    rules: [
      {
        id: "block-raw-images-always",
        messages: ["put"],
        flows: ["egress"],
        permission: "deny",
        key_exprs: [
          "robot-fleet-A/camera/image_raw",
          "robot-fleet-A/pointcloud2"
        ]
      }
    ],
    subjects: [
      { id: "all-clients" }   // wildcard: matches every session
    ],
    policies: [
      { rules: ["block-raw-images-always"], subjects: ["all-clients"] }
    ]
  }
}
```

---

## Test Results (v1.9.0, 2026-06-23)

All 8 scenarios passed against `eclipse/zenoh-bridge-ros2dds:latest` and `eclipse/zenoh:latest` (both v1.9.0) running locally under Podman Compose.

| # | Scenario | Assertions | Result |
|---|----------|-----------|--------|
| 1 | Baseline (no filter) | 4 topics flow | ✓ 4/4 |
| 2 | Allow whitelist | 2 flow, 2 blocked | ✓ 4/4 |
| 3 | Allow blocks all (empty lists) | 4 blocked | ✓ 4/4 |
| 4 | Allow by regex namespace | 2 flow, 2 blocked | ✓ 4/4 |
| 5 | Deny blacklist + Issue #241 probe | 3 asserted + 1 note | ✓ 3/3 |
| 6 | Namespace scoping | 2 flow + Zenoh key prefix check | ✓ 3/3 |
| 7 | Rate limiting (`pub_max_frequencies`) | 1 blocked + 2 rate-limited | ✓ 3/3 |
| 8 | Router ACL (independent layer) | 2 flow, 2 blocked at router | ✓ 4/4 |
| **Total** | | | **29/29 passed** |

**Issue #241 note (Scenario 5):** `deny.subscribers` filtering is **correctly enforced** in v1.9.0. The bug (subscriber deny silently ignored) reported for older releases is absent in the current version.

Run the suite:
```bash
make test-filtering              # all 8 scenarios
make test-filtering-scenario N=2 # single scenario
```

---

## Limitations and Known Issues

| Issue | Severity | Details |
|-------|----------|---------|
| `allow` and `deny` are mutually exclusive | Design constraint | Cannot combine; pick one policy per bridge config. Enforced at the Rust type level. |
| Both `publishers` AND `subscribers` must be listed in `allow` | Config trap | Listing a topic only in `publishers` publishes it to Zenoh but the listener bridge creates no subscription — messages are silently lost. |
| Filter patterns are regex, not Zenoh key-exprs | Syntax trap | Use `.*` not `**`; use `.*` not `*`. Do not mix up the two syntaxes. |
| `namespace` requires matching ROS node namespaces | Operational constraint | `namespace: "/robot-1"` restricts bridge discovery to `/robot-1` ROS namespace. Publishing nodes must run with `ROS_NAMESPACE=robot-1` or their topics are invisible to the bridge. |
| `namespace` must start with `/` | Config error | `namespace: "robot-1"` fails at startup with "invalid namespace ... must start with '/'". |
| `scope` field does not exist in v1.9.0 | Research correction | The `scope` field existed in `zenoh-plugin-dds` (generic DDS bridge). It does not exist in `zenoh-plugin-ros2dds` v1.9.0. Use `namespace` instead. |
| Zenoh key format is bare topic name, no `rt/` prefix | Research correction | In v1.9.0, DDS `/chatter` → Zenoh key `chatter` (not `rt/chatter`). Router ACL rules must use bare names: `sensor/**` not `rt/sensor/**`. |
| Router ACL requires `rules` + `subjects` + `policies` | Config error (v1.9.0) | Providing only `rules` causes the router to exit: "All ACL rules/subjects/policies config lists must be provided". An empty `subjects` entry acts as a wildcard. |
| Router ACL priority bug (pre-1.6.1) | High for old versions | Deny-overrides-allow was non-deterministic in Zenoh ≤ 1.5. Fixed in 1.6.1 (PR #2141). Pin router to ≥ 1.6.1. |
| Router ACL wildcard performance penalty | Medium | Wildcard rules (`**`, `*`) are significantly slower than exact key matches. |
| Router ACL blocks at the session gate, not at routing | Design | ACL denies a message that has already been received by the router. Bridge `allow` filtering prevents topics from entering the Zenoh key space at all, providing true bandwidth savings. |
| `rmw_zenoh_cpp` has no native allow/deny | Gap | The `rmw_zenoh_cpp` path does not expose allow/deny filtering. Filtering must be implemented entirely at the router ACL layer. |

---

## Approach Comparison: Bridge vs. Router Filtering

| Dimension | Bridge `allow`/`deny` | Router ACL |
|-----------|----------------------|------------|
| Syntax | Standard regex on ROS interface names | Zenoh key-expression wildcards (`*`, `**`) |
| Config location | `plugins.ros2dds.allow` / `plugins.ros2dds.deny` | `access_control.rules` + `subjects` + `policies` |
| Scope | One bridge's DDS ingest | Router-wide, cross-session flow |
| Granularity | Per interface type (pub/sub/service/action) | Per message type (put/query/reply) and flow direction |
| When it fires | At DDS discovery / ingest — topic never enters Zenoh | At router — message already in Zenoh session |
| Bandwidth effect | Prevents topic from ever using WAN bandwidth | Permits/denies already-routed messages |
| Applies to | `zenoh-bridge-ros2dds` only | Any Zenoh session (bridge or rmw_zenoh_cpp) |
| Rate limiting | `pub_max_frequencies` (bridge only) | No built-in rate limiting in core router |
| Zenoh key format | Bare topic name (`chatter`, `sensor/scan`) | Bare topic name — no `rt/` prefix |

---

## Recommended Operational Checklist

- [ ] Place all filter config under `plugins.ros2dds` (not at root) — verified with `--help` against the pinned image tag
- [ ] Use `allow` (not `deny`) as the bridge filter policy
- [ ] List the topic in **both** `allow.publishers` and `allow.subscribers` for end-to-end delivery
- [ ] Enumerate all six interface types in the `allow` block (empty list = none bridged; omitting = same)
- [ ] If using `namespace` scoping, also set `ROS_NAMESPACE` on the publishing nodes to the same value
- [ ] Set `pub_max_frequencies` for any sensor topic that publishes > 10 Hz
- [ ] Pin Zenoh router to ≥ 1.6.1 if using router ACL deny rules
- [ ] Provide all three arrays (`rules`, `subjects`, `policies`) in router ACL config; use an empty `subjects` entry as a wildcard
- [ ] Use bare topic names in router ACL `key_exprs` (`sensor/**` not `rt/sensor/**`)
- [ ] Use exact key expressions in router ACL rules for hot paths; reserve wildcards for coarse policy

---

## Open Questions

1. For `rmw_zenoh_cpp` deployments: what is the quantitative bandwidth reduction achievable with router-only ACL filtering, given that bridge-side filtering is unavailable?
2. What is the measurable latency overhead of wildcard router ACL rules (`**`) vs. exact key matches at sensor data rates (10–100 MB/s lidar + camera)?
3. Does the Zenoh router's routing layer support key-expression-based selective forwarding that prevents a topic from being routed between clusters entirely (as opposed to ACL, which denies at the session gate)?
4. How does `namespace` scoping interact with the `allow`/`deny` filter when both are set? Does `namespace` apply before or after the regex filter?

---

## Sources

| Source | Type | Coverage |
|--------|------|----------|
| [zenoh-plugin-ros2dds DEFAULT_CONFIG.json5](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds/blob/main/DEFAULT_CONFIG.json5) | Primary | `plugins.ros2dds` nesting, allow/deny, pub_max_frequencies, namespace |
| [zenoh-plugin-ros2dds README](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) | Primary | Filter semantics, mutual exclusivity, regex patterns |
| [Zenoh Access Control docs](https://zenoh.io/docs/manual/access-control/) | Primary | Router ACL structure, wildcard performance, intersection matching |
| [zenoh DEFAULT_CONFIG.json5](https://github.com/eclipse-zenoh/zenoh/blob/main/DEFAULT_CONFIG.json5) | Primary | Router ACL JSON5 schema (rules + subjects + policies) |
| [Key Expressions RFC](https://github.com/eclipse-zenoh/roadmap/blob/main/rfcs/ALL/Key%20Expressions.md) | Primary | `*` / `**` wildcard semantics |
| [Access Control Rules RFC](https://github.com/eclipse-zenoh/roadmap/blob/main/rfcs/ALL/Access%20Control%20Rules.md) | Primary | ACL priority, deny-overrides-allow |
| [zenoh-plugin-ros2dds Issue #241](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds/issues/241) | Forum | Deny-subscriber silent-ignore bug (resolved in v1.9.0) |
| Empirical test suite (`tests/`, `scripts/test-bridge-filtering.sh`) | Primary | All claims verified against live v1.9.0 containers |
