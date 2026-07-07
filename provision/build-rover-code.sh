#!/usr/bin/env bash
# build-rover-code.sh — build the Friday Labs OS ROS 2 packages on the Pi.
#
# Clones (or updates) the friday-labs-os repo and colcon-builds the rover
# packages into /opt/friday/ros2_ws. Run AFTER first-boot.sh (needs ROS 2
# Jazzy installed). Idempotent: re-running updates + rebuilds.
#
# Usage:
#   sudo bash provision/build-rover-code.sh            # build main
#   FRIDAY_LABS_OS_REF=stage1/gazebo sudo -E bash provision/build-rover-code.sh

set -euo pipefail

ROS_DISTRO="${FRIDAY_ROS_DISTRO:-jazzy}"
WS="${FRIDAY_WS:-/opt/friday/ros2_ws}"
REPO_URL="${FRIDAY_LABS_OS_URL:-https://github.com/Friday-Labs-Inc/friday-labs-os.git}"
REPO_REF="${FRIDAY_LABS_OS_REF:-main}"

# The packages the Core Hub actually runs. friday_description (sim/URDF) and
# friday_locomotion (runs on the ESP32 side via its agent) are skipped here.
CORE_PACKAGES="friday_msgs friday_module_agent friday_core_hub friday_telemetry"

log() { echo "[build-rover-code] $*"; }
die() { echo "[build-rover-code] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash provision/build-rover-code.sh)"
[ -f "/opt/ros/$ROS_DISTRO/setup.bash" ] \
    || die "ROS 2 $ROS_DISTRO not found — run provision/first-boot.sh first"

# --- deps ------------------------------------------------------------------
log "build dependencies"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3-colcon-common-extensions python3-rosdep git

# --- clone / update ---------------------------------------------------------
mkdir -p "$WS/src"
if [ -d "$WS/src/friday-labs-os/.git" ]; then
    log "updating friday-labs-os @ $REPO_REF"
    git -C "$WS/src/friday-labs-os" fetch origin
    git -C "$WS/src/friday-labs-os" checkout "$REPO_REF"
    git -C "$WS/src/friday-labs-os" pull --ff-only origin "$REPO_REF" || true
else
    log "cloning friday-labs-os @ $REPO_REF"
    git clone --branch "$REPO_REF" "$REPO_URL" "$WS/src/friday-labs-os"
fi

# --- rosdep (system deps for the packages) ----------------------------------
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
    rosdep init || true
fi
rosdep update --rosdistro "$ROS_DISTRO" >/dev/null 2>&1 || log "rosdep update skipped (offline?)"
# ROS setup scripts reference unbound vars — disable nounset around the source, or
# 'set -u' aborts with 'AMENT_TRACE_SETUP_FILES: unbound variable'.
set +u
# shellcheck disable=SC1090
source "/opt/ros/$ROS_DISTRO/setup.bash"
set -u
rosdep install --from-paths "$WS/src/friday-labs-os/src" --ignore-src -y \
    --rosdistro "$ROS_DISTRO" 2>/dev/null || log "rosdep install skipped (offline?)"

# --- build -------------------------------------------------------------------
log "colcon build: $CORE_PACKAGES"
cd "$WS"
# shellcheck disable=SC2086
colcon build \
    --base-paths src/friday-labs-os/src \
    --packages-select $CORE_PACKAGES \
    --symlink-install \
    --cmake-args -DCMAKE_BUILD_TYPE=Release

[ -f "$WS/install/setup.bash" ] || die "build failed — no install/setup.bash"

# --- runtime wrapper (systemd can't 'source', so services exec through this) --
# $ROS_DISTRO and $WS expand NOW (baked into the wrapper); \$@ stays literal so
# the wrapper forwards its runtime args to `ros2 run`.
install -D -m 0755 /dev/stdin /opt/friday/bin/ros2-run <<EOF
#!/usr/bin/env bash
# ros2-run — exec a ROS 2 entry point with the Friday workspace sourced.
# Usage: ros2-run <package> <executable> [args...]
# No 'set -u' here: ROS setup scripts reference unbound vars and would abort.
set -eo pipefail
source "/opt/ros/$ROS_DISTRO/setup.bash"
source "$WS/install/setup.bash"
exec ros2 run "\$@"
EOF
log "installed runtime wrapper → /opt/friday/bin/ros2-run"

# --- record build provenance ------------------------------------------------
mkdir -p /etc/friday
git -C "$WS/src/friday-labs-os" rev-parse HEAD > /etc/friday/ros-workspace.commit 2>/dev/null || true

log ""
log "=== SUCCESS ==="
log "ROS workspace built at $WS. Start the registry:"
log "  sudo systemctl enable --now module-registry.service"
log "  sudo bash provision/verify.sh"
