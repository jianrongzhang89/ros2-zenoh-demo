# Gazebo Simulation Runbook

Operational guide for running the diff-drive robot simulation on OpenShift and
controlling it via ROS 2 topics bridged over Zenoh.

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
  ├── gazebo-sim      gz sim -s --headless-rendering diff_drive.sdf
  │                   + gz-launch WebsocketServer (background, port 9002)
  ├── ros-gz-bridge   gz-transport ↔ ROS 2 DDS  (/odom, /cmd_vel, /tf, /clock)
  └── zenoh-bridge    ROS 2 DDS → Zenoh TCP → zenoh-router

zenoh-router pod      forwards Zenoh sessions to external rmw_zenoh_cpp clients
```

---

## 1. Deploy

```bash
# Build and push images (first time or after Dockerfile changes)
VERSION=0.0.5 make build-gazebo push-gazebo

# Deploy simulation stack
VERSION=0.0.5 make deploy-gazebo

# Deploy GzWeb landing page + WebSocket route
VERSION=0.0.5 make deploy-gzweb

# Verify all pods are Running
kubectl get pods -n ros2-zenoh-gazebo
# Expected:
#   gazebo-sim-<hash>    3/3   Running
#   gzweb-<hash>         1/1   Running
#   zenoh-router-<hash>  1/1   Running
```

---

## 2. Run the Simulation Verification

```bash
make test-gazebo
# Checks: pod readiness, simulation loop, ros_gz_bridge topic bridges,
#         zenoh-bridge connectivity, /odom message flow, /cmd_vel write-back
```

---

## 3. Open GzWeb (3D Visualization)

### Step 1 — Get the URLs

```bash
make urls-gzweb
# Landing page : https://gzweb-ros2-zenoh-gazebo.apps.<cluster>
# WebSocket    : wss://gazebo-ws-ros2-zenoh-gazebo.apps.<cluster>
```

### Step 2 — Open the landing page

Navigate to the landing page URL. Click **Copy** to copy the WebSocket URL.

### Step 3 — Connect GzWeb

1. Click **Open GzWeb ↗** — opens `app.gazebosim.org/visualization`
2. **Clear** the default `ws://localhost:9002` in the WebSocket URL field
3. **Paste** the copied `wss://...` URL
4. Leave Authorization Key **empty**
5. Click **Connect**

The 3D world loads in the main viewport. The robot is a blue box at the origin.
If the viewport is empty after connecting, click the **⌂ (home)** icon in the
top-right of the 3D viewport to reset the camera to the world origin.

### GzWeb camera controls

| Action | Mouse |
|---|---|
| Orbit | Left-click drag |
| Zoom | Scroll wheel |
| Pan | Right-click drag |

---

## 4. Move the Robot

All commands run from your local terminal. The `--once` flag sends a single
velocity command; the DiffDrive plugin holds the last received command
indefinitely until a new one is received.

### Stop (always run this first)

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"'
```

### Drive forward

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 0.3}, angular: {z: 0.0}}"'
```

### Drive backward

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: -0.3}, angular: {z: 0.0}}"'
```

### Turn left (counter-clockwise)

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 0.0}, angular: {z: 1.0}}"'
```

### Turn right (clockwise)

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 0.0}, angular: {z: -1.0}}"'
```

### Drive in a circle for N seconds, then stop

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   timeout 5 ros2 topic pub --rate 10 /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 0.3}, angular: {z: 0.5}}" ; \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"'
```

> **Tip:** `linear.x` is forward speed in m/s (positive = forward, negative = backward).
> `angular.z` is turn rate in rad/s (positive = left, negative = right).
> Safe operating range: `|linear.x| ≤ 0.5`, `|angular.z| ≤ 1.5`.

---

## 5. Monitor Topics

### Watch odometry (robot position)

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic echo /odom --field pose.pose'
```

### Watch simulation clock

```bash
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic echo /clock'
```

### Stream all pod logs

```bash
make demo-gazebo
```

---

## 6. Reset the Simulation

Use this when the robot has fallen over, driven out of view, or become
unresponsive. Returns the robot to its initial pose at the world origin.

```bash
# Step 1 — send zero velocity (stops the DiffDrive plugin)
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c ros-gz-bridge -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"'

# Step 2 — reset all entities to initial poses
kubectl exec -n ros2-zenoh-gazebo deploy/gazebo-sim -c gazebo-sim -- bash -c \
  'source /opt/ros/jazzy/setup.bash && \
   /opt/ros/jazzy/opt/gz_tools_vendor/bin/gz service \
     -s /world/diff_drive_world/control \
     --reqtype gz.msgs.WorldControl --reptype gz.msgs.Boolean \
     --timeout 3000 --req "reset: {all: true}"'

# Step 3 — reconnect GzWeb (Disconnect → paste WSS URL → Connect → click ⌂)
```

---

## 7. Tear Down

```bash
# Remove GzWeb landing page and WebSocket route (keeps simulation running)
make undeploy-gzweb

# Remove the entire simulation namespace
make undeploy-gazebo
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Robot not visible in GzWeb | Camera not at origin, or scene not loaded | Click **⌂** home icon; if still missing, Disconnect → reconnect |
| Robot not responding to cmd_vel | Robot fell over (tipped sideways) | Reset the simulation (Section 6) |
| Robot drives away and disappears | DiffDrive holds last command — `--once` still runs until a zero is sent | Always stop first, then reset |
| GzWeb shows `ws://localhost:9002` | Went to app.gazebosim.org directly without copying the WSS URL | Use the landing page Copy button; paste into GzWeb manually |
| `gazebo-sim` pod shows 2/3 ready | WebSocket server still warming up (15 s delay) | Wait 20 s after pod starts, then check logs |
| `/odom` not flowing | ros_gz_bridge not connected to Gazebo | Check `kubectl logs … -c ros-gz-bridge`; restart the pod if needed |
