# Disposable Ubuntu integration

Use fresh disposable Ubuntu **24.04 and 26.04** VMs on **amd64 and arm64** with
systemd as PID 1. A normal Docker container does not validate systemd hardening.
Install prerequisites if your minimal image omits them:

```bash
sudo apt-get update
sudo apt-get install -y openssh-server curl ca-certificates tar coreutils util-linux iproute2 passwd grep
```

Verify the VM SSH fingerprint using its console and enroll it in known_hosts.
Allow outbound HTTPS to official GitHub release assets. Do not use a production
host; this test installs two persistent services and writes actual metrics/data.

```bash
zig build
VM_HOST="disposable-ubuntu.example.com"
VM_USER="root"
export VM_HOST VM_USER
tests/integration/victorialogs.sh
```

Expected: install and `monitoring verify` succeed for VictoriaMetrics and
VictoriaLogs. The runner checks both active/enabled services and requires exactly
one listener for each port, at `127.0.0.1:8428` and `127.0.0.1:9428`. It checks
HTTP health, VictoriaLogs' `vl_storage_is_read_only == 0`, the managed and running
logs flags `-retentionPeriod=100y` and `-retention.maxDiskUsagePercent=75`, and
VictoriaMetrics' `90d` retention. The CLI verification also checks the current
reserve policy, running executable hashes, managed units, and service hardening.

The second install must report `No changes required.`, with identical MainPID and
ExecMainStartTimestampMonotonic values for **both** services. The runner then
appends one harmless comment to the managed VictoriaLogs unit, reruns install,
and requires a VictoriaLogs-only restart followed by another no-op. Finally it
creates the root-owned VictoriaLogs restart marker to model persisted intent after
interruption, reruns install, and checks that only VictoriaLogs restarted and the
marker cleared after verification. This simulates recovery state; it does not kill
an installer at an actual failure boundary. No application log is injected and no
storage files are manually deleted.

Check the reported metrics reserve against
`stat -f -c '%b %S' /var/lib/dragontools/victoriametrics`, multiplying blocks by block
size and rounding one fifth of the result upward. The logs percentage is a native
cleanup target: periodic checks and preservation of the newest two days allow
usage to exceed 75%. This runner checks configuration and writable state, not
long-duration disk-pressure cleanup behavior.

The runner uses your default SSH agent/identities and port 22; adapt all invocations
together for other authentication. It supports root or noninteractive `sudo -n`,
uses strict host-key checks, and suppresses raw remote stderr. `TOOL` may point to
another already-built binary. On failure, inspect the named service using the VM
console or your trusted SSH session and rerun; a managed test comment or restart
marker may remain until installation recovers. Destroy the VM through your provider
afterwards. DragonTools has no uninstall or provisioning command yet.

The older `victoriametrics.sh` runner remains available as a narrower process
stability check; its `monitoring install` invocation now also installs VictoriaLogs.
Use `victorialogs.sh` for the complete two-component lifecycle checks.

Before accepting a release, additionally exercise:

- Unknown SSH key and missing tools fail before mutation.
- Unsupported Ubuntu release or non-systemd target fails before account creation.
- Existing conflicting account/unmanaged unit causes a safe refusal.
- Wrong checksum, interrupted download and unavailable HTTPS do not activate a binary.
- Changed unit repairs once; a subsequent install is a no-op. The runner covers
  VictoriaLogs comment drift; repeat with meaningful unit drift on the disposable VM.
- Stop either service; reinstall restores health without rewriting matching files
  or restarting the other healthy component.
- Interrupt between unit write and restart; rerun consumes the persisted marker.
- Corrupt the installed executable in this disposable VM; reinstall repairs it.
- Verify inability to connect to target ports 8428 and 9428 externally, in addition
  to the loopback-only listeners checked by the runner.
- Check root/service ownership, `systemd-analyze security`, journal errors and real
  query persistence across a restart. Inspect unexpected drop-ins and overrides.
- Test the VictoriaMetrics low-space reserve on a dedicated disposable volume;
  confirm ingestion stops, not that files are deleted. For VictoriaLogs, separately
  verify native oldest-partition cleanup, the newest-two-days exception, periodic
  overshoot, and failure of verification in read-only mode. Never fill a production
  root filesystem or claim these pressure scenarios passed from configured flags.

Integration is opt-in and was not run merely because unit tests passed. Record OS,
architecture, versions, command outputs and results without credentials.
The new runner has not been executed against a VM as part of its local addition;
local syntax checks and fake-remote tests do not establish VM runtime compatibility.
