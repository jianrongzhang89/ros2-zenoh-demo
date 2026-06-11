# Proposal: Zenoh ROS 2 Bridge (zenoh-bridge-ros2dds) on OpenShift

## Context

The existing work on this branch already deploys **rmw_zenoh** + ROS 2 Jazzy on OpenShift
(`k8s/`, `Dockerfile.ros2`, `docs/openshift-deployment-proposal.md`).  That setup replaces
DDS entirely at the RMW layer — all ROS 2 nodes speak Zenoh natively and connect to a central
`rmw_zenohd` router over TCP.

This proposal adds a second deployment pattern: **zenoh-bridge-ros2dds**.  The bridge keeps
standard DDS-based ROS 2 nodes unchanged and wraps them with a Zenoh bridge sidecar so their
traffic can cross pod and cluster boundaries.

---

## Why Two Patterns?

| Dimension | rmw_zenoh (existing) | zenoh-bridge-ros2dds (this proposal) |
|-----------|---------------------|--------------------------------------|
| DDS dependency | Eliminated entirely | Retained per-pod (localhost only) |
| Node changes required | Must set `RMW_IMPLEMENTATION=rmw_zenoh_cpp` | None — nodes keep their default RMW |
| Best for | Greenfield ROS 2 deployments, full Kubernetes-native | Legacy/vendor nodes that cannot change RMW, cross-domain bridging, edge-to-cloud |
| Interoperability | rmw_zenoh nodes only | Any DDS-based ROS 2 node |
| OpenShift SCC | restricted-v2 (no privileges needed) | restricted-v2 (same) |

> **Note from adversarial verification:** rmw_zenoh and zenoh-bridge-ros2dds are **not
> directly interoperable** — they use different key-expression schemas, serialization formats,
> and liveliness tokens.  A cluster must commit to one pattern per communication boundary, or
> deploy a separate router for each.

---

## Architecture

### Why Sidecar?

DDS multicast discovery does not work across pods in Kubernetes/OpenShift.  The
`zenoh-bridge-ros2dds` documentation requires that DDS be restricted to `localhost` on each
bridged host (`ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST`) to prevent duplicate or looped messages
across bridge boundaries.

Because DDS is localhost-only, the bridge **must run in the same pod** as the DDS nodes it
bridges — it cannot be a standalone Deployment reaching across pod network boundaries via
standard DDS multicast.  The sidecar pattern satisfies this constraint naturally: all containers
in a pod share a network namespace, so the bridge sees DDS traffic on `lo` and forwards it over
Zenoh TCP to the central router.

### Component Diagram

```
                    OpenShift Namespace: ros2-zenoh-bridge
  ┌───────────────────────────────────────────────────────────────────┐
  │                                                                   │
  │   ┌───────────────────────────────┐                              │
  │   │   Deployment: zenoh-router    │                              │
  │   │   (zenoh-bridge-ros2dds       │◄────── ClusterIP Service     │
  │   │    --mode router)             │        zenoh-router:7447     │
  │   └───────────────────────────────┘              ▲              │
  │                                                  │              │
  │   ┌─────────────────────────────────────────┐   │              │
  │   │  Pod: ros2-dds-talker                   │   │              │
  │   │                                         │   │              │
  │   │  ┌──────────────────┐  DDS/localhost   │   │              │
  │   │  │ ros2-talker      │◄────────────────►│   │              │
  │   │  │ (default RMW)    │                  │   │              │
  │   │  └──────────────────┘  ┌──────────────┐│   │              │
  │   │                        │ zenoh-bridge  ││───┘              │
  │   │                        │ (sidecar)     ││  TCP/7447        │
  │   │                        └──────────────┘│                  │
  │   └─────────────────────────────────────────┘                  │
  │                                                                   │
  │   ┌─────────────────────────────────────────┐                   │
  │   │  Pod: ros2-dds-listener                 │                   │
  │   │                                         │                   │
  │   │  ┌──────────────────┐  DDS/localhost   │                   │
  │   │  │ ros2-listener    │◄────────────────►│                   │
  │   │  │ (default RMW)    │                  │                   │
  │   │  └──────────────────┘  ┌──────────────┐│                   │
  │   │                        │ zenoh-bridge  ││────TCP/7447──────►│
  │   │                        │ (sidecar)     ││                   │
  │   │                        └──────────────┘│                   │
  │   └─────────────────────────────────────────┘                   │
  └───────────────────────────────────────────────────────────────────┘
```

