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
use a production host: the monitoring installer now installs ten persistent
services and writes actual metrics/data. Configured live alert rules may deliver
real notifications. The older Victoria runners below retain only their
backend-specific checks; use the full station checklist and Grafana checks too.

```bash
zig build -Doptimize=ReleaseSafe
VM_HOST="disposable-ubuntu.example.com"
VM_USER="root"
INGRESS_HOSTNAME="monitoring-test.example.com"
export VM_HOST VM_USER INGRESS_HOSTNAME
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
narrower checks. Their current `monitoring install` commands install all ten
services, but these earlier runners do not inspect the other seven process
identities. Use `victoriatraces.sh` for three-component process stability and
VictoriaTraces-isolated repair; the logs runner still covers logs-isolated repair.

Before accepting a release, also exercise:

- Unknown SSH key and missing prerequisites fail before mutation.
- Unsupported Ubuntu or non-systemd targets fail before account creation.
- Conflicting accounts/unmanaged units and unexpected symlinks fail safely.
- Wrong checksums, interrupted downloads, and unavailable HTTPS do not activate
  an unverified binary.
- Each component's unit repair restarts only that component. Binary repair has the
  same isolation, except that both vmalert instances share one pinned binary and
  therefore both preserve restart intent when that binary changes. Metadata-only
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
- Target ports 8428, 9428, 10428, 3000, 9115, 9093, 8880 and 8881 cannot be reached
  externally. The additional traces gRPC and Alertmanager cluster listeners are
  disabled; no public OTLP path exists.
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


## Eight-service probe and alert checklist

Use each supported disposable Ubuntu/architecture combination above. Replace
`monitoring-test` with a verified native SSH alias and use that alias consistently.
Provide an HTTP/HTTPS endpoint you control; the example below is not a live test
target. No Telegram references are needed for the basic station test.

```bash
zig build -Doptimize=ReleaseSafe
cat > /tmp/dragontools-monitoring-integration.toml <<'TOML'
version = 1
[connection]
ssh_host = "monitoring-test"
[ingress]
hostname = "monitoring-test.example.com"
[[probe]]
name = "controlled-health"
url = "https://service.example.com/healthz"
TOML
# Replace the alias and URL in the file before continuing.
./zig-out/bin/dragontool monitoring install --config /tmp/dragontools-monitoring-integration.toml --plan
./zig-out/bin/dragontool monitoring install --config /tmp/dragontools-monitoring-integration.toml
./zig-out/bin/dragontool monitoring verify --config /tmp/dragontools-monitoring-integration.toml
./zig-out/bin/dragontool monitoring status --config /tmp/dragontools-monitoring-integration.toml

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monitoring-test 'set -eu
for component in victoriametrics victorialogs victoriatraces grafana blackbox-exporter alertmanager vmalert-logs vmalert-metrics ingress-auth caddy; do
  systemctl show "dragontools-$component.service" -p MainPID -p ExecMainStartTimestampMonotonic -p User -p Group -p ActiveState -p UnitFileState
done'

