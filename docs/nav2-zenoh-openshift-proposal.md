# Proposal: ROS 2 Nav2 + Gazebo Simulation via Zenoh DDS Bridge on OpenShift

## Executive Summary

The next evolution of this demo is to deploy the **ROS 2 Navigation Stack (Nav2)**
as independent OpenShift pods that receive sensor data from the Gazebo simulation
through the existing Zenoh bridge and send autonomous navigation commands back to
the robot — all without any DDS multicast, all Kubernetes-native.

Nav2's server-based plugin architecture maps directly onto Kubernetes: each server
process (Planner Server, Controller Server, BT Navigator) becomes its own pod,
communicating through ROS 2 action server interfaces routed over Zenoh. The Gazebo
simulation already provides the required topics (/odom, /tf, /cmd_vel). Adding a
lidar sensor to the robot model unlocks SLAM via slam_toolbox, enabling real-time
map building from the cloud.

The recommended first demo is **autonomous warehouse navigation** — Nav2 ships three
production-ready Python scripts for this scenario that run against any diff-drive
robot without modification.

> Research basis: 104 agents, 22 sources, 92 claims extracted, 25 adversarially
> verified (14 confirmed, 11 killed). No existing published project combines all four
> elements (Nav2 + Zenoh + Kubernetes + Gazebo); this is novel cloud-native robotics
> engineering.

---

## Background: What Is Already Running

```
Namespace: ros2-zenoh-gazebo
  gazebo-sim pod          gz sim -s (diff-drive robot, SceneBroadcaster)
  ├── ros-gz-bridge        /odom /tf /cmd_vel /clock  ←→  gz-transport
  └── zenoh-bridge         ROS 2 DDS → Zenoh TCP

  zenoh-router pod         central Zenoh hub (TCP :7447)
  gzweb pod                GzWeb landing page + WebSocket 3D view
```

All ROS 2 topics from the simulation are already available over Zenoh. Any pod
using `rmw_zenoh_cpp` as its RMW layer can subscribe and publish to these topics
simply by connecting to the zenoh-router Service.

**Zenoh is now Tier-1 RMW** in ROS 2 Kilted Kaiju (released May 23, 2025) —
the first ROS 2 distribution to officially designate `rmw_zenoh_cpp` as Tier-1
middleware (satisfying thread safety, SROS2 security, and REP-2005 requirements).
For Jazzy deployments (currently used), rmw_zenoh_cpp is Tier-3/experimental but
fully functional.

---

## Nav2 Architecture on Kubernetes

Nav2 is a collection of **independently deployable lifecycle node servers** that
communicate through ROS 2 action server interfaces. This decomposition maps
naturally onto Kubernetes pods (confirmed 3-0 by IEEE ICRA 2023 KubeROS paper):

