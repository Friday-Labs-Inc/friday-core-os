# Core Hub bring-up guide — Pi 4B 8 GB with Ubuntu 24.04 LTS

> **Read this first.** Follow the steps in order. Every step is one command or one file edit. If a step fails, fix that step before moving on — do not skip ahead.

This turns a bare Pi 4B running Ubuntu Server 24.04 LTS into a working **friday-core-os** node — the rover's brain. When you finish this guide, your Pi will appear in the Command Center at `https://friday-lenovo-legion-5-pro-16ach6h.tail2074fe.ts.net/` as an online rover.

## What you need before you start

- [x] Raspberry Pi 4B (8 GB RAM recommended, 4 GB works)
- [x] Ubuntu Server 24.04 LTS installed (arm64) on the microSD card
- [x] Pi is powered on, connected to your router by ethernet, and you can SSH into it
- [x] You know the Pi's IP address on your local network
- [x] You have a WireGuard "peer" config file from the Command Center (`mark1-core.conf`). *If you don't have one yet, see **Getting a WireGuard config** at the bottom of this guide.*

## Step 0 — SSH into the Pi and update

From your Mac or workstation:

```bash
ssh ubuntu@<your-pi-ip>
```

On the Pi:

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git curl gnupg lsb-release
```

If that succeeds, you're ready.

## Step 1 — Clone friday-core-os

```bash
sudo mkdir -p /opt/friday && sudo chown ubuntu:ubuntu /opt/friday
cd /opt/friday
git clone https://github.com/Friday-Labs-Inc/friday-core-os.git
cd friday-core-os
```

## Step 2 — Drop in your WireGuard config

Copy the `mark1-core.conf` file you received from the Command Center to the Pi and place it at `/opt/friday/friday-core-os/provision/secrets/mark1-core.conf`.

Easiest way, from your workstation:

```bash
scp mark1-core.conf ubuntu@<your-pi-ip>:/opt/friday/friday-core-os/provision/secrets/mark1-core.conf
```

**Never commit this file. It contains your rover's private VPN key.** The `secrets/` directory is gitignored.

## Step 3 — Run first-boot provisioning

Back on the Pi:

```bash
sudo bash provision/first-boot.sh
```

This does everything:

- Sets the hostname to `mark1-core`
- Configures a static IP `10.0.1.1` on the internal ethernet (for the future Telemetry Gateway)
- Installs `mosquitto` (internal MQTT broker)
- Installs **ROS 2 Jazzy** from the OSRF apt repository
- Installs **WireGuard** and brings up the tunnel to the Command Center
- Enables the `friday-core-os.target` systemd target with hardened defaults
- Writes a module-identity file at `/etc/friday/module-identity.json`

The script is idempotent — you can re-run it safely.

Watch the output. If any step fails, the script exits with an error and tells you what to fix. **Don't skip a failure.** Common ones:

- "mosquitto: no such user" → the apt install didn't create the user. Re-run `apt-get install -y mosquitto` manually.
- "netplan: eth0 not found" → your Pi's ethernet interface isn't `eth0`; check with `ip -br link` and edit `/etc/netplan/10-internal-bridge.yaml` to match.
- "ros-jazzy-desktop: no installation candidate" → the OSRF apt repository didn't get added; check `/etc/apt/sources.list.d/ros2.list`.

## Step 4 — Reboot

```bash
sudo reboot
```

Wait ~30 seconds. SSH back in — this time you should be able to use the new hostname:

```bash
ssh ubuntu@mark1-core.local     # if mDNS works on your network
# or
ssh ubuntu@<your-pi-ip>
```

## Step 5 — Verify

Run this all-in-one health check:

```bash
sudo bash /opt/friday/friday-core-os/provision/verify.sh
```

You should see:

```
[OK] hostname: mark1-core
[OK] internal-bridge address: 10.0.1.1
[OK] wireguard: peer connected, last handshake N seconds ago
[OK] mosquitto: listening on 10.0.1.1:1883
[OK] ROS 2 Jazzy: /opt/ros/jazzy/setup.bash present
[OK] friday-core-os.target: active
[OK] module-identity: MARK1-CORE-001
```

Any `[FAIL]` line points to the exact thing to fix. Come back to the guide after resolving.

## Step 6 — Open the Command Center

On your Mac, open:

```
https://friday-lenovo-legion-5-pro-16ach6h.tail2074fe.ts.net/
```

Your new rover **MARK1-CORE-001** should appear in the rover list. The rover last-seen timestamp updates as its health-beacon reaches the FCC.

**If it does NOT appear:**

- On the Pi, check the WireGuard tunnel: `sudo wg show`. The peer should say "latest handshake: X seconds ago".
- On the Pi, check that mosquitto is running: `systemctl status mosquitto-internal.service`.
- On the Pi, check that the target is up: `systemctl status friday-core-os.target`.

## Step 7 — Build + start the module-registry (Phase A2)

Steps 0–6 gave you a Core Hub *foundation*. This step makes the rover's brain
actually run: it builds the Friday Labs OS ROS 2 packages and starts the
**module-registry** — the service every other rover service registers to.

On the Pi:

```bash
cd /opt/friday/friday-core-os

