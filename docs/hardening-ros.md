# Why ROS 2 services use a looser hardening profile

The non-ROS services on the Core Hub (mosquitto, future network helpers) get the
strict `systemd/friday-core-os@.service.d/security.conf` drop-in — full syscall
filtering, `MemoryDenyWriteExecute`, `IPAddressDeny=any`, `PrivateTmp`, etc.

**ROS 2 services do NOT get that drop-in.** They use an inline, deliberately
looser profile (see `systemd/module-registry.service`). This is a real
tradeoff, documented here so it's a conscious decision, not an oversight.

## What ROS 2 / DDS needs that the strict profile blocks

| Strict setting | Why it breaks ROS 2 / rclpy |
|---|---|
| `MemoryDenyWriteExecute=yes` | Python's CPython + some DDS vendors JIT/mmap executable pages; rclpy can crash on import. |
| `PrivateTmp=yes` | Fast-DDS shared-memory transport uses `/dev/shm` (not `/tmp`), but some tooling also probes `/tmp`; safest to leave shared. |
| `IPAddressDeny=any` | DDS discovery is multicast on the local subnet; denying all IP kills discovery even for localhost-only graphs. |
| Strict `SystemCallFilter` | DDS uses `mmap`, `membarrier`, `sched_setaffinity`, shared-memory syscalls that trip a tight `@system-service` filter. |

## What we DO keep on ROS 2 services

The module-registry unit still applies the meaningful, DDS-safe protections:

- `NoNewPrivileges=yes` — no privilege escalation, ever
- `ProtectSystem=strict` + explicit `ReadWritePaths` — read-only rootfs, writes only to the workspace + state dirs + `/dev/shm`
- `ProtectHome=yes` — no access to user home dirs
- `ProtectKernelTunables` + `ProtectControlGroups` — no kernel/cgroup tampering
- `RestrictSUIDSGID` + `LockPersonality`
- Runs as the unprivileged `friday` user, not root
- Crash-loop guard (5 restarts / 60 s) per the Spark Authority addendum

## The path to tightening this (Phase B)

The looseness is a Phase A2 expedient. When the real services are built in
Phase B, tighten per-service with **measured** allow-lists:

1. Run each service under `systemd-analyze security <unit>` to get its exposure score.
2. Use `SystemCallFilter=@system-service @ipc @memlock` plus a service-specific
   allow-list derived from an `strace` of a real run — rather than the blanket
   `@system-service` minus a denylist.
3. Consider `rmw_zenoh` (2027 target per the 2030 Horizon) — Zenoh's transport
   is unicast + peer-configured, which is far more compatible with
   `IPAddressAllow` allow-listing than DDS multicast discovery.

## Bottom line

A ROS 2 node running as a non-root user with a read-only rootfs and no privilege
escalation is a **reasonable** security posture. It is not the *maximal* posture
the non-ROS services get. That gap closes in Phase B with per-service measured
profiles — not with a blanket strict drop-in that would simply prevent the
robot from booting.
