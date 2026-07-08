#!/usr/bin/env bash
# build-uros-agent.sh — build Micro-XRCE-DDS-Agent (the micro-ROS bridge) and
# install it to /opt/friday/microros_ws.
#
# Builds the agent via micro_ros_setup's create_agent_ws.sh + build_agent.sh,
# installs per-mode runtime wrappers, the udev hotplug rule for USB-serial, and
# the two systemd units (udev-triggered serial template + static UDP service).
#
# Run AFTER first-boot.sh (needs ROS 2 Jazzy installed). Idempotent: if the
# agent binary is already present the build is skipped; wrappers, units, and
# the udev rule are always (re-)installed so they stay current.
#
# Usage:
#   sudo bash provision/build-uros-agent.sh

set -euo pipefail

ROS_DISTRO="${FRIDAY_ROS_DISTRO:-jazzy}"
# Stable install target — the agent lives here for the lifetime of the OS image.
AGENT_WS="${FRIDAY_UROS_WS:-/opt/friday/microros_ws}"
# Staging workspace used only to build the micro_ros_setup tooling itself.
SETUP_WS="/opt/friday/microros_setup_ws"
MICRO_ROS_SETUP_URL="https://github.com/micro-ROS/micro_ros_setup.git"
MICRO_ROS_SETUP_REF="${FRIDAY_UROS_SETUP_REF:-jazzy}"
# Serial baud MUST match the value compiled into the ESP32 firmware.
SERIAL_BAUD="${FRIDAY_UROS_BAUD:-115200}"
# UDP port MUST match the value compiled into the ESP32 WiFi firmware.
UDP_PORT="${FRIDAY_UROS_UDP_PORT:-8888}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Canonical path of the agent binary after a successful colcon install.
# Used as the idempotency sentinel AND baked into the runtime wrappers.
AGENT_BIN="$AGENT_WS/install/micro_xrce_dds_agent/lib/micro_xrce_dds_agent/MicroXRCEAgent"