# clone + colcon-build the Core Hub ROS 2 packages into /opt/friday/ros2_ws
# (this takes 5-15 min on a Pi 4B — it compiles friday_msgs)
sudo bash provision/build-rover-code.sh

# start the registry
sudo systemctl enable --now module-registry.service

# confirm it's alive
sudo bash provision/verify.sh
```

`verify.sh` should now additionally show:

```
[OK]   module-registry.service active
[OK]   register_module ROS service present
```

To see the registry actually working:

```bash
source /opt/ros/jazzy/setup.bash
source /opt/friday/ros2_ws/install/setup.bash
export ROS_DOMAIN_ID=42

ros2 service list | grep mark1      # -> /mark1/system/register_module
ros2 topic echo /mark1/system/presence   # modules appear here as they register
```

With no other modules connected yet, the registry runs but reports an empty
fleet — that's correct. When you later connect the Locomotion ESP32 or the
Research Deck, they register here and appear on `/mark1/system/presence`.

**If `build-rover-code.sh` fails:** the most common cause on a fresh Pi is a
missing rosdep key or an out-of-memory colcon build (the Pi 4B can run low
building `friday_msgs`). Add swap if needed:
`sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`, then re-run.

**Why one service does three jobs:** in this walking-skeleton phase the
`core_hub` node provides module-registry *plus* a lite health-manager and a lite
safety-supervisor. The arch doc lists those as separate services; they get split
out in Phase B when each gets its full implementation. See
[`docs/architecture.md`](architecture.md).

## What this DID NOT do (yet)

Deliberate scope: this is **Phase A1 — foundation only**. It does NOT do:

- **ROS 2 lifecycle services** — no `module-registry`, `system-health-manager`, `autonomy-manager` yet. Those come in Phase A2, once the actual ROS 2 code is built as `.deb` packages.
- **A/B partitions + RAUC OTA** — Phase A2. Right now updates are `git pull && sudo bash provision/first-boot.sh`.
- **TPM key sealing** — Phase A2. The rover's Ed25519 key currently lives on disk (LUKS-encrypted). Getting a TPM chip is a follow-on.
- **Full-disk encryption via LUKS** — recommended but not automated in Phase A1. See `docs/luks-setup.md` for the manual walk-through.
- **Mode-manager** — Phase C.
- **Hermes integration** — Phase D.

You have the *foundation* the whole rover will build on. Everything above plugs into it without changing what you just built.

## Getting a WireGuard config

If you don't yet have a `mark1-core.conf`:

1. Open the Command Center
2. Go to **Fleet → Add Rover**
3. Fill in: rover_id = `MARK1-CORE-001`, hardware = `raspberry-pi-4b-8gb`, os_image = `friday-core-os`
4. Click **Provision** — the CC generates the WireGuard peer config + a rover Ed25519 keypair
5. Download the `mark1-core.conf` file

If the FCC doesn't have this UI yet (as of Phase A1 it doesn't — the pending FCC work item), you can mint one manually — see `docs/manual-wg-provisioning.md`.

## Rebuilding from scratch

Wipe the microSD, re-flash Ubuntu 24.04, and repeat from Step 0. All state is captured in `/etc/friday/` and `/opt/friday/`, both regenerated by `first-boot.sh`. There is no state you cannot rebuild.

## Related

- Full architecture — [`docs/architecture.md`](architecture.md)
- Systemd hardening — [`systemd/friday-core-os@.service.d/security.conf`](../systemd/friday-core-os@.service.d/security.conf)
- Redesign proposal (parent doc) — Phase 1 design proposal in the scratchpad
- Command Center handoff — `friday-command-center` repo, `docs/HANDOFF_LEGION.md`
