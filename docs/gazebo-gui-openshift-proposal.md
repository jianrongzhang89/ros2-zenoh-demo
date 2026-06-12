# Proposal: Gazebo GUI Deployment on OpenShift

## Executive Summary

Gazebo Harmonic's GUI frontend (`gz sim -g`) can be deployed and accessed inside an
OpenShift/Kubernetes cluster via two distinct approaches. The simulation server already
runs headless (`gz sim -s --headless-rendering`); this proposal covers the GUI layer only.

The core obstacle is that Gazebo Transport (ZeroMQ + UDP multicast) does not propagate
across pod boundaries by default. The `GZ_RELAY` environment variable resolves this by
switching discovery to unicast. A second constraint is that OpenShift's default
`restricted-v2` SCC blocks the fixed UIDs that VNC tooling requires.

> Research basis: 106 agents, 23 sources, 86 claims extracted, 25 adversarially verified
> (13 confirmed, 12 killed).

---

## Architecture Background: How the Client/Server Split Works

Gazebo already has a proper client/server architecture (confirmed 3-0):

- **`gz sim -s`** — simulation server (physics, sensors, plugins)
- **`gz sim -g`** — GUI-only frontend (Qt-based, connects over Gazebo Transport)

All data crossing the process boundary flows through **Gazebo Transport**
(ZeroMQ + Protobuf). The `SceneBroadcaster` system plugin is the required bridge on the
server side — it packages world state and sends it to the frontend. This plugin is already
present in the deployed `diff_drive.sdf`.

### The Discovery Problem

