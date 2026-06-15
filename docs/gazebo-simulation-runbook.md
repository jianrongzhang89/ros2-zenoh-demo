# Gazebo Simulation Runbook

Operational guide for the diff-drive robot simulation on OpenShift — covering
manual teleoperation and the Nav2 autonomous warehouse patrol.

---

## Architecture

```
Browser (GzWeb)
  │  WSS
  ▼
OpenShift Route: gazebo-ws-ros2-zenoh-gazebo.apps.<cluster>
  │  port 9002
  ▼
gazebo-sim pod
  ├── gazebo-sim      gz sim -s --headless-rendering warehouse.sdf
  │                   + gz-launch WebsocketServer (background, port 9002)
  ├── ros-gz-bridge   gz-transport ↔ CycloneDDS (/odom, /cmd_vel, /tf, /clock)
  └── zenoh-bridge    CycloneDDS → Zenoh TCP → zenoh-router

zenoh-router pod      central Zenoh hub (TCP :7447)

nav2 pod  (autonomous patrol — deployed separately)
  ├── nav2-server     Nav2 bringup (planner, controller, bt_navigator, …)
  │                   CycloneDDS, LOCALHOST, odom-frame navigation
  ├── mission         Python patrol script (4-waypoint loop)
  └── zenoh-bridge    CycloneDDS ↔ zenoh-router
                      Inbound:  /odom /tf /clock
                      Outbound: /cmd_vel
```

---

## Part A — Simulation Only (manual teleoperation)

### 1. Deploy

```bash
# Build and push images (first time or after Dockerfile changes)
VERSION=0.0.6 make build-gazebo push-gazebo

# Deploy simulation stack (creates namespace ros2-zenoh-gazebo)
VERSION=0.0.6 make deploy-gazebo

# Deploy GzWeb landing page + WebSocket route
VERSION=0.0.6 make deploy-gzweb

# Verify all pods Running
kubectl get pods -n ros2-zenoh-gazebo
# Expected: gazebo-sim 3/3, gzweb 1/1, zenoh-router 1/1
```

### 2. Verify

```bash
make test-gazebo
```

### 3. Open GzWeb (3D view)

```bash
make urls-gzweb
# → Landing page : https://gzweb-ros2-zenoh-gazebo.apps.<cluster>
# → WebSocket    : wss://gazebo-ws-ros2-zenoh-gazebo.apps.<cluster>
```

1. Open the landing page → click **Copy** to copy the WSS URL
2. Click **Open GzWeb ↗** → opens `app.gazebosim.org/visualization`
3. **Clear** `ws://localhost:9002`, **paste** the WSS URL, leave key empty, click **Connect**
4. Click **⌂** (home icon, top-right of viewport) to center the camera

### 4. Move the Robot Manually

> **Rule:** DiffDrive holds the last command forever. Always stop before
> changing direction and before deploying Nav2.

```bash
# Stop
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"'

# Forward / backward
# linear.x: m/s  (positive = forward, negative = backward)
# angular.z: rad/s (positive = left, negative = right)
# Safe range: |linear.x| ≤ 0.5, |angular.z| ≤ 1.5

kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 0.3}, angular: {z: 0.0}}"'

# Drive in a circle for 5 s then stop
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   timeout 5 ros2 topic pub --rate 10 /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 0.3}, angular: {z: 0.5}}" ; \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"'
```

### 5. Reset the Simulation

Use when the robot falls over, drifts far from origin, or behaves erratically.

```bash
# 1 — stop the robot
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"'

# 2 — reset all entities to initial poses
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c gazebo-sim -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   /opt/ros/jazzy/opt/gz_tools_vendor/bin/gz service \
     -s /world/diff_drive_world/control \
     --reqtype gz.msgs.WorldControl --reptype gz.msgs.Boolean \
     --timeout 3000 --req "reset: {all: true}"'

# 3 — reconnect GzWeb: Disconnect → paste WSS URL → Connect → click ⌂
```

---