```
┌─────────────────────────────────────────────────────────────────────┐
│  Namespace: ros2-zenoh-gazebo                                       │
│                                                                     │
│  ┌──────────────────────────────────────────────┐                  │
│  │  Existing: gazebo-sim pod                    │                  │
│  │  publishes: /odom /tf /tf_static /clock      │                  │
│  │  subscribes: /cmd_vel                        │                  │
│  └──────────────────┬───────────────────────────┘                  │
│                     │ Zenoh TCP via zenoh-router                   │
│  ┌──────────────────▼───────────────────────────┐                  │
│  │  New: nav2 pod (all servers co-located)      │                  │
│  │                                              │                  │
│  │  ┌─────────────────┐  ┌──────────────────┐  │                  │
│  │  │  BT Navigator   │  │  Map Server      │  │                  │
│  │  │  (orchestrator) │  │  (static map)    │  │                  │
│  │  └────────┬────────┘  └──────────────────┘  │                  │
│  │           │ action                           │                  │
│  │  ┌────────▼────────┐  ┌──────────────────┐  │                  │
│  │  │  Planner Server │  │  AMCL            │  │                  │
│  │  │  (global path)  │  │  (localisation)  │  │                  │
│  │  └────────┬────────┘  └──────────────────┘  │                  │
│  │           │ action                           │                  │
│  │  ┌────────▼──────────────────────────────┐  │                  │
│  │  │  Controller Server + local Costmap2D  │  │                  │
│  │  │  → publishes /cmd_vel to robot        │  │                  │
│  │  └───────────────────────────────────────┘  │                  │
│  └──────────────────────────────────────────────┘                  │
│                                                                     │
│  ┌──────────────────────────────────────────────┐  (Phase 2)      │
│  │  New: slam-toolbox pod                       │                  │
│  │  subscribes: /scan /tf                       │                  │
│  │  publishes: /map (nav_msgs/OccupancyGrid)    │                  │
│  └──────────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Nav2 Server Roles (confirmed 3-0)

| Server | Role | Kubernetes Fit |
|---|---|---|
| **BT Navigator** | Orchestrates the full navigation pipeline via Behaviour Trees; exposes `NavigateToPose` action | Single pod; lightweight |
| **Planner Server** | Computes global path from current pose to goal (e.g. NavFn, Smac) | CPU-intensive; scalable independently |
| **Controller Server** | Executes local trajectory following; **hosts local Costmap2D** (co-located by design for low latency) | Co-located with planner in initial deployment |
| **Map Server** | Serves a pre-built static map as `nav_msgs/OccupancyGrid` | Stateless; ConfigMap-backed |
| **AMCL** | Probabilistic localisation on a known map using /odom + /scan | Requires /scan; Phase 2 |

> **Note:** The Controller Server and local Costmap2D are deliberately co-located
> in the same process for low-latency costmap updates. Do not split them.

---

## Topic Bridge Requirements

### Phase 1 — Navigation on a Known Map (no SLAM)

| Topic | Direction | Type | Purpose |
|---|---|---|---|
| `/odom` | Sim → Nav2 | `nav_msgs/Odometry` | Wheel odometry for localisation |
| `/tf` | Sim → Nav2 | `tf2_msgs/TFMessage` | `odom → base_link` transform chain |
| `/tf_static` | Sim → Nav2 | `tf2_msgs/TFMessage` | Static transforms (base_link → sensors) |
| `/clock` | Sim → Nav2 | `rosgraph_msgs/Clock` | Simulation time (`use_sim_time: true`) |
| `/cmd_vel` | Nav2 → Sim | `geometry_msgs/Twist` | Velocity commands from Controller Server |
| `/map` | Map Server → Nav2 | `nav_msgs/OccupancyGrid` | Static occupancy grid for planning |

All of these are already bridged or directly available via the existing Zenoh
infrastructure. **No new bridge configuration is needed for Phase 1** beyond
adding Nav2 pods that use `rmw_zenoh_cpp` and point to `zenoh-router:7447`.

### Phase 2 — SLAM (replaces static map)

Add to the Gazebo robot SDF:
```xml
<sensor name="lidar" type="lidar">
  <topic>/scan</topic>
  <update_rate>10</update_rate>
  ...
</sensor>
```

Add to `configmap-gz-bridge-config.yaml`:
```yaml
- ros_topic_name: /scan
  gz_topic_name: /scan
  ros_type_name: sensor_msgs/msg/LaserScan
  gz_type_name: gz.msgs.LaserScan
  direction: GZ_TO_ROS