Traffic flow:
1. `ros2-talker` publishes on DDS, restricted to `lo` (localhost).
2. `zenoh-bridge` sidecar sees it on `lo` and re-publishes on the Zenoh session.
3. Zenoh session connects (as client) to `zenoh-router:7447` via TCP.
4. The central Zenoh router fans the message out to all connected bridge clients.
5. The `zenoh-bridge` sidecar in the listener pod receives it and re-publishes on its local DDS `lo`.
6. `ros2-listener` receives the DDS message normally.

---

## Container Images

### Option A — Use the Official Bridge Image (Recommended)

Eclipse Zenoh publishes a ready-made image on Docker Hub:

```
docker.io/eclipse/zenoh-bridge-ros2dds:latest
```

This avoids building or maintaining the bridge binary.  The sidecar container in each pod
references this image directly.  A Quay.io mirror can be added to the CI pipeline if needed for
air-gapped clusters.

### Option B — Bake Bridge into the Existing Image

Add to `Dockerfile.ros2`:

```dockerfile
RUN dnf install -y \
        ros-jazzy-zenoh-bridge-ros2dds \
    && dnf clean all
```

> As of June 2026 the RHEL9 ROS 2 repo may not carry this package; check availability first.
> If unavailable, use Option A or build from source in a multi-stage Dockerfile.

### ROS 2 DDS Node Image

The existing `Dockerfile.ros2` already installs `ros-jazzy-demo-nodes-cpp` and is OpenShift
compatible (UID 1001, GID 0, restricted-v2 SCC).  For DDS-mode deployments, simply **do not**
set `RMW_IMPLEMENTATION=rmw_zenoh_cpp` — the default RMW (CycloneDDS or FastDDS) will be used.

---

## Kubernetes Manifests

All new files go under `k8s/bridge/` to keep them separate from the existing rmw_zenoh setup.

### File Layout

```
k8s/bridge/
├── namespace.yaml                       (can reuse k8s/namespace.yaml if same namespace)
├── configmap-bridge-config.yaml         (Zenoh bridge client config)
├── deployment-zenoh-bridge-router.yaml  (central Zenoh router — bridge mode)
├── service-zenoh-bridge-router.yaml     (ClusterIP on 7447)
├── deployment-ros2-dds-talker.yaml      (DDS talker + bridge sidecar)
└── deployment-ros2-dds-listener.yaml    (DDS listener + bridge sidecar)
```

### configmap-bridge-config.yaml

The bridge config points each sidecar at the central router as a client.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bridge-zenoh-config
  namespace: ros2-zenoh-bridge
data:
  bridge.json5: |
    {
      mode: "client",
      connect: {
        endpoints: ["tcp/zenoh-bridge-router:7447"]
      },
      scouting: {
        multicast: { enabled: false }
      }
    }
```

### deployment-zenoh-bridge-router.yaml

The central router runs the standalone `zenoh-bridge-ros2dds` binary in router mode.  It acts
as a Zenoh router (not a DDS bridge itself) — it only routes Zenoh sessions; it does not expose
any DDS domain of its own.  Alternatively, `zenohd` (the bare Zenoh router) can be used here.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zenoh-bridge-router
  namespace: ros2-zenoh-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zenoh-bridge-router
  template:
    metadata:
      labels:
        app: zenoh-bridge-router
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: zenoh-router
          image: docker.io/eclipse/zenoh-bridge-ros2dds:latest
          # Run as a pure Zenoh router — no DDS domain; just routes Zenoh sessions
          args: ["--no-ros-discovery", "--mode", "router"]
          ports:
            - containerPort: 7447
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: 7447
            initialDelaySeconds: 3
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            tcpSocket:
              port: 7447
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

> **Note:** The exact CLI flags for the bridge image may differ between releases.  Verify
> against `docker run eclipse/zenoh-bridge-ros2dds --help`.  If `zenohd` is used instead of
> the bridge binary, use `docker.io/eclipse/zenoh:latest`.

### service-zenoh-bridge-router.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: zenoh-bridge-router
  namespace: ros2-zenoh-bridge
spec:
  selector:
    app: zenoh-bridge-router
  ports:
    - port: 7447
      targetPort: 7447
      protocol: TCP
```

### deployment-ros2-dds-talker.yaml

