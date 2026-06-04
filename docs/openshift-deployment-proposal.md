# OpenShift Deployment Proposal: ROS2 + Zenoh Demo

## Overview

This document proposes a deployment architecture for the ROS2 Jazzy + Zenoh demo on OpenShift. The goal is to faithfully reproduce the three-container compose setup (Zenoh router, talker, listener) as a production-ready OpenShift workload, using Quay.io as the container registry and GitHub Actions for CI/CD.

---

## Architecture

### Compose → OpenShift Mapping

```
compose                         OpenShift
────────────────────────────────────────────────────────
Podman bridge network      →    Kubernetes Namespace
  zenoh-router container   →    Deployment + ClusterIP Service
  ros2-talker container    →    Deployment
  ros2-listener container  →    Deployment
zenoh-client.json5 (file)  →    ConfigMap (volume-mounted)
sleep 5 / sleep 7          →    Init containers (port readiness check)
platform: linux/arm64      →    nodeSelector or multi-arch image
```

### Component Diagram

```
                        Namespace: ros2-zenoh
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │   ┌─────────────────┐      ClusterIP Service        │
  │   │  zenoh-router   │◄─────  zenoh-router:7447  ───┐│
  │   │  (rmw_zenohd)   │                              ││
  │   └─────────────────┘                              ││
  │                                                    ││
  │   ┌─────────────────┐                              ││
  │   │   ros2-talker   │──── connects to router ──────┘│
  │   │  (demo talker)  │                               │
  │   └─────────────────┘                               │
  │                                                     │
  │   ┌─────────────────┐                               │
  │   │  ros2-listener  │──── connects to router ───────┤
  │   │ (demo listener) │                               │
  │   └─────────────────┘                               │
  └──────────────────────────────────────────────────────┘
```

All inter-pod communication uses the `zenoh-router` ClusterIP Service on port 7447. No external exposure is required for the demo.

---

## Container Image

### Registry: Quay.io

| Item | Value |
|------|-------|
| Registry | `quay.io` |
| Repository | `quay.io/jianrzha/ros2-zenoh-demo` |
| Tag strategy | `latest` for main branch; Git SHA tags for traceability |
| Visibility | Public (mirrors the GitHub repo) |

A single image is used for all three services. The role of each container is determined by its startup command, not the image.

### Dockerfile Changes

Two additions are needed to make the image OpenShift-compatible:

**1. Non-root user** — OpenShift's default `restricted-v2` SCC blocks containers that run as root (UID 0). Adding a dedicated user satisfies this constraint without requiring elevated SCCs.

**2. File ownership** — The Zenoh client config copied into the image must be readable by the non-root user.

```dockerfile
FROM ros:jazzy-ros-base

RUN apt-get update && apt-get install -y \
    ros-jazzy-rmw-zenoh-cpp \
    ros-jazzy-demo-nodes-cpp \
    && rm -rf /var/lib/apt/lists/*

# Non-root user required by OpenShift's restricted-v2 SCC
RUN useradd -m -u 1001 ros
USER 1001

COPY --chown=1001:1001 zenoh-client.json5 /zenoh-client.json5
```

> **Note:** The `zenoh-client.json5` baked into the image serves as a fallback default. In the OpenShift deployment, the ConfigMap-mounted version takes precedence (see below).

---

## Kubernetes Manifests

All manifests live under `k8s/` and are applied in a single command:

```bash
kubectl apply -f k8s/
```

### File Layout

```
k8s/
├── namespace.yaml
├── configmap-zenoh-client.yaml
├── deployment-zenoh-router.yaml
├── service-zenoh-router.yaml
├── deployment-ros2-talker.yaml
└── deployment-ros2-listener.yaml
```

### namespace.yaml

Creates an isolated namespace for the demo.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ros2-zenoh
```

### configmap-zenoh-client.yaml

Externalises the Zenoh session config so it can be changed without rebuilding the image. The `ZENOH_SESSION_CONFIG_URI` env var on the talker and listener pods points to the mount path.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: zenoh-client-config
  namespace: ros2-zenoh
data:
  zenoh-client.json5: |
    {
      mode: "client",
      connect: {
        endpoints: ["tcp/zenoh-router:7447"]
      },
      scouting: {
        multicast: { enabled: false }
      },
      transport: {
        shared_memory: { enabled: false }
      }
    }
```

### deployment-zenoh-router.yaml

Runs `rmw_zenohd`. The readiness probe on port 7447 blocks the talker/listener init containers until the router is accepting connections.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zenoh-router
  namespace: ros2-zenoh
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zenoh-router
  template:
    metadata:
      labels:
        app: zenoh-router
    spec:
      containers:
        - name: zenoh-router
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - bash
            - -c
            - source /opt/ros/jazzy/setup.bash && ros2 run rmw_zenoh_cpp rmw_zenohd
          ports:
            - containerPort: 7447
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: 7447
            initialDelaySeconds: 2
            periodSeconds: 3
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

### service-zenoh-router.yaml

Exposes the router to other pods in the namespace at the hostname `zenoh-router`, matching the address already in the Zenoh client config.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: zenoh-router
  namespace: ros2-zenoh
