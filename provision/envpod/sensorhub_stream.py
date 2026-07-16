#!/usr/bin/env python3
"""Friday Labs env pod streamer -- DockerPi SensorHub -> Core Hub over UDP.

Runs on the Pi Zero W (Raspbian, no ROS: ARMv6). Reads the SensorHub HAT
(I2C 0x17) once a second and sends one JSON datagram to the Core Hub's
friday_envpod_bridge. One-way, fire-and-forget; no commands are received.
"""
import json
import os
import socket
import time

try:
    import smbus
except ImportError:
    import smbus2 as smbus

BUS = int(os.environ.get("ENVPOD_I2C_BUS", "1"))
ADDR = 0x17
HOST = os.environ.get("ENVPOD_HOST", "192.168.1.12")
PORT = int(os.environ.get("ENVPOD_PORT", "5556"))
PERIOD_S = float(os.environ.get("ENVPOD_PERIOD_S", "1.0"))

R_TEMP, R_RH = 0x05, 0x06
R_P0, R_P1, R_P2 = 0x09, 0x0A, 0x0B
R_L0, R_L1, R_HUMAN = 0x02, 0x03, 0x0D


def read_sample(bus):
    def r(reg):
        return bus.read_byte_data(ADDR, reg)
    return {
        "temp_c": r(R_TEMP),
        "rh_pct": r(R_RH),
        "press_pa": r(R_P0) | (r(R_P1) << 8) | (r(R_P2) << 16),
        "lux": r(R_L0) | (r(R_L1) << 8),
        "human": 1 if r(R_HUMAN) else 0,
    }


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dest = (HOST, PORT)
    bus = smbus.SMBus(BUS)
    print("envpod streamer -> udp://%s:%d @ %.1fs" % (HOST, PORT, PERIOD_S),
          flush=True)
    while True:
        try:
            sock.sendto(json.dumps(read_sample(bus)).encode("utf-8"), dest)
        except OSError as exc:
            print("i2c/udp error: %s" % exc, flush=True)
        time.sleep(PERIOD_S)


if __name__ == "__main__":
    main()
