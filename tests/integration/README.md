# Disposable Ubuntu integration

## Host utility: Oh My Zsh

This is a separate test from the monitoring runners below. Use a disposable
Ubuntu host and a fresh account whose shell configuration can safely be tested.
Configure `monitoring-test` as a replaceable native OpenSSH alias, enroll its
verified host key, and allow outbound HTTPS to the official Oh My Zsh archive.
The command may install missing distro packages with root or `sudo -n`; it creates
no account and does not install or change monitoring services.

```bash
zig build -Doptimize=ReleaseSafe
TEST_ALIAS="monitoring-test"
./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host "$TEST_ALIAS" --plan
./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host "$TEST_ALIAS"

# Read-only inspection using the same alias and authentication:
ssh -o StrictHostKeyChecking=yes "$TEST_ALIAS" 'set -eu
getent passwd "$(id -u)"
command -v zsh
test -f "$HOME/.oh-my-zsh/oh-my-zsh.sh"
test -f "$HOME/.zshrc"
stat -c "%u %g %a %n" "$HOME/.oh-my-zsh" "$HOME/.zshrc"
sha256sum "$HOME/.zshrc"'

# Deliberate unchanged rerun:
./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host "$TEST_ALIAS"
```

Expected: the first run installs only absent pieces, reports the current login
shell without changing it, and preserves any existing regular `.zshrc`. The second
run reports `No changes required.`. Compare account records, `.zshrc` bytes and
metadata, Oh My Zsh content/metadata, and apt/download activity before and after
the rerun. `$HOME` in the inspection assumes the ordinary login environment matches
the account home; use the actual `getent` home when testing a customized environment
or `--target-user`.

Also exercise these cases on disposable accounts/hosts only:

- A native alias with a non-root user, non-default port, quoted IdentityAgent path
  containing spaces, and a jump host resolves through OpenSSH. Unknown keys fail.
- A pre-existing regular `.zshrc` with distinct contents is byte-for-byte unchanged,
  even when it does not load Oh My Zsh. An existing recognizable Oh My Zsh checkout
  keeps local changes and its branch unchanged.
- `--target-user` uses an existing account's real home, including a nonstandard
  home path, and does not change its login shell; a missing user fails.
- Existing zsh causes no package reinstall; missing zsh is installed noninteractively.
  Unsupported distributions fail before any apt mutation.
- Conflicting files/directories or symlinks fail without overwriting user data.
  Do not introduce these fixtures in a real user's home.
- Interrupt after packages, during download/extraction, after final directory
  publication, and after `.zshrc` creation. The next install safely completes only
  missing pieces, followed by a no-op. Check that unrelated temporary files survive.
- Incorrect archive digests or unavailable HTTPS fail without a partial final
  `.oh-my-zsh`. Only the reviewed exact source archive is accepted.

**Disposable-host integration not run.** Local fake-remote, rendered shell and CLI
tests are separate evidence; none establishes a real apt/SSH/shell deployment.