# Deliberate unchanged rerun, then repeat the same process-identity inspection:
./zig-out/bin/dragontool monitoring install --config /tmp/dragontools-monitoring-integration.toml
```

Expected: all ten services verify, failed target availability is still valid
telemetry, and the unchanged install prints `No changes required.`. Compare all
ten PIDs/start times, managed file bytes/metadata and download/reload activity.
The controller's status check queries stored samples; it must not request a fresh
probe. Grafana reports its authenticated Logs query unchecked when its references
are absent. None of these expected outcomes has been observed on a supported host
for this slice yet.

- Require loopback-only listeners at VM 8428, VL 9428, VT 10428, Grafana 3000,
  blackbox 9115, Alertmanager 9093, logs evaluator 8880 and metrics evaluator 8881.
  Inspect both TCP and UDP; Alertmanager clustering must add neither. Check all
  effective account, root-owned binary/config, capability, address-family and
  filesystem hardening properties. Blackbox and both vmalert services must have
  no persistent writable namespace path; Alertmanager writes only its data path.
- Check blackbox's exact loaded `/config`, `/-/healthy`, build and successful
  reload metrics. The rendered normalized-config fixture follows pinned source
  but has not been compared with a running upstream exporter. Exercise HTTPS with
  a valid chain, invalid chain, redirects, IPv4 preference and an IPv6-only DNS
  answer on controlled endpoints. Confirm HTTP/2 remains disabled and probes time
  out within the configured module/scrape limits, without executing a curl process
  per target on the controller.
- Require VictoriaMetrics' loaded native scraper config/targets to match the
  named probe list and each configured target to produce recent stored
  `probe_success` and duration samples. Check the allowlisted metric names/labels,
  including `probe`, `target` and `instance`. Do not interpret a down target as
  failed station verification. The separate VictoriaMetrics self-scrape still
  needs time to expose `vm_app_version`.
  Compare the real `/api/v1/status/config` YAML with the source-derived pinned
  serialization fixture too; renderer tests alone do not establish that runtime
  representation. Exercise a stale loaded metric-relabel policy with identical
  targets and desired restored disk bytes: reinstall must reload the desired
  policy, then verify it before clearing intent. At the 64-probe limit, replace
  one identity and ensure historical samples inside the 90-second window do not
  invalidate current readiness or status.
- Add, remove and edit a controlled probe. Require only scraper config publication
  and native reload, retaining all ten service identities. The first upgrade
  from the prior station slice adds VM's scrape flag and legitimately restarts
  VM once. After any successful verification, require cleared scrape reload intent
  and another no-op; verify alone must never reload or clear that marker.
- Validate both fixed rule files with the pinned vmalert dry-run path and check
  loaded group/rule names, types, queries, labels, annotations, timing and health.
  Confirm metrics reads VM, logs reads VL, both notify local Alertmanager and both
  use local VM remote read/write for state. With a controlled failed endpoint,
  observe the critical `ServiceProbeFailed` alert only after its two-minute hold.
  Restore that endpoint and observe resolution. This explicit test can cause live
  notifications when Telegram is configured; it is not run automatically.
  After configuring a controlled unavailable endpoint yourself and successfully
  running `monitoring verify`, the optional observer reads stored samples and
  the existing evaluator alert with a bounded 210-second deadline:

  ```bash
  python3 -I -B tests/integration/run_blackbox.py --ssh-host monitoring-test --probe controlled-down
  ```

  Replace the alias and probe name. The script sends only read-only requests to
  local VM and vmalert APIs over strict SSH; it never contacts a target, edits
  configuration or sends a notification. Existing evaluator activity can still
  notify independently. Expected output begins `PASS: fresh failed probe telemetry
  and an existing firing alert with a two-minute hold`. Its local fixture tests
  are separate from running it on a real host; the host invocation remains unrun.
- Cause temporary startup absence and delayed self-observation. Require bounded
  readiness retries and successful finalization; fixed binary/unit/account/argv
  or public-listener mismatches must fail immediately without retrying. Timeout
  must retain the relevant intent marker. Correct the cause and require recovery,
  marker clearing only after success, then a no-op. Include interrupted rule/config
  staging and shared vmalert binary replacement, which must retain both evaluators'
  independent restart intent. Do not delete arbitrary staging files.
- For optional Telegram, add only the two SecretRefs documented in README to the
  local test config. Install through protected stdin; inspect metadata only, never
  print secret files. Require token/chat files owned by `dt-alertmanager` at 0400
  and restricted directory access. Equal credentials must not rewrite files or
  restart services. Test interrupted protected publication and recovery, secret
  replacement and removal of configured references without disclosing values.
  With local `op` deliberately unavailable, verify/status must still inspect the
  installed Telegram policy; omit Grafana references for this particular resolver
  test because authenticated Grafana verification resolves its own references.
- Require Alertmanager's effective `StandardOutput=null` and
  `StandardError=null`; the pinned notifier can expose a token-bearing request URL
  in native errors. Expect no native Alertmanager journal diagnostics. Use systemd
  state, readiness/API/metrics and fixed DragonTools errors. Confirm verification
  sends no synthetic alert. Only explicitly run the following command when the
  configured test chat is intended to receive a notification:

  ```bash
  ./zig-out/bin/dragontool monitoring notify-test --config /tmp/dragontools-monitoring-integration.toml
  ```

  Record Alertmanager acceptance separately from actual human receipt, grouping,
  deduplication, resolved notification and unauthorized bot/chat failures. Neither
  renderer tests nor successful API acceptance proves Telegram delivery.

Record exact pins and checksum provenance from
[the design](../../design.md#external-probing-and-alert-runtime), supported OS and
architecture, all ten identities and outcomes. Never include resolved secrets
or secret-bearing native errors in the evidence. **Disposable-host integration
not run.**

The local archive auditor checks already-downloaded official artifacts without
extracting or executing them:

```bash
python3 -I -B tests/integration/blackbox_archive.py /tmp/dragontools-blackbox-0.28.0-linux-amd64.tar.gz amd64
python3 -I -B tests/integration/blackbox_archive.py /tmp/dragontools-blackbox-0.28.0-linux-arm64.tar.gz arm64
python3 -I -B tests/integration/alertmanager_archive.py /tmp/dragontools-alerting-am-amd64-v0.34.1.tar.gz amd64
python3 -I -B tests/integration/alertmanager_archive.py /tmp/dragontools-alerting-am-arm64-v0.34.1.tar.gz arm64
python3 -I -B tests/integration/vmalert_archive.py /tmp/dragontools-alerting-vmutils-amd64-v1.152.0.tar.gz amd64
python3 -I -B tests/integration/vmalert_archive.py /tmp/dragontools-alerting-vmutils-arm64-v1.152.0.tar.gz arm64
```

Replace paths with the corresponding local archives. The blackbox auditor checks
committed archive and executable SHA-256 values, the exact five-member catalog,
types and modes. The Alertmanager auditor checks its six-entry archive and both
server/amtool binaries; the vmutils auditor checks its seven regular files and
the selected vmalert binary. All six architecture/artifact audits passed without
executing downloaded code; they do not validate systemd, HTTP requests, rule timing
or notifications.

Run the observer's local input/state fixtures without SSH:

```bash
python3 -I -B tests/blackbox_observe_test.py
```

The normal Zig test suite also runs these fixtures on both Linux and macOS.

## Grafana component checklist

Run on each supported Ubuntu/architecture disposable-host combination above. The
replaceable alias `monitoring-test` must use the same SSH authentication throughout;
verify its host key first. Ensure no other process occupies target loopback port
3000. Permit TCP 22 from the administrator IP and TCP 9443/9444 from monitored hosts. Do not add a
Hetzner/provider port-3000 rule, public HTTP/HTTPS rule, or Cloudflare change.

```bash
zig build -Doptimize=ReleaseSafe
TEST_ALIAS="monitoring-test"
./zig-out/bin/dragontool monitoring install --ssh-host "$TEST_ALIAS" --ingress-hostname monitoring-test.example.com --plan
./zig-out/bin/dragontool monitoring install --ssh-host "$TEST_ALIAS" --ingress-hostname monitoring-test.example.com
./zig-out/bin/dragontool monitoring verify --ssh-host "$TEST_ALIAS"
./zig-out/bin/dragontool monitoring status --ssh-host "$TEST_ALIAS"

