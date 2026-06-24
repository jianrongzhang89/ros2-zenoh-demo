# ROS 2 + Zenoh Demo

Two complementary approaches to running ROS 2 across pod boundaries on OpenShift using Zenoh as the transport layer:

| Approach | RMW | Use Case |
|----------|-----|----------|
| **rmw_zenoh_cpp** | Zenoh is the RMW | Greenfield: replace DDS entirely |
| **zenoh-bridge-ros2dds** | Standard DDS + bridge sidecar | Brownfield: keep existing DDS nodes, add cross-cluster reach |

---

## Approach 1 — rmw_zenoh_cpp (Zenoh as RMW)

ROS 2 nodes run with `rmw_zenoh_cpp` as the RMW layer. Zenoh handles discovery and transport directly; there is no DDS on the wire.

### Architecture

Talker and listener run in `mode: "client"` and connect to the router. All messages flow through the router:

```
ros2-talker ──TCP──► zenoh-router:7447 ──TCP──► ros2-listener
```

| Component | Role |
|-----------|------|
| `zenoh-router` | Runs `rmw_zenohd`, the ROS 2 Zenoh router on port 7447 |
| `ros2-talker` | Publishes `Hello World` messages on `/chatter` |
| `ros2-listener` | Subscribes to `/chatter` and prints received messages |

---

## Approach 2 — zenoh-bridge-ros2dds (Bridge Sidecar)

ROS 2 nodes use the default DDS RMW (`rmw_fastrtps_cpp`) with `ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST` so DDS stays pod-local. A `zenoh-bridge-ros2dds` sidecar in each pod forwards DDS traffic through a central Zenoh router.

### Architecture

```
  Pod: ros2-dds-talker               Pod: ros2-dds-listener
  ┌──────────────────────────┐       ┌──────────────────────────┐
  │  ros2-talker  (DDS/shm)  │       │  ros2-listener (DDS/shm) │
  │       ↕  localhost DDS   │       │       ↕  localhost DDS   │
  │  zenoh-bridge (client)   │       │  zenoh-bridge (client)   │
  └──────────┬───────────────┘       └───────────┬──────────────┘
             │ TCP :7447                          │ TCP :7447
             └──────────┬─────────────────────────┘
                        ▼
              Pod: zenoh-bridge-router
              ┌──────────────────────┐
              │  eclipse/zenoh       │
              │  (plain Zenoh router)│
              └──────────────────────┘
```

| Component | Image | Role |
|-----------|-------|------|
| `zenoh-bridge-router` | `eclipse/zenoh` | Plain Zenoh routing daemon; no DDS |
| `ros2-dds-talker` (2-container pod) | `ros2-zenoh-demo` + `eclipse/zenoh-bridge-ros2dds` | Talker node (DDS) + bridge sidecar |
| `ros2-dds-listener` (2-container pod) | `ros2-zenoh-demo` + `eclipse/zenoh-bridge-ros2dds` | Listener node (DDS) + bridge sidecar |

The bridge sidecar reads `bridge.json5` from the `bridge-zenoh-config` ConfigMap, runs in Zenoh `client` mode, and connects to `zenoh-bridge-router:7447`.

---

## Local: Mac M2 / Podman

### Prerequisites

- **Podman** 5.x with a running machine (`podman machine start`)
- **podman-compose** (`brew install podman-compose`)

### Quick Start (Approach 1)

```bash
# First run: build the image (~5 min to pull and install packages)
podman compose up --build

# Subsequent runs
podman compose up
```

You should see:

```
ros2-talker   | [talker]: Publishing: 'Hello World: 1'
ros2-talker   | [talker]: Publishing: 'Hello World: 2'
ros2-listener | [listener]: I heard: [Hello World: 1]
ros2-listener | [listener]: I heard: [Hello World: 2]
```

Stop with `Ctrl+C`, then `podman compose down`.

### Inspecting the Demo

