# ROS2 + Zenoh Demo (Mac M2 / Podman)

A minimal demo running ROS2 Jazzy with `rmw_zenoh_cpp` (Zenoh as the RMW layer) on a Mac M2 using Podman. Three containers — a Zenoh router, a talker, and a listener — communicate over a Podman bridge network.

## Prerequisites

- **Podman** 5.x with a running machine (`podman machine start`)
- **podman-compose** (`brew install podman-compose`)

## Architecture

```
[zenoh-router]  <── Zenoh TCP ──>  [ros2-talker]
                                         ↑
                                   [ros2-listener]
```

All three containers share a Podman bridge network. Zenoh uses unicast TCP (no multicast) to route messages through the dedicated router container.

| Container | Role |
|-----------|------|
| `zenoh-router` | Runs `rmw_zenohd`, the ROS2 Zenoh router on port 7447 |
| `ros2-talker` | Publishes `Hello World` messages on `/chatter` |
| `ros2-listener` | Subscribes to `/chatter` and prints received messages |

## Quick Start

```bash
# First run: build the image (~5 min to pull and install packages)
podman compose up --build

# Subsequent runs
podman compose up
```

You should see:

```
ros2-talker   | [talker]: Publishing: 'Hello World: 1'
ros2-talker   | [talker]: Publishing: 'Hello World: 2'
ros2-listener | [listener]: I heard: [Hello World: 1]
ros2-listener | [listener]: I heard: [Hello World: 2]
```

Stop with `Ctrl+C`, then `podman compose down`.

## Inspecting the Demo

```bash
# Check running containers
podman ps

# List ROS2 topics visible from the listener
podman exec -it ros2-zenoh_ros2-listener_1 bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic list"

# Echo the chatter topic live
podman exec -it ros2-zenoh_ros2-talker_1 bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic echo /chatter"

# Check container logs
podman logs -f ros2-zenoh_ros2-listener_1
```

## Files

### `Dockerfile.ros2`

Single image used by all three services. Installs `rmw_zenoh_cpp` and `demo_nodes_cpp` on top of the official `ros:jazzy-ros-base` ARM64 image. The Zenoh client config is copied in at build time.

### `zenoh-client.json5`

Zenoh session config for the talker and listener:

- `mode: "client"` — connects to the router rather than doing peer scouting
- `connect.endpoints` — points directly to the `zenoh-router` service hostname
- Multicast scouting disabled (doesn't work across Podman bridge containers)
- Shared memory transport disabled (POSIX SHM is not available in containers)

### `compose.yml`

Orchestrates the three services on a shared bridge network. Key environment variables on talker/listener:

| Variable | Value | Purpose |
|----------|-------|---------|
| `RMW_IMPLEMENTATION` | `rmw_zenoh_cpp` | Tells ROS2 to use Zenoh instead of the default DDS |
| `ZENOH_SESSION_CONFIG_URI` | `/zenoh-client.json5` | Path to the Zenoh session config (note: NOT `ZENOH_CONFIG`) |

## Gotchas

**`ZENOH_SESSION_CONFIG_URI`, not `ZENOH_CONFIG`.**
`rmw_zenoh_cpp` uses its own environment variable to load the session config. The generic `ZENOH_CONFIG` variable is silently ignored; the library falls back to its bundled default (`DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5`) which hardcodes `tcp/localhost:7447`.

**Use `rmw_zenohd` as the router, not `eclipse/zenoh`.**
The standalone `eclipse/zenoh` image is a generic Zenoh router and is incompatible with the ROS2 graph management expected by `rmw_zenoh_cpp`. The router must be started with `ros2 run rmw_zenoh_cpp rmw_zenohd`.

**SHM must be disabled in containers.**
Zenoh tries to use POSIX shared memory by default. In containers this fails with `OS error 12` (ENOMEM). Set `transport.shared_memory.enabled: false` in the session config.

**Container names use underscores with `podman-compose`.**
`podman-compose` names containers like `ros2-zenoh_ros2-talker_1`, not `ros2-zenoh-ros2-talker-1` (hyphens vs. underscores). Use `podman ps` to find the exact names.

**`ros2 doctor` router warning is a red herring.**
Even when everything works, `ros2 doctor` prints "Unable to connect to a Zenoh router" because it spawns a transient diagnostic session that may not connect in time. Check actual talker/listener logs to verify communication.
