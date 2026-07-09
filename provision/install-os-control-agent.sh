#!/usr/bin/env bash
# install-os-control-agent.sh — install the Command Center OS-control agent on
# the Core Hub. Idempotent. Run as root (sudo).
#
# The agent lets the Friday Command Center start/stop/restart the allowlisted
# Core Hub systemd units over HTTP (bearer-token). It runs as the unprivileged
# `fridayctl` user; a polkit rule scopes the OS privilege to the same units.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=/opt/friday/bin
ENVF=/etc/friday/os-control.env

# 1. unprivileged system user (no login, no home)
id fridayctl &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin fridayctl

# 2. agent binary
install -d -o fridayctl -g fridayctl "$BIN"
install -o fridayctl -g fridayctl -m 0644 "$HERE/os-control-agent.py" "$BIN/os-control-agent.py"

# 3. token env (generated once; keep across re-installs)
install -d /etc/friday
if [ ! -f "$ENVF" ]; then
  { echo "FRIDAY_OS_CONTROL_TOKEN=$(openssl rand -hex 24)"; echo "FRIDAY_OS_CONTROL_PORT=8710"; } > "$ENVF"
fi
chown fridayctl:fridayctl "$ENVF"; chmod 600 "$ENVF"

# 4. polkit rule — OS-level backstop scoping privilege to the allowlisted units
install -m 0644 "$HERE/polkit/49-friday-os-control.rules" /etc/polkit-1/rules.d/49-friday-os-control.rules

# 5. systemd unit
install -m 0644 "$HERE/../systemd/os-control-agent.service" /etc/systemd/system/os-control-agent.service
systemctl daemon-reload
systemctl enable --now os-control-agent.service

echo
echo "os-control-agent installed and running on :8710."
echo "Wire the FCC gateway: copy the token from $ENVF into the gateway host's"
echo "  /etc/fcc/fcc.env as OS_CONTROL_TOKEN, plus OS_CONTROL_URL=http://<core-hub-ip>:8710"