# Read-only listener inspection. Eight backend/admin services bind only to loopback; Caddy owns IPv4 9443/9444; authorization uses Unix sockets.
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" \
  'sudo -n ss -lntp'

# Record all ten service identities around a deliberate unchanged install.
GRAFANA_CHECK_DIR=$(mktemp -d)
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" \
  'for name in victoriametrics victorialogs victoriatraces grafana blackbox-exporter alertmanager vmalert-logs vmalert-metrics ingress-auth caddy; do
     systemctl show "dragontools-$name.service" --no-pager \
       --property=Id,ActiveState,UnitFileState,MainPID,ExecMainStartTimestampMonotonic
   done' > "$GRAFANA_CHECK_DIR/before"
./zig-out/bin/dragontool monitoring install --ssh-host "$TEST_ALIAS" --ingress-hostname monitoring-test.example.com
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TEST_ALIAS" \
  'for name in victoriametrics victorialogs victoriatraces grafana blackbox-exporter alertmanager vmalert-logs vmalert-metrics ingress-auth caddy; do
     systemctl show "dragontools-$name.service" --no-pager \
       --property=Id,ActiveState,UnitFileState,MainPID,ExecMainStartTimestampMonotonic
   done' > "$GRAFANA_CHECK_DIR/after"
cmp "$GRAFANA_CHECK_DIR/before" "$GRAFANA_CHECK_DIR/after"

