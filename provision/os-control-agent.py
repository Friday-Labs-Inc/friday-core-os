#!/usr/bin/env python3
"""Friday Labs OS — service control agent (Core Hub).

Exposes allowlisted systemd status + start/stop/restart over HTTP for the
Command Center. Runs as the unprivileged `fridayctl` user; a polkit rule
(49-friday-os-control.rules) grants that user manage-units on EXACTLY the
allowlisted units — so even a code bug cannot touch any other service.

Defence in depth:
  1. bearer-token auth (token in /etc/friday/os-control.env)
  2. unit allowlist + action allowlist in this file
  3. polkit scopes the OS privilege to the same units (belt and braces)

Every mutating action (and every auth failure) is written to an audit log.
Stdlib only — no dependencies.
"""
import datetime
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("FRIDAY_OS_CONTROL_TOKEN", "")
PORT = int(os.environ.get("FRIDAY_OS_CONTROL_PORT", "8710"))
AUDIT_LOG = os.environ.get("FRIDAY_OS_CONTROL_AUDIT", "/var/log/friday-os-control/audit.log")

ALLOW = [
    "friday-core-os.target",
    "module-registry.service",
    "mosquitto-internal.service",
    "micro-ros-agent-gpio.service",
    "micro-ros-agent-udp.service",
]
ACTIONS = {"start", "stop", "restart"}


def audit(entry: dict) -> None:
    entry = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), **entry}
    line = json.dumps(entry, separators=(",", ":"))
    print("AUDIT " + line, flush=True)  # -> journald
    try:
        with open(AUDIT_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass  # journald still has it


def systemctl(*args):
    # No sudo: as fridayctl this talks to systemd over D-Bus; polkit authorises.
    return subprocess.run(["systemctl", *args], capture_output=True, text=True, timeout=25)


def status(name):
    r = systemctl("show", name,
                  "--property=ActiveState,SubState,UnitFileState,Description,LoadState", "--no-pager")
    d = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return {
        "name": name,
        "active": d.get("ActiveState", "unknown"),
        "sub": d.get("SubState", ""),
        "enabled": d.get("UnitFileState", ""),
        "description": d.get("Description", name),
    }


class H(BaseHTTPRequestHandler):
    def _auth(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "services": len(ALLOW)})
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if self.path == "/services":
            return self._send(200, [status(n) for n in ALLOW])
        self._send(404, {"error": "not found"})

    def do_POST(self):
        client = self.client_address[0]
        if not self._auth():
            audit({"client": client, "event": "auth_failed", "path": self.path})
            return self._send(401, {"error": "unauthorized"})
        if self.path != "/service":
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})
        name, action = body.get("name"), body.get("action")
        if name not in ALLOW:
            audit({"client": client, "event": "rejected", "reason": "not_allowlisted",
                   "unit": name, "action": action})
            return self._send(403, {"error": f"service not allowlisted: {name}"})
        if action not in ACTIONS:
            audit({"client": client, "event": "rejected", "reason": "bad_action",
                   "unit": name, "action": action})
            return self._send(400, {"error": f"action must be one of {sorted(ACTIONS)}"})
        r = systemctl(action, name)
        st = status(name)
        ok = r.returncode == 0
        audit({"client": client, "event": "action", "unit": name, "action": action,
               "ok": ok, "active": st["active"], "sub": st["sub"],
               "stderr": r.stderr.strip()[:300]})
        return self._send(200 if ok else 500, {
            "name": name, "action": action, "ok": ok,
            "active": st["active"], "sub": st["sub"],
            "stderr": r.stderr.strip()[:300],
        })


if __name__ == "__main__":
    print(f"os-control-agent on :{PORT} · {len(ALLOW)} services · auth={'on' if TOKEN else 'OFF'} · audit={AUDIT_LOG}")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