```

slam_toolbox requires exactly (confirmed 2-1):
- `/scan` (`sensor_msgs/LaserScan`)
- TF: `odom → base_link` (already bridged)

---

## Recommended Demo Use Cases

### Use Case 1 (Recommended): Autonomous Warehouse Navigation

**Why:** Nav2 Simple Commander ships three production-ready demo scripts for warehouse
scenarios that run against any diff-drive robot without modification (confirmed 2-1).
This is the lowest implementation risk with the highest visual impact.

**The three built-in scripts:**

| Script | Behaviour | Nav2 Primitive |
|---|---|---|
| `demo_security.py` | Robot patrols a set of waypoints in a loop (security guard pattern) | `NavigateThroughPoses` action |
| `demo_picking.py` | Robot navigates to item pick locations in sequence (warehouse picking) | `NavigateToPose` action |
| `demo_inspection.py` | Robot stops at each shelf location, executes a task, then moves on | `WaypointFollower` + task executors |

**Demo flow:**
1. GzWeb shows the robot in a warehouse-layout world
2. A Python controller pod sends a sequence of waypoint goals via Nav2 Simple Commander
3. Nav2 computes and executes the path; the robot navigates autonomously
4. `/cmd_vel` flows: Nav2 → zenoh-router → zenoh-bridge → ros_gz_bridge → Gazebo DiffDrive
5. GzWeb shows the robot moving along the planned path in real time

---

### Use Case 2: Security Patrol with Event-Driven Deployment

Inspired by **RobotKube** (IEEE ITSC 2023, confirmed 3-0): an Event Detector pod
monitors robot state (position, battery, proximity) and triggers on-demand Nav2
mission pods via the Kubernetes API. The robot patrols a facility autonomously;
when it reaches a point of interest, a new inspection task pod is spawned.

**OpenShift angle:** Demonstrates OpenShift's event-driven pod lifecycle as part
of the robotics application — not just Kubernetes as infrastructure, but as an
active participant in robot decision-making.

---

### Use Case 3 (Phase 3): Multi-Robot Fleet Coordination

Using **Open RMF Free Fleet adapter** (confirmed 3-0): each simulated robot gets
its own Gazebo pod with a per-robot zenoh-bridge namespace prefix. A Fleet Manager
pod issues `navigate_to_pose` actions to each robot independently. The Zenoh router
fans out commands to the correct robot namespace.

**Namespace isolation** (confirmed 2-1): the zenoh-bridge-ros2dds `namespace`
parameter prefixes all Zenoh key expressions per robot. Each Nav2 pod is launched
with a matching ROS namespace so its topics align with the bridge prefix.

```
Robot 1: namespace="/robot1"  → Zenoh keys: robot1/rt/odom, robot1/rt/cmd_vel
Robot 2: namespace="/robot2"  → Zenoh keys: robot2/rt/odom, robot2/rt/cmd_vel
Fleet Manager: subscribes to */odom, publishes to */navigate_to_pose
```

> **Caveat:** Nav2's TF tree (`map → odom → base_link → sensor`) uses globally
> shared frame names. Multi-robot deployments require explicit per-robot TF prefix
> configuration in Nav2 params — bridge-side namespacing alone is not sufficient.

---

## Implementation Phases

### Phase 1 — Nav2 on a Static Map (4–6 weeks)

**Deliverables:**
- `Dockerfile.nav2` — Ubuntu Noble + `ros-jazzy-navigation2` + `ros-jazzy-nav2-bringup`
  + `ros-jazzy-rmw-zenoh-cpp`
- Robot world SDF updated with a warehouse layout (walls, shelves, aisles)
- Static map image (PGM + YAML) generated from the world geometry
- `k8s/nav2/` manifests:
  - `configmap-nav2-params.yaml` — Nav2 parameter file (use_sim_time, costmap config)
  - `configmap-nav2-map.yaml` — static occupancy grid map
  - `deployment-nav2.yaml` — Nav2 servers pod (rmw_zenoh_cpp, connects to zenoh-router)
- `k8s/nav2/deployment-mission.yaml` — Python Simple Commander mission controller
- `Makefile` targets: `deploy-nav2`, `undeploy-nav2`, `demo-patrol`, `demo-picking`

**Topic flow:**
```
gazebo-sim → zenoh-bridge → zenoh-router → nav2 pod
   /odom ─────────────────────────────────► Nav2 localisation
   /tf ───────────────────────────────────► Nav2 TF tree
   /clock ────────────────────────────────► use_sim_time
                                            Nav2 planning
nav2 pod → zenoh-router → zenoh-bridge → gazebo-sim
   /cmd_vel ◄─────────────────────────────── Controller Server
