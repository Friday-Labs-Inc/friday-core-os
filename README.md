# friday-core-os

Core Hub OS image for the **Mark 1** autonomous research rover by **Friday Labs**.

Runs on the **Raspberry Pi 4B (8 GB)** — the rover's primary brain.

## What this is

`friday-core-os` is the bootable OS image that turns a Pi 4B into the Mark 1 Core Hub.
It provisions Ubuntu 24.04 LTS with ROS 2 Jazzy, the Friday Labs OS runtime, and the
internal MQTT bridge that connects to the Telemetry Gateway over Ethernet.

## Stack

| Layer | Detail |
|-------|--------|
| Base OS | Ubuntu 24.04 LTS (arm64) |
| Robotics | ROS 2 Jazzy |
| Runtime | Friday Labs OS (lifecycle, authority lease, safe-stop, mission logic) |
| Internal bridge | `mosquitto` broker on Ethernet interface (signed CBOR envelopes to Telemetry Gateway) |
| Downstream links | USB-serial micro-ROS to Locomotion ESP32 + Aerial Bay ESP32 |
| systemd target | `friday-core-os.target` |

## Architecture context

Mark 1 runs **two distinct OS images** — this repo builds the robotics brain; the
network gateway lives in
[friday-telemetry-os](https://github.com/Friday-Labs-Inc/friday-telemetry-os).

```
Core Hub (Pi 4B)          Ethernet/MQTT         Telemetry GW (Pi 3B+)
friday-core-os  ◄──────────────────────────────►  friday-telemetry-os
ROS 2 + signing              signed CBOR          no ROS 2, pure gateway
     │                                                    │
     │ USB-serial (micro-ROS)                     4G / LoRa / Wi-Fi
     ▼                                                    ▼
ESP32 Mobility                                   Command Center (EMQX)
```

## Directory layout

```
systemd/          systemd target + service units
mosquitto/        internal MQTT broker config (Core ↔ Telemetry bridge)
provision/        first-boot provisioning scripts
image/            pi-gen / image build configuration
```

## Related repos

- [friday-labs-os](https://github.com/Friday-Labs-Inc/friday-labs-os) — ROS 2 packages (the software this OS runs)
- [friday-telemetry-os](https://github.com/Friday-Labs-Inc/friday-telemetry-os) — Telemetry Gateway OS
- [friday-command-center](https://github.com/Friday-Labs-Inc/friday-command-center) — Command Center (Frappe)

## License

Proprietary — Friday Labs Inc.
