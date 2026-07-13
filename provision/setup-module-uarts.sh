#!/usr/bin/env bash
# setup-module-uarts.sh — enable the four dedicated GPIO UARTs for the ESP32
# module fleet on the Core Hub Pi 4. Idempotent. Run as root (sudo). REBOOT
# REQUIRED after the first run (device-tree overlays load at boot).
#
# WIRING DECISION (2026-07-12, docs/build/MK1_Pi4_ESP32_UART_Wiring.html in
# the rover repo): all four module boards use UART2/3/4/5 — UART0 (pins 8/10)
# stays reserved for the Linux serial console. UART is point-to-point, so each
# board gets its own controller:
#
#   board  overlay  Pi TX pin (GPIO)  Pi RX pin (GPIO)  expected tty
#   ESP#1  uart2    27 (GPIO0)        28 (GPIO1)        ttyAMA2
#   ESP#2  uart3     7 (GPIO4)        29 (GPIO5)        ttyAMA3
#   ESP#3  uart4    24 (GPIO8)        21 (GPIO9)        ttyAMA4
#   ESP#4  uart5    32 (GPIO12)       33 (GPIO13)       ttyAMA5
#
# VERIFIED on Pi 4B (2026-07-13): uart2->ttyAMA2, uart3->ttyAMA3, uart4->ttyAMA4,
# uart5->ttyAMA5.  There is NO ttyAMA1 (the mini-uart/uart1 is left disabled), so
# the four module ttys are ttyAMA2..ttyAMA5 — NOT ttyAMA1..4.  If a future board
# enumerates differently, re-check with `dmesg | grep ttyAMA` and adjust WANTS.
#
# Agents: reuses the hardened micro-ros-agent-serial@.service template (the
# same one udev uses for USB serial). GPIO UARTs are always-present devices,
# not hot-plug, so instances are pulled in at boot by friday-core-os.target
# via add-wants symlinks — BindsTo=dev-%i.device in the template still holds
# them off until the tty exists.
#
# NOTE: uart2 claims GPIO0/1 (the HAT ID-EEPROM pins) — fine on this rover
# (no HAT), but don't stack a HAT on top of this configuration.
set -euo pipefail

CONFIG=/boot/firmware/config.txt
MARK_BEGIN="# --- friday module UARTs (setup-module-uarts.sh) ---"
MARK_END="# --- end friday module UARTs ---"
OVERLAYS=(uart2 uart3 uart4 uart5)
WANTS=(ttyAMA2 ttyAMA3 ttyAMA4 ttyAMA5)

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
[ -f "$CONFIG" ] || { echo "missing $CONFIG — is this the Pi?"; exit 1; }

# 1. device-tree overlays (idempotent marker block; replaces any prior block)
if grep -qF "$MARK_BEGIN" "$CONFIG"; then
  sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$CONFIG"
fi
{
  echo "$MARK_BEGIN"
  for o in "${OVERLAYS[@]}"; do echo "dtoverlay=$o"; done
  echo "$MARK_END"
} >> "$CONFIG"
echo "overlays written to $CONFIG: ${OVERLAYS[*]}"

# 2. agent instances at boot, via the existing hardened template.
#    (systemctl enable is useless for a template with no [Install]; add-wants
#    creates the friday-core-os.target.wants/ symlink explicitly.)
for tty in "${WANTS[@]}"; do
  systemctl add-wants friday-core-os.target "micro-ros-agent-serial@${tty}.service"
done
systemctl daemon-reload
echo "boot-wants added: micro-ros-agent-serial@{${WANTS[*]// /,}}"

# 3. guidance
cat <<GUIDE

NEXT STEPS
  1. reboot
  2. verify the tty mapping:      dmesg | grep ttyAMA ; ls -l /dev/ttyAMA*
  3. verify the agents came up:   systemctl status 'micro-ros-agent-serial@ttyAMA*'
  4. once boards are rewired off UART0, retire the old pin-8/10 agent:
       systemctl disable --now micro-ros-agent-gpio.service
     (UART0 then returns to Linux serial-console duty — no console-disable
      step is needed anymore, per the wiring decision.)
GUIDE