```bash
# Check running containers
podman ps

# List ROS 2 topics visible from the listener
podman exec -it ros2-zenoh_ros2-listener_1 bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic list"

# Echo the chatter topic live
podman exec -it ros2-zenoh_ros2-talker_1 bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic echo /chatter"
```

---

## OpenShift Deployment — Approach 1 (rmw_zenoh_cpp)

### Prerequisites

- `oc` / `kubectl` logged in to an OpenShift cluster
- `podman` with a Quay.io login (`podman login quay.io`)
- Python 3 (for `make test` latency calculation)

### Namespace Architecture

```
              Namespace: ros2-zenoh
┌──────────────────────────────────────────────────────┐
│                                                      │
│  ┌──────────────────┐   ClusterIP Service            │
│  │   zenoh-router   │◄──  zenoh-router:7447          │
│  │   (rmw_zenohd)   │                                │
│  └──────────────────┘                                │
│          ▲                    ▲                      │
│          │ TCP                │ TCP                  │
│  ┌───────┴──────┐   ┌────────┴──────┐               │
│  │ ros2-talker  │   │ ros2-listener │               │
│  └──────────────┘   └───────────────┘               │
└──────────────────────────────────────────────────────┘
```

The Zenoh client config (`zenoh-client.json5`) is stored in a ConfigMap and mounted into the talker and listener pods. The router's hostname resolves via the `zenoh-router` ClusterIP Service.

### Files

```
k8s/
├── namespace.yaml                # ros2-zenoh namespace
├── configmap-zenoh-client.yaml   # Zenoh client config (mode: client)
├── service-zenoh-router.yaml     # ClusterIP on port 7447
├── deployment-zenoh-router.yaml  # rmw_zenohd router
├── deployment-ros2-talker.yaml   # talker + wait-for-router init container
└── deployment-ros2-listener.yaml # listener + wait-for-router init container
```

### Build and Push

```bash
make build push VERSION=0.0.2
```

### Deploy

```bash
make deploy VERSION=0.0.2
```

The `deploy` target substitutes `IMAGE:latest` with `IMAGE:VERSION` in each manifest at apply time, so the static YAML files always carry `:latest` as a placeholder.

### Verify

```bash
make test VERSION=0.0.2 NAMESPACE=ros2-zenoh
```

`scripts/verify.sh` checks:
1. All three pods are `1/1 Ready`
2. Messages are flowing from talker to listener (sequence number cross-check)
3. End-to-end latency (publish → receive, typically ~0.5 ms)

Example output:

```
=== ROS2 + Zenoh Communication Verification ===
    Namespace : ros2-zenoh

── Pod Readiness ────────────────────────────────────────────────────────
  PASS  zenoh-router  (1/1 Ready)
  PASS  ros2-talker  (1/1 Ready)
  PASS  ros2-listener  (1/1 Ready)

── Message Flow ─────────────────────────────────────────────────────────
    Talker    messages sampled : 60
    Listener  messages sampled : 60
    Delivered (talker∩listener): 60
    Dropped   (in talker only) : 0

── End-to-End Latency (publish → receive) ───────────────────────────────
    Samples : 60
    Average : 0.53 ms
    Min     : 0.44 ms
    Max     : 0.86 ms
  PASS  Messages flowing  talker → zenoh-router → listener
  PASS  No drops in 60-line sample

═════════════════════════════════════════════════════════════════════════
  Result : 5 passed, 0 failed
```

### Live Demo

```bash
make demo NAMESPACE=ros2-zenoh
```

Streams all three pods with labeled prefixes:

```
[talker  ] [INFO] ... Publishing: 'Hello World: 312'
[listener] [INFO] ... I heard: [Hello World: 312]
```

---

## OpenShift Deployment — Approach 2 (zenoh-bridge-ros2dds)

Each ROS 2 pod contains two containers: a standard DDS node (using the default RMW) and a `zenoh-bridge-ros2dds` sidecar. The sidecar bridges localhost DDS traffic to a central plain Zenoh router over TCP.

