#!/usr/bin/env bash
# first-boot.sh — run once on first boot to provision a Pi 4B as the Core Hub.
# Intended to be called from cloud-init or a systemd oneshot.
set -euo pipefail

HOSTNAME="mark1-core"
INTERNAL_IP="10.0.1.1"
INTERNAL_IFACE="eth0"

echo "=== Friday Labs OS — Core Hub first-boot provisioning ==="

# --- hostname ---
hostnamectl set-hostname "$HOSTNAME"

# --- static IP on the internal Ethernet (Core ↔ Telemetry Gateway) ---
cat > /etc/netplan/10-internal-bridge.yaml <<EOF
network:
  version: 2
  ethernets:
    $INTERNAL_IFACE:
      addresses:
        - ${INTERNAL_IP}/24
      dhcp4: false
EOF
netplan apply

# --- install mosquitto ---
apt-get update -qq
apt-get install -y -qq mosquitto
systemctl stop mosquitto
cp /opt/friday/mosquitto-internal.conf /etc/friday/mosquitto-internal.conf
systemctl enable mosquitto-internal.service

# --- install ROS 2 Jazzy ---
# (the image should already have ROS 2 baked in; this is a fallback)
if ! command -v ros2 &>/dev/null; then
  echo "ROS 2 Jazzy not found — installing..."
  apt-get install -y -qq ros-jazzy-desktop
fi

# --- module identity ---
mkdir -p /etc/friday
cat > /etc/friday/module-identity.json <<EOF
{
  "module_id": "MARK1-CORE-001",
  "module_type": "core-hub",
  "hardware": "raspberry-pi-4b-8gb",
  "os_image": "friday-core-os"
}
EOF

# --- enable the target ---
systemctl enable friday-core-os.target
systemctl set-default friday-core-os.target

echo "=== Core Hub provisioned. Reboot to activate. ==="
