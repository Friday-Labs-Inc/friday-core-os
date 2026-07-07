#!/usr/bin/env bash
# verify.sh — post-provisioning health check for the Core Hub.
# Runs a series of checks and prints [OK] / [FAIL] for each. Exits 0 if all pass,
# non-zero if any fail — safe to call from CI, cloud-init, or a monitoring hook.

INTERNAL_IP="${FRIDAY_INTERNAL_IP:-10.0.1.1}"
ROS_DISTRO="${FRIDAY_ROS_DISTRO:-jazzy}"
FAIL=0

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "[OK]   $label"
    else
        echo "[FAIL] $label"
        FAIL=$((FAIL + 1))
    fi
}

check_out() {
    # Same as check() but prints the value for context.
    local label="$1"; shift
    local out
    out="$("$@" 2>/dev/null)" || { echo "[FAIL] $label"; FAIL=$((FAIL + 1)); return; }
    echo "[OK]   $label: $out"
}

echo "=== Mark 1 Core Hub — post-provisioning verify ==="

check_out "hostname"                              hostname
check_out "internal-bridge address"               ip -o -4 addr show dev eth0 scope global
check     "mosquitto systemd unit active"         systemctl is-active mosquitto-internal.service
check     "mosquitto listening on $INTERNAL_IP:1883" bash -c \
              "ss -Hlnt sport = :1883 | grep -q '$INTERNAL_IP:1883'"
check     "ROS 2 $ROS_DISTRO setup.bash present"  test -f "/opt/ros/$ROS_DISTRO/setup.bash"
check     "friday-core-os.target enabled"         systemctl is-enabled friday-core-os.target
check     "module identity file"                  test -s /etc/friday/module-identity.json

if command -v wg >/dev/null && [ -f /etc/wireguard/wg-core.conf ]; then
    check "wireguard interface up"                wg show wg-core
    check "wireguard has a recent handshake"      bash -c \
              "wg show wg-core latest-handshakes | awk '{print \$2}' | grep -qvE '^0?\$'"
else
    echo "[SKIP] wireguard: no config, tunnel not configured yet"
fi

# --- module-registry (Phase A2; only once the ROS workspace is built) ---
if systemctl is-enabled module-registry.service >/dev/null 2>&1; then
    check "module-registry.service active" systemctl is-active module-registry.service
    if [ -f /opt/friday/ros2_ws/install/setup.bash ]; then
        check "register_module ROS service present" bash -lc \
          "export ROS_DOMAIN_ID=42; source /opt/ros/$ROS_DISTRO/setup.bash && source /opt/friday/ros2_ws/install/setup.bash && ros2 service list 2>/dev/null | grep -q register_module"
    fi
else
    echo "[SKIP] module-registry: not enabled yet (run provision/build-rover-code.sh)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "All checks passed. Core Hub is ready."
    exit 0
else
    echo "$FAIL check(s) failed. See docs/bring-up-guide.md → 'if it does NOT appear'."
    exit 1
fi
