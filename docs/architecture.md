# friday-core-os — architecture

> How the pieces of the Core Hub OS image fit together, in plain English.
> Sister doc to `bring-up-guide.md` (the "how to run it") and the
> Redesign Proposal (the "why it's shaped this way").

## What friday-core-os actually is

It is **not** a full custom Linux distribution. It is **Ubuntu Server 24.04 LTS with a specific set of provisioned services and configs on top**, packaged as a set of scripts and systemd units in this repo. You take a stock Ubuntu install and turn it into a rover node with one shell script.

Three layers, bottom to top:

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3  Friday Labs OS services                       │  ← ROS 2 lifecycle nodes
│           (module-registry, autonomy-manager,           │     built from friday-labs-os
│            safety-supervisor, mode-manager, ...)        │     src/ — Phase B and later
├─────────────────────────────────────────────────────────┤
│  Layer 2  friday-core-os systemd + broker + comms       │  ← THIS REPO (Phase A)
│           (target, hardened units, WireGuard,           │
│            mosquitto internal broker, provisioning)     │
├─────────────────────────────────────────────────────────┤
│  Layer 1  Ubuntu Server 24.04 LTS + ROS 2 Jazzy         │  ← you install this yourself
│           (Linux kernel, systemd, netplan, apt)         │
└─────────────────────────────────────────────────────────┘
```

## What Phase A1 delivers (the current state)

- **The systemd target** `friday-core-os.target` — the boot-order root that pulls in all rover services.
- **The internal MQTT broker** — mosquitto on `10.0.1.1:1883`, bound to the internal Ethernet only. This is how the Core Hub talks to the Telemetry Gateway.
- **The WireGuard tunnel** — the Core Hub's connection to the Command Center over any bearer (4G, LoRa, or a lab LAN). Uses per-rover certificates issued by the FCC.
- **Hardened systemd defaults** — a drop-in (`friday-core-os@.service.d/security.conf`) that applies `NoNewPrivileges`, `ProtectSystem=strict`, syscall filtering, and IP-address allow-listing to every rover service.
- **Bring-up automation** — one shell script (`provision/first-boot.sh`) turns a bare Ubuntu install into all of the above.
- **Post-provisioning verification** — `provision/verify.sh` runs a health-check that either says "all OK" or points at the exact failure.

## What Phase A2 adds

Not yet built. Planned next:

- **A/B partitions + RAUC** — atomic OS updates with automatic rollback. Any bad update reverts on next boot.
- **LUKS full-disk encryption** — data partition + rover key encrypted at rest.
- **TPM 2.0 key sealing** — the rover's Ed25519 signing key held in a TPM chip; released only to a validated (measured-boot) OS. Requires an external TPM module (~$12).
- **Placeholder service units** for all 10 Friday Labs OS services listed in the compute-arch doc, wired to the target. Each starts as a "hello world" ROS 2 node until Phase B replaces them with the real implementations.

## The three networks the Core Hub sits on

The Core Hub is a small router. Three networks pass through it:

**1. Internal ethernet (10.0.1.0/24)** — a private, static-IP wired link to the Telemetry Gateway (10.0.1.2) and, in the future, the Research Deck (10.0.1.3). Only mosquitto listens here. No authentication needed — both endpoints are physically the same rover.

**2. WireGuard tunnel (via any bearer)** — an encrypted tunnel to the Command Center over whatever bearer is up (4G via Telemetry Gateway, Wi-Fi, or a lab LAN during development). Every packet is WireGuard-encrypted + signed at the application layer with Ed25519 CBOR envelopes. Two layers of security.

**3. USB / serial (Locomotion + Aerial Bay ESP32s)** — micro-ROS over USB CDC serial. Not IP-routed; ROS 2 messages tunneled over serial by the `micro-ros-agent` daemon.

## The service hierarchy (once Phase A2 lands)

Per the compute-architecture doc, `friday-core-os.target` will own:

```
friday-core-os.target
├── mosquitto-internal.service           [Phase A1 ✅]
├── wg-quick@wg-core.service              [Phase A1 ✅]
├── module-registry.service              [Phase A2 — placeholder, Phase B — real]
├── system-health-manager.service        [Phase A2 → Phase B]
├── command-router.service               [Phase A2 → Phase B]
├── safety-supervisor.service            [Phase A2 → Phase B]
├── fault-manager.service                [Phase A2 → Phase B]
├── authority-lease-service.service      [Phase A2 → Phase B]
├── logging-service.service              [Phase A2 → Phase B]
├── mission-planner.service              [Phase A2 → Phase C]
├── autonomy-manager.service             [Phase A2 → Phase D]
├── sensor-fusion-manager.service        [Phase A2 → Phase C]
└── mode-manager.service                 [Phase C]
```

Each `.service` = one ROS 2 lifecycle node, subject to the hardened drop-in.

## Design decisions worth calling out

- **Ubuntu Server 24.04, not Ubuntu Core.** Ubuntu Core is more locked-down (snap-only, read-only root by default) and would be the truly cutting-edge choice. But it's less familiar, harder to debug on a first hardware bring-up, and the A/B robustness Core provides can be matched by RAUC on Server. For Phase A we optimize for "you can SSH in and fix things when they break." Revisit at Mark 2.
- **WireGuard, not Tailscale, on the rover.** The Command Center runs Tailscale; the rovers use plain WireGuard peered to it. Reason: WireGuard has no daemon dependency, no cloud identity, no license concerns for a fleet. If a rover is captured, its WG key can be revoked centrally without touching a third-party account.
- **Mosquitto for the internal bridge, not DDS.** DDS is peer-to-peer and multicast-heavy, which is fine on ROS 2's own bus (Core Hub ↔ Research Deck) but wasteful over a 100Mbit Ethernet link where you have exactly two peers. Mosquitto with the signed CBOR envelope format is simpler and matches the format used on the external link. No translation, no leakage.
- **First-boot is a shell script, not cloud-init.** Cloud-init is one layer of indirection when a bash script does the same thing more debuggable. Cloud-init YAML can call this script if you're building images from Packer or pi-gen later.

## Related

- [Bring-up guide](bring-up-guide.md) — the "how to run it"
- [Systemd security drop-in](../systemd/friday-core-os@.service.d/security.conf) — the hardening defaults
- [First-boot script](../provision/first-boot.sh) — the provisioning entry point
- [Verify script](../provision/verify.sh) — the health check
- Parent — Redesign Proposal (scratchpad, Phase 1 deliverable)