log() { echo "[build-uros-agent] $*"; }
die() { echo "[build-uros-agent] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash provision/build-uros-agent.sh)"
[ -f "/opt/ros/$ROS_DISTRO/setup.bash" ] \
    || die "ROS 2 $ROS_DISTRO not found — run provision/first-boot.sh first"

# --- deps -------------------------------------------------------------------
log "build dependencies"
# build-essential + cmake: the Micro-XRCE-DDS-Agent is a CMake/C++ project;
# Ubuntu Server ships no C++ toolchain by default.
# python3-vcstool: micro_ros_setup's create_agent_ws.sh calls 'vcs import' to
# fetch the agent source tree — not pulled in automatically by anything else.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential \
    cmake \
    git \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool

# --- rosdep -----------------------------------------------------------------
# Both 'rosdep init' (one-time, root) AND 'rosdep update' (per-user cache) must
# succeed before create_agent_ws.sh / build_agent.sh, or the build fails deep
# inside with 'your rosdep installation has not been initialized yet'.
log "rosdep init (one-time, idempotent)"
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
    rosdep init
else
    log "  already initialized"
fi
log "rosdep update"
# NOT silenced/best-effort: a real rosdep failure here (bad cache, DNS, rate
# limit) must stop the script now with a clear cause, not surface later as a
# cryptic error deep inside build_agent.sh.
rosdep update --rosdistro "$ROS_DISTRO" \
    || die "rosdep update failed — check network connectivity and re-run"

# --- idempotency guard ------------------------------------------------------
if [ -x "$AGENT_BIN" ]; then
    log "agent binary already present — skipping build"
    log "  to force a full rebuild: sudo rm -rf $AGENT_WS $SETUP_WS && re-run"
else
    # ROS setup scripts reference unbound shell variables (AMENT_TRACE_SETUP_FILES
    # etc.). Sourcing them under 'set -u' aborts with 'unbound variable'.
    set +u
    # shellcheck disable=SC1090
    source "/opt/ros/$ROS_DISTRO/setup.bash"
    set -u

    log "staging micro_ros_setup @ $MICRO_ROS_SETUP_REF → $SETUP_WS"
    mkdir -p "$SETUP_WS/src"
    if [ -d "$SETUP_WS/src/micro_ros_setup/.git" ]; then
        git -C "$SETUP_WS/src/micro_ros_setup" fetch origin
        git -C "$SETUP_WS/src/micro_ros_setup" checkout "$MICRO_ROS_SETUP_REF"
        git -C "$SETUP_WS/src/micro_ros_setup" pull --ff-only origin "$MICRO_ROS_SETUP_REF" \
            || true
    else
        git clone --branch "$MICRO_ROS_SETUP_REF" "$MICRO_ROS_SETUP_URL" \
            "$SETUP_WS/src/micro_ros_setup"
    fi

    log "building micro_ros_setup (staging)"
    cd "$SETUP_WS"
    colcon build \
        --packages-select micro_ros_setup \
        --cmake-args -DCMAKE_BUILD_TYPE=Release

    [ -f "$SETUP_WS/install/setup.bash" ] \
        || die "micro_ros_setup build failed — no $SETUP_WS/install/setup.bash"

    set +u
    # shellcheck disable=SC1090
    source "$SETUP_WS/install/setup.bash"
    set -u

    log "creating agent workspace → $AGENT_WS"
    mkdir -p "$AGENT_WS"
    cd "$AGENT_WS"
    ros2 run micro_ros_setup create_agent_ws.sh

    [ -d "$AGENT_WS/src" ] \
        || die "create_agent_ws.sh produced no src/ directory in $AGENT_WS"

    log "building Micro-XRCE-DDS-Agent (10-20 min on Pi 4B)"
    cd "$AGENT_WS"
    ros2 run micro_ros_setup build_agent.sh

    [ -x "$AGENT_BIN" ] \
        || die "agent build failed — expected binary at $AGENT_BIN"
    log "Micro-XRCE-DDS-Agent built"
fi

# --- runtime wrappers -------------------------------------------------------
# systemd ExecStart= cannot source shell environments. Both agent modes exec
# through thin wrapper scripts — same pattern as /opt/friday/bin/ros2-run
# (installed by build-rover-code.sh).
#
# NAMING: wrapper filenames use the hyphenated 'micro-ros-agent-*' form, and
# the systemd unit ExecStart= lines below must match EXACTLY. (A prior draft
# of this script drifted to 'microros-agent-*' in the units — verified fixed
# here; keep this comment as a tripwire for future edits.)
mkdir -p /opt/friday/bin

log "installing wrapper → /opt/friday/bin/micro-ros-agent-serial"
# Contract: the unit passes ONLY the kernel device name as $1 (e.g. ttyUSB0),
# NOT a full /dev/ path — this wrapper is the one place that prepends /dev/.
# (A prior draft double-prefixed this: the unit passed /dev/%i AND the wrapper
# added /dev/ again, producing /dev//dev/ttyUSB0. Fixed: unit passes %i only.)
install -D -m 0755 /dev/stdin /opt/friday/bin/micro-ros-agent-serial <<EOF
#!/usr/bin/env bash
# micro-ros-agent-serial — bridge one ESP32 over USB-serial to the ROS 2 graph.
# Usage: micro-ros-agent-serial <device-name>   (e.g. ttyUSB0, ttyACM0 — NOT a /dev/ path)
# Called by the udev-triggered micro-ros-agent-serial@<dev>.service instance.
# Do NOT use 'set -u': ROS setup scripts reference unbound shell variables.
set -eo pipefail
DEVICE="\${1:?usage: micro-ros-agent-serial <device-name>  e.g. ttyUSB0}"
source "/opt/ros/$ROS_DISTRO/setup.bash"
source "$AGENT_WS/install/setup.bash"
export ROS_DOMAIN_ID=42
# Point ROS_HOME at the state directory so rclpy can create its log dir.
# ProtectHome=yes (in the unit) hides /home; ~/.ros would be inaccessible.
export ROS_HOME=/var/lib/friday/ros
exec "$AGENT_BIN" serial --dev "/dev/\$DEVICE" --baudrate $SERIAL_BAUD
EOF

log "installing wrapper → /opt/friday/bin/micro-ros-agent-udp"
install -D -m 0755 /dev/stdin /opt/friday/bin/micro-ros-agent-udp <<EOF
#!/usr/bin/env bash
# micro-ros-agent-udp — bridge WiFi-connected ESP32 clients to the ROS 2 graph.
# Listens on UDP port $UDP_PORT. Called by micro-ros-agent-udp.service.
# Do NOT use 'set -u': ROS setup scripts reference unbound shell variables.
set -eo pipefail
source "/opt/ros/$ROS_DISTRO/setup.bash"
source "$AGENT_WS/install/setup.bash"
export ROS_DOMAIN_ID=42
export ROS_HOME=/var/lib/friday/ros
exec "$AGENT_BIN" udp4 --port $UDP_PORT
EOF

# --- udev rule (serial hotplug) ---------------------------------------------
# Installs the repo-tracked rule (udev/99-friday-microros-serial.rules) — do
# NOT embed a second, divergent copy here. That file uses TAG+="systemd" +
# ENV{SYSTEMD_WANTS}+= (append, not clobber) to start the matching template
# instance on plug, and relies ENTIRELY on each unit's own BindsTo=dev-%i.device
# for stop-on-unplug — no udev RUN+="systemctl stop ..." action. A synchronous
# systemctl call from a udev RUN+= line during a REMOVE event blocks the udev
# worker thread and can race/deadlock with systemd's own device-unit teardown;
# BindsTo= handles it atomically within systemd instead.
log "installing udev rule → /etc/udev/rules.d/99-friday-microros-serial.rules"
install -D -m 0644 \
    "$REPO_ROOT/udev/99-friday-microros-serial.rules" \
    /etc/udev/rules.d/99-friday-microros-serial.rules

# --- systemd units ----------------------------------------------------------
log "installing systemd units"
install -D -m 0644 \
    "$REPO_ROOT/systemd/micro-ros-agent-serial@.service" \
    /etc/systemd/system/micro-ros-agent-serial@.service
install -D -m 0644 \
    "$REPO_ROOT/systemd/micro-ros-agent-udp.service" \
    /etc/systemd/system/micro-ros-agent-udp.service

systemctl daemon-reload

# Enable AND start the UDP agent now — it has no device dependency, so there's
# no reason to defer to next boot. Do NOT enable the serial template directly;
# udev is its only trigger (enabling it statically would try to start an
# instance with an empty device name and fail on every boot).
log "enabling + starting micro-ros-agent-udp.service"
systemctl enable --now micro-ros-agent-udp.service

# Reload udev so the new rule is live immediately, then re-trigger the tty
# subsystem so any ESP32 already plugged in before provisioning gets its
# service instance started now without requiring a replug.
log "reloading udev rules"
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty --action=add || true

# --- ownership fix ----------------------------------------------------------
# colcon built as root; the 'friday' service user needs write access to the
# agent workspace at runtime (DDS socket files, ROS log symlinks).
# $SETUP_WS is build-time tooling only — left root-owned deliberately.
log "workspace ownership → friday:friday ($AGENT_WS)"
chown -R friday:friday "$AGENT_WS" 2>/dev/null || true

# --- build provenance -------------------------------------------------------
mkdir -p /etc/friday
date --iso-8601=seconds > /etc/friday/uros-agent.built
"$AGENT_BIN" --version 2>&1 | head -1 > /etc/friday/uros-agent.version 2>/dev/null \
    || echo "unknown" > /etc/friday/uros-agent.version

log ""
log "=== SUCCESS ==="
log "Micro-XRCE-DDS-Agent installed at $AGENT_WS"
log ""
log "UDP agent (always-on, already started):"
log "  sudo systemctl status micro-ros-agent-udp.service"
log "  ss -ulnp | grep $UDP_PORT"
log ""
log "Serial agent (hotplug — starts automatically when an ESP32 is plugged in):"
log "  plug in the Locomotion ESP32 via USB, then:"
log "  sudo systemctl status 'micro-ros-agent-serial@ttyUSB*.service'"
log ""
log "Verify the bridge joins the ROS 2 graph (requires a connected ESP32):"
log "  source /opt/ros/$ROS_DISTRO/setup.bash"
log "  export ROS_DOMAIN_ID=42"
log "  ros2 node list   # -> a microros node appears once the ESP32 connects"
