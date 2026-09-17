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

On a fresh disposable account initially using bash, exercise the explicit options
with the same alias and target account on every invocation:

```bash
./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host "$TEST_ALIAS" \
  --set-default-shell --update-managed-zshrc

# Read-only verification of the actual account and generated prompt:
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" 'set -eu
record=$(getent passwd "$(id -u)")
target_home=$(printf "%s\n" "$record" | cut -d: -f6)
target_shell=$(printf "%s\n" "$record" | cut -d: -f7)
test "$target_shell" = "$(command -v zsh)"
grep -Fx -- "$target_shell" /etc/shells
grep -Fx "# DragonTools managed .zshrc v2" "$target_home/.zshrc"
grep -F "%n@%m %~ %#" "$target_home/.zshrc"'

./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host "$TEST_ALIAS" \
  --set-default-shell --update-managed-zshrc

# Reconnect to see the new login shell and prompt; exit afterward.
ssh -o StrictHostKeyChecking=yes "$TEST_ALIAS"
```

Expected: the first opt-in run changes bash to the discovered listed zsh shell;
the second reports `No changes required.` without invoking `chsh`. Verify this
with account records and suitable test-host audit evidence, not only CLI text.
New configurations display a user/hostname/directory prompt and retain Oh My Zsh
and the git plugin. Check the actual remote hostname against the prompt even when
it differs from the SSH alias: root uses `#`, ordinary users `%`. The configuration
contains no hardcoded hostname. These are expected results until actually exercised
on a host.

Also exercise these cases on disposable accounts/hosts only:

- A native alias with a non-root user, non-default port, quoted IdentityAgent path
  containing spaces, and a jump host resolves through OpenSSH. Unknown keys fail.
- A pre-existing regular `.zshrc` with distinct contents is byte-for-byte unchanged,
  even when it does not load Oh My Zsh. An existing recognizable Oh My Zsh checkout
  keeps local changes and its branch unchanged.
- `--target-user` uses an existing account's real home, including a nonstandard
  home path, and does not change its login shell without `--set-default-shell`;
  a missing user fails.
- A zsh path absent from `/etc/shells` is rejected before a shell change. An already
  matching shell never calls `chsh`, including after an interrupted prior change.
- Subsequent SSH commands work with the selected account shell and silent
  noninteractive startup files. Test a startup-induced verification failure only
  on a disposable account with independent console access: the shell change may
  already be committed. After repairing startup, rerunning must inspect the account
  and skip `chsh` if its shell is already correct.
- The exact unmarked DragonTools v0 and marked v1 `.zshrc` remain unchanged on
  ordinary reruns and migrate only with `--update-managed-zshrc`. A current v2
  rerun does not rewrite the file. Compare bytes, UID, GID and mode before/after
  both operations, including an allowed non-primary file group. A migration that
  cannot preserve the original group must refuse publication.
- Foreign `.zshrc` files and marked templates with local edits remain byte-for-byte
  unchanged even with `--update-managed-zshrc`. Do not run an editor concurrently
  with migration. Adoption requires manually backing up and moving the file to an
  unused path before rerunning; there is no force/adopt flag for foreign content.
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
sudo apt-get install -y openssh-server curl ca-certificates tar coreutils util-linux iproute2 passwd grep python3
```

Verify the VM SSH fingerprint through its console and enroll it in known_hosts.
Allow outbound HTTPS to official GitHub release assets, `dl.grafana.com`, and
`grafana.com` for the pinned plugin catalog artifact. Never
use a production host: the monitoring installer now installs four persistent
services and writes actual metrics/data. The older Victoria runners below retain
their backend-specific checks; use the Grafana checklist too for the fourth component.

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
narrower checks. Their current `monitoring install` commands install all four
components, but these earlier runners do not inspect Grafana process stability. Use `victoriatraces.sh` for three-component process stability and
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
- Target ports 8428, 9428, 10428, and 3000 cannot be reached externally. The additional
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


## Grafana fourth-component checklist

Run on each supported Ubuntu/architecture disposable-host combination above. The
replaceable alias `monitoring-test` must use the same SSH authentication throughout;
verify its host key first. Ensure no other process occupies target loopback port
3000. Public inbound stays TCP 22 from the administrator IP only. Do not add a
Hetzner/provider port-3000 rule, public HTTP/HTTPS rule, or Cloudflare change.

```bash
zig build -Doptimize=ReleaseSafe
TEST_ALIAS="monitoring-test"
./zig-out/bin/dragontool monitoring install --ssh-host "$TEST_ALIAS" --plan
./zig-out/bin/dragontool monitoring install --ssh-host "$TEST_ALIAS"
./zig-out/bin/dragontool monitoring verify --ssh-host "$TEST_ALIAS"
./zig-out/bin/dragontool monitoring status --ssh-host "$TEST_ALIAS"