## Part B — Nav2 Autonomous Patrol

### Expected Behaviour

The robot patrols a 4-waypoint loop in the odom frame (relative to its spawn
position at the origin). Each lap covers all four warehouse aisles:

```
         (0, +2.5)  north aisle
               ↑
(-2.5, 0) ←───┼───→ (+2.5, 0)
    west       │        east
               ↓
         (0, -2.5)  south aisle
```

Waypoints are visited in order: west → north → east → south → repeat.
The robot rotates and drives to each goal, then immediately moves to the next.

### 6. Deploy Nav2 (Critical Procedure)

> **⚠️ Critical constraint:** Both `gazebo-sim` and `nav2` pods **must be
> restarted together** in the same rollout. The CycloneDDS ↔ Zenoh bridge
> routes for `/odom` and `/tf` are only reliably established when both bridge
> processes start fresh at the same time. Restarting `nav2` alone after
> `gazebo-sim` has been running for a while causes the Zenoh→DDS relay to
> fail silently.

```bash
# Build and push Nav2 image (first time or after Dockerfile changes)
VERSION=0.0.6 make build-nav2 push-nav2

# Deploy Nav2 — this also restarts gazebo-sim (required!)
VERSION=0.0.6 make deploy-nav2

# Expected output:
#   gazebo-sim 3/3 Running  0 restarts
#   nav2       3/3 Running  0 restarts
#
# Nav2 takes ~60 s to initialize after the pod starts.
# The patrol mission begins ~120 s after the pod starts.
```

### 7. Watch the Patrol

```bash
# Live labeled logs from Nav2 + mission
make demo-nav2

# Key messages to look for:
#   [patrol] Nav2 is ready for use!
#   [patrol] Navigating to waypoint 1/4...
#   [patrol]   distance remaining: X.XX m   ← robot is moving
#   [patrol]   Waypoint 1 reached.
```

