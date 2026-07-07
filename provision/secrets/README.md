# provision/secrets/

This directory holds the rover's **per-node secrets** that the Command Center
provisions once and are never regenerated on the rover:

| File | What | Provisioned by |
|------|------|----------------|
| `mark1-core.conf` | WireGuard peer config for this rover's tunnel to the Command Center | FCC "Add Rover" flow |
| `rover-signing-key.priv` *(future)* | Ed25519 private key for signing telemetry (unencrypted until Phase A2 seals to TPM) | FCC "Add Rover" flow |
| `mqtt-client.crt` / `.key` *(future)* | mTLS client cert for the external Command Center broker | FCC certificate authority |

**Everything in this directory except this README + `.gitkeep` is `.gitignored`.**
If you accidentally commit a secret, revoke it in the Command Center immediately
and provision a new one.

For how to get these from the Command Center, see
[`../../docs/bring-up-guide.md`](../../docs/bring-up-guide.md) → "Getting a WireGuard config".
