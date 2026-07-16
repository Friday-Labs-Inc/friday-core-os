# Env pod deploy (Pi Zero W + DockerPi SensorHub)

Advisory environmental pod. Zero W (Raspbian, no ROS: ARMv6) reads the SensorHub
HAT over I2C and streams JSON/UDP to the Core Hub's `friday_envpod_bridge`
(module `MARK1-ENVPOD-001` -> `/mark1/envpod/*`). Verified end-to-end 2026-07-16.

## Zero W (pi@192.168.1.15)
- `sensorhub_stream.py` -> `/opt/friday/envpod/` ; reads 0x17 @ 1 Hz, sends
  `{"temp_c","rh_pct","press_pa","lux","human"}` to `ENVPOD_HOST:5556`.
- `friday-envpod-stream.service` (systemd, User=pi, Restart=always).
- I2C: `dtparam=i2c_arm=on` in config.txt + `echo i2c-dev > /etc/modules-load.d/friday-i2c.conf`
  so `/dev/i2c-1` exists at boot (it was configured but the module was never loaded).
- `smbus2` (python3) already installed. NTC external probe (reg 0x01) reads garbage
  when unplugged -- not streamed.

## Core Hub (friday@192.168.1.12)
- `envpod-bridge.service` -> runs `friday_envpod_bridge envpod_bridge` (domain 42,
  FASTDDS UDPv4 to reach the registry). Node `/envpod`.
- Added `envpod` to `core_hub.params.yaml` managed_nodes so the supervisor
  configure/activates it on every boot.