### Files

```
k8s/bridge/
├── namespace.yaml                    # ros2-zenoh-bridge namespace
├── configmap-bridge-config.yaml      # bridge.json5 (client mode, router endpoint)
├── service-zenoh-bridge-router.yaml  # ClusterIP on port 7447
├── deployment-zenoh-bridge-router.yaml  # eclipse/zenoh plain router
├── deployment-ros2-dds-talker.yaml   # 2-container pod: ros2-talker + zenoh-bridge
└── deployment-ros2-dds-listener.yaml # 2-container pod: ros2-listener + zenoh-bridge
```

### Mirror Images (first time or airgapped clusters)

The bridge uses two upstream Docker Hub images. Mirror them to Quay.io before deploying to clusters with restricted egress:

```bash
export QUAY_USERNAME=<your-username>
export QUAY_PASSWORD=<your-password>
make mirror-bridge
```

This copies `eclipse/zenoh-bridge-ros2dds:latest` and `eclipse/zenoh:latest` to `quay.io/jianrzha/`. CI runs this automatically on every push to `main` or `zeno-dds-bridge`.

### Deploy

```bash
make deploy-bridge VERSION=0.0.2
```

Applies all manifests under `k8s/bridge/`, substituting `IMAGE:latest` → `IMAGE:VERSION` for the `ros2-zenoh-demo` image. The sidecar and router images (`eclipse/zenoh-bridge-ros2dds`, `eclipse/zenoh`) are pinned to `:latest` in the manifests and are not substituted.

### Verify

```bash
make test-bridge
```

`scripts/verify-bridge.sh` checks:
1. All three deployments are `1/1 Ready`
2. Each `zenoh-bridge` sidecar shows connection evidence in its logs
3. Messages flow from talker to listener (sequence number cross-check)
4. End-to-end latency across the DDS→bridge→Zenoh→bridge→DDS path

Example output:

```
=== ROS 2 + zenoh-bridge-ros2dds Communication Verification ===
    Namespace : ros2-zenoh-bridge

── Pod Readiness ────────────────────────────────────────────────────────
  PASS  zenoh-bridge-router  (1/1 Ready)
  PASS  ros2-dds-talker  (1/1 Ready)
  PASS  ros2-dds-listener  (1/1 Ready)

── Bridge Sidecar Connectivity ──────────────────────────────────────────
  PASS  ros2-dds-talker / zenoh-bridge  connected to router
  PASS  ros2-dds-listener / zenoh-bridge  connected to router

── Message Flow ─────────────────────────────────────────────────────────
    Talker    messages sampled : 60
    Listener  messages sampled : 60
    Delivered (talker∩listener): 60
    Dropped   (in talker only) : 0

── End-to-End Latency (DDS→bridge→Zenoh→bridge→DDS) ─────────────────────
    Samples : 60
    Average : 1.20 ms
    Min     : 0.90 ms
    Max     : 2.10 ms
  PASS  Messages flowing  talker DDS → bridge → Zenoh → bridge → listener DDS
  PASS  No drops in 60-line sample

═════════════════════════════════════════════════════════════════════════
  Result : 7 passed, 0 failed
```

### Live Demo

```bash
make demo-bridge
```

Streams the talker node, listener node, and router with labeled prefixes:

```
[talker  ] [INFO] ... Publishing: 'Hello World: 45'
[listener] [INFO] ... I heard: [Hello World: 45]
```

To inspect the bridge sidecar logs separately:

```bash
kubectl logs -n ros2-zenoh-bridge -l app=ros2-dds-talker   -c zenoh-bridge -f
kubectl logs -n ros2-zenoh-bridge -l app=ros2-dds-listener -c zenoh-bridge -f
```

### Tear Down

```bash
make undeploy-bridge
```

---