# Read-only listener inspection. All four must bind only to their loopback addresses.
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" \
  'sudo -n ss -lntp'

# Record all four service identities around a deliberate unchanged install.
GRAFANA_CHECK_DIR=$(mktemp -d)
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" \
  'for name in victoriametrics victorialogs victoriatraces grafana; do
     systemctl show "dragontools-$name.service" --no-pager \
       --property=Id,ActiveState,UnitFileState,MainPID,ExecMainStartTimestampMonotonic
   done' > "$GRAFANA_CHECK_DIR/before"
./zig-out/bin/dragontool monitoring install --ssh-host "$TEST_ALIAS"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" \
  'for name in victoriametrics victorialogs victoriatraces grafana; do
     systemctl show "dragontools-$name.service" --no-pager \
       --property=Id,ActiveState,UnitFileState,MainPID,ExecMainStartTimestampMonotonic
   done' > "$GRAFANA_CHECK_DIR/after"
cmp "$GRAFANA_CHECK_DIR/before" "$GRAFANA_CHECK_DIR/after"

# Keep the tunnel session open while testing in a browser.
ssh -o StrictHostKeyChecking=yes -L 127.0.0.1:3000:127.0.0.1:3000 "$TEST_ALIAS"
```

If the alias logs in as root on an image without sudo, use `ss -lntp` directly in
that inspection command. Expected: all four active/persistently enabled, listener
addresses `127.0.0.1:8428`, `127.0.0.1:9428`, `127.0.0.1:10428`, and
`127.0.0.1:3000`, `No changes required.` on unchanged install, and no diff in the
four process identities. Also compare managed Grafana files' bytes, modes, owners
and modification times around the rerun, and inspect download evidence: no archive
request or provisioning rewrite should occur. `verify` must preserve the same
process identities and files.

Open `http://127.0.0.1:3000` locally. Without configured credential references, on a
fresh database sign in with the standard
initial `admin` / `admin` credentials and immediately change the password at the
prompt. Do not include it in test logs, CLI arguments or repository files. Confirm
that anonymous requests cannot browse datasources and authentication remains
required. Reinstall/verify after changing the password: both must work without the
CLI knowing it, and the new password must remain intact.

For managed credentials, use an explicit config based on
`examples/monitoring.toml` with disposable references and the same test alias.
Authenticate the local `op` CLI through its normal setup. Plan must neither resolve
references nor contact the host. Record only safe outcome categories, never
resolved values, provider output or secret-bearing commands.

```bash
./zig-out/bin/dragontool monitoring install --config monitoring-test.toml --plan
./zig-out/bin/dragontool monitoring install --config monitoring-test.toml
./zig-out/bin/dragontool monitoring verify --config monitoring-test.toml
./zig-out/bin/dragontool monitoring install --config monitoring-test.toml
```

Check fresh initialization with the desired login, then an existing manually
changed password reconciled from the configured references. Repeat with the
already-correct credentials and require `No changes required.`, no password reset,
no restart, and stable identities for all four services. Configured standalone
verify must authenticate read-only; mismatched credentials must fail without
reconciliation. Exercise failure/retry and confirm no secret files or retained plaintext
are created, without printing resolved contents. Ensure no plaintext value appears in unit,
ordinary config, process arguments or DragonTools output. Live 1Password access and
these remote behaviors are separate integration gates, not fixture-test claims.

In the authenticated UI:

1. Confirm the **Metrics** datasource is provisioned, default and not editable;
   run **Save & test**, then Explore `vm_app_version` and see stored data.
2. Confirm the **Traces** datasource uses Jaeger and the exact local
   `/select/jaeger` base path; run **Save & test** and Explore its services.
   An empty list is expected before application trace ingestion. Do not claim
   trace arrival solely from this response.
3. Confirm **Logs** uses `victoriametrics-logs-datasource` **0.32.0**, the fixed
   UID `dragontools-logs`, and `http://127.0.0.1:9428`. Require Grafana's plugin page
   to show a valid signature. Run **Save & test**, then Explore in Raw Logs mode
   with `*` over the last five minutes. A valid zero-row response is success;
   do not inject synthetic logs just for this test.
4. Confirm no default dashboards, agents, alerts or public listeners were added.

The automated verifier checks plugin integrity, read-only records for all three
datasources and direct backend queries under the Grafana UID. Configured references
also check administrator identity, signed plugin identity, Logs plugin health and a
read-only LogsQL query through Grafana. Confirm those checks work with the real
plugin and configured references. Without references, require the explicit
`Logs plugin query unchecked; configure administrator references to verify` message;
there must be no implicit default-password login or anonymous-access change.
The UI steps above and real Metrics/Traces requests through Grafana remain separate
integration evidence. Local fake-remote or renderer tests do not establish it.

