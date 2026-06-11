# Proposal: Gazebo Simulation Integration with Zenoh ROS 2 Bridge on OpenShift

## Executive Summary

Integration is **architecturally feasible** but requires a **mandatory two-bridge topology**. Gazebo does not speak DDS — it uses its own `gz-transport` (Protobuf/ZeroMQ) layer — so `zenoh-bridge-ros2dds` alone cannot see Gazebo topics. A second bridge, `ros_gz_bridge`, must sit between Gazebo and the existing Zenoh stack.

> Research basis: 214 agents, 49 sources, 204 claims extracted, 50 adversarially verified across two research rounds (24 confirmed, 26 refuted).

---

## The Mandatory Two-Bridge Data Flow

```
Gazebo Harmonic
  (gz-transport / ZeroMQ)
        │
        ▼  [ros_gz_bridge pod]
 ROS 2 DDS layer
  (standard topics: /scan, /odom, /cmd_vel, /joint_states, /tf ...)
        │
        ▼  [zenoh-bridge-ros2dds pod]
   Zenoh router
        │
        ▼
  Remote ROS 2 nodes
  (rmw_zenoh_cpp clients anywhere)
```

**Refuted assumption**: `zenoh-bridge-ros2dds` cannot bridge Gazebo topics transparently without `ros_gz_bridge` — confirmed 3-0 by adversarial review.

---

## Package Requirements (ROS 2 Jazzy)

| Package | Role | Install |
|---|---|---|
| `ros-jazzy-ros-gz` | Meta-package: bridge + sim + msgs | `apt install ros-jazzy-ros-gz` |
| `ros_gz_bridge` | Translates gz-transport ↔ ROS 2 DDS | included above |
| `ros_gz_sim` | Launches Gazebo from ROS 2 launch files | included above |
| `gz_ros2_control` | Connects ros2_control stack to Gazebo physics | `apt install ros-jazzy-gz-ros2-control` |
| `joint_state_broadcaster` | Publishes `/joint_states` from Gazebo hardware interfaces | via `ros2_control` |

**Pairing (3-0 confirmed)**: ROS 2 Jazzy → **Gazebo Harmonic** (LTS). Gazebo Ionic + Jazzy exists but has no official binaries.

---

## Headless Rendering in OpenShift Containers

**Confirmed (3-0)**:
- Gazebo headless mode requires **OGRE2** (not OGRE1) — Gazebo Harmonic ships OGRE2 by default
- Launch command: `DISPLAY= gz sim -v 4 -s -r --headless-rendering robot.sdf`
- Uses **EGL** (GPU-side context without X server) — no display server needed
- `ros-jazzy-ros-gz` APT packages include OGRE2-enabled Gazebo Harmonic

**Refuted**: The claim that `gui:=false` with a separate visualization client is the headless pattern — 0-3 vote. The `--headless-rendering` + empty `DISPLAY` flag is the correct pattern.

### GPU vs. Software EGL Decision

Software EGL via Mesa (`llvmpipe`) is technically feasible — a GPU is **not required** for the headless path. No benchmark data comparing Mesa software rendering against NVIDIA GPU EGL for Gazebo sensor workloads exists in primary sources (all such claims were unconfirmed in adversarial review), so the performance trade-off must be measured empirically.

| Scenario | Rendering approach | Pod env vars |
|---|---|---|
| CI / functional testing | Mesa software EGL (no GPU) | `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe` |
| Production / real-time sensor sim | NVIDIA GPU via GPU Operator | GPU resource request + device mount |

**NVIDIA GPU Operator SCC (confirmed 3-0)**: The driver DaemonSet SCC (`0410_scc.openshift.yaml`) sets `runAsUser`, `seLinuxContext`, `fsGroup`, and `supplementalGroups` all to `RunAsAny` — the most permissive SCC. This applies only to the driver container; the Gazebo workload pod requires a separate, narrower SCC scoped to its actual privilege needs (device access to `/dev/dri` or similar).

---

## ros_gz_bridge Configuration

Bridge direction is per-topic, configured via YAML or CLI:

```yaml
# ros_gz_bridge YAML config
- ros_topic_name: /scan
  gz_topic_name: /lidar
  ros_type_name: sensor_msgs/msg/LaserScan
  gz_type_name: gz.msgs.LaserScan
  direction: GZ_TO_ROS   # or BIDIRECTIONAL / ROS_TO_GZ

- ros_topic_name: /cmd_vel
  gz_topic_name: /cmd_vel
  ros_type_name: geometry_msgs/msg/Twist
  gz_type_name: gz.msgs.Twist
  direction: ROS_TO_GZ
```