Key decisions:
- `ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST` restricts DDS to the pod's `lo` interface.
- The `zenoh-bridge` sidecar connects to the central router as a client.
- Both containers share the same network namespace (pod default) so the bridge sees DDS on `lo`.
- `ZENOH_BRIDGE_ROS2DDS_CONFIG` or `-c` flag points to the mounted config.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ros2-dds-talker
  namespace: ros2-zenoh-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ros2-dds-talker
  template:
    metadata:
      labels:
        app: ros2-dds-talker
    spec:
      securityContext:
        runAsNonRoot: true
      initContainers:
        - name: wait-for-router
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - python3
            - -c
            - |
              import socket, time, sys
              while True:
                  try:
                      s = socket.create_connection(("zenoh-bridge-router", 7447), timeout=2)
                      s.close(); sys.exit(0)
                  except OSError:
                      time.sleep(1)
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
      containers:
        - name: ros2-talker
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - bash
            - -c
            - |
              source /opt/ros/jazzy/setup.bash
              exec ros2 run demo_nodes_cpp talker
          env:
            # Use default DDS RMW (CycloneDDS or FastDDS) — NOT rmw_zenoh_cpp
            - name: ROS_AUTOMATIC_DISCOVERY_RANGE
              value: LOCALHOST          # DDS stays on lo; bridge handles cross-pod
            - name: ROS_HOME
              value: /tmp
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi

        - name: zenoh-bridge
          image: docker.io/eclipse/zenoh-bridge-ros2dds:latest
          args:
            - "-c"
            - "/etc/zenoh/bridge.json5"
          env:
            - name: ROS_AUTOMATIC_DISCOVERY_RANGE
              value: LOCALHOST
          volumeMounts:
            - name: bridge-config
              mountPath: /etc/zenoh
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

      volumes:
        - name: bridge-config
          configMap:
            name: bridge-zenoh-config
```

### deployment-ros2-dds-listener.yaml

Identical structure to the talker; substitute `listener` for the ROS 2 node command.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ros2-dds-listener
  namespace: ros2-zenoh-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ros2-dds-listener
  template:
    metadata:
      labels:
        app: ros2-dds-listener
    spec:
      securityContext:
        runAsNonRoot: true
      initContainers:
        - name: wait-for-router
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - python3
            - -c
            - |
              import socket, time, sys
              while True:
                  try:
                      s = socket.create_connection(("zenoh-bridge-router", 7447), timeout=2)
                      s.close(); sys.exit(0)
                  except OSError:
                      time.sleep(1)
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
      containers:
        - name: ros2-listener
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - bash
            - -c
            - |
              source /opt/ros/jazzy/setup.bash
              exec ros2 run demo_nodes_cpp listener
          env:
            - name: ROS_AUTOMATIC_DISCOVERY_RANGE
              value: LOCALHOST
            - name: ROS_HOME
              value: /tmp
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi

        - name: zenoh-bridge
          image: docker.io/eclipse/zenoh-bridge-ros2dds:latest
          args:
            - "-c"
            - "/etc/zenoh/bridge.json5"
          env:
            - name: ROS_AUTOMATIC_DISCOVERY_RANGE
              value: LOCALHOST
          volumeMounts:
            - name: bridge-config
              mountPath: /etc/zenoh
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

      volumes:
        - name: bridge-config
          configMap:
            name: bridge-zenoh-config
```

---

## Security Context

The `zenoh-bridge-ros2dds` sidecar requires **no elevated privileges** when DDS is restricted
to localhost.  Research adversarially verified (3-0 votes) that:

- `hostNetwork: true` is **not** required — Zenoh uses TCP unicast, not DDS multicast.
- `NET_ADMIN` / `NET_RAW` capabilities are **not** required.
- `privileged: true` is **not** required.
- Multiple ROS 2 containers per pod are **not** blocked (RTPS localhost ports are per-process).

All containers can run under OpenShift's default `restricted-v2` SCC:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
```

The existing UID 1001 / GID 0 convention from `Dockerfile.ros2` applies to the ROS 2 node
container.  The `eclipse/zenoh-bridge-ros2dds` image ships with its own non-root user; confirm
with `docker inspect eclipse/zenoh-bridge-ros2dds` before deploying.

---

## Networking Summary

| Layer | Mechanism | Notes |
|-------|-----------|-------|
| DDS discovery (within pod) | localhost (`lo`) | `ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST` |
| DDS discovery (cross-pod) | **None** — bridge handles it | No multicast needed |
| Bridge → Router | TCP port 7447 | ClusterIP Service `zenoh-bridge-router` |
| Router → Bridge | TCP port 7447 (server-initiated push) | Zenoh session-level pub/sub |
| External robot → cluster | OpenShift Route (TLS passthrough) or LoadBalancer on 7447 | Out of scope for demo |

No `hostNetwork`, no multicast routes, no special NetworkPolicy rules needed beyond the cluster
defaults.

---

## CI/CD Additions

Extend `.github/workflows/build.yml` to also mirror the bridge image into Quay.io for
air-gapped clusters:

```yaml
      - name: Mirror zenoh-bridge-ros2dds to Quay.io
        run: |
          docker pull docker.io/eclipse/zenoh-bridge-ros2dds:latest
          docker tag docker.io/eclipse/zenoh-bridge-ros2dds:latest \
                     quay.io/jianrzha/zenoh-bridge-ros2dds:latest
          docker push quay.io/jianrzha/zenoh-bridge-ros2dds:latest