spec:
  selector:
    app: zenoh-router
  ports:
    - port: 7447
      targetPort: 7447
      protocol: TCP
```

### deployment-ros2-talker.yaml

The init container replaces the `sleep 5` hack with a proper readiness wait. The ConfigMap is mounted at `/etc/zenoh/` and `ZENOH_SESSION_CONFIG_URI` points to it.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ros2-talker
  namespace: ros2-zenoh
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ros2-talker
  template:
    metadata:
      labels:
        app: ros2-talker
    spec:
      initContainers:
        - name: wait-for-router
          image: busybox
          command: ['sh', '-c', 'until nc -z zenoh-router 7447; do sleep 1; done']
      containers:
        - name: ros2-talker
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - bash
            - -c
            - source /opt/ros/jazzy/setup.bash && ros2 run demo_nodes_cpp talker
          env:
            - name: RMW_IMPLEMENTATION
              value: rmw_zenoh_cpp
            - name: ZENOH_SESSION_CONFIG_URI
              value: /etc/zenoh/zenoh-client.json5
          volumeMounts:
            - name: zenoh-config
              mountPath: /etc/zenoh
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: zenoh-config
          configMap:
            name: zenoh-client-config
```

### deployment-ros2-listener.yaml

Identical structure to the talker deployment, substituting the listener command.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ros2-listener
  namespace: ros2-zenoh
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ros2-listener
  template:
    metadata:
      labels:
        app: ros2-listener
    spec:
      initContainers:
        - name: wait-for-router
          image: busybox
          command: ['sh', '-c', 'until nc -z zenoh-router 7447; do sleep 1; done']
      containers:
        - name: ros2-listener
          image: quay.io/jianrzha/ros2-zenoh-demo:latest
          command:
            - bash
            - -c
            - source /opt/ros/jazzy/setup.bash && ros2 run demo_nodes_cpp listener
          env:
            - name: RMW_IMPLEMENTATION
              value: rmw_zenoh_cpp
            - name: ZENOH_SESSION_CONFIG_URI
              value: /etc/zenoh/zenoh-client.json5
          volumeMounts:
            - name: zenoh-config
              mountPath: /etc/zenoh
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: zenoh-config
          configMap:
            name: zenoh-client-config
```

---

## CI/CD: GitHub Actions → Quay.io

A GitHub Actions workflow builds the image on every push to `main` and pushes it to Quay.io. A Quay.io robot account is used for authentication.

### Secrets Required

Add these to the GitHub repository under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `QUAY_USERNAME` | Quay.io robot account username (e.g. `jianrzha+github_ci`) |
| `QUAY_PASSWORD` | Quay.io robot account token |

### .github/workflows/build.yml

```yaml
name: Build and Push to Quay.io

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU (for ARM64 cross-build)
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Quay.io
        uses: docker/login-action@v3
        with:
          registry: quay.io
          username: ${{ secrets.QUAY_USERNAME }}
          password: ${{ secrets.QUAY_PASSWORD }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile.ros2
          platforms: linux/arm64,linux/amd64
          push: true
          tags: |
            quay.io/jianrzha/ros2-zenoh-demo:latest
            quay.io/jianrzha/ros2-zenoh-demo:${{ github.sha }}
```

> **Note on build time:** The `ros:jazzy-ros-base` image with `rmw_zenoh_cpp` is large. The first build will take 10–15 minutes. Subsequent builds benefit from Docker layer caching via Buildx's `cache-from`/`cache-to` options if needed.

---

## Deployment Steps

```bash
# 1. Apply all manifests
kubectl apply -f k8s/

# 2. Watch pods come up
kubectl get pods -n ros2-zenoh -w

# 3. Verify the listener is receiving messages
kubectl logs -n ros2-zenoh -l app=ros2-listener -f

# 4. Verify the talker is publishing
kubectl logs -n ros2-zenoh -l app=ros2-talker -f
```

Expected output from the listener pod:

```
[listener]: I heard: [Hello World: 1]
[listener]: I heard: [Hello World: 2]
```

---

## Considerations and Caveats

| Topic | Detail |
|-------|--------|
| **SCC** | The `restricted-v2` SCC (OpenShift default) is satisfied by running as UID 1001. No manual SCC grants are required. |
| **Router HA** | The Zenoh router runs as a single replica. For production, Zenoh supports router clustering — multiple `zenoh-router` replicas behind the Service would provide redundancy. |
| **ROS domain isolation** | All pods share `ROS_DOMAIN_ID=0`. If multiple instances of this demo are deployed in the same namespace, set distinct domain IDs per deployment. |
| **Multi-arch image** | The workflow builds both `linux/arm64` (for M2 dev) and `linux/amd64` (for typical OpenShift nodes). The correct variant is pulled automatically at runtime. |
| **External robot connectivity** | To allow a physical robot outside the cluster to connect to the Zenoh router, add an OpenShift Route (TLS passthrough on port 7447) or a LoadBalancer Service. This is out of scope for the demo. |
| **Config changes** | Updating `zenoh-client.json5` requires only `kubectl apply -f k8s/configmap-zenoh-client.yaml` followed by a pod rollout — no image rebuild. |