On this disposable target only, test recovery and component isolation:

- On a pre-plugin DragonTools installation, rerun with the same configured
  references. Expect one pinned plugin download, Logs provisioning and one Grafana
  restart. Record all four PIDs/start times; VM/VL/VT must remain unchanged. Require
  configured verification and UI queries to succeed, then an unchanged no-op.
- Inspect the active plugin symlink, versioned content and per-file catalog. Require
  root ownership, executable/readable modes, intact `MANIFEST.txt`, and both plugin
  roots in effective `ReadOnlyPaths`. Confirm the `dt-grafana` service cannot alter
  its plugin code. Check that native plugin transport uses a private Unix socket,
  with no added TCP listener.
- Change one managed Grafana config/provisioning file, then reinstall. Only Grafana
  may restart; retain all VM/VL/VT PIDs/start times. Follow with an unchanged no-op.
- On a disposable fixture, corrupt one recognized plugin file and rerun. Require
  checksum-verified repair, atomic selection, retained prior content and only a
  Grafana restart. Unknown extra files/symlinks must fail safely. Test an explicitly
  reviewed future pin in the same way before accepting a plugin version update.
- Interrupt plugin download, extraction and publication. A bad checksum or unsafe
  ZIP must never replace the active working version. A failed health or Logs query
  after activation must preserve Grafana restart intent and prior recoverable plugin
  state. After correcting the cause, rerun, verify, then require a no-op. Confirm
  VictoriaLogs itself was neither restarted nor modified by these failures.
- Exercise Grafana unit drift and recognized binary/tree corruption independently.
  Each repair restarts only Grafana; unknown extra paths and symlinks must refuse
  safely instead of destroying administrator data. Confirm upstream package paths
  such as `/etc/grafana` remain untouched.
- Stop Grafana, then reinstall; it starts. Disable it, then reinstall; persistent
  enablement is restored without disturbing the three healthy backends.
- Interrupt during private archive staging and around atomic publication/activation.
  Rerun from the actual state, retaining the Grafana restart marker until its
  verification succeeds. Never delete arbitrary staging paths to make a test pass.
- Cause a Grafana health/provisioning verification failure without modifying backend
  state; confirm VM/VL/VT remain healthy and the Grafana marker survives. Correct the
  cause, reinstall, verify the marker clears, then require a no-op rerun.
- Inspect `systemd-analyze security dragontools-grafana.service`, unit effective
  properties, and journal output. Exercise SQLite persistence across restart.
  Recheck loopback-only binding and no added public listener/firewall rule.

Record exact OS, architecture, Grafana build, plugin version and checksum provenance, commands,
service identities, authenticated UI checks and outcomes without credentials.
Destroy the disposable host after testing. **Disposable-host integration not run.**


To reproduce the reviewed Grafana archive audit without installing or executing it,
download the exact official versioned artifact documented in `design.md`, then run:

```bash
python3 -I -B tests/integration/grafana_archive.py /tmp/dragontools-grafana-13.2.2-amd64.tar.gz amd64
python3 -I -B tests/integration/grafana_archive.py /tmp/dragontools-grafana-13.2.2-arm64.tar.gz arm64
```

Replace each path with the corresponding already-downloaded archive. The audit
checks committed archive, server-binary and full catalog pins, regular-file/directory
counts and safe archive paths. It does not extract or execute the release and is
separate from the systemd/UI integration gate. Each no-op installation also hashes
the full live release tree; expect read I/O even though no resources are rewritten.


Review the pinned plugin ZIP without extracting or executing it:

```bash
python3 -I -B tests/integration/grafana_victorialogs_archive.py /tmp/dragontools-vl-plugin-0.32.0.zip
```

Use the already-downloaded official artifact and replace its local path as needed.
The helper verifies the committed archive SHA-256, full catalog, safe ZIP entries
and signed manifest's file hashes. This helper does not independently verify PGP;
Grafana verifies the preserved signature at runtime. A separate local GPG review
of this exact ZIP passed against the embedded public key from pinned Grafana 13.2.2,
fingerprint `F33B25B691074E84636570F37E4D0C6A708866E7`. That review used an isolated
temporary public keyring, disabled network key retrieval and executed no plugin
code. Exact artifact URL, digest and upstream key/source links are in
[the plugin design](../../design.md#official-victorialogs-datasource-plugin).
None of these archive checks is a systemd, Grafana plugin-loading or UI test.
