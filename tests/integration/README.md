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
host; this test installs a persistent service and writes actual metrics/data.

```bash
zig build
VM_HOST="disposable-ubuntu.example.com"
VM_USER="root"
export VM_HOST VM_USER
bash tests/integration/victoriametrics.sh
```

Expected: first install/verify succeeds, second install reports no changes and
MainPID/ExecMainStartTimestampMonotonic remain identical. Check the reported storage
reserve against `stat -f -c '%b %S' /var/lib/dragontools/victoriametrics` divided by 5.
The runner uses your default SSH agent/identities and port 22; adapt all invocations
together for other authentication. Destroy the VM through your provider afterwards.
DragonTools has no uninstall or provisioning command yet.

Before accepting a release, additionally exercise:

- Unknown SSH key and missing tools fail before mutation.
- Unsupported Ubuntu release or non-systemd target fails before account creation.
- Existing conflicting account/unmanaged unit causes a safe refusal.
- Wrong checksum, interrupted download and unavailable HTTPS do not activate a binary.
- Changed unit repairs once; a subsequent install is a no-op.
- Stop the service; reinstall restores health without rewriting matching files.
- Interrupt between unit write and restart; rerun consumes the persisted marker.
- Corrupt the installed executable in this disposable VM; reinstall repairs it.
- Verify loopback-only listener and inability to connect to target port 8428 externally.
- Check root/service ownership, `systemd-analyze security`, journal errors and real
  query persistence across a restart. Inspect unexpected drop-ins and overrides.
- Test low-space reserve on a dedicated disposable small volume; never fill a
  production root filesystem. Confirm ingestion stops, not that files are deleted.

Integration is opt-in and was not run merely because unit tests passed. Record OS,
architecture, versions, command outputs and results without credentials.
