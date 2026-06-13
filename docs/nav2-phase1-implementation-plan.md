# Nav2 Phase 1 — Implementation Plan: Autonomous Warehouse Navigation on OpenShift

## Context

Deploy ROS 2 Nav2 (Navigation Stack) as OpenShift pods connected to the Gazebo
diff-drive robot simulation through the existing zenoh-bridge-ros2dds infrastructure.
Phase 1 uses a static warehouse map with AMCL localization and Nav2's built-in
Simple Commander for a repeating security-patrol demo.

---

## Target Architecture

```
Namespace: ros2-zenoh-gazebo

[gazebo-sim pod]                  [zenoh-router]              [nav2 pod]
  gazebo-sim (Harmonic)                                         nav2-server
  ros-gz-bridge          ← /odom /tf /scan /clock via Zenoh →  (AMCL + planners
  gz-ws-server           ← /cmd_vel via Zenoh ←                 + controllers)
  zenoh-bridge                                                   mission (patrol)
                                                                 zenoh-bridge
```

All three pods connect to `zenoh-router:7447` via TCP. Nav2 uses DDS on localhost
(same pattern as existing bridge pods) — no rmw_zenoh_cpp config complexity.

---

## Files to Create (new)

### 1. `Dockerfile.nav2`
Ubuntu Noble base (`ros:jazzy-ros-core`), same pattern as `Dockerfile.gazebo`:
- `ros-jazzy-navigation2` — full Nav2 stack
- `ros-jazzy-nav2-bringup` — launch files
- `ros-jazzy-nav2-simple-commander` — Python patrol API
- Non-root user UID 1001, GID 0 for OpenShift `restricted-v2` SCC

### 2. `k8s/nav2/configmap-nav2-params.yaml`
Full `nav2_params.yaml` covering:
- `use_sim_time: true` throughout (critical for Gazebo clock)
- **AMCL**: `scan_topic: /scan`, `odom_frame: odom`, `map_frame: map`,
  `robot_model_type: nav2_amcl::DifferentialMotionModel`
- **BT Navigator**: `NavigateToPose` + `NavigateThroughPoses` plugins
- **Planner Server**: NavFn (global path planning)
- **Controller Server** + local Costmap2D: DWB local planner, `robot_radius: 0.22m`
- **Global costmap**: `static_layer` + `obstacle_layer` (subscribes `/scan`) + `inflation_layer`
- **Local costmap**: rolling window 3×3m, odom frame, VoxelLayer subscribing `/scan`
- **Behavior Server**: spin, back_up, wait recovery behaviors
- **Velocity Smoother**: max 0.5 m/s linear, 1.0 rad/s angular

### 3. `k8s/nav2/configmap-nav2-map.yaml`
Two ConfigMap keys mounted at `/map/`:
- `warehouse.yaml` — map_server metadata:
  ```yaml
  image: warehouse.pgm
  resolution: 0.1
  origin: [-4.0, -4.0, 0.0]
  occupied_thresh: 0.65
  free_thresh: 0.25
  negate: 0
  ```
- `warehouse.pgm` — 80×80 pixel ASCII P2 PGM (8m × 8m at 0.1m/pixel):
  - Outer walls: 3px thick (0.3m) on all four sides
  - Left shelf: cols 20–23, rows 20–60 (at x≈−1.85m, running 4m north-south)
  - Right shelf: cols 57–60, rows 20–60 (at x≈+1.85m)
  - All other pixels: 254 (free)

### 4. `k8s/nav2/configmap-nav2-mission.yaml`
Python patrol script (mounted at `/mission/patrol.py`):
- Uses `nav2_simple_commander.robot_navigator.BasicNavigator`
- Calls `goThroughPoses()` with 4 waypoints in the map frame:
  `(-3,0)` → `(0,3)` → `(3,0)` → `(0,-3)` (west → north → east → south aisle)
- Loops continuously; prints `Distance remaining: Xm` feedback
- Waits for Nav2 to be active before starting

### 5. `k8s/nav2/deployment-nav2.yaml`
Three containers in one pod:

| Container | Image | Role |
|---|---|---|
| `nav2-server` | `quay.io/jianrzha/ros2-zenoh-nav2:latest` | Nav2 bringup launch (AMCL + planners + controllers + map server) |
| `mission` | `quay.io/jianrzha/ros2-zenoh-nav2:latest` | Python patrol script; calls `NavigateThroughPoses` on nav2-server via localhost DDS |
| `zenoh-bridge` | `eclipse/zenoh-bridge-ros2dds:latest` | Bridges localhost DDS ↔ zenoh-router; reuses `configmap-zenoh-bridge-config` |

- All containers: `ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST`
- initContainer waits for `zenoh-router:7447` (same Python wait-loop pattern)
- nav2-server waits an additional 20 s for the simulation to be fully up before starting (sleep in entrypoint)
- mission container waits via `navigator.waitUntilNav2Active()` (Nav2 lifecycle)

---

## Files to Modify (existing)

### 6. `k8s/gazebo/configmap-robot-model.yaml`
Add to the diff_drive world SDF:

**Warehouse walls** (4 static box models):
```
north_wall: pose (0, 3.85, 1.0)  size 8.0 × 0.3 × 2.0
south_wall: pose (0,-3.85, 1.0)  size 8.0 × 0.3 × 2.0
east_wall:  pose (3.85, 0, 1.0)  size 0.3 × 8.0 × 2.0
west_wall:  pose(-3.85, 0, 1.0)  size 0.3 × 8.0 × 2.0
```