Gazebo Transport uses **UDP multicast for node discovery**, which does not propagate
across pod/network boundaries (confirmed 3-0; also reported in gz-transport issue #544).

**Solution: `GZ_RELAY`** (confirmed 3-0)

```bash
# Set on the GUI pod — switches discovery to unicast relay toward the sim server pod
export GZ_RELAY=<sim-server-pod-ip>
gz sim -g
```

Post-discovery data exchange uses standard Kubernetes pod-to-pod TCP/UDP networking,
which is mutually reachable within a cluster with no NAT issues.

---

## Option A — TurboVNC + noVNC (Remote Desktop in Browser)

**Confidence: high (3-0 confirmed)**

Runs the Gazebo Qt GUI inside a virtual X session and exposes it as an HTML5 remote
desktop through an OpenShift Route. No physical display required.

### Architecture

```
Namespace: ros2-zenoh-gazebo
┌─────────────────────────────────────────────────────────────────┐
│  Deployment: gazebo-gui                                         │
│                                                                 │
│  TurboVNC (Xvnc) ── acts as X server + VNC server on :5901     │
│       │                                                         │
│  gz sim -g  (Qt GUI, DISPLAY=:1, GZ_RELAY=<sim-pod-ip>)        │
│       │                                                         │
│  noVNC ── WebSocket bridge → HTML5 browser on :6901             │
└───────────────────────┬─────────────────────────────────────────┘
                        │ OpenShift Route (HTTP → :6901)
                        ▼
            Browser: https://gazebo-gui.<cluster-domain>
```

### Data Flow

```
Existing gazebo-sim pod          New gazebo-gui pod
  gz sim -s (server)    ←─ GZ_RELAY (unicast) ─→   gz sim -g (client)
  SceneBroadcaster plugin                            Qt GUI renders world
                                                     │
                                                TurboVNC (Xvnc :1)
                                                noVNC (:6901)
                                                     │
                                             Browser (HTML5 canvas)
```

### New Kubernetes Objects Required

| Object | Purpose |
|---|---|
| `ServiceAccount/gazebo-gui` | Dedicated SA to receive anyuid SCC |
| `Deployment/gazebo-gui` | TurboVNC + noVNC + gz sim -g |
| `Service/gazebo-gui` | ClusterIP exposing port 6901 |
| `Route/gazebo-gui` | OpenShift HTTP route to the browser |
| `Dockerfile.gazebo-gui` | Ubuntu Noble + ros-jazzy-ros-gz + TurboVNC + noVNC + Lubuntu/XFCE |

### OpenShift SCC Requirement

```bash
oc create serviceaccount gazebo-gui -n ros2-zenoh-gazebo
oc adm policy add-scc-to-user anyuid \
  system:serviceaccount:ros2-zenoh-gazebo:gazebo-gui
```

`anyuid` allows any UID including root, but **SELinux MCS labels are still enforced**
(MustRunAs strategy). This is less permissive than `privileged` and is the correct level
for VNC workloads.

### Reference Implementations

- [`github.com/Open-UAV/openuav-turbovnc`](https://github.com/Open-UAV/openuav-turbovnc)
  — TurboVNC + noVNC + Gazebo on headless UAV servers
- [`github.com/li-haojia/nvidia-ros-vnc`](https://github.com/li-haojia/nvidia-ros-vnc)
  — TurboVNC + noVNC + VirtualGL + Gazebo, browser access at `http://hostip:6901`

Both target bare-metal nvidia-docker2, not Kubernetes natively. No existing Kubernetes-
native Helm chart or maintained container image for this pattern was found — a new
`Dockerfile.gazebo-gui` must be built from scratch.

---

## Option B — GzWeb (Native Browser Visualization via WebSocket)

**Confidence: medium (2-1 confirmed)**

GzWeb is a JavaScript/TypeScript browser client that renders the simulation in WebGL.
No VNC, no X server, no SCC changes required.

### Architecture

```
Namespace: ros2-zenoh-gazebo
┌──────────────────────────────────┐    ┌──────────────────────────────┐
│  Deployment: gazebo-sim          │    │  Deployment: gzweb           │
│  (existing — add plugin)         │    │                              │
│                                  │    │  GzWeb JS bundle             │
│  gz sim -s --headless-rendering  │    │  (static web server)         │
│  + WebsocketServer plugin        │◄───│                              │
│                                  │ WS │                              │
│  Service port: 9002 (WebSocket)  │    └──────────────┬───────────────┘
└──────────────────────────────────┘                   │ OpenShift Route
         Service/gazebo-sim-ws                         ▼
                                           Browser: WebGL 3D view
```

### Changes to Existing Deployment

Add the WebSocket launcher plugin to the existing `diff_drive.sdf` (or inject at runtime
via a separate `gz launch` command in the existing `gazebo-sim` pod):

```xml
<!-- Add to diff_drive.sdf world element -->
<plugin filename="gz-launch-websocket-server"
        name="gz::launch::WebsocketServer">
  <port>9002</port>
</plugin>
```

Expose port 9002 from the existing `gazebo-sim` pod via a new Service:

```yaml
# k8s/gazebo/service-gazebo-ws.yaml
apiVersion: v1
kind: Service
metadata:
  name: gazebo-sim-ws
  namespace: ros2-zenoh-gazebo
spec:
  selector:
    app: gazebo-sim
  ports:
    - port: 9002
      targetPort: 9002
      protocol: TCP
```

Deploy GzWeb as a static web server pointing at the WebSocket endpoint:

```yaml
# k8s/gazebo/deployment-gzweb.yaml
# Serves github.com/gazebo-web/gzweb JS bundle
# Browser connects to app.gazebosim.org/visualization or self-hosted gzweb
```

### No SCC Changes Required

GzWeb is a pure web server — it runs as any UID and the existing `restricted-v2` SCC is
sufficient. The existing `gazebo-sim` pod also requires no SCC changes.

### Caveat

GzWeb is a **community project** under the `gazebo-web` organization, not a first-party
Gazebo tool (refuted 0-3 in adversarial verification). Its Harmonic compatibility needs
independent verification — specifically whether `gz::launch::WebsocketServer` ships with
`ros-jazzy-ros-gz` and is stable in Harmonic.

---

## Comparison

| Criterion | Option A (TurboVNC + noVNC) | Option B (GzWeb) |
|---|---|---|
| GUI fidelity | Full (all panels, plugins, entity inspector) | Visualization only (no GUI panels) |
| Browser experience | Remote desktop (VNC latency ~50–200 ms) | Native WebGL (smooth) |
| OpenShift SCC change | `anyuid` required | None |
| Implementation effort | High — new Dockerfile, SCC setup | Low — add plugin + one new Deployment |
| Harmonic compatibility | Confirmed | Needs verification |
| No GPU required | Yes (Mesa llvmpipe, same as sim server) | Yes (WebGL runs in browser) |
| Maintenance overhead | High (TurboVNC + noVNC versions) | Low |

---

## Recommendation

**Start with Option B (GzWeb)** — it requires the fewest changes:
- One new XML plugin element in the SDF (or a launch file addition)
- One new `Service` for port 9002
- One new `Deployment` for the GzWeb static server
- One new `Route`
- Zero SCC changes

**Use Option A (TurboVNC + noVNC)** if full Gazebo GUI panel access (entity inspector,
plugin loading, world editing) is required, accepting the anyuid SCC grant and the effort
of building a new GUI image.

---

## Open Questions Before Implementation

1. **GZ_RELAY port range**: Does `gz sim -g` connecting via `GZ_RELAY` to a sim server
   in a different pod work reliably? What port range does Gazebo Transport use for
   post-discovery data exchange that would need to be exposed via a Service?

2. **WebSocket plugin availability**: Does `gz::launch::WebsocketServer` ship with
   `ros-jazzy-ros-gz` (Harmonic), or must it be installed separately? Is the GzWeb
   JavaScript client compatible with the Harmonic WebSocket API?

3. **GPU for GUI rendering** (Option A only): For GPU-accelerated Gazebo Qt rendering
   in a Kubernetes pod, does `anyuid` + NVIDIA device plugin resource limit suffice, or
   is the `privileged` SCC required?

---

## Sources

- [Gazebo Harmonic Architecture](https://gazebosim.org/docs/harmonic/architecture/)
- [Gazebo Transport 14 Relay](https://gazebosim.org/api/transport/14/relay.html)
- [gz-transport Kubernetes issue #544](https://github.com/gazebosim/gz-transport/issues/544)
- [Gazebo Web Visualization (Harmonic)](https://gazebosim.org/docs/harmonic/web_visualization/)
- [GzWeb GitHub](https://github.com/gazebo-web/gzweb)
- [Open-UAV TurboVNC](https://github.com/Open-UAV/openuav-turbovnc)
- [nvidia-ros-vnc (TurboVNC + noVNC + Gazebo)](https://github.com/li-haojia/nvidia-ros-vnc)
- [OCP 4.14 SCC Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/html/authentication_and_authorization/managing-pod-security-policies)
- [Red Hat Guide to OpenShift and UIDs](https://www.redhat.com/en/blog/a-guide-to-openshift-and-uids)
