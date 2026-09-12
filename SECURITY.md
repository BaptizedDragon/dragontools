# Security policy

Do not report credential leaks or exploitable vulnerabilities in public issues.
Use the repository's **Security → Advisories → Report a vulnerability** private
reporting feature if enabled. If unavailable, ask the maintainer for a private
reporting channel without including exploit details, secrets, or affected hostnames.
No private email address is invented by this project. Rotate exposed credentials
through their provider and share only sanitized evidence.

This is an initial development milestone, not a claim of a security audit or full
monitoring coverage. Only the current development version is maintained.

## Trust model

DragonTools connects over SSH. Install requires administrator-level target access.
Strict known-host verification is mandatory; verify fingerprints out-of-band before
first use. The controller, its PATH/OpenSSH installation, known-hosts file, SSH agent,
target OS, trusted distro CA store and reviewed artifact pins are trusted.
No forwarding or local SSH config is inherited. SSH private keys remain with the
agent or OpenSSH identity file; 1Password itself is optional.

Future telemetry authorization is source-IP/network based. Monitored hosts are
trusted infrastructure; a compromised allowlisted host can submit telemetry.
Grafana still needs user authentication. A provider firewall is recommended outside
the monitoring-only host rules. Raw administrative APIs must not be exposed to agent
networks. Current VictoriaMetrics binds loopback only, reachable by target-local
users and explicitly established SSH tunnels. No firewall or TLS protection is
claimed beyond this boundary.

## Secrets and privileges

Secret handles redact formatted output and wipe owned memory. Resolved secrets must
never enter ordinary command strings, process arguments, systemd Environment lines,
world-readable files, logs, errors or plans. Generic file writing is non-secret only.
No secret resolver or persistent credential handling is enabled yet. Future consumers
must use systemd credentials as described in architecture.md, with encrypted
root-only sources and a reviewed plaintext fallback only when explicitly selected.

Service hardening limits privileges and filesystem writes. It is not protection
against an already-compromised root account or controller. An artifact digest verifies
agreement with the reviewed upstream release; it does not protect against a malicious
publisher. Managed root directories must not be shared with untrusted writers.

## Failure and recovery

A failed install may have created accounts/directories or replaced a binary/unit.
Later phases stop; no destructive rollback is attempted. Output reports confirmed
progress and the failed phase. Inspect the unit/journal locally, fix the cause and
rerun. Do not post raw command output or secret-bearing logs publicly.
Keep storage backups independently; a free-space threshold does not replace them.