# Keep the tunnel session open while testing in a browser.
ssh -o StrictHostKeyChecking=yes -L 127.0.0.1:3000:127.0.0.1:3000 "$TEST_ALIAS"
```

If the alias logs in as root on an image without sudo, use `ss -lntp` directly in
that inspection command. Expected: all ten active/persistently enabled, loopback
ports 8428, 9428, 10428, 3000, 9115, 9093, 8880 and 8881, Caddy on IPv4
9443/9444, and private authorization on Unix sockets,
`No changes required.` on unchanged install, and no diff in the ten
process identities. Also compare managed Grafana files' bytes, modes, owners
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
no restart, and stable identities for all ten services. Configured standalone
verify must authenticate read-only; mismatched credentials must fail without
reconciliation. Exercise failure/retry and confirm no Grafana secret files or retained
administrator plaintext are created, without printing resolved contents. Ensure no plaintext value appears in unit,
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
  restart. Record all ten PIDs/start times; the other services must remain unchanged. Require
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

## Application contract: two-host gate

The [application monitoring.toml procedure](application.md) covers plan/apply,
trusted signals, probes and alert firing/resolution, multi-repo ownership,
unchanged reruns and interruption recovery. **Disposable-host integration not run.**
Local and isolated-process evidence must not be reported as that deployment gate.

## Monitored-host logs/metrics: two-host Ubuntu gate

**Disposable-host integration not run.** The isolated Linux Vector metric fixture
and local Python/mTLS or fake-remote tests are narrower checks. They do not prove
systemd hardening, complete two-host forwarding, outage recovery or alert delivery.
Run this gate only on disposable Ubuntu 24.04/26.04 systemd hosts, covering
amd64/arm64 where available. Keep operator access and a recovery console.

Prepare an existing DragonTools station and an application host, with verified
OpenSSH aliases `replace-me-monitoring` and `replace-me-application`, root or
noninteractive sudo, normal prerequisites plus Python 3 for private authorization/non-PKI checks, and a routable
DNS/IPv4 station HostName. Allow TCP 9443 metrics and 9444 logs only from monitored hosts in the
operator-managed firewall. Raw VM/VL/VT/Grafana/Alertmanager remain private. Prepare
an `app.service` that emits ordinary structured journal entries and a small
Prometheus endpoint at `127.0.0.1:16000/metrics` containing a real application
metric; use `worker.service` as a quiet stream. Do not generate an application
error merely to make verification pass. Keep both hosts' clocks synchronized.
Use canonical unit names with empty `LogNamespace`; alias/mismatched IDs or
namespaced units must fail before any station registration.

```bash
zig build
./zig-out/bin/dragontool monitoring agents install \
  --ssh-host replace-me-application --station replace-me-monitoring \
  --service app.service --service worker.service \
  --metrics-target app=http://127.0.0.1:16000/metrics
./zig-out/bin/dragontool monitoring agents verify \
  --ssh-host replace-me-application --station replace-me-monitoring
./zig-out/bin/dragontool monitoring agents status \
  --ssh-host replace-me-application --station replace-me-monitoring
