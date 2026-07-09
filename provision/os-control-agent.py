#!/usr/bin/env python3
"""Friday Labs OS — service control + brain-config agent (Core Hub).

Two scoped capabilities for the Command Center, over HTTP (bearer-token auth):
  1. systemd control — allowlisted start/stop/restart (NOT general remote-exec),
     runs as unprivileged fridayctl, polkit-scoped to the same units.
  2. brain config — read/write SOUL.md (fixed path, size-capped, atomic + fsync).

Auth fails CLOSED: refuses to start without a token; constant-time compare.
Stdlib only.
"""
import datetime, hmac, json, os, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("FRIDAY_OS_CONTROL_TOKEN", "")
PORT = int(os.environ.get("FRIDAY_OS_CONTROL_PORT", "8710"))
AUDIT_LOG = os.environ.get("FRIDAY_OS_CONTROL_AUDIT", "/var/log/friday-os-control/audit.log")

ALLOW = [
    "friday-core-os.target", "module-registry.service", "mosquitto-internal.service",
    "micro-ros-agent-gpio.service", "micro-ros-agent-udp.service",
]
ACTIONS = {"start", "stop", "restart"}
BRAIN_SOUL = os.environ.get("FRIDAY_BRAIN_SOUL", "/var/lib/friday-brain/SOUL.md")
MAX_SOUL_BYTES = 65536


def audit(entry: dict) -> None:
    entry = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), **entry}
    line = json.dumps(entry, separators=(",", ":"))
    print("AUDIT " + line, flush=True)
    try:
        with open(AUDIT_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def systemctl(*args):
    return subprocess.run(["systemctl", *args], capture_output=True, text=True, timeout=25)


def status(name):
    r = systemctl("show", name, "--property=ActiveState,SubState,UnitFileState,Description,LoadState", "--no-pager")
    d = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1); d[k] = v
    return {"name": name, "active": d.get("ActiveState", "unknown"), "sub": d.get("SubState", ""),
            "enabled": d.get("UnitFileState", ""), "description": d.get("Description", name)}


class H(BaseHTTPRequestHandler):
    timeout = 30  # per-connection socket deadline; bounds slow-loris / stalled reads

    def _auth(self):
        return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {TOKEN}")

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length < 0 or length > MAX_SOUL_BYTES * 2:
            return None, self._send(413, {"error": "payload too large"})
        try:
            return json.loads(self.rfile.read(length) or b"{}"), None
        except Exception:
            return None, self._send(400, {"error": "bad json"})

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "services": len(ALLOW)})
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if self.path == "/services":
            return self._send(200, [status(n) for n in ALLOW])
        if self.path == "/config/soul":
            try:
                with open(BRAIN_SOUL, encoding="utf-8") as f:
                    content = f.read()
                exists = True
            except FileNotFoundError:
                content, exists = "", False
            return self._send(200, {"path": BRAIN_SOUL, "exists": exists,
                                    "bytes": len(content.encode("utf-8")), "content": content})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        client = self.client_address[0]
        if not self._auth():
            audit({"client": client, "event": "auth_failed", "path": self.path})
            return self._send(401, {"error": "unauthorized"})
        if self.path != "/service":
            return self._send(404, {"error": "not found"})
        body, err = self._read_json()
        if err is not None:
            return
        name, action = body.get("name"), body.get("action")
        if name not in ALLOW:
            audit({"client": client, "event": "rejected", "reason": "not_allowlisted", "unit": name, "action": action})
            return self._send(403, {"error": f"service not allowlisted: {name}"})
        if action not in ACTIONS:
            audit({"client": client, "event": "rejected", "reason": "bad_action", "unit": name, "action": action})
            return self._send(400, {"error": f"action must be one of {sorted(ACTIONS)}"})
        r = systemctl(action, name)
        st = status(name)
        ok = r.returncode == 0
        audit({"client": client, "event": "action", "unit": name, "action": action, "ok": ok,
               "active": st["active"], "sub": st["sub"], "stderr": r.stderr.strip()[:300]})
        return self._send(200 if ok else 500, {"name": name, "action": action, "ok": ok,
                                                "active": st["active"], "sub": st["sub"], "stderr": r.stderr.strip()[:300]})

    def do_PUT(self):
        client = self.client_address[0]
        if not self._auth():
            audit({"client": client, "event": "auth_failed", "path": self.path})
            return self._send(401, {"error": "unauthorized"})
        if self.path != "/config/soul":
            return self._send(404, {"error": "not found"})
        body, err = self._read_json()
        if err is not None:
            return
        content = body.get("content")
        if not isinstance(content, str):
            return self._send(400, {"error": "content must be a string"})
        data = content.encode("utf-8")
        if len(data) > MAX_SOUL_BYTES:
            return self._send(413, {"error": f"SOUL.md exceeds {MAX_SOUL_BYTES} bytes"})
        try:
            os.makedirs(os.path.dirname(BRAIN_SOUL), exist_ok=True)
            tmp = BRAIN_SOUL + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(content); f.flush(); os.fsync(f.fileno())
            os.replace(tmp, BRAIN_SOUL)
        except OSError as e:
            audit({"client": client, "event": "soul_write_failed", "error": str(e)[:200]})
            return self._send(500, {"error": f"write failed: {e}"})
        audit({"client": client, "event": "soul_write", "bytes": len(data)})
        return self._send(200, {"ok": True, "path": BRAIN_SOUL, "bytes": len(data)})


if __name__ == "__main__":
    if not TOKEN:
        sys.exit("FATAL: FRIDAY_OS_CONTROL_TOKEN is empty — refusing to start (would disable auth)")
    print(f"os-control-agent on :{PORT} · {len(ALLOW)} services · soul={BRAIN_SOUL} · auth=on")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
