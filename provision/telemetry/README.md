# Telemetry agent provisioning (Command Center boundary + world-sense egress)

The telemetry agent is the rover's ONLY radio to the Command Center: inbound
signed commands, outbound signed telemetry (odom/fault + tlm/env + tlm/gps).

## One-time setup on the Core Hub Pi

1. Certs (from the FCC CA, `bridge/gen_certs.sh` in friday-command-center):
   copy `ca.crt`, `rover.crt` (CN=MARK1-001), `rover.key` to `/etc/friday/certs/`
   (`rover.key` chmod 600). The MQTT client id MUST equal the cert CN — the
   broker ACL matches on it.
2. Signing key — generated ON the Pi, private half never leaves it:
   `python3 -c "from cryptography.hazmat.primitives.asymmetric.ed25519 import *; from cryptography.hazmat.primitives import serialization as s; k=Ed25519PrivateKey.generate(); print(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption()).hex())" | sudo tee /etc/friday/rover_signing.key`
   (chmod 600). Derive the public hex and set it on the Frappe `Rover`
   doc (`signing_public_key`) so the gateway verifies this rover — then
   restart `fcc-gateway` to refresh its key cache.
3. `telemetry.params.yaml` -> `/etc/friday/`, `telemetry-agent.service` ->
   `/etc/systemd/system/`, `{}` -> `/etc/friday/operators.json` (empty
   allowlist = all inbound commands rejected until operators are enrolled).
4. Add `telemetry=MARK1-TLM-001` to `managed_nodes` in
   `/etc/friday/core_hub.params.yaml` — the supervisor configures/activates it.

## The transport rule (hard-won)

EVERY fleet service must run `Environment=FASTDDS_BUILTIN_TRANSPORTS=UDPv4`.
The core hub originally lacked it (shared-memory + UDP vs the agents' UDP-only)
and the resulting flaky pub/sub made the telemetry agent believe the Core was
dead — it self-promoted to authority epoch 2 on the LIVE bench (split-brain,
harmless without motors, wrong regardless). `20-udpv4.conf` pins it.
