# Phone pod deploy (OnePlus 6T -> GPS + IMU)

Advisory pod. Phone streams one-way over WiFi to the Core Hub; friday_phone_bridge
(PR #6) publishes /mark1/phone/fix (NavSatFix) + /mark1/phone/imu (Imu). Module
MARK1-PHONE-001. Pi side deployed + verified 2026-07-16 (registered, listening).

## Core Hub (friday@192.168.1.12)
- gpsd: `provision/phone/gpsd.default` -> /etc/default/gpsd (DEVICES="udp://*:29998",
  receives phone NMEA on UDP :29998, serves fixes on TCP :2947). gpsd.socket disabled,
  gpsd.service enabled.
- `systemd/phone-bridge.service` -> runs `friday_phone_bridge phone_bridge` (domain 42,
  UDPv4). Node /phone. `phone` is in core_hub.params.yaml managed_nodes -> auto-wake.

## Phone apps (both UDP, target = Pi 192.168.1.12, same WiFi)
- GPSd Forwarder (F-Droid): host 192.168.1.12, port 29998, UDP, NMEA. Location ON.
- HyperIMU (Play Store): IP 192.168.1.12, port 5555, UDP, JSON; accel+gyro(+mag), ~50 Hz.
