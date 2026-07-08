# micro-ROS agent — bridging the ESP32 to the ROS 2 graph

The **micro-ROS agent** is the daemon that lets a microcontroller (in Mark 1's
case, an ESP32) speak ROS 2. The ESP32 runs micro-ROS firmware; it does not
run a full DDS stack. The agent translates between the ESP32's lightweight
XRCE-DDS wire format and the Core Hub's ROS 2 / Fast-DDS graph. Without it,
the ESP32 is invisible to `ros2 topic list`, `ros2 service list`, and
everything else.

This document explains how the agent is deployed on friday-core-os: why there
are two modes, why the serial mode works the way it does, and the
operational quirks that bit us during real hardware bring-up.

## Two modes — serial and UDP/WiFi

The Mark 1 Locomotion Control Unit (LCU) is an ESP32 connected to the Core
Hub by a USB-serial cable — the safety-relevant path. USB serial is
deterministic, low-jitter, and stays up regardless of WiFi state, which is
why the electronics design specifies it for anything that can move the
rover. A WiFi/UDP mode is useful for bench proof-of-life testing and for
non-safety sensor nodes that don't warrant a cable run.

| Mode | Transport | Use case | Deployment |
|---|---|---|---|
| Serial | USB CDC (`/dev/ttyUSB*` or `/dev/ttyACM*`) | LCU ESP32 (safety path) | udev-triggered, per-device |
| UDP/WiFi | UDP port 8888 | Bench proof-of-life, non-safety sensor nodes | Static systemd service, always on |

## Why serial is udev-triggered, not statically enabled

The obvious design — "start a systemd service at boot and have it open
`/dev/ttyUSB0`" — breaks in two ways:

1. **The device may not exist at boot.** On a fresh Pi boot with no ESP32
   plugged in, `/dev/ttyUSB0` does not exist. A static service would fail
   immediately and crash-loop, burning through `StartLimitBurst` before
   you've even connected a board.
2. **The device path isn't stable.** Plug a USB hub in front of the ESP32
   and `/dev/ttyUSB0` can become `/dev/ttyUSB1`. A static service hardcoded
   to one device name silently stops working.

The correct pattern for pluggable hardware is **udev-triggered systemd
template instances**. When the kernel creates a `/dev/ttyUSB0` device node,
`udev/99-friday-microros-serial.rules` fires and starts:

```
micro-ros-agent-serial@ttyUSB0.service
```

When the device is unplugged, the unit's own `BindsTo=dev-%i.device`
directive tears the service down automatically — no udev "on remove" rule is
used for this (see below). Nothing crash-loops when no board is connected.
Plug in a second ESP32 on `/dev/ttyACM0` and a second instance starts
automatically, no config change required.

The template unit is `micro-ros-agent-serial@.service`. The `%i` template
argument becomes the device name (e.g. `ttyUSB0`), passed to the
`micro-ros-agent-serial` wrapper, which invokes:

```
MicroXRCEAgent serial --dev /dev/ttyUSB0 --baudrate 115200
```

**Contract to keep straight:** the unit passes only the bare device name
(`%i`, e.g. `ttyUSB0`) to the wrapper — never a `/dev/`-prefixed path. The
wrapper is the one place that prepends `/dev/`. Getting this backwards (unit
passes `/dev/%i`, wrapper prepends `/dev/` again) produces the nonexistent
path `/dev//dev/ttyUSB0` — an early build of this feature had exactly that
bug, caught before it ever reached the Pi.

### Why stop-on-remove uses `BindsTo=`, not a udev `RUN+=` rule

A tempting alternative is a second udev rule that runs
`systemctl stop micro-ros-agent-serial@%k.service` on `ACTION=="remove"`.
**Don't do this.** `RUN+=` blocks the udev worker thread while the command
runs, and a synchronous `systemctl stop` racing systemd's own handling of the
same device-removal event is a known deadlock vector. `BindsTo=dev-%i.device`
in the unit file achieves the identical result — the service is torn down
the moment the device unit disappears — atomically, inside systemd, with no
blocking udev callout.

## Why UDP/WiFi is a static always-on service

UDP mode just opens a socket and waits for a WiFi client to connect. There's
no device to be absent, so the udev-trigger pattern doesn't apply. Running it
statically under `friday-core-os.target` — the same way `module-registry.service`
runs — is the right call: it starts at boot (and immediately, via `build-uros-agent.sh`'s
`enable --now`) and sits there ready.

This is `micro-ros-agent-udp.service`, listening on port 8888.

## Hardening — DDS-safe loose, not strict

Both agent services run as the unprivileged `friday` user with the same
looser hardening profile as `module-registry.service`. They do **not** get
the strict `friday-core-os@.service.d/security.conf` drop-in.

The reasons are identical to those documented in
[`docs/hardening-ros.md`](hardening-ros.md). The micro-ROS agent is
effectively a DDS participant:

- It uses `/dev/shm` for Fast-DDS shared-memory transport.
- `MemoryDenyWriteExecute=yes` would break the DDS vendor's JIT/mmap use.
- `IPAddressDeny=any` would break DDS multicast discovery, even for a
  localhost-only graph.
- A strict `SystemCallFilter` trips on `mmap`, `membarrier`, and
  shared-memory syscalls DDS needs.

What both services **do** keep: `NoNewPrivileges=yes`, `ProtectSystem=strict`,
explicit `ReadWritePaths`, `ProtectHome=yes`, `ProtectKernelTunables=yes`,
`ProtectControlGroups=yes`, `RestrictSUIDSGID=yes`, `LockPersonality=yes`.
Neither sets `PrivateDevices=yes` or any `DeviceAllow=` restriction — either
would hide `/dev/ttyUSB*`/`/dev/ttyACM*` from the serial service, defeating
its entire purpose. Device access instead relies on the `friday` user's
`dialout` group membership (granted once in `first-boot.sh`, asserted again
explicitly via `SupplementaryGroups=dialout` in the serial unit).

## Operational gotcha — DDS discovery binds at process start

The micro-ROS agent, like every DDS participant, locks in its view of the
network at start time. The multicast group it joins for peer discovery is
resolved once, when the process starts.

**What this means in practice:** if the Core Hub's network changes after the
agent is already running — a netplan reapply, a new interface coming up, a
WiFi reassociation — the agent's DDS discovery can go stale. It keeps
talking to peers it already knew about, but new nodes that appear after the
network change may not be visible to it, or it to them.

The fix is always the same:

```bash
sudo systemctl restart micro-ros-agent-udp.service
# or, for a connected serial instance:
sudo systemctl restart micro-ros-agent-serial@ttyUSB0.service
```

This is not unique to the micro-ROS agent — `module-registry.service` has
the identical behavior. It's a property of DDS, not of this deployment.

## Related

- [`docs/hardening-ros.md`](hardening-ros.md) — full explanation of why ROS
  services get the looser hardening profile
- [`systemd/micro-ros-agent-serial@.service`](../systemd/micro-ros-agent-serial@.service) — the per-device template
- [`systemd/micro-ros-agent-udp.service`](../systemd/micro-ros-agent-udp.service) — the static WiFi service
- [`udev/99-friday-microros-serial.rules`](../udev/99-friday-microros-serial.rules) — the udev rule that triggers serial instances
- [`provision/build-uros-agent.sh`](../provision/build-uros-agent.sh) — the idempotent build script
- [`docs/architecture.md`](architecture.md) — USB/serial as the third network the Core Hub sits on
