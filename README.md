# ROS2 + Zenoh Demo

A minimal demo running ROS2 Jazzy with `rmw_zenoh_cpp` (Zenoh as the RMW layer). Three components — a Zenoh router, a talker, and a listener — communicate over Zenoh's client/router topology.

## Architecture

Both the talker and listener run in `mode: "client"` and connect to the router. They do **not** talk to each other directly — all messages flow through the router:

```
ros2-talker ──TCP──► zenoh-router:7447 ──TCP──► ros2-listener
```

| Component | Role |
|-----------|------|
| `zenoh-router` | Runs `rmw_zenohd`, the ROS2 Zenoh router on port 7447 |
| `ros2-talker` | Publishes `Hello World` messages on `/chatter` |
| `ros2-listener` | Subscribes to `/chatter` and prints received messages |

---

## Local: Mac M2 / Podman

### Prerequisites

- **Podman** 5.x with a running machine (`podman machine start`)
- **podman-compose** (`brew install podman-compose`)

### Quick Start

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

# List ROS2 topics visible from the listener
podman exec -it ros2-zenoh_ros2-listener_1 bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic list"

# Echo the chatter topic live
podman exec -it ros2-zenoh_ros2-talker_1 bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic echo /chatter"
```

---

## OpenShift Deployment

### Prerequisites

- `oc` / `kubectl` logged in to an OpenShift cluster
- `podman` with a Quay.io login (`podman login quay.io`)
- Python 3 (for `make test` latency calculation)

### Architecture

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

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make build` | Build the `linux/amd64` image and tag it `IMAGE:VERSION` |
| `make push` | Push the image to Quay.io |
| `make deploy` | Apply all manifests, injecting the current `VERSION` tag |
| `make test` | Wait for rollout then run `scripts/verify.sh` |
| `make demo` | Live-stream all three pods with labeled prefixes |
| `make logs` | Stream raw logs from all three pods |
| `make undeploy` | Delete the namespace and all resources |

Key variables (override with `make VAR=value`):

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | `0.0.1` | Image tag to build, push, and deploy |
| `IMAGE` | `quay.io/jianrzha/ros2-zenoh-demo` | Image repository |
| `NAMESPACE` | `ros2-zenoh` | Target namespace |
| `PLATFORM` | `linux/amd64` | Build platform |

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

Streams all three pods with labeled prefixes. Watch matching sequence numbers flow from talker to listener:

```
[talker  ] [INFO] ... Publishing: 'Hello World: 312'
[listener] [INFO] ... I heard: [Hello World: 312]
```

### OpenShift-Specific Notes

**`runAsUser` must not be set.**
OpenShift's `restricted-v2` SCC assigns UIDs from a per-namespace range (e.g. `1000770000–1000779999`). Setting `runAsUser: 1001` in the pod spec conflicts with this range and causes a `FailedCreate` event. The Dockerfile creates a UID 1001 user with `GID 0` and `g=u` permissions so the pod remains functional regardless of which UID OpenShift assigns at runtime.

**Image must be `linux/amd64`.**
OpenShift cluster nodes typically run on `x86_64`. An `arm64`-only image (built natively on an M2 Mac) produces `Exec format error` on startup. The Makefile defaults to `PLATFORM=linux/amd64`.

**Version injection happens at deploy time.**
Static manifests keep `:latest` as a placeholder. `make deploy VERSION=x.y.z` uses `sed` to substitute the correct tag before `kubectl apply`, so the running pods always use the specified version.

---

## Files

### `Dockerfile.ros2`

Single image used by all three components. Installs `rmw_zenoh_cpp` and `demo_nodes_cpp` on top of `ros:jazzy-ros-base`. Creates a non-root user with `GID 0` for OpenShift compatibility.

### `zenoh-client.json5`

Zenoh session config for the talker and listener:

- `mode: "client"` — connects to the router rather than doing peer scouting
- `connect.endpoints` — points to the `zenoh-router` service hostname
- Multicast scouting disabled (not available across pod networks)
- Shared memory transport disabled (POSIX SHM is not available in containers)

### `compose.yml`

Orchestrates the three services locally on a shared Podman bridge network.

### `k8s/`

Kubernetes manifests for OpenShift. Applied by `make deploy`.

### `scripts/verify.sh`

Verification script: checks pod readiness, message delivery (sequence number cross-check between talker and listener logs), and end-to-end latency. Called by `make test`.

### `scripts/demo.sh`

Live-streaming script: tails all three pods with labeled prefixes. Called by `make demo`.

---

## Gotchas

**`ZENOH_SESSION_CONFIG_URI`, not `ZENOH_CONFIG`.**
`rmw_zenoh_cpp` reads its own env var. `ZENOH_CONFIG` is silently ignored; the library falls back to its bundled default which hardcodes `tcp/localhost:7447`.

**Use `rmw_zenohd` as the router, not `eclipse/zenoh`.**
The standalone `eclipse/zenoh` image is a generic Zenoh router and is incompatible with ROS2 graph management. The router must be started with `ros2 run rmw_zenoh_cpp rmw_zenohd`.

**SHM must be disabled in containers.**
Zenoh tries to use POSIX shared memory by default. In containers this fails with `OS error 12` (ENOMEM). Set `transport.shared_memory.enabled: false` in the session config.

**`ros2 doctor` router warning is a red herring.**
Even when everything works, `ros2 doctor` prints "Unable to connect to a Zenoh router" because it spawns a transient diagnostic session that may not connect in time. Check actual talker/listener logs to verify communication.

**Container names use underscores with `podman-compose`.**
`podman-compose` names containers like `ros2-zenoh_ros2-talker_1`. Use `podman ps` to find exact names.
