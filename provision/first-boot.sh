#!/usr/bin/env bash
# first-boot.sh — provision a Pi 4B as the Mark 1 Core Hub.
#
# Idempotent: safe to re-run. Every step checks its current state and skips
# the ones already done. If a step fails, the script exits with a clear error
# and leaves the system in a recoverable state.
#
# Follow docs/bring-up-guide.md end-to-end; this script is Step 3.

set -euo pipefail

# ---- config (override with env vars if needed) --------------------------
HOSTNAME="${FRIDAY_HOSTNAME:-mark1-core}"
INTERNAL_IP="${FRIDAY_INTERNAL_IP:-10.0.1.1}"
INTERNAL_IFACE="${FRIDAY_INTERNAL_IFACE:-eth0}"
MODULE_ID="${FRIDAY_MODULE_ID:-MARK1-CORE-001}"
ROS_DISTRO="${FRIDAY_ROS_DISTRO:-jazzy}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="$REPO_ROOT/provision/secrets"
WG_CONF="$SECRETS_DIR/mark1-core.conf"

# ---- helpers ------------------------------------------------------------
log()  { echo "[first-boot] $*"; }
warn() { echo "[first-boot] WARN: $*" >&2; }
die()  { echo "[first-boot] ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (sudo bash provision/first-boot.sh)"
}

require_ubuntu_24() {
    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [ "$codename" = "noble" ] || die "expected Ubuntu 24.04 (noble), got '$codename'"
}

# ---- steps --------------------------------------------------------------
create_friday_user() {
    log "service user → friday"
    if ! id friday >/dev/null 2>&1; then
        useradd --system --home-dir /var/lib/friday --create-home \
                --shell /usr/sbin/nologin friday
    fi
    # dialout = access to /dev/ttyUSB* for micro-ROS serial to the ESP32s.
    usermod -aG dialout friday 2>/dev/null || true
    install -d -o friday -g friday /var/lib/friday /var/log/friday
}

set_hostname() {
    log "hostname → $HOSTNAME"
    hostnamectl set-hostname "$HOSTNAME"
    # cloud-init rewrites the hostname on EVERY boot unless told to preserve it,
    # which reverts our hostname after a reboot. Opt out.
    if [ -d /etc/cloud/cloud.cfg.d ]; then
        echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-friday-preserve-hostname.cfg
    fi
    # ensure /etc/hosts resolves the new hostname locally
    grep -qE "^127\.0\.1\.1\s+$HOSTNAME" /etc/hosts \
        || echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
}

configure_internal_network() {
    log "internal ethernet → $INTERNAL_IFACE @ $INTERNAL_IP/24"
    ip link show "$INTERNAL_IFACE" >/dev/null 2>&1 \
        || die "interface '$INTERNAL_IFACE' not found. Check 'ip -br link' and set FRIDAY_INTERNAL_IFACE."
    cat > /etc/netplan/10-internal-bridge.yaml <<EOF
# Mark 1 Core Hub — internal ethernet bridge to Telemetry Gateway.
# Managed by friday-core-os first-boot.sh; do not edit by hand.
# ignore-carrier keeps the static IP assigned even with NO cable plugged (bench:
# the Telemetry Gateway isn't wired to eth0 yet), so the internal broker can always
# bind ${INTERNAL_IP}. On the field rover eth0 is cabled and this is a no-op.
network:
  version: 2
  ethernets:
    $INTERNAL_IFACE:
      addresses:
        - ${INTERNAL_IP}/24
      dhcp4: false
      optional: true
      ignore-carrier: true
EOF
    chmod 600 /etc/netplan/10-internal-bridge.yaml
    netplan apply || warn "netplan apply reported an issue; check 'journalctl -u systemd-networkd'"
}