For reproducible source review, obtain the exact official archive linked in
[design.md](../../design.md#host-utility-install-oh-my-zsh), then audit the existing
local file without extracting it or making a network connection:

```bash
python3 tests/integration/oh_my_zsh_archive.py /tmp/dragontools-omz-0ee67f0.tar.gz
```

Replace that path with your downloaded archive. The audit reads the literal commit
and SHA-256 pins from `src/host/oh_my_zsh.zig`, requires the reviewed catalog of
1,159 regular files, 417 directories and nine internal relative symlinks, and
rejects traversal, duplicates, hardlinks, special files, setuid/setgid bits, unsafe
link targets, or members beneath links. It never executes downloaded code. This is
source archive review, not an Ubuntu installation or shell-runtime test.

## Monitoring services

Use fresh disposable Ubuntu **24.04 and 26.04** VMs on **amd64 and arm64**, with
systemd as PID 1. A normal Docker container does not validate systemd hardening.
Install prerequisites if your minimal image omits them:

```bash
sudo apt-get update
sudo apt-get install -y openssh-server curl ca-certificates tar coreutils util-linux iproute2 passwd grep
```

Verify the VM SSH fingerprint through its console and enroll it in known_hosts.
Allow outbound HTTPS to official GitHub release assets. Never use a production
host: this runner installs three persistent services and writes actual metrics/data.

```bash
zig build -Doptimize=ReleaseSafe
VM_HOST="disposable-ubuntu.example.com"
VM_USER="root"
export VM_HOST VM_USER
tests/integration/victoriatraces.sh
```

Expected: install and `monitoring verify` succeed for VictoriaMetrics v1.151.0,
VictoriaLogs v1.52.0, and VictoriaTraces v0.11.0. The runner requires all three
services to be active and persistently enabled, with one loopback listener each at
`127.0.0.1:8428`, `127.0.0.1:9428`, and `127.0.0.1:10428`. It checks HTTP health,
exact writable-storage metrics for the logs/traces data paths, the managed/running
`100y` and native `75` flags, the disabled extra traces gRPC listener flag, and
VictoriaMetrics' `90d` retention. CLI verification additionally checks pinned
running/disk binaries, managed and loaded units, effective hardening, metadata,
current links, and PID ownership of listeners. No synthetic log or trace is injected.

The deliberate second install must report `No changes required.` with identical
MainPID and ExecMainStartTimestampMonotonic for **all three** services. Verification
also must preserve all three process identities. The runner then appends a harmless
comment to the managed VictoriaTraces unit and reruns install. Only VictoriaTraces
may restart; another install must be a no-op. Finally it creates a root-owned
VictoriaTraces restart marker to model persisted intent after interruption, reruns
install, and requires another VictoriaTraces-only recovery followed by a no-op.
This models recovery state; it does not kill an installer at an actual failure
boundary or prove every interruption scenario. No storage files are manually deleted.

The reported metrics reserve must equal one fifth of filesystem capacity rounded
up. Inspect capacity with
`stat -f -c '%b %S' /var/lib/dragontools/victoriametrics` and multiply blocks by block
size. In both pinned logs/traces releases, the native 75% flag compares each
backend's own partition bytes against total filesystem capacity. Other writers
are excluded. Cleanup is periodic and preserves the newest two daily partitions,
which can span more than two calendar days. Independent budgets do not enforce a
combined usage ceiling. This runner checks configuration and writable-state
signals; it does not prove long-duration partition cleanup or capacity planning.

The runner uses default SSH agent/identities on port 22; adapt all invocations
together for different authentication. It supports root or noninteractive `sudo -n`,
uses strict host-key checks, and suppresses raw remote stderr. `TOOL` may point to
another already-built binary. On failure, inspect the named service through a
trusted console or SSH session and rerun. A managed test comment or restart marker
may remain until installation recovers. Destroy the VM through your provider after
testing; DragonTools has no uninstall or provisioning command.

The earlier `victoriametrics.sh` and `victorialogs.sh` runners remain available as
narrower checks. Their current `monitoring install` commands also install all three
components. Use `victoriatraces.sh` for three-component process stability and
VictoriaTraces-isolated repair; the logs runner still covers logs-isolated repair.

Before accepting a release, also exercise:

- Unknown SSH key and missing prerequisites fail before mutation.
- Unsupported Ubuntu or non-systemd targets fail before account creation.
- Conflicting accounts/unmanaged units and unexpected symlinks fail safely.
- Wrong checksums, interrupted downloads, and unavailable HTTPS do not activate
  an unverified binary.
- Each component's unit or binary repair restarts only that component. Metadata-only
  repairs and an unchanged rerun do not restart any healthy service.
- Stop or disable each service independently; reinstall starts/enables it without
  rewriting matching resources or restarting other healthy services.
- Interrupt before/after binary or unit replacement and before/after activation;
  retries preserve restart intent until successful verification.
- A failed health check retains its marker, and read-only `monitoring verify` never
  mutates files, reloads systemd, changes services, or clears restart markers.
- Binary-only repair does not itself require `daemon-reload` when loaded unit state
  is already current; changed or stale loaded unit
  state triggers reload only as needed.
- Target ports 8428, 9428, and 10428 cannot be reached externally. The additional
  traces gRPC listener is disabled; no public OTLP path exists.
- Inspect root/service ownership, `systemd-analyze security`, journal errors, and
  query persistence across restart; review unexpected drop-ins/overrides.
- On dedicated disposable volumes, verify the metrics low-space ingestion stop,
  native logs/traces oldest-partition cleanup, newest-two-partition exception,
  periodic overshoot, and read-only-state verification failure. Test shared-writer
  pressure separately; do not infer it is controlled by each backend's budget.
  Never fill a production root filesystem.

Record OS, architecture, component versions, commands and results without
credentials. Integration is opt-in and is never silently counted as a passing
unit test. **Disposable-host integration not run.** The new traces runner has only
local syntax checks until a real supported target is supplied; fake-remote and
renderer tests do not establish runtime/production compatibility.