```

Expected status includes Vector `active`, `enabled`, `log forwarding healthy
(recent stream identity)`, `host metrics flowing`; configured vmagent reports
`active`, `enabled`, `configured targets: 1` and `remote write healthy (fresh scrape telemetry; target may be down)`. Treat these as expected outputs until observed.

1. Query stored station metrics/logs for the machine-ID-derived `dt-<32 hex>`
   host. Inspect the actual CPU/memory/filesystem/inode metric names against
   `src/monitoring/agents/metric_contract.zig`. Confirm app samples carry trusted
   `host`, `app` and `agent` labels. Confirm every selected service arrives and an
   unselected service does not. Application JSON must not redefine host/service.
2. Quiet `worker.service` should have only distinct info-level
   `type=dragontools_stream` metadata every 30 seconds unless it emits logs itself.
   Verify no fake application error, journal test write, notification or target
   probe was generated by install/verify/status.
3. Inspect listeners and effective service properties: Vector API disabled,
   telemetry `127.0.0.1:8686`; vmagent `127.0.0.1:8429`; station ingestion
   `0.0.0.0:9443` (metrics) and `0.0.0.0:9444` (logs) owned by Caddy with registered-client mTLS. Confirm 9445 is closed; the private auth service has only protected Unix sockets. No new administrative/public raw
   backend listener is acceptable. Test missing/unregistered certificates,
   wrong methods/routes, oversized requests and attempts to select backend URLs;
   they must fail without exposing request contents in service logs.
4. Inspect metadata, not private-key contents: dedicated accounts, service-owned
   mode-0400 client bundles, root-private CA issuance state, protected registration,
   safe symlinks, expected binary digests and hardened effective units. Full stderr
   and executable commands must not appear in DragonTools failure reports.
5. Confirm effective journald limits are at most min(1 GiB, 5% `/var/log` capacity),
   min(256 MiB, 2% `/run` capacity), and seven days. Repeat with stricter existing
   administrator settings; unrelated drop-ins/main configuration must remain
   byte-identical. A later conflicting override must be refused. No journal
   vacuuming or management of direct application file logs is expected.
6. Record all relevant service PIDs, start timestamps, certificate hashes and
   registration bytes. Deliberately repeat the exact install command above.
   Expect `No changes required.` with identical agent PIDs, credentials and
   registration, and no extra installer-triggered metadata event.
7. Change only selected services, then only one metrics target. Confirm respectively
   Vector-only and vmagent-only restart, with Caddy/private authorization and unrelated
   station services stable. Change a target URL while retaining its name and leave
   old samples in VM: verification must require samples after the new process
   start and fail until the new endpoint emits data. Reordering identical
   selections is unchanged. Omit all
   targets on a new host: vmagent must not be installed. On an existing managed
   host, removing all targets must stop/disable vmagent while retaining data/files.
8. On these disposable hosts only, stop ingestion temporarily while continuously
   producing bounded normal log/metric traffic:

   ```bash
   ssh replace-me-monitoring sudo -n systemctl stop dragontools-caddy.service
   # Observe bounded queues and failed verification; do not dump private data.
   ./zig-out/bin/dragontool monitoring agents verify \
     --ssh-host replace-me-application --station replace-me-monitoring
   ssh replace-me-monitoring sudo -n systemctl start dragontools-caddy.service
   ```

   Restore ingestion promptly even if a check fails. Confirm Vector disk buffering
   and backpressure, vmagent's 1 GiB queue limit/drop policy, preserved processes,
   resumed delivery, and fresh signal verification. A 45-second signal timeout
   must fail installation and retain pending restart intent. Record a bounded
   extended-outage test separately; journal expiry and queue drops may lose data.
9. Interrupt separately after Vector and vmagent configuration publication. Rerun
   and verify that only the component with retained intent restarts/finalizes.
   A Vector failure must not damage vmagent; a vmagent failure must leave verified
   Vector forwarding intact. Registration made before failure may safely remain.
10. Inspect metrics-evaluator loaded rules: exactly the fixed host-pressure pack
    uses the observed Vector contract and existing policy durations/thresholds.
    No HostDown, ServiceDown, ServiceRestartLoop or tracing collector is introduced.
    Observe actual rule evaluation and notification separately; renderer validation
    alone is insufficient. Finish with verify and an unchanged install rerun.

Retain sanitized evidence for both hosts/architectures, test timestamps, versions,
service properties, listener bounds, queue recovery, verification result and
unchanged rerun. Do not retain CA/client private data or log/metric payload secrets.

### Agent artifact and isolated process review

Four archive audits were run for the pinned Vector 0.58.0 / vmagent v1.152.0
artifacts. To repeat against the already-downloaded official archives (replace
local paths when necessary):

```bash
python3 -I -B tests/integration/vector_archive.py /tmp/dragontools-vector-amd64-0.58.0.tar.gz amd64
python3 -I -B tests/integration/vector_archive.py /tmp/dragontools-vector-arm64-0.58.0.tar.gz arm64
python3 -I -B tests/integration/vmagent_archive.py /tmp/dragontools-alerting-vmutils-amd64-v1.152.0.tar.gz amd64
python3 -I -B tests/integration/vmagent_archive.py /tmp/dragontools-alerting-vmutils-arm64-v1.152.0.tar.gz arm64
```

Archive digests were reviewed against official release API metadata, plus Vector's
SHA256SUMS; extracted-binary digests were calculated from verified archives. See
[the pin table](../../design.md#pins-and-observed-host-metric-contract). The audits
verify archives without starting services and are distinct from runtime validation.

Vector's actual host source and Prometheus output were observed in an isolated
Linux/aarch64 process fixture on 2026-09-17. The reviewed binary ran as uid 65534
inside an already-cached local Linux container, with networking disabled, read-only
root, all capabilities dropped, no-new-privileges, bounded memory/PIDs and a small
writable `/tmp`. Generated Vector configuration passed native validation; a native
transform fixture rejected forged application host/service identity. Generated
vmagent scraping configuration and the combined six-rule metrics document passed
upstream dry-run validation. These checks do not exercise systemd, real journald
collection, mTLS delivery, two-host signals or outage recovery.

The captured contract is committed at
`src/monitoring/agents/vector_metrics_fixture.prom`. The optional native Linux
process helper can repeat the host source capture with checksum-pinned local
binaries; it is not part of ordinary Zig CI:

```bash
python3 -I -B tests/integration/agent_runtime.py \
  --vector /path/to/verified/vector \
  --vmagent /path/to/verified/vmagent-prod
