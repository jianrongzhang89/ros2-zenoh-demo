# Proposal: Gazebo Simulation Integration with Zenoh ROS 2 Bridge on OpenShift

## Executive Summary

Integration is **architecturally feasible** but requires a **mandatory two-bridge topology**. Gazebo does not speak DDS — it uses its own `gz-transport` (Protobuf/ZeroMQ) layer — so `zenoh-bridge-ros2dds` alone cannot see Gazebo topics. A second bridge, `ros_gz_bridge`, must sit between Gazebo and the existing Zenoh stack.

> Research basis: 110 agents, 27 sources, 109 claims extracted, 25 adversarially verified (17 confirmed, 8 refuted).

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

**Open gap**: Whether OpenShift nodes need the NVIDIA GPU Operator or can fall back to Mesa software EGL (`llvmpipe`/`swrast`) for sensor simulation is **unconfirmed**. CPU EGL is technically possible but performance is uncharacterized.

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
Namespace: ros2-zenoh
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│  ┌──────────────────────┐                                          │
│  │  Deployment:         │  DISPLAY= gz sim --headless-rendering    │
│  │  gazebo-sim          │  robot.sdf                               │
│  │  (ros-jazzy-ros-gz   │                                          │
│  │   + OGRE2 + EGL)     │  gz-transport (ZeroMQ) ──────────┐      │
│  └──────────────────────┘                                   │      │
│                                                             │      │
│  ┌──────────────────────┐                                   │      │
│  │  Deployment:         │◄──────────────────────────────────┘      │
│  │  ros-gz-bridge       │  ros_gz_bridge parameter_bridge           │
│  │  (ros-jazzy-ros-gz)  │  gz-transport → ROS 2 DDS                │
│  └──────────┬───────────┘                                          │
│             │ ROS 2 DDS (CycloneDDS, same pod network)             │
│  ┌──────────▼───────────┐                                          │
│  │  Deployment:         │  zenoh-bridge-ros2dds                    │
│  │  zenoh-bridge        │  DDS → Zenoh (pub_max_frequencies)       │
│  └──────────┬───────────┘                                          │
│             │ TCP :7447                                             │
│  ┌──────────▼───────────┐   ClusterIP / Route                      │
│  │  Deployment:         │                                           │
│  │  zenoh-router        │◄──── external rmw_zenoh_cpp clients       │
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

## Open Questions / Known Gaps

1. **GPU vs. software EGL**: Does the OpenShift cluster need the NVIDIA GPU Operator, or does Mesa `llvmpipe` provide acceptable performance for headless sensor simulation (lidar raycast, camera rendering)?

2. **DDS multicast in OVN-Kubernetes**: OpenShift's default CNI is OVN-Kubernetes. Whether DDS/RTPS discovery between `ros-gz-bridge` and `zenoh-bridge` pods requires `ROS_AUTOMATIC_DISCOVERY_RANGE=SUBNET` + multicast routing, or whether host-networking / unicast-only peer config is needed, is unconfirmed. This is the most critical operational risk.

3. **Bridge loop isolation**: When `ros_gz_bridge` and `zenoh-bridge-ros2dds` share the same DDS domain, DDS discovery must be scoped (e.g., `ROS_DOMAIN_ID` or `localhost` range) to prevent the bridge from seeing its own reflected traffic.

4. **TurtleBot4 reference**: The `turtlebot4_simulator` package (GitHub: `turtlebot/turtlebot4_simulator`) uses Gazebo Harmonic + `ros_gz_bridge` and is the closest upstream reference for this topology, though no containerized OpenShift reference deployment exists yet.

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