```

Then update all sidecar references from `docker.io/eclipse/zenoh-bridge-ros2dds:latest` to
`quay.io/jianrzha/zenoh-bridge-ros2dds:latest`.

---

## Deployment Steps

```bash
# 1. Apply bridge manifests
kubectl apply -f k8s/bridge/

# 2. Watch pods come up (each pod will have 2/2 containers ready)
kubectl get pods -n ros2-zenoh-bridge -w

# 3. Confirm the bridge sidecars connected to the router
kubectl logs -n ros2-zenoh-bridge -l app=ros2-dds-talker -c zenoh-bridge

# 4. Confirm DDS messages are flowing
kubectl logs -n ros2-zenoh-bridge -l app=ros2-dds-listener -c ros2-listener -f
```

Expected listener output:
```
[listener]: I heard: [Hello World: 1]
[listener]: I heard: [Hello World: 2]
```

---

## Open Questions and Risks

| # | Question | Risk | Mitigation |
|---|----------|------|------------|
| 1 | **Exact CLI flags** for `eclipse/zenoh-bridge-ros2dds` image vary between releases | Bridge may not start with wrong flags | Always run `--help` against the pinned image version; pin a specific tag (e.g., `:0.11.x`) |
| 2 | **rmw_zenoh ↔ zenoh-bridge-ros2dds interop** — research returned 1-2 vote (not confirmed) | Hybrid deployments mixing both patterns may not route messages correctly | Keep the two namespaces (`ros2-zenoh` and `ros2-zenoh-bridge`) fully isolated; do not connect their routers until interop is tested |
| 3 | **OpenShift SCC for bridge image** — no confirmed evidence the official image uses a non-root UID | Pod rejected by `restricted-v2` SCC | Inspect the image; if root, build a wrapper image with UID 1001 / GID 0 |
| 4 | **zenoh-plugin-dds deprecation** — the generic DDS bridge (`zenoh-plugin-dds`) is being deprecated for ROS 2 | If the bridge image switches plugins internally, behavior may change | Use `zenoh-plugin-ros2dds` / `zenoh-bridge-ros2dds` explicitly; avoid `zenoh-bridge-dds` |
| 5 | **Router HA** — single-replica router is a SPOF | Loss of router drops all cross-pod pub/sub | For production: run multiple router replicas behind a headless Service; Zenoh routers gossip-connect to each other |
| 6 | **Zenoh version cadence** — releases move fast (1.6.x as of June 2026) | Config syntax changes across minor versions | Pin image tags; test upgrades in a staging namespace first |

---

## Comparison: This Proposal vs. Existing rmw_zenoh Setup

```
                 rmw_zenoh (existing)              zenoh-bridge-ros2dds (this proposal)
                 ─────────────────────             ──────────────────────────────────
RMW layer        Zenoh native                      Standard DDS (CycloneDDS / FastDDS)
Router binary    rmw_zenohd (from ROS pkg)         zenoh-bridge-ros2dds or zenohd
Node config      ZENOH_SESSION_CONFIG_URI           ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST
Bridge sidecar   Not needed                         Required per pod
Namespace        ros2-zenoh                         ros2-zenoh-bridge
Port 7447        rmw_zenohd router                 zenoh-bridge-ros2dds router
Interoperable?   No (different protocol layer)      No (with rmw_zenoh)
```

Both patterns are fully compatible with OpenShift `restricted-v2` SCC and require no elevated
privileges or host networking.  The choice between them depends on whether the ROS 2 nodes can
adopt `rmw_zenoh_cpp` (greenfield) or must retain their existing DDS RMW (legacy/vendor nodes).

---

## Sources

- [zenoh-plugin-ros2dds README](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) — bridge flags, DDS locality requirement, v0.11.0 mode change
- [ros2/rmw_zenoh](https://github.com/ros2/rmw_zenoh) — client mode config, unsupported env vars
- [ROS 2 Zenoh docs (Rolling)](https://docs.ros.org/en/rolling/Installation/RMW-Implementations/Non-DDS-Implementations/Working-with-Zenoh.html) — multicast disabled by default
- [zenoh-plugin-dds deprecation notice](https://github.com/eclipse-zenoh/zenoh-plugin-dds) — use ros2dds variant for ROS 2
- [Clearpath Robotics Zenoh docs](https://docs.clearpathrobotics.com/docs/ros/networking/ros2_networking/zenoh/) — ZENOH_CONFIG_OVERRIDE client-mode syntax
- [eclipse/zenoh-bridge-ros2dds on Docker Hub](https://hub.docker.com/r/eclipse/zenoh-bridge-ros2dds) — official image