```

Add `--vector-config` / `--vmagent-config` only for explicit non-secret fixture
configuration paths when testing native syntax. The helper passed in the same
isolated Linux setup with official Python image manifest
`sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea`,
the repository and fixture directory mounted read-only, and the command:

```bash
python3 -I -B /repo/tests/integration/agent_runtime.py \
  --vector /fixture/vector --vmagent /fixture/vmagent \
  --vector-config /fixture/full.yaml --vmagent-config /fixture/prometheus.yml
```

This remains a process/metric fixture, not the unrun disposable-host gate above.
Native validation warns that host/internal/demo sources do not support end-to-end
acknowledgements; journald does. Bounded disk buffers still apply, but do not
promise lossless host telemetry from the source.

### Isolated native mTLS pipeline evidence

A separate real-process fixture passed all five checks in
`tests/integration/agent_ingestion_pipeline.py` using pinned Linux/arm64 binaries:
VictoriaMetrics v1.151.0, VictoriaLogs v1.52.0, Vector 0.58.0 and vmagent v1.152.0.
The runner checks their committed binary hashes before executing. It established:

- VictoriaMetrics replaces a forged remote-write host label with the authenticated
  host identity supplied by the ingestion route.
- Actual Vector host metrics arrive through mTLS into VictoriaMetrics.
- Every selected service's distinct metadata stream arrives through mTLS into
  actual VictoriaLogs.
- Actual vmagent scrapes an explicit fixture endpoint and its application samples
  arrive with the trusted host despite a spoofed input label.
- Production station signal queries accept host/log/app samples since process
  start and reject a future cutoff, validating the actual MetricsQL timestamp
  conjunction and newest-first LogsQL query against the pinned backends.

The run used official Python 3.12-slim image manifest
`sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea`
(local image ID `4f8d1afed6d5`), with no external network, read-only mounts/root,
dropped capabilities and bounded temporary memory. The exact execution was:

```bash
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 \
  --tmpfs /tmp:rw,size=1g --memory 1g \
  --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
  --mount type=bind,src=/tmp/dragontools-ingestion-fixture,dst=/fixture,readonly \
  4f8d1afed6d5 python3 -I -B /repo/tests/integration/agent_ingestion_pipeline.py /fixture
