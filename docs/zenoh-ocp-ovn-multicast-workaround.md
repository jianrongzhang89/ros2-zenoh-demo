# Zenoh on OCP/OVN: Multicast Scouting Workaround

## The Problem

OpenShift Container Platform (OCP) uses OVN-Kubernetes as its default CNI plugin.
OVN-Kubernetes **blocks multicast traffic between pods by default**. Enabling multicast
requires an explicit opt-in annotation on each namespace and typically needs cluster-admin
permission to grant.

Zenoh's default scouting mechanism relies on UDP multicast to discover peers:

```
Zenoh default scouting → UDP multicast to 224.0.0.224:7446
```

On a plain Kubernetes cluster or on bare-metal, this works. On OCP with OVN-Kubernetes,
the multicast packets are silently dropped. The result: Zenoh nodes start cleanly but never
find each other, and no messages are exchanged.

---

## Symptoms

This failure mode is silent — there are no crash logs or error messages, only absence of traffic.

| Observable | With multicast blocked |
|------------|----------------------|
| Pods start | Yes — all containers reach `Running` |
| `ros2 topic list` output | Empty (no peers discovered) |
| `ros2 topic echo /chatter` | No output |
| Zenoh logs | Repeated "scouting" lines, no peer found |
| `kubectl logs` errors | None |

The silent failure is the main gotcha: operators assume the deployment is broken for an unrelated
reason when the actual root cause is a missing two-line config change.

---

## The Fix: Unicast Connect Endpoints

Disable multicast scouting and tell every Zenoh client exactly where the router lives:

```json5
{
  mode: "client",
  connect: {
    endpoints: ["tcp/zenoh-router:7447"]   // explicit unicast → no multicast needed
  },
  scouting: {
    multicast: { enabled: false }           // must be false on OCP/OVN
  }
}
```

In client mode with explicit `connect.endpoints`, Zenoh skips scouting entirely and opens a
direct TCP connection to the named endpoint. OVN-Kubernetes routes TCP traffic to ClusterIP
Services correctly; only multicast is blocked.

**The router does not need this change.** `rmw_zenohd` and `zenohd` listen passively on port
7447 and accept incoming connections — they do not initiate scouting themselves.

---

## Reference ConfigMap

Apply `k8s/configmap-zenoh-ocp.yaml` to create both configs in a single command:

```bash
kubectl apply -f k8s/configmap-zenoh-ocp.yaml
```

The file covers both deployment patterns used in this repo:

| ConfigMap | Pattern | Namespace |
|-----------|---------|-----------|
| `zenoh-ocp-client-config` | `rmw_zenoh_cpp` clients (talker/listener) | `ros2-zenoh` |
| `zenoh-ocp-bridge-config` | `zenoh-bridge-ros2dds` sidecars | `ros2-zenoh-bridge` |

See the file for the full YAML with inline comments explaining each field.

---

## Why Each Field Matters

### `mode: "client"`

Puts the Zenoh session in client mode. A client does not route messages itself; it connects to a
router and delegates all routing there. This is the correct mode for talker/listener pods and
bridge sidecars on Kubernetes — only the central router pod runs in `mode: "router"`.

### `connect.endpoints`

A static list of TCP addresses the client dials at startup. By providing the ClusterIP Service
name (`zenoh-router:7447` or `zenoh-bridge-router:7447`), the client bypasses the scouting phase
entirely and goes straight to a TCP connect. Kubernetes DNS resolves the Service name to the
ClusterIP, which OVN forwards correctly to the router pod.

### `scouting.multicast.enabled: false`

Disables the UDP multicast probe entirely. Without this flag, Zenoh still attempts multicast even
after a successful `connect` — the probe runs in the background and generates noisy log lines.
Setting it to `false` produces a clean startup with no multicast traffic.

### `transport.shared_memory.enabled: false`

Shared memory transport is a performance optimization for processes on the same host. It has no
effect across pods and can trigger warnings if the container's `/dev/shm` size is constrained by
the pod's `medium: Memory` tmpfs. Disabling it explicitly prevents both the noise and any
potential startup failures on constrained environments.

---

## Alternative: Enable OVN Multicast (Not Recommended)

OVN-Kubernetes can be told to forward multicast within a namespace:

```bash
# Requires cluster-admin or a role that can annotate namespaces
kubectl annotate namespace ros2-zenoh k8s.ovn.org/multicast-enabled="true"
```

This is **not recommended** for Zenoh deployments because:

1. Requires elevated permissions — typically blocked for application teams on managed OCP.
2. Enables multicast for all workloads in the namespace, not just Zenoh.
3. The unicast workaround is simpler and more deterministic than relying on multicast forwarding.
4. The official ROS 2 Zenoh docs and the upstream `rmw_zenoh` sample configs already use the
   unicast pattern; multicast is never needed in a Kubernetes deployment.

---

## Diagnostic Steps

If Zenoh communication is broken on OCP, run through this checklist:

### 1. Verify TCP reachability

```bash
# From inside a talker or listener pod
kubectl exec -n ros2-zenoh deploy/ros2-talker -- \
  python3 -c "
import socket, sys
try:
    s = socket.create_connection(('zenoh-router', 7447), timeout=3)
    s.close(); print('OK: TCP 7447 reachable')
except OSError as e:
    print(f'FAIL: {e}'); sys.exit(1)
"
```

If this fails, the Service or Deployment is not ready — check `kubectl get svc,pods -n ros2-zenoh`.

### 2. Check the loaded Zenoh config

```bash
# Confirm the env var points to the ConfigMap mount
kubectl exec -n ros2-zenoh deploy/ros2-talker -- \
  sh -c 'echo $ZENOH_SESSION_CONFIG_URI && cat $ZENOH_SESSION_CONFIG_URI'
```

Expected output shows `scouting.multicast.enabled: false` and the correct `connect.endpoints`.

### 3. Inspect Zenoh startup logs

```bash
kubectl logs -n ros2-zenoh -l app=ros2-talker | grep -E 'scouting|connect|peer|session'
```

With the correct config you should see a TCP connect log line and no multicast probe lines.
With the wrong config (or no config) you will see repeated "scouting multicast" attempts.

### 4. Verify multicast is blocked (optional — confirms root cause)

```bash
# Send a test multicast packet from one pod and listen in another
# If nothing arrives, OVN is blocking it as expected
kubectl exec -n ros2-zenoh deploy/ros2-talker -- \
  python3 -c "
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.sendto(b'test', ('224.0.0.224', 7446))
print('packet sent')
"
```

---

## Config File Locations by Pattern

### rmw_zenoh_cpp (native Zenoh RMW)

The config path is set by the `ZENOH_SESSION_CONFIG_URI` environment variable:

```yaml
env:
  - name: ZENOH_SESSION_CONFIG_URI
    value: /etc/zenoh/zenoh-client.json5
volumeMounts:
  - name: zenoh-config
    mountPath: /etc/zenoh
volumes:
  - name: zenoh-config
    configMap:
      name: zenoh-ocp-client-config
```

If `ZENOH_SESSION_CONFIG_URI` is unset, `rmw_zenoh_cpp` falls back to the config baked into the
image at `/zenoh-client.json5`. The `Dockerfile.ros2` in this repo copies a correct config there,
but the ConfigMap mount takes precedence and is the authoritative source.

### zenoh-bridge-ros2dds (DDS bridge sidecar)

The config path is passed via the `-c` flag to the bridge binary:

```yaml
containers:
  - name: zenoh-bridge
    image: docker.io/eclipse/zenoh-bridge-ros2dds:latest
    args: ["-c", "/etc/zenoh/bridge.json5"]
    volumeMounts:
      - name: bridge-config
        mountPath: /etc/zenoh
volumes:
  - name: bridge-config
    configMap:
      name: zenoh-ocp-bridge-config
```

---

## Related Files

| File | Purpose |
|------|---------|
| `k8s/configmap-zenoh-ocp.yaml` | Reference ConfigMap — apply this first |
| `k8s/configmap-zenoh-client.yaml` | rmw_zenoh client config (namespace: ros2-zenoh) |
| `k8s/bridge/configmap-bridge-config.yaml` | Bridge sidecar config (namespace: ros2-zenoh-bridge) |
| `docs/openshift-deployment-proposal.md` | Full rmw_zenoh OCP deployment |
| `docs/zenoh-bridge-ros2dds-openshift-proposal.md` | Full bridge sidecar OCP deployment |