**Confirmed supported message types** (3-0): `sensor_msgs/LaserScan`, `sensor_msgs/Image`, `sensor_msgs/PointCloud2`, `nav_msgs/Odometry`, `geometry_msgs/Twist`, `tf2_msgs/TFMessage`. Custom types require custom bridge code.

---

## zenoh-bridge-ros2dds Topic Filtering

Once `ros_gz_bridge` publishes on DDS, `zenoh-bridge-ros2dds` sees them identically to any ROS 2 publisher. Use regex filtering in `zenoh-client.json5` to control what crosses the Zenoh layer:

```json5
// zenoh-client.json5 additions
allow: {
  publishers: [".*/(scan|odom|joint_states|tf|tf_static|camera/image_raw)"],
  subscribers: [".*/cmd_vel"],
},
pub_max_frequencies: [
  ".*/camera/image_raw=10",   // cap camera at 10 Hz
  ".*/scan=5",                // cap lidar at 5 Hz
  ".*/odom=20"
]
```

**Known bug**: The `deny` filter on the subscriber side has a defect (issue #241, Sept 2024). Use `allow` (not `deny`) for subscriber filtering.

---

## Complete OpenShift Architecture Proposal

```
Namespace: ros2-zenoh   [annotated: k8s.ovn.org/multicast-enabled=true]
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│  ┌──────────────────────┐  LIBGL_ALWAYS_SOFTWARE=1 (CI)           │
│  │  Deployment:         │  OR NVIDIA GPU device (production)       │
│  │  gazebo-sim          │  DISPLAY= gz sim --headless-rendering    │
│  │  (ros-jazzy-ros-gz   │  robot.sdf                               │
│  │   + OGRE2 + EGL)     │  gz-transport (ZeroMQ) ──────────┐      │
│  └──────────────────────┘                                   │      │
│                                                             │      │
│  ┌──────────────────────┐                                   │      │
│  │  Deployment:         │◄──────────────────────────────────┘      │
│  │  ros-gz-bridge       │  ros_gz_bridge parameter_bridge          │
│  │  (ros-jazzy-ros-gz)  │  gz-transport → ROS 2 DDS               │
│  └──────────┬───────────┘                                          │
│             │ ROS 2 DDS/RTPS multicast (enabled by ns annotation)  │
│  ┌──────────▼───────────┐                                          │
│  │  Deployment:         │  zenoh-bridge-ros2dds                    │
│  │  zenoh-bridge        │  DDS → Zenoh TCP (no multicast needed)   │
│  └──────────┬───────────┘                                          │
│             │ TCP :7447                                             │
│  ┌──────────▼───────────┐   ClusterIP / Route                      │
│  │  Deployment:         │                                          │
│  │  zenoh-router        │◄──── external rmw_zenoh_cpp clients      │
│  └──────────────────────┘                                          │
│                                                                    │
│  ┌──────────────────────┐                                          │
│  │  Deployment:         │  Subscribes /scan, /odom via Zenoh       │
│  │  ros2-nav-node       │  Publishes /cmd_vel back to Gazebo        │
│  └──────────────────────┘                                          │
└────────────────────────────────────────────────────────────────────┘
```

### New Kubernetes Objects Needed

| Object | Purpose |
|---|---|
| `Deployment/gazebo-sim` | Gazebo Harmonic headless simulation pod |
| `Deployment/ros-gz-bridge` | `ros_gz_bridge` translating sim topics to DDS |
| `ConfigMap/ros-gz-bridge-config` | YAML bridge topic list |
| `Deployment/ros2-controller` | Nav/control node subscribing over Zenoh |

The existing `zenoh-router`, `zenoh-bridge`, and `zenoh-client.json5` ConfigMap remain unchanged, with only the `allow`/`pub_max_frequencies` additions above.

---

## gz_ros2_control Integration (for Actuated Robots)

For a robot with controllable joints (arm, wheels with encoder feedback):

```xml
<!-- in robot URDF/SDF -->
<plugin filename="gz_ros2_control-system" name="gz_ros2_control::GazeboSimROS2ControlPlugin">
  <parameters>$(find my_robot_bringup)/config/ros2_controllers.yaml</parameters>
</plugin>
```

This publishes:
- `/joint_states` (`sensor_msgs/JointState`) — bridged by `zenoh-bridge-ros2dds` automatically
- `/dynamic_joint_states` (`control_msgs/DynamicJointState`) — full hardware state
- Subscribes `/diff_drive_controller/cmd_vel` — write-back path through Zenoh → DDS → Gazebo

---

## DDS Discovery Under OVN-Kubernetes (Resolved)

OVN-Kubernetes **blocks all UDP multicast between pods by default**. This is a confirmed fact (3-0) supported by official OVN-Kubernetes and Red Hat OpenShift documentation across versions 4.4–4.19.

### Solution: Per-Namespace Multicast Annotation

```bash
oc annotate namespace ros2-zenoh k8s.ovn.org/multicast-enabled=true
```

This enables IP multicast for all pods within the `ros2-zenoh` namespace, scoped strictly to that namespace by OVN ACLs. DDS/RTPS auto-discovery between `ros_gz_bridge` and `zenoh-bridge-ros2dds` then works normally — no additional ROS env vars or CycloneDDS XML needed.

**Key insight (confirmed 0-3 refutation)**: `zenoh-plugin-ros2dds` does **not** use UDP multicast for its own peer discovery — it uses Zenoh's TCP-based scouting. This means the multicast dependency is scoped only to the DDS/RTPS layer between `ros_gz_bridge` and `zenoh-bridge` pods. The Zenoh network side (bridge → router → remote clients) is unaffected.

### Fallback Options (if multicast annotation is not available)

```
Option B: Co-locate both bridges in one Pod
  Run ros_gz_bridge + zenoh-bridge-ros2dds as two containers in the same Pod.
  DDS stays on localhost (shared network namespace) — no multicast needed.
  Add: ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST to both containers.

Option C: Fast-DDS Discovery Server
  Deploy a discovery server pod via a headless Kubernetes Service.
  All ROS 2 pods point to it for unicast-only discovery.
  More operational complexity; no confirmed OpenShift reference deployment exists.
```

---

## Open Questions / Remaining Gaps

1. **Mesa llvmpipe throughput**: No benchmark data exists comparing software EGL vs. GPU EGL for Gazebo sensor workloads. Must be measured empirically in your cluster. Start with `LIBGL_ALWAYS_SOFTWARE=1` in CI and benchmark lidar raycasting FPS.

2. **Gazebo workload pod SCC**: The NVIDIA GPU Operator driver SCC is known (`RunAsAny`), but the correct SCC for the Gazebo simulation pod consuming the GPU device (likely needs access to `/dev/dri` or equivalent) is not specified in available documentation.

3. **Bridge loop isolation**: When `ros_gz_bridge` and `zenoh-bridge-ros2dds` share the same DDS domain, DDS discovery must be scoped to prevent the bridge from seeing its own reflected traffic. Set distinct `ROS_DOMAIN_ID` values or use `ROS_LOCALHOST_ONLY=1` on the bridge side.

4. **No confirmed OpenShift end-to-end reference**: The closest references (`ros_k8s`, `ros2-on-kubernetes`) target generic Kubernetes, not OpenShift. `turtlebot/turtlebot4_simulator` uses Gazebo Harmonic + `ros_gz_bridge` and is the best upstream reference for the robot model side.

---

## Sources

- [Gazebo Sim 9 Headless Rendering](https://gazebosim.org/api/sim/9/headless_rendering.html)
- [Gazebo Harmonic ROS 2 Integration](https://gazebosim.org/docs/harmonic/ros2_integration/)
- [ros_gz_bridge ROS 2 Jazzy docs](https://docs.ros.org/en/jazzy/p/ros_gz_bridge/)
- [ros_gz GitHub](https://github.com/gazebosim/ros_gz)
- [gz_ros2_control GitHub](https://github.com/ros-controls/gz_ros2_control)
- [gz_ros2_control ROS 2 Jazzy docs](https://control.ros.org/jazzy/doc/gz_ros2_control/doc/index.html)
- [zenoh-plugin-ros2dds DEFAULT_CONFIG.json5](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds/blob/main/DEFAULT_CONFIG.json5)
- [zenoh-plugin-ros2dds GitHub](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds)
- [TurtleBot4 Simulator](https://turtlebot.github.io/turtlebot4-user-manual/software/turtlebot4_simulator.html)
- [ROS 2 + Kubernetes CNI study (arXiv)](https://arxiv.org/html/2403.04440v1)
- [OVN-Kubernetes Multicast](https://ovn-kubernetes.io/features/multicast/)
- [OpenShift Enabling Multicast (OCP 4.9+)](https://docs.openshift.com/en/container-platform/4.9/networking/ovn_kubernetes_network_provider/enabling-multicast.html)
- [NVIDIA GPU Operator OpenShift SCC](https://github.com/NVIDIA/gpu-operator/blob/main/assets/state-driver/0410_scc.openshift.yaml)