```

These local paths/image ID record the actual test, not a portable setup command.
The fixture directory held reviewed checksum-matching binaries, generated fixture
configuration and local test credentials prepared by the runner's
`--prepare-credentials` mode. The journald source was replaced by closed stdin
because the container has no systemd; generated remapping, host/internal metrics,
metadata, mTLS and disk buffers remained active. This is evidence for the native
ingestion/data contracts, **not** SSH, systemd hardening, full installer reruns,
real journal collection or extended outage/buffer recovery. The disposable-host
gate remains unrun.


## Native PKI and maintenance fixture gate

See [the dated native validation record](native-pki-validation.md) for exact local
commands, results, emulation details and the remaining deployment/CI limits.

Run `zig build test --summary all`: native `src/pki/tests.zig` and
`src/agent_tests.zig` replace the retired Python/OpenSSL PKI implementation tests.
They cover strict profile/signature parsing, historical OpenSSL bundle no-op,
station/client locality, empty bootstrap/registry migration, renewal, legacy
migration, retained rollback/disabled consumers, expired leases and interrupted
publication/finalization/cleanup. `zig build test-fixture` builds a test-only
certificate factory and TLS probe, excluded from release artifacts.
`python3 -I -B tests/agent_ingestion_test.py` exercises the private Unix-socket
helper with a test-only TLS terminator. For the actual pinned Caddy configuration,
run the same fixture as Linux/macOS CI:

```bash
python3 -I -B tools/fetch_caddy_fixture.py --output /tmp/dragontools-caddy-2.11.4
python3 -I -B tests/agent_ingestion_test.py --caddy /tmp/dragontools-caddy-2.11.4
```

Both variants use native-created certificates and the native TLS client. Set
`DRAGONTOOLS_PKI_FIXTURE` to a target-native test helper in isolated Linux runs.
No OpenSSL CLI generates or validates these test credentials.

`tests/helper_install_test.py --fixture PATH --agent PATH` executes the actual
helper installation scripts under a private temporary replacement for `/opt` on
Linux. The temporary filesystem must allow executable files. It checks fresh
upload, exact no-op, interrupted/bad upload, version switch, retained prior
release and conflicting metadata/symlinks. No real `/opt` path is changed.
`tests/integration/maintenance_metrics.py` takes `--vector`, `--fixture`, `--agent`
and `--config` (from `render_agent_apps.py`). It validates actual production
configuration, executes the native fixture through the exact Vector source and
metric transforms, and captures trusted labels without a network sink. Pinned
Vector 0.58.0 names/values are recorded in `maintenance_fixture.prom`.
These Linux process/filesystem and local TLS checks are not disposable-host
SSH/systemd integration. That gate still requires supported Ubuntu hosts, actual
service users, hardening, fresh station telemetry and unchanged rerun evidence.

## Structured journald log contract

`structured_logs.py` runs the exact generated `logs_identity` VRL with pinned
Vector 0.58.0, then sends the normalized events through the production private
Unix-socket authorization handler to pinned VictoriaLogs v1.52.0. It checks both
binary hashes against committed component pins before execution. Prepare and run
on Linux in an isolated network namespace:

```bash
python3 -I -B tests/integration/render_doers.py /tmp/dragontools-log-fixture
python3 -I -B tools/fetch_doers_fixture.py --output /tmp/dragontools-log-fixture
sudo unshare --net sh -c 'ip link set lo up; exec python3 -I -B tests/integration/structured_logs.py /tmp/dragontools-log-fixture'
```

This fixture covers JSON/plain/malformed/non-object input, scalar budgets and
types, nested/array policy, message selection, timestamps, severity and attempted
identity/control-field overrides. Actual backend queries prove HTTP filters,
numeric comparisons, exactly four stream field names, the unchanged ErrorBurst
and CriticalLogEvent expressions, generated app HighErrorRate, freshness checks,
and preservation of an older opaque record. Linux CI runs it with the existing
Doers fixture binaries. Both Linux/macOS Zig suites exercise candidate-publication
failure/preservation, stream verification and independent restart/no-op behavior.

The offline Linux/arm64 process fixture passed locally. Its journal input is
stdin and its Unix-socket peer assertions are fixture headers; it does **not**
test real journald, Caddy TLS, SSH, systemd or live Doers. Disposable-host
integration and the production VMUI browser checks remain unrun for this schema
change. On a supported deployment, apply, emit normal application HTTP logs, run
app-verify, and inspect `{application="doers"} path:*`, exclusions for `/healthz`
and `/metrics`, and the four stream fields in VMUI. Historical records keep their
old schema. See README's structured-log section for collision/size/time policies.

Local commands used for the schema change (macOS controller, offline Linux/arm64
Docker processes; `/tmp` directories are local fixture data, not deployment paths):

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache python3 -I -B tests/integration/render_doers.py /tmp/dragontools-structured-logs
docker run --rm --network none -v "$PWD:/work:ro" -v /tmp/dragontools-structured-logs:/rendered:ro -v /tmp/dragontools-caddy-pipeline:/binaries:ro -w /work dragontools-pki-test:ubuntu24.04 python3 -I -B tests/integration/structured_logs.py /rendered /binaries
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache python3 -I -B tests/integration/render_doers.py /tmp/dragontools-caddy-pipeline
docker run --rm --network none -v "$PWD:/work:ro" -v /tmp/dragontools-caddy-pipeline:/fixture:ro -w /work dragontools-pki-test:ubuntu24.04 python3 -I -B tests/integration/doers_runtime.py /fixture --metrics-only
```

Both process runs passed. The separate Doers fixture additionally checks actual
Caddy mTLS, quiet-service stream verification, host metrics, application metrics,
zero-client station readiness and scoped rule APIs. `--metrics-only` stops before
the stop/recovery and outage scenarios; neither those scenarios nor real systemd
are claimed for this run. The macOS Zig suite passed 414/414, and CLI smoke passed
309 checks plus 19 UI lifecycle tests (Fish unavailable). GitHub Actions was not
dispatched from this local run; the Linux/macOS test matrix is retained.