## Makefile Reference

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | `0.0.1` | Image tag to build, push, and deploy |
| `IMAGE` | `quay.io/jianrzha/ros2-zenoh-demo` | Image repository |
| `NAMESPACE` | `ros2-zenoh` | Namespace for Approach 1 |
| `BRIDGE_NS` | `ros2-zenoh-bridge` | Namespace for Approach 2 |
| `PLATFORM` | `linux/amd64,linux/arm64` | Build platforms (multi-arch) |

### Targets

| Target | Description |
|--------|-------------|
| `make build` | Build multi-arch image and tag it `IMAGE:VERSION` |
| `make push` | Push the image to Quay.io |
| `make deploy` | Apply Approach 1 manifests (`k8s/`), injecting `VERSION` |
| `make test` | Wait for rollout then run `scripts/verify.sh` |
| `make demo` | Live-stream all three Approach 1 pods |
| `make logs` | Stream raw logs from Approach 1 pods |
| `make undeploy` | Delete the `ros2-zenoh` namespace |
| `make deploy-bridge` | Apply Approach 2 manifests (`k8s/bridge/`), injecting `VERSION` |
| `make test-bridge` | Wait for rollout then run `scripts/verify-bridge.sh` |
| `make demo-bridge` | Live-stream the Approach 2 message pipeline |
| `make logs-bridge` | Stream raw logs from all Approach 2 containers |
| `make undeploy-bridge` | Delete the `ros2-zenoh-bridge` namespace |
| `make mirror-bridge` | Copy `eclipse/zenoh-bridge-ros2dds` and `eclipse/zenoh` to Quay.io |

---

## Files

### `Dockerfile.ros2`

Single image used by all ROS 2 node containers (both approaches). Installs `rmw_zenoh_cpp` and `demo_nodes_cpp` on top of `ros:jazzy-ros-base`. Creates a non-root user with `GID 0` for OpenShift compatibility.

### `zenoh-client.json5`

Zenoh session config for Approach 1 talker and listener:

- `mode: "client"` — connects to the router rather than doing peer scouting
- `connect.endpoints` — points to the `zenoh-router` service hostname
- Multicast scouting disabled (not available across pod networks)
- Shared memory transport disabled (POSIX SHM is not available in containers)

### `k8s/bridge/configmap-bridge-config.yaml`

Zenoh session config for the Approach 2 bridge sidecars (`bridge.json5`):

- `mode: "client"` — bridge connects to the central Zenoh router
- `connect.endpoints` — points to `zenoh-bridge-router:7447`
- Multicast scouting disabled

### `compose.yml`

Orchestrates the three Approach 1 services locally on a shared Podman bridge network.

### `k8s/`

Kubernetes manifests for Approach 1. Applied by `make deploy`.

### `k8s/bridge/`

Kubernetes manifests for Approach 2. Applied by `make deploy-bridge`.

### `scripts/verify.sh`

Approach 1 verification: pod readiness, message delivery, and end-to-end latency.

### `scripts/verify-bridge.sh`

Approach 2 verification: pod readiness, bridge sidecar connectivity, message delivery, and DDS→bridge→Zenoh→bridge→DDS latency.

### `scripts/demo.sh`

Approach 1 live stream: tails all three pods with labeled prefixes.

### `scripts/demo-bridge.sh`

Approach 2 live stream: tails the talker node, listener node, and router with labeled prefixes.

### `.github/workflows/build.yml`

CI pipeline: builds and pushes the `ros2-zenoh-demo` image for `linux/amd64` and `linux/arm64`, then mirrors `eclipse/zenoh-bridge-ros2dds` and `eclipse/zenoh` to Quay.io. Runs on push to `main` or `zeno-dds-bridge`.

---

## OpenShift-Specific Notes

**OVN-Kubernetes blocks multicast (critical).**
See [docs/zenoh-ocp-ovn-multicast-workaround.md](docs/zenoh-ocp-ovn-multicast-workaround.md) for
the root cause and the reference ConfigMap. Every deployment in this repo already applies the
workaround; this note exists so you know why `scouting.multicast: false` appears in every config.