### 8. Verify Nav2 Nodes Are Active

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/nav2 -c nav2-server -- bash -c \
  'source /opt/ros/jazzy/setup.bash
   for n in bt_navigator planner_server controller_server; do
     state=$(timeout 3 ros2 service call /${n}/get_state \
       lifecycle_msgs/srv/GetState "{}" 2>/dev/null | grep -oP "label='"'"'\K[^'"'"']+")
     echo "${n}: ${state}"
   done'
# Expected: all three = active
```

### 9. Check Data Flow

```bash
# /odom flowing from gazebo → nav2 at ~20 Hz
kubectl exec -n ros2-zenoh-gazebo deploy/nav2 -c nav2-server -- bash -c \
  'source /opt/ros/jazzy/setup.bash && ros2 topic hz /odom 2>/dev/null | head -2'

# cmd_vel non-zero during navigation (Nav2 generating drive commands)
kubectl exec -n ros2-zenoh-gazebo deploy/nav2 -c nav2-server -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic echo /cmd_vel_nav --field linear.x 2>/dev/null | head -4'

# Robot position changing in Gazebo
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c gazebo-sim -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   /opt/ros/jazzy/opt/gz_tools_vendor/bin/gz topic -e -n 1 \
     -t /world/diff_drive_world/pose/info 2>/dev/null | grep -A 4 diff_drive_robot'
```

### 10. Stop / Restart the Patrol

```bash
# Remove Nav2 (keeps gazebo-sim running)
make undeploy-nav2

# Redeploy Nav2 — must restart gazebo-sim at the same time
VERSION=0.0.6 make deploy-nav2
```

---

## Part C — Tear Down

```bash
# Remove GzWeb routes only (keeps simulation running)
make undeploy-gzweb

# Remove Nav2 only (keeps simulation running)
make undeploy-nav2

# Remove the entire namespace (stops everything)
make undeploy-gazebo
```

---

## Known Constraints

| Constraint | Detail |
|---|---|
| **Simultaneous restart required** | `gazebo-sim` and `nav2` must be rolled out together. Deploying `nav2` alone after `gazebo-sim` has been running for minutes causes the Zenoh→DDS relay for `/odom` and `/tf` to fail silently (`Bad Parameter` in bundled CycloneDDS). `make deploy-nav2` handles this automatically. |
| **Lidar sensor not functional** | The 2D lidar in the SDF uses the OGRE2 rendering pipeline. With software EGL (Mesa llvmpipe, no GPU), the ray sensor produces no data. `/scan` is always empty. This means: (a) AMCL localization is disabled; (b) costmap obstacle detection is disabled; (c) collision_monitor has no sensor input. |
| **Odom-frame navigation only** | Because AMCL is disabled (no `/scan`), Nav2 navigates in the **odom frame** (relative to where the robot was when Nav2 started), not the map frame. Wheel odometry accumulates drift over time. Waypoints are ±2.5 m from the robot's starting position, not from the warehouse map. |
| **DiffDrive holds last command** | The DiffDrive Gazebo plugin keeps the last received `/cmd_vel` value indefinitely. A `--once` publish of `{linear: {x: 0.3}}` will keep the robot moving at 0.3 m/s until a zero command is sent. Always stop before Nav2 deployment or simulation reset. |
| **Nav2 uses CycloneDDS only** | The nav2 image is built with `ros-jazzy-rmw-cyclonedds-cpp`. Using default FastRTPS causes `Bad Parameter` DDS writer errors in the zenoh-bridge relay. Do not change `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` in the nav2 containers. |
| **Collision monitor requires source_timeout=0** | The collision_monitor is configured with a `/scan` source that never receives data (lidar not functional). With `source_timeout: 2.0` (default), the monitor blocks all cmd_vel after 2 s of no data. `source_timeout: 0.0` causes timed-out sources to be immediately excluded, letting cmd_vel pass through. |
| **No GPU required** | Gazebo runs headless with `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe` (Mesa software EGL). No NVIDIA GPU Operator or special SCC is needed. Performance is adequate for physics simulation and odometry but insufficient for OGRE2 sensor rendering (lidar, cameras). |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Robot not visible in GzWeb | Camera not at origin, or scene not loaded after pod restart | Click **⌂** home icon; if still missing, Disconnect → reconnect |
| Robot not responding to manual cmd_vel | Robot fell over (tipped sideways) | Reset the simulation (Section 5) |
| Robot drives away and disappears | DiffDrive holds last command | Always stop (`--once {}`) before changing direction |
| GzWeb shows `ws://localhost:9002` | Went to app.gazebosim.org directly | Use the landing page Copy button; paste into GzWeb manually |
| `gazebo-sim` pod 2/3 ready | WebSocket server warming up (15 s delay) | Wait 20 s after pod starts |
| `/odom` not flowing to nav2 pod | Zenoh→DDS relay not established | Restart both pods together: `VERSION=0.0.6 make deploy-nav2` |
| Nav2 patrol: distance stuck at exactly N.NN m | Robot drifted far from origin before Nav2 started | Reset simulation (Section 5), then the patrol naturally resumes |
| Nav2 patrol: `Waypoint N failed` on every lap | collision_monitor blocking cmd_vel (source_timeout issue) | Verify `source_timeout: 0.0` in nav2-params ConfigMap; `kubectl apply -f k8s/nav2/configmap-nav2-params.yaml && kubectl rollout restart deployment/nav2 -n ros2-zenoh-gazebo` |
| Nav2 nodes `unconfigured` after pod start | Map PGM file truncated in ConfigMap | Redeploy: `VERSION=0.0.6 make deploy-nav2` (restarts both pods) |
| `bt_navigator` fails with "backup not available" | behavior_server action servers register slowly | Verify `wait_for_service_timeout: 30000` in params; the current BT (`navigate_w_replanning_time.xml`) does not require backup |
| cmd_vel non-zero in nav2 but zeros at Gazebo | Rare race in Zenoh bridge initialization | Restart both pods together: `VERSION=0.0.6 make deploy-nav2` |