**Shelves** (2 static box models, gray visual):
```
left_shelf:  pose(-1.85, 0, 0.75)  size 0.3 × 3.0 × 1.5
right_shelf: pose( 1.85, 0, 0.75)  size 0.3 × 3.0 × 1.5
```

**Lidar sensor** added to the robot (`diff_drive_robot` model):
```xml
<link name="laser">
  <pose relative_to="base_link">0.15 0 0.05 0 0 0</pose>
  <sensor name="lidar" type="lidar">
    <topic>scan</topic>
    <update_rate>10</update_rate>
    <!-- 360° scan, 8m range, CPU-based (no GPU/OGRE2 required) -->
  </sensor>
</link>
<joint name="laser_joint" type="fixed">
  <parent>base_link</parent><child>laser</child>
</joint>
```

### 7. `k8s/gazebo/configmap-gz-bridge-config.yaml`
Add one bridge entry:
```yaml
- ros_topic_name: /scan
  gz_topic_name: /scan
  ros_type_name: sensor_msgs/msg/LaserScan
  gz_type_name: gz.msgs.LaserScan
  direction: GZ_TO_ROS
```

### 8. `Makefile`
New variable: `NAV2_IMAGE ?= quay.io/jianrzha/ros2-zenoh-nav2`

New targets (same pattern as existing `build-gazebo`, `push-gazebo`, `deploy-gazebo`):

| Target | Action |
|---|---|
| `build-nav2` | `podman build -f Dockerfile.nav2 -t NAV2_IMAGE:VERSION` |
| `push-nav2` | `podman push NAV2_IMAGE:VERSION` |
| `deploy-nav2` | Apply updated gazebo configmaps → restart gazebo-sim → apply k8s/nav2/ → wait for rollout |
| `undeploy-nav2` | Delete nav2 deployment + nav2 ConfigMaps |
| `demo-nav2` | Stream labeled logs from nav2-server and mission containers |
| `logs-nav2` | Raw kubectl logs from nav2 pod |

`deploy-nav2` sequence:
1. `kubectl apply` updated `configmap-robot-model.yaml` and `configmap-gz-bridge-config.yaml`
2. `kubectl rollout restart deployment/gazebo-sim -n ros2-zenoh-gazebo`
3. Wait for gazebo-sim rollout (300 s)
4. `kubectl apply` all `k8s/nav2/*.yaml` with `sed NAV2_IMAGE:latest → NAV2_IMAGE:VERSION`
5. Wait for nav2 rollout (300 s)

### 9. `.github/workflows/build.yml`
New job `build-nav2` (same structure as `build-gazebo`):
- Builds `Dockerfile.nav2`, pushes `quay.io/jianrzha/ros2-zenoh-nav2:latest` and `:$sha`
- Triggers on same branches as existing jobs

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Nav2 RMW | DDS + zenoh-bridge sidecar | Consistent with existing bridge pattern; avoids rmw_zenoh_cpp config |
| Mission controller | 3rd container in nav2 pod | Shares localhost DDS with Nav2 servers; simpler than separate pod |
| Namespace | `ros2-zenoh-gazebo` (existing) | Reuses zenoh-router Service; no cross-namespace networking needed |
| zenoh-bridge config | Reuse existing `configmap-zenoh-bridge-config` | Identical requirements (client mode → zenoh-router:7447) |
| Lidar type | `type="lidar"` (CPU raycast) | No GPU/OGRE2 required; works with existing software EGL setup |
| Lidar frame name | `laser` | Matches ROS nav2 conventions; TF from SceneBroadcaster auto-provided |
| Static map format | 80×80 ASCII P2 PGM in ConfigMap | Avoids binary encoding; manageable size (~25 KB) |
| Robot radius | 0.22 m | Circumscribed radius of 0.4×0.2m chassis; Nav2 obstacle inflation margin |
| AMCL initial pose | (0,0) matching SDF spawn position | Robot always starts at world origin |

---

## Verification Steps

```bash
# 1. All pods Running
kubectl get pods -n ros2-zenoh-gazebo
# Expected: gazebo-sim 3/3, nav2 3/3, gzweb 1/1, zenoh-router 1/1

# 2. Lidar data flowing (10 Hz)
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && ros2 topic hz /scan'
# Expected: average rate: ~10.000

# 3. Nav2 AMCL publishing map→odom TF
kubectl exec -n ros2-zenoh-gazebo deploy/nav2 -c nav2-server -- bash -c \
  'source /opt/ros/jazzy/setup.bash && ros2 topic echo /tf --once 2>/dev/null | grep -A3 frame_id'
# Expected: frame_id: map or frame_id: odom

# 4. Patrol mission active (distance countdown per waypoint)
kubectl logs -n ros2-zenoh-gazebo deploy/nav2 -c mission -f
# Expected: "Navigating to waypoint 1/4...", "Distance remaining: X.XXm"

# 5. GzWeb: reconnect at wss://gazebo-ws-ros2-zenoh-gazebo.apps.<cluster>
#    Robot should be visible moving autonomously along the warehouse aisles
```

---

## Open Questions Before Implementation

1. **AMCL convergence**: AMCL may not converge quickly without good initial scan matches
   against the static map. If localization drifts, the robot will navigate incorrectly.
   Mitigation: use `set_initial_pose: true` in params to seed AMCL at (0,0).

2. **Nav2 lifecycle startup order**: All Nav2 servers launch via a single
   `bringup_launch.py` — the launch file handles the lifecycle ordering internally.
   No additional ordering mechanism needed.

3. **DWB vs MPPI**: DWB is simpler to configure. MPPI (newer, smoother trajectories)
   can be swapped by changing `controller_plugins` in the params.