**`runAsUser` must not be set.**
OpenShift's `restricted-v2` SCC assigns UIDs from a per-namespace range (e.g. `1000770000–1000779999`). Setting `runAsUser: 1001` conflicts with this range and causes a `FailedCreate` event. The Dockerfile creates UID 1001 with `GID 0` and `g=u` permissions so the pod remains functional regardless of which UID OpenShift assigns at runtime.

**Image must include `linux/amd64`.**
OpenShift cluster nodes typically run on `x86_64`. An `arm64`-only image produces `Exec format error` on startup. The Makefile defaults to `PLATFORM=linux/amd64,linux/arm64` for multi-arch builds.

**Version injection happens at deploy time.**
Static manifests keep `:latest` as a placeholder for the `ros2-zenoh-demo` image. `make deploy VERSION=x.y.z` and `make deploy-bridge VERSION=x.y.z` use `sed` to substitute the correct tag before `kubectl apply`.

**Mirror upstream images before deploying to restricted clusters.**
Clusters with `imagePullPolicy` restrictions or no Docker Hub egress need the `eclipse/zenoh` and `eclipse/zenoh-bridge-ros2dds` images pre-mirrored. Use `make mirror-bridge` or rely on the CI workflow.

---

## Gotchas

**OCP/OVN blocks multicast — always use unicast connect endpoints.**
OVN-Kubernetes (OCP's default CNI) drops UDP multicast between pods by default. Zenoh's
peer-discovery (scouting) uses UDP multicast to `224.0.0.224:7446`. Without the workaround,
pods start cleanly but never exchange messages — no error is logged, which makes this the hardest
failure mode to diagnose. The fix is already applied in every ConfigMap in this repo
(`scouting.multicast.enabled: false` + explicit `connect.endpoints`). See
[docs/zenoh-ocp-ovn-multicast-workaround.md](docs/zenoh-ocp-ovn-multicast-workaround.md) for
the full explanation, diagnostic steps, and the reference ConfigMap at
[`k8s/configmap-zenoh-ocp.yaml`](k8s/configmap-zenoh-ocp.yaml).

**`ZENOH_SESSION_CONFIG_URI`, not `ZENOH_CONFIG`.**
`rmw_zenoh_cpp` reads its own env var. `ZENOH_CONFIG` is silently ignored; the library falls back to its bundled default which hardcodes `tcp/localhost:7447`.

**Use `rmw_zenohd` as the router for Approach 1, not `eclipse/zenoh`.**
The standalone `eclipse/zenoh` image is a generic Zenoh router and is incompatible with ROS 2 graph management. Approach 1's router must be started with `ros2 run rmw_zenoh_cpp rmw_zenohd`. Approach 2 uses `eclipse/zenoh` intentionally — the bridges speak plain Zenoh, not ROS 2 graph protocol.

**Set `ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST` for Approach 2.**
Without this, DDS multicast spans across pods and causes duplicate or split delivery. The bridge sidecars handle cross-pod forwarding; DDS must not attempt it independently.

**SHM must be disabled in containers.**
Zenoh tries to use POSIX shared memory by default. In containers this fails with `OS error 12` (ENOMEM). Set `transport.shared_memory.enabled: false` in the session config.

**`ros2 doctor` router warning is a red herring.**
Even when everything works, `ros2 doctor` prints "Unable to connect to a Zenoh router" because it spawns a transient diagnostic session that may not connect in time. Check actual talker/listener logs to verify communication.

**Container names use underscores with `podman-compose`.**
`podman-compose` names containers like `ros2-zenoh_ros2-talker_1`. Use `podman ps` to find exact names.

**Bridge sidecar logs require `-c zenoh-bridge`.**
`kubectl logs` on a multi-container pod defaults to the first container. Always specify `-c zenoh-bridge` or `-c ros2-talker`/`-c ros2-listener` to target the right container.