install_mosquitto() {
    log "mosquitto (internal MQTT broker)"
    if ! command -v mosquitto >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mosquitto
    fi
    mkdir -p /etc/friday
    install -m 0644 "$REPO_ROOT/mosquitto/mosquitto-internal.conf" /etc/friday/mosquitto-internal.conf
    install -D -m 0644 "$REPO_ROOT/systemd/mosquitto-internal.service" \
        /etc/systemd/system/mosquitto-internal.service
    install -D -m 0644 "$REPO_ROOT/systemd/friday-core-os.target" \
        /etc/systemd/system/friday-core-os.target
    install -D -m 0644 "$REPO_ROOT/systemd/friday-core-os@.service.d/security.conf" \
        /etc/systemd/system/friday-core-os@.service.d/security.conf
    # module-registry unit installed (but NOT enabled — it needs the ROS
    # workspace, built later by build-rover-code.sh, which enables it).
    install -D -m 0644 "$REPO_ROOT/systemd/module-registry.service" \
        /etc/systemd/system/module-registry.service
    systemctl stop mosquitto 2>/dev/null || true
    systemctl disable mosquitto 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable mosquitto-internal.service
}

install_ros2_jazzy() {
    log "ROS 2 $ROS_DISTRO"
    if [ -f "/opt/ros/$ROS_DISTRO/setup.bash" ]; then
        log "  already installed"
        return 0
    fi
    apt-get install -y -qq software-properties-common curl gnupg
    add-apt-repository -y universe >/dev/null
    # -s (non-empty), not -f: a 0-byte leftover from a failed fetch must not trap re-runs.
    if [ ! -s /usr/share/keyrings/ros-archive-keyring.gpg ]; then
        # A rover lives on flaky links. -4 dodges intermittent IPv6 resolution;
        # --retry rides out transient DNS/network blips instead of dying under set -e.
        curl -4 -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
            https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
            -o /usr/share/keyrings/ros-archive-keyring.gpg \
            || die "failed to fetch the ROS apt key (network?) — fix connectivity and re-run"
    fi
    local codename
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $codename main" \
        > /etc/apt/sources.list.d/ros2.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "ros-$ROS_DISTRO-ros-base"
    [ -f "/opt/ros/$ROS_DISTRO/setup.bash" ] \
        || die "ROS 2 install failed; expected /opt/ros/$ROS_DISTRO/setup.bash"
}

install_wireguard() {
    log "WireGuard (join Command Center tunnel)"
    if ! command -v wg >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard wireguard-tools
    fi
    if [ ! -f "$WG_CONF" ]; then
        warn "no WireGuard config at $WG_CONF — skipping tunnel setup"
        warn "  drop mark1-core.conf into that path and re-run to complete WG setup"
        return 0
    fi
    install -D -m 0600 "$WG_CONF" /etc/wireguard/wg-core.conf
    systemctl enable --now wg-quick@wg-core.service \
        || warn "wg-quick failed to start; check 'sudo journalctl -u wg-quick@wg-core'"
}

write_module_identity() {
    log "module identity → /etc/friday/module-identity.json"
    mkdir -p /etc/friday
    cat > /etc/friday/module-identity.json <<EOF
{
  "module_id": "$MODULE_ID",
  "module_type": "core-hub",
  "hardware": "raspberry-pi-4b-8gb",
  "os_image": "friday-core-os",
  "os_version": "phase-a1",
  "ros_distro": "$ROS_DISTRO",
  "provisioned_at": "$(date --iso-8601=seconds)"
}
EOF
    chmod 0644 /etc/friday/module-identity.json
}

enable_target() {
    log "systemd target → friday-core-os.target (default)"
    systemctl daemon-reload
    systemctl enable friday-core-os.target
    systemctl set-default friday-core-os.target
}

# ---- main ---------------------------------------------------------------
main() {
    require_root
    require_ubuntu_24
    log "starting Mark 1 Core Hub provisioning"

    create_friday_user
    set_hostname
    configure_internal_network
    install_mosquitto
    install_ros2_jazzy
    install_wireguard
    write_module_identity
    enable_target

    log ""
    log "=== SUCCESS ==="
    log "Reboot the Pi now (sudo reboot), then run:"
    log "  sudo bash /opt/friday/friday-core-os/provision/verify.sh"
    log ""
}

main "$@"