```

### Phase 2 — SLAM (2–3 weeks after Phase 1)

**Deliverables:**
- Lidar sensor added to `diff_drive.sdf` (type: `lidar`, 360° scan at 10 Hz)
- `/scan` added to `configmap-gz-bridge-config.yaml`
- `deployment-slam.yaml` — slam_toolbox pod (online async mode)
- Remove static map; Nav2 uses slam_toolbox `/map` output

### Phase 3 — Multi-Robot Fleet (3–4 weeks after Phase 2)

**Deliverables:**
- Parameterised Gazebo deployment (robot namespace, spawn position)
- Per-robot zenoh-bridge namespace configuration
- Fleet Manager pod with Open RMF Free Fleet adapter
- OpenShift dashboard showing robot positions from `/robot*/odom`

---

## New Kubernetes Objects (Phase 1)

| Object | Purpose |
|---|---|
| `Deployment/nav2` | Nav2 BT Navigator + Planner + Controller + Map Server + AMCL |
| `ConfigMap/nav2-params` | Nav2 YAML parameter file |
| `ConfigMap/nav2-map` | Static PGM map + YAML descriptor |
| `Deployment/mission-controller` | Python Simple Commander waypoint sequencer |
| `ConfigMap/nav2-waypoints` | JSON waypoint list for the demo scenario |

No new Services or Routes needed for Phase 1 — all communication goes through
the existing `zenoh-router` Service.

---

## Reference Projects

| Project | Venue | Relevance |
|---|---|---|
| **KubeROS** | IEEE ICRA 2023 | Demonstrates Nav2 servers split across containers; schedules ROS 2 modules across edge/cloud K8s continuum |
| **RobotKube** | IEEE ITSC 2023 | Event-driven pod deployment triggered by robot state; multi-robot cooperative missions on K8s |
| **Nav2 Simple Commander** | OSRF / nav2 | Three production-ready warehouse demo scripts (`demo_security.py`, `demo_picking.py`, `demo_inspection.py`) |
| **Open RMF Free Fleet** | OSRF | Fleet management adapter that issues `navigate_to_pose` goals to Nav2-enabled robots via Zenoh |
| **rmw_zenoh Tier-1** | ROS 2 Kilted Kaiju (May 2025) | Official Tier-1 status for rmw_zenoh_cpp; validates the transport layer for production use |

---

## Open Questions / Risks

1. **Nav2 lifecycle startup ordering**: Nav2 servers must be brought up in a specific
   sequence (`map_server` → `amcl` → `costmap` → `controller` → `planner` →
   `bt_navigator`). No out-of-box Kubernetes operator manages this sequence across
   separate pods. The simplest mitigation: run all servers in one pod with a
   single launch file (the default `nav2_bringup` approach).

2. **Inter-pod action latency**: Splitting Planner and Controller servers across
   separate Kubernetes pods introduces network latency on action server round-trips.
   Measured impact on controller loop timing is unknown. Recommended: start with
   all Nav2 servers co-located in one pod; split only after profiling.

3. **TF frame naming for multi-robot**: Nav2 uses globally named TF frames by
   convention (`map`, `odom`, `base_link`). Multi-robot Phase 3 requires per-robot
   TF prefix configuration at the Nav2 parameter level — not just bridge-side
   namespacing. This requires careful parameter templating in the Nav2 config.

4. **Simulation fidelity for navigation**: The current diff-drive robot SDF has no
   lidar sensor. Phase 1 uses a static map + wheel odometry (AMCL). AMCL requires
   a sensor input for particle filter updates — either add a lidar sensor (Phase 2)
   or use odometry-only localisation (less accurate). The warehouse world SDF must
   also be more detailed than the current flat plane with no walls.

---

## Sources

- [Nav2 Concepts & Architecture](https://docs.nav2.org/concepts/index.html)
- [Nav2 Controller Server Configuration](https://docs.nav2.org/configuration/packages/configuring-controller-server.html)
- [Nav2 Simple Commander API](https://navigation.ros.org/commander_api/index.html)
- [slam_toolbox GitHub](https://github.com/SteveMacenski/slam_toolbox)
- [zenoh-plugin-ros2dds GitHub](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds)
- [KubeROS — IEEE ICRA 2023](https://ieeexplore.ieee.org/document/10160632/)
- [RobotKube — IEEE ITSC 2023](https://arxiv.org/abs/2308.07053)
- [Open RMF Free Fleet Nav2 Integration](https://osrf.github.io/ros2multirobotbook/integration_free_fleet_adapter.html)
- [ROS 2 Kilted Kaiju Release Notes (rmw_zenoh Tier-1)](https://docs.ros.org/en/kilted/Releases/Release-Kilted-Kaiju.html)
