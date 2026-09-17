DragonTools is an opinionated Zig tool for minimalistic architecture enthusiasts who prefer a few well-understood Linux servers, systemd services, and explicit infrastructure over large orchestration stacks.

# DragonTools · v0.1 foundation

Install the monitoring station once, then keep each application's monitoring
contract in its own repository:

```bash
dragontool monitoring install --config station.toml

cd my-application
dragontool monitoring apply --plan
dragontool monitoring apply
dragontool monitoring app-verify
dragontool monitoring apply # Deliberate unchanged rerun
```

Application commands read only `./monitoring.toml` by default, or one explicit
`--config PATH`. They configure host metrics, selected journal logs, optional
application metrics, station HTTP probes and application alerts. The strict
version-1 schema rejects unknown keys and contains no station secrets. See
[the application contract](#application-repository-contract) and the illustrative
[Doers example](examples/doers-monitoring.toml). Keep central
[station configuration](examples/station.toml) outside application repositories.

The station installs **VictoriaMetrics, VictoriaLogs, VictoriaTraces,
Grafana OSS, blackbox_exporter, Alertmanager, vmalert-logs and vmalert-metrics**. Each has a dedicated Unix account, pinned versioned artifacts,
a hardened systemd service, and a loopback-only listener. Grafana provisions Metrics,
Logs and Traces datasources and provides a visual UI through SSH forwarding.
VictoriaMetrics keeps 90-day metrics with a disk reserve; VictoriaLogs and
VictoriaTraces keep disk-bound history with native cleanup. Healthy unchanged
processes remain running on reruns. External HTTP probes are scraped locally and
evaluated by vmalert-metrics; a separate vmalert-logs evaluates the fixed log pack.
Alertmanager optionally delivers grouped Telegram notifications. The separate
`monitoring apply` workflow installs Vector for selected journal logs and host
metrics, plus vmagent for explicitly selected application metrics. Host alerts use
verified Vector metrics. OTel traces agents, service-state alerts and dashboards
remain unavailable.

A separate `host install-oh-my-zsh` convenience command installs missing shell
tooling for an existing user. It does not change the monitoring stack.

## Install the controller

The release workflow builds standalone controller binaries for macOS arm64/amd64
and Linux arm64/amd64. Users of those binaries do **not** need Zig. A release tag
such as `v0.1.0` produces these assets, after the same Linux/macOS test suites pass:

```text
dragontool_0.1.0_darwin_arm64.tar.gz
dragontool_0.1.0_darwin_amd64.tar.gz
dragontool_0.1.0_linux_arm64.tar.gz
dragontool_0.1.0_linux_amd64.tar.gz
SHA256SUMS
```

Download the matching archive and `SHA256SUMS` from a published repository release.
Verify its SHA-256 against that manifest, extract it, then install `dragontool`
into a directory on your PATH. Archives contain the executable, README and MIT
license. Checksums establish artifact integrity, not an independent publisher
signature. macOS binaries are not Developer ID signed or notarized. Adding the
workflow does not imply that a release has already been published.

For source builds, use Zig **0.16.0**: `zig build -Doptimize=ReleaseSafe`; the
executable is `./zig-out/bin/dragontool`. OpenSSH is required at runtime; optional
station secret references require the local 1Password CLI.

## Quick Start: deploy the monitoring station

Controller: a release binary or Zig **0.16.0** source build, OpenSSH, macOS or Linux,
amd64 or arm64.
Target: **Ubuntu 24.04 LTS or 26.04 LTS**, systemd, amd64 or arm64.
The target needs `curl`, CA certificates, `tar`, GNU coreutils, `util-linux`
(including `runuser`), `iproute2`, `passwd`, `grep`, and Python 3 with its standard
`sqlite3` module. The installer checks prerequisites; it does not install OS packages.
Use root or an account with noninteractive `sudo -n` access.

Configure the replaceable example alias `monitoring` in your own `~/.ssh/config`:

```sshconfig
Host monitoring
    HostName monitoring.example.com
    User root
```

Enroll the server's verified SSH host key first; compare its fingerprint through a
trusted provider console, not unverified `ssh-keyscan`. Use the same alias and
configured authentication for install, verification, rerun, and the tunnel:

```bash
zig build -Doptimize=ReleaseSafe
zig build test

./zig-out/bin/dragontool monitoring install --ssh-host monitoring --plan
./zig-out/bin/dragontool monitoring install --ssh-host monitoring
./zig-out/bin/dragontool monitoring verify --ssh-host monitoring
./zig-out/bin/dragontool monitoring status --ssh-host monitoring

# Deliberate safe rerun: healthy unchanged services keep running.
./zig-out/bin/dragontool monitoring install --ssh-host monitoring

# Keep this SSH session open while using Grafana.
ssh -L 127.0.0.1:3000:127.0.0.1:3000 monitoring
```

Open **http://127.0.0.1:3000** on your laptop. The tunnel explicitly binds the
laptop listener to loopback too. Grafana is not public. Do not add
port 3000 to the Hetzner firewall; no Cloudflare change is needed. This is temporary
pre-TLS access. A later slice will place `monitoring.baptizeddragon.com` in front
of Grafana over HTTPS; it is not configured now. Intended public inbound remains
**TCP 22 from the administrator IP only**; DragonTools changes no firewall rule
and adds no 80/443/3000 rule.

Grafana credentials are optional managed inputs. Without credential references,
existing installation behavior remains supported and output explicitly warns that
administrator credentials are unmanaged. On a fresh unmanaged database, complete
Grafana's standard `admin` / `admin` first login and change the password immediately.
Existing accounts are preserved in unmanaged mode. To manage credentials through
1Password, use the explicit configuration below; no resolved credentials are stored
in ordinary configuration or printed by DragonTools. Authentication stays enabled,
while anonymous access, auth proxy and signup stay disabled.

## Monitoring configuration and Grafana credentials

`--config` reads one explicit, small TOML file for monitoring `install`, `verify`,
`status`, and `notify-test`. There is no implicit file discovery. The version-1
schema accepts an OpenSSH alias, Grafana/Telegram secret references and bounded
named HTTP/HTTPS probes; component tuning, literal passwords, unknown keys and
duplicate keys are rejected.

The checked-in [examples/monitoring.toml](examples/monitoring.toml) contains these
**example** references. Replace the alias and vault/item/field paths with your own:

```toml
version = 1

[connection]
ssh_host = "monitoring"

[grafana]
username = { op = "op://BaptizedDragon/Grafana/username" }
password = { op = "op://BaptizedDragon/Grafana/password" }
```

A reference contains no resolved secret and is safe to keep in configuration or
version control, subject to your policy about revealing vault/item names. These
paths are examples, never global defaults. Both references must be supplied.
1Password is optional; only installations using these references need `op`, and
it runs **locally on the controller**. The monitoring host never needs 1Password,
its CLI, or its session credentials.

```bash
# Authenticate or unlock using your normal local 1Password CLI setup.
op signin

zig build -Doptimize=ReleaseSafe
./zig-out/bin/dragontool monitoring install --config examples/monitoring.toml --plan
./zig-out/bin/dragontool monitoring install --config examples/monitoring.toml
./zig-out/bin/dragontool monitoring verify --config examples/monitoring.toml
./zig-out/bin/dragontool monitoring status --config examples/monitoring.toml

# Desired credentials already work: no password reset or service restart.
./zig-out/bin/dragontool monitoring install --config examples/monitoring.toml
```

Explicit CLI values override the corresponding configuration values. The direct
CLI equivalent is:

```bash
./zig-out/bin/dragontool monitoring install \
  --ssh-host monitoring \
  --grafana-user-op 'op://BaptizedDragon/Grafana/username' \
  --grafana-password-op 'op://BaptizedDragon/Grafana/password'
```

`--plan` validates syntax and describes credentials as configured via secret
references; it never invokes `op` or SSH. `status` reports service state and does
not resolve administrator credentials. Install and configured verification resolve
both references before contacting the host. Missing `op`, locked/signed-out access,
missing references, empty values and subprocess failures produce safe errors;
provider stderr and resolved username/password values are suppressed.

A configured install first checks whether the desired administrator credentials
already authenticate. A successful check is a no-op. Otherwise it reconciles the
administrator through Grafana's supported interfaces, verifies the desired login,
and only then finalizes. It can migrate an existing manually changed password
without knowledge of that password. Credential-only reconciliation does not restart
Grafana or affect VictoriaMetrics, VictoriaLogs or VictoriaTraces. Management targets
the original local administrator (ID 1); incompatible or externally authenticated
accounts and desired-login collisions fail safely. Fresh initialization uses the
desired credentials before service startup, without first exposing the default login.
Standalone `verify` checks configured credentials through a read-only API request
and never repairs them. Grafana itself may update ordinary authentication metadata.

Usernames must be UTF-8, at most 190 bytes, without a colon, control characters or
leading/trailing whitespace. Passwords must be UTF-8, 4 bytes to 16 KiB, without CR,
LF or NUL. DragonTools uses the supported Grafana CLI's stdin password mode and
supported user API for existing accounts; it does not directly edit credential SQL.

The resulting SQLite database retains Grafana's normal password hash. DragonTools
retains no plaintext administrator password on the host after successful
reconciliation, does not embed it in `grafana.ini` or systemd, and transports resolved
values through protected SSH stdin rather than command arguments. No secret
temporary file is created. Details and recovery limits are in [the design](design.md#monitoring-configuration-and-grafana-credentials).

DragonTools output, remote command arguments and credential-helper output exclude
both resolved values. Grafana still owns its account identity and authentication
metadata; its own operational/audit logs can include the administrator username.
The helper never prints the password. This native Grafana logging boundary has
been reviewed in pinned source, not validated on a disposable host.

## Grafana: Metrics, Logs and Traces

All three datasources are provisioned automatically and are not editable in the UI:

| Name | Datasource | Local backend URL |
| --- | --- | --- |
| Metrics (default) | Built-in Prometheus | `http://127.0.0.1:8428` |
| Logs | Official `victoriametrics-logs-datasource` plugin | `http://127.0.0.1:9428` |
| Traces | Built-in Jaeger | `http://127.0.0.1:10428/select/jaeger` |

The signed official VictoriaLogs plugin is pinned at **0.32.0**. DragonTools verifies
the exact archive and installed file catalog; it does not call an online plugin
installer or fetch `latest`. Plugin storage is persistent, outside the versioned
Grafana server tree. Signature verification stays enabled; unsigned plugins are not
allowed. See [exact pins and installation design](design.md#official-victorialogs-datasource-plugin).
The plugin uses the VictoriaLogs base URL documented by upstream, without Loki
compatibility or a guessed path prefix. [Official VictoriaLogs integration](https://docs.victoriametrics.com/victorialogs/integrations/grafana/),
[official Grafana plugin catalog](https://grafana.com/grafana/plugins/victoriametrics-logs-datasource/).

Run install/verify with the example configuration above, keep the SSH tunnel open,
then visit **http://127.0.0.1:3000**. In Explore select **Logs**, use Raw Logs mode,
and execute the harmless LogsQL query `*`. A successful empty response is valid
before application ingestion; verification never injects logs. Metrics and Traces
remain available through their own Explore views. Traces may have no services yet.
No dashboard is provisioned and no public port is opened.

Expected listeners **on the server**:

| Component | Pinned release | Listener |
| --- | --- | --- |
| VictoriaMetrics | `v1.151.0` | `127.0.0.1:8428` |
| VictoriaLogs | `v1.52.0` | `127.0.0.1:9428` |
| VictoriaTraces | `v0.11.0` | `127.0.0.1:10428` |
| Grafana OSS | `13.2.2` | `127.0.0.1:3000` |
| blackbox_exporter | `0.28.0` | `127.0.0.1:9115` |
| Alertmanager | `v0.34.1` | `127.0.0.1:9093`; clustering disabled |
| vmalert-logs | `v1.152.0` | `127.0.0.1:8880` |
| vmalert-metrics | `v1.152.0` | `127.0.0.1:8881` |

Grafana archive SHA-256 pins match the official OSS `13.2.2` download page;
executable and full-tree catalog digests come from those verified archives.
See [the Grafana design and exact pins](design.md#grafana-installation-provisioning-and-verification).
Allow space for the roughly 0.45 GB archive plus the roughly 1.3 GB extracted tree
(and the prior tree during repair). Full-tree integrity is read on every run, so an
unchanged install can still take time while leaving files and services unchanged.

Install and verification show each component before noticeable work, then calm
inspection, change and verification progress. A configured unchanged rerun includes:

```text
[1/8] VictoriaMetrics
      inspecting...
      verifying...
      healthy; no changes
[2/8] VictoriaLogs
      inspecting...
      verifying...
      healthy; no changes
[3/8] VictoriaTraces
      inspecting...
      verifying...
      healthy; no changes
[4/8] Grafana
      inspecting...
      checking VictoriaLogs datasource plugin...
      plugin current
      datasources current
      verifying...
      administrator credentials verified
      Logs datasource health and query verified
      healthy; no changes
[5/8] Blackbox exporter
      inspecting...
      verifying...
      healthy; no changes
[6/8] Alertmanager
      inspecting...
      verifying...
      healthy; no changes
[7/8] vmalert logs
      inspecting...
      verifying...
      healthy; no changes
[8/8] vmalert metrics
      inspecting...
      verifying...
      healthy; no changes
No changes required.
```

Changed components report `applying required changes...` and
`healthy; changes applied`. After a readiness retry has waited about two seconds, a single
`waiting for readiness...` message is shown for that component. Progress is flushed
promptly, without logging commands, individual SSH roundtrips or secret values.

`verify` is read-only and fails if any component fails its checks. Storage backend
checks include managed units, running/disk executable identity, hardening, private
listeners, HTTP health, VictoriaMetrics self-scraped metrics, and logs/traces writable
storage metrics. Grafana checks service state, loopback listener ownership,
application identity, pinned installation, deterministic configuration, and
non-secret provisioned datasource records through a read-only SQLite connection.
It also queries Metrics, VictoriaLogs and Jaeger endpoints as the Grafana service
account. With credentials configured, verification authenticates the administrator,
checks the Logs plugin health endpoint, and sends a bounded read-only LogsQL query
through Grafana's query engine. A valid empty result succeeds. No application log
contents are printed and no synthetic logs/traces are injected.

Without references, installation and verification preserve the existing unmanaged
credential workflow: plugin integrity, provisioning records and direct backend
queries are checked, but the authenticated Logs plugin query is explicitly reported
as unchecked. Supply the existing Grafana secret-reference options to exercise it;
DragonTools never assumes a default password or enables anonymous access. Metrics
and Traces checks establish backend reachability, not queries through Grafana's
query engine. Save & test/Explore in the browser remains a disposable-host gate.

`status` reports all eight service states, expected datasource mappings, and stored
external-probe state from VictoriaMetrics. It does not trigger fresh target requests
or resolve credentials. Use `verify` for full station verification; a recorded failed
probe means the target is down, while missing/stale data is reported as unknown.

Verification separates fixed configuration checks from startup readiness. Unit,
checksum, symlink, service-user, hardening and process-argument mismatches, and
unexpected public listeners, fail immediately. Runtime probes check immediately,
then retry after 500 ms and at 1-second intervals only while not ready: up to
15 seconds for systemd activation, 30 seconds for HTTP readiness, and 45 seconds
for telemetry or datasource readiness. VictoriaMetrics self-scraped
`vm_app_version` can appear after its configured `-selfScrapeInterval=15s`.
There is no unconditional startup sleep or new CLI option. A timeout fails the
command and keeps that component's restart marker; readiness within the deadline
allows normal finalization and an unchanged install remains a no-op. Failures name
a safe semantic check, such as `self_scrape_ready`, without exposing remote stderr
or executable commands.

Raw storage APIs have no configured authentication and must remain loopback-only.
Local users on the target can reach them. Agent ingestion uses a separate authenticated mTLS endpoint on port 9443.
There is no public Grafana TLS, firewall management or maintenance timer. Use a
provider firewall as an outer layer; allow ingestion only from monitored hosts.

`--ssh-host` delegates aliases, user, port, identities, agent paths, and jump hosts
to native OpenSSH configuration while enforcing strict host-key verification and
noninteractive authentication. It rejects direct connection overrides. Put those
settings in SSH configuration instead. This trusts your local configuration,
including proxy commands. The station wizard assembles the direct form below; agent setup uses two OpenSSH aliases.

Direct SSH remains supported:

```bash
./zig-out/bin/dragontool monitoring install \
  --host monitoring.example.com --user root --ssh-sock "$SSH_AUTH_SOCK"
```

Direct options include `--port 2222`, `--user ops`, and
`--identity "$HOME/.ssh/id_ed25519"`. Choose one explicit authentication mode.
`--ssh-sock` accepts a normal or 1Password agent; without a mode OpenSSH uses the
environment agent and default identities. Interactive passphrases are not prompted.
Direct mode passes `-F /dev/null`, so inherited aliases/proxy settings are disabled.
Direct socket/identity paths must be absolute and contain no whitespace, quotes,
backslash, or OpenSSH `%` expansions. Neither connection mode changes firewall rules.

## Install Oh My Zsh for a host user

This small convenience command ensures zsh and `~/.oh-my-zsh` exist on an
Ubuntu/Debian host. Existing Oh My Zsh installations are not updated, and an
existing `.zshrc` is preserved byte-for-byte by default, even when it does not load
Oh My Zsh. If `.zshrc` is absent, DragonTools creates a marked configuration with
Oh My Zsh, the `git` plugin and a server prompt showing user, hostname and current
directory, such as `root@monitoring ~ #` or `vasyl@monitoring ~ %`. The hostname is
the remote machine's actual short hostname, resolved by Zsh when displaying the
prompt; it is not copied from the local SSH alias or hardcoded in `.zshrc`.
DragonTools does not change the hostname. It sets the prompt directly instead of
depending on an upstream theme. The login shell is unchanged unless explicitly requested.

Configure a replaceable example alias in your own `~/.ssh/config`:

```sshconfig
Host monitoring
    HostName monitoring.example.com
    User root
    # Optional 1Password agent configuration on macOS:
    # IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

Verify and enroll the host's SSH key through a trusted channel first. Then run:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring --set-default-shell --plan
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring \
  --set-default-shell

# Deliberate rerun: unchanged state requires no mutation.
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring \
  --set-default-shell
```

Reconnect after changing the login shell to start the new shell:

```bash
ssh monitoring
```

With a new or explicitly migrated generated configuration and remote hostname
`monitoring`, the root prompt should look like `root@monitoring ~ #`.
An existing arbitrary configuration remains unchanged, so its prompt may differ.

`--ssh-host` delegates `HostName`, `User`, `Port`, `IdentityAgent`, `IdentityFile`,
`ProxyJump`, and other SSH configuration to OpenSSH. DragonTools does not parse
the SSH config and does not require `--user` or `--ssh-sock` in this mode. In
particular, a quoted `IdentityAgent` path containing spaces is handled by OpenSSH.
Strict host-key verification remains mandatory. This mode trusts your local SSH
configuration, including any configured proxy commands.

The default target is the actual SSH login user, with its home obtained from host
account information. `--target-user vasyl` selects another existing account;
missing accounts fail rather than being created. The local `--plan` performs no
SSH and cannot resolve an alias's effective user or inspect remote state.

Direct SSH remains available for this command:

```bash
./zig-out/bin/dragontool host install-oh-my-zsh \
  --host monitoring.example.com --user root --ssh-sock "$SSH_AUTH_SOCK" \
  --target-user vasyl
```

Use either `--ssh-host` or the direct `--host` form. Alias mode rejects direct
connection overrides; put its user, port, and authentication settings in SSH
configuration instead. `--target-user` selects the installation account and is
independent of the connection mode.

Two boolean options opt into additional changes for the selected account:

```bash
# Set the login shell and migrate an unchanged older DragonTools .zshrc, if present.
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring --set-default-shell --update-managed-zshrc

# Deliberate unchanged rerun with the same requested state:
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring --set-default-shell --update-managed-zshrc
```

`--set-default-shell` uses the discovered zsh executable path only after checking
that it is listed in `/etc/shells`. It changes the account's login shell only when
different and verifies the new account record. It never calls `chsh` for an already
matching shell. An unlisted zsh path fails; DragonTools never edits `/etc/shells`.
Changing the login shell may require root or noninteractive sudo;
it leaves the running shell intact and affects subsequent SSH commands and logins.
Keep noninteractive startup files silent: OpenSSH invokes the account shell for
remote commands, so subsequent zsh connections may read `.zshenv` (normally not
`.zshrc`). The shell change can succeed even if a later verification connection
fails; restore a working SSH startup environment and rerun to inspect actual state.

`--update-managed-zshrc` updates only an exact known DragonTools template. It remains
explicit because the existing host command promises to preserve existing `.zshrc`
on an ordinary rerun; installing missing tools does not silently replace a startup
file. The unmarked v0 template (including its `robbyrussell` line) and the marked
v1 template (including its literal `%%` prompt ending) are recognized by their
complete bytes and migrate only with this flag. Migration preserves the file's
user, group and mode, or refuses the update if it cannot preserve them.
The current template starts with `# DragonTools managed .zshrc v2`, sets
`ZSH_THEME=""`, and sets `PROMPT='%n@%m %~ %# '` after loading Oh My Zsh. The final
`%#` expands to `#` for root and `%` for an ordinary user. A marker alone is insufficient:
local edits, extra lines, and arbitrary configurations are preserved. An already
current template requires no rewrite. Do not edit `.zshrc` concurrently with an
explicit managed update.

For an arbitrary existing `.zshrc`, DragonTools reports preservation even with the
update flag. To adopt a fresh generated file, first back up and manually move your
existing file to a unique, unused name in that account's home; then rerun the host
command. Keep the backup until you have reviewed and transferred any desired
settings. DragonTools provides no option to claim or overwrite a foreign file.

The first run installs only missing pieces. An unchanged rerun reports
`No changes required.` without reinstalling zsh, downloading Oh My Zsh, rewriting
`.zshrc`, changing an already correct login shell, or repairing ownership of an
existing installation. The result reports whether the configuration was created,
updated or preserved. A shell change reports the old and new paths and asks you to
reconnect; an unchanged requested shell is reported as already correct. Without the opt-in
flags, an existing `.zshrc` may still need manual configuration and the login shell
stays unchanged.

This command adds no service, listener, monitoring agent, package-management
framework, or dotfile manager. See [the host utility design](design.md#host-utility-install-oh-my-zsh)
for source pinning, privilege, path, and recovery limits.

## Safe reruns and recovery

Every mutating workflow must converge from the host's actual state. The first
install creates the desired resources; an unchanged second install inspects and
verifies them without redownloading binaries, rewriting matching units, or
restarting healthy services. There is no controller-side state database.

| Resource | Rerun behavior |
| --- | --- |
| Account | Correct account is a no-op; an incompatible account fails explicitly |
| Directory | Matching type, owner, group, and mode are a no-op; only supported metadata repairs are made |
| Binary | Valid pinned binary is reused; a missing/changed binary is verified and installed atomically |
| Grafana Logs plugin | Matching pinned file catalog is reused without download; verified replacements switch atomically and set only Grafana restart intent |
| Grafana config/provisioning | Deterministic managed files are reused unchanged; content changes record only Grafana restart intent |
| Grafana credentials | Configured credentials authenticate before mutation; correct credentials skip reset and restart; omitted references leave credentials unmanaged |
| Unit | Identical content is reused; changed content is replaced atomically; metadata-only repair does not restart |
| Service | Active/persistently enabled and unchanged is a no-op; inactive starts; disabled or runtime-only enablement is repaired; only the affected dirty component restarts |
| Verification | Always read-only and safe to repeat |

Unexpected symlinks or incompatible managed paths fail. Systemd reloads only when
its loaded unit state requires it; a binary-only repair does not itself require
`daemon-reload`. Persistently enabling a disabled or runtime-only unit requires a reload but does not restart
an already running service. A global stale-unit flag alone does not make a
component dirty. A pending per-component restart marker survives interruptions and
failed health checks. Rerun the same install command to inspect actual state,
resume activation, verify, and clear the marker only after success. Never assume
the previous run completed. Run one install per host at a time.
Unmanaged changes to a running process/configuration can fail verification and
require operator correction; rerun safety does not mean every manual runtime
change is automatically adopted or repaired.

## External HTTP probes and Telegram

The station performs outside-in HTTP/HTTPS availability checks even when a service
has stopped emitting logs or exposing metrics. Add bounded service definitions to
an explicit monitoring config; replace the example URLs with your own endpoints:

```toml
version = 1

[connection]
ssh_host = "monitoring"

[[probe]]
name = "software-landing"
url = "https://service-a.example.com/healthz"

[[probe]]
name = "orderflow"
url = "https://service-b.example.com/healthz"

# Optional deployment values, never built-in defaults:
[telegram]
bot_token = { op = "op://BaptizedDragon/DragonTools/alarms-telegram-bot-token" }
chat_id = { op = "op://BaptizedDragon/DragonTools/alarms-telegram-chat-id" }
```

Run with the same enrolled SSH alias throughout:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dragontool monitoring install --config monitoring.toml --plan
./zig-out/bin/dragontool monitoring install --config monitoring.toml
./zig-out/bin/dragontool monitoring verify --config monitoring.toml
./zig-out/bin/dragontool monitoring status --config monitoring.toml
# Deliberate unchanged rerun:
./zig-out/bin/dragontool monitoring install --config monitoring.toml
# Explicitly sends a test alert through Alertmanager to its configured receiver:
./zig-out/bin/dragontool monitoring notify-test --config monitoring.toml
```

Only GET with expected HTTP 2xx is supported. Probe names are unique, at most 63
ASCII bytes, start alphanumeric and contain only alphanumerics, `-` or `_`. There
are at most 64 probes; URLs are at most 2048 bytes and must use HTTP or HTTPS.
Credentials, query strings, fragments, control characters, custom headers and
user-defined labels/modules are rejected before SSH. Use dedicated health paths
without embedded secret material. The URL becomes a stored `target` label;
scheme/hostname case, default ports and an empty path are normalized.

The pinned blackbox exporter uses a five-second module timeout, IPv4 preference
with address-family fallback, normal redirects and verified TLS certificates.
This first slice deliberately uses HTTP/1.1: HTTP/2 is disabled because upstream
0.28.0 contains the transport affected by [GO-2026-4918](https://pkg.go.dev/vuln/GO-2026-4918).
VictoriaMetrics' native scraper runs every 30 seconds with a five-second scrape
timeout; blackbox's default 500 ms response margin leaves up to 4.5 seconds for a
probe. Address-family fallback selects an available family during DNS resolution;
it is not a retry across every resolved address. No vmagent or polling daemon is
needed for this station-local path.

`ServiceProbeFailed` selects the owned `probe_success == 0` series and holds for
**two minutes**, with `severity=critical` and `source=blackbox`. Notifications name
the configured probe and target. Duration metrics are collected, but no latency
alert is installed. Stored exporter metrics keep only the fixed metric allowlist
and owned `job`, `instance`, `probe`, `target` and fixed timing `phase` labels;
dynamic certificate fingerprints and arbitrary response values are excluded.

A target failure is valid telemetry: install and verify require a recent result
of either `probe_success=0` or `1`, not healthy applications. They check exporter,
scraper configuration/recorded metrics, both evaluators and Alertmanager. Status
reads recorded samples from VictoriaMetrics instead of probing targets again.
With no configured probes, the scrape list is empty and there are no probe targets.

Adding or removing a probe atomically updates only the scraper file and reloads
VictoriaMetrics' native scraper. It does not restart VictoriaMetrics, blackbox,
vmalert or the other services. Upgrading from the prior station slice requires
one VictoriaMetrics unit restart to enable native scraping; later probe changes
use an independent persisted reload intent. An unchanged install reports
`No changes required.` and does not rewrite configuration/secrets, download
artifacts, restart services or send a test notification.

Telegram references resolve locally during install. Only its dedicated protected
stdin consumer persists the token and chat ID under
`/etc/dragontools/alertmanager/secrets/`, owned by `dt-alertmanager`, mode `0400`.
Neither value enters YAML, units, argv or DragonTools output; the host needs no
1Password installation. Correct existing values are not rewritten. Omit the
entire `[telegram]` table to use the discard receiver. Verification checks installed
configuration and protected-file policy without resolving Telegram references or
sending notifications. `notify-test` uses installed Alertmanager configuration;
API acceptance is not proof that Telegram delivered a message to a human.

Alertmanager's native stdout/stderr are disabled because its pinned Telegram
client can include a bot-token URL in an error. Diagnose through systemd state,
read-only health/API/metrics and DragonTools' fixed semantic errors; native
Alertmanager journal messages are deliberately unavailable.
See the [exact pins and operational limits](design.md#external-probing-and-alert-runtime).

## Interactive setup

The wizard helps assemble a regular DragonTools command, explains defaults, and
shows the equivalent command and a summary before dispatch. It uses the same
options, validation, and installation implementation as CLI flags.

After building, put the binary on your current shell's `PATH` to use the shorter
commands below (or invoke `./zig-out/bin/dragontool` directly):

```bash
export PATH="$PWD/zig-out/bin:$PATH"
dragontool wizard
# The same helper opens with no arguments when stdin and stdout are terminals:
dragontool
```

Choose installation, agent setup, verification, status, firewall guidance, the
information-only architecture overview, or command-line help. The overview and
command preview are local: they do not connect to a host or resolve credentials.
The current installer provides the eight station components listed above. Use
monitoring TOML for probes and optional Telegram references. Roadmap inputs
such as public domain/TLS, IP allowlists, and firewall configuration
remain explicitly unavailable and fail before SSH, including in plan mode.
Station setup asks for host, SSH user/port, and authentication, then offers optional
roadmap settings with a default of no. Accepting that default produces a usable
eight-component install command. Metrics retention stays fixed at 90 days with a 20%
capacity reserve. Logs and traces use a logical 100-year limit and native 75%
partition budgets, as detailed below. Agent setup asks for application/station
OpenSSH aliases, repeated validated `.service` names and optional private metrics
endpoints. It previews the same CLI command and requires default-No confirmation.

Enter accepts a displayed default; required empty values and malformed values
are prompted again. Use `?` for prompt help, `back` to return where offered, and
`quit`, Ctrl+C, or end-of-input to cancel. Prompts use plain ASCII and need no
colors, Unicode, or full-screen terminal support; `NO_COLOR` and `TERM=dumb` work.
Before a mutating workflow, choose **Show plan only**, **Apply**, **Go back**, or
**Cancel**. Plan uses the regular `--plan` behavior. Apply requires a separate
`Continue? [y/N]` confirmation; Enter means no.

Credential questions accept supported reference mechanisms, never pasted tokens.
The preview can show an `op://` reference, but never a resolved secret. Such
references may reveal vault/item names, so review the preview before sharing it.
Private-key references remain unavailable; a normal or 1Password SSH agent socket
can be used for the implemented installation. No protected-file credential option
is offered until the regular CLI supports it.

Without a terminal on both stdin and stdout, a no-argument invocation prints help
and exits successfully without reading input. Explicit `wizard` instead reports
`InteractiveTerminalRequired` and exits nonzero. Use explicit CLI commands in
scripts, pipes, and CI. See `dragontool wizard --help` for a concise guide.

## Shell completion

DragonTools generates Bash, Zsh, and Fish completion scripts from its CLI metadata.
Completion includes nested commands, relevant options, and enum choices such as
`--tls manual|cloudflare`; path options use the shell's native path completion.
It is local, deterministic, side-effect free, and never contacts remote hosts or
secret providers. The binary has no shell dependency for script generation.

Bash (with bash-completion installed and enabled):

```bash
mkdir -p "$HOME/.local/share/bash-completion/completions"
dragontool completion bash > "$HOME/.local/share/bash-completion/completions/dragontool"
# Enable in this Bash session immediately:
source "$HOME/.local/share/bash-completion/completions/dragontool"
```

Zsh:

```zsh
mkdir -p "$HOME/.zsh/completions"
dragontool completion zsh > "$HOME/.zsh/completions/_dragontool"
fpath=("$HOME/.zsh/completions" $fpath)
autoload -Uz compinit
compinit
```

For future Zsh sessions, add the `fpath` line to your own `~/.zshrc` **before** its
existing `compinit` initialization. If none exists, add the `autoload` and `compinit`
lines too. You control these edits; completion installation does not change shell startup files.

Fish:

```fish
mkdir -p "$HOME/.config/fish/completions"
dragontool completion fish > "$HOME/.config/fish/completions/dragontool.fish"
```

If you use a custom `XDG_CONFIG_HOME`, place the Fish file in its `fish/completions`
directory instead. Type `dragontool monitoring install --` and press Tab, or type
`dragontool monitoring install --tls ` and press Tab for `manual` and `cloudflare`.
Completion can describe unavailable roadmap flags; selecting them does not enable
their implementation. `dragontool completion --help` shows installation guidance.

## Inspect backend health from your workstation

An explicit temporary SSH tunnel allows inspecting the three storage backends:

```bash
ssh -o StrictHostKeyChecking=yes -N \
  -L 127.0.0.1:8428:127.0.0.1:8428 -L 127.0.0.1:9428:127.0.0.1:9428 \
  -L 127.0.0.1:10428:127.0.0.1:10428 monitoring
# In another terminal:
curl --fail http://127.0.0.1:8428/health
curl --fail 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version'
curl --fail http://127.0.0.1:9428/health
curl --fail http://127.0.0.1:9428/metrics | grep '^vl_storage_is_read_only'
curl --fail http://127.0.0.1:10428/health
curl --fail http://127.0.0.1:10428/metrics | grep '^vt_storage_is_read_only'
```

Expected: all three HTTP health checks succeed, the metrics query returns stored data,
and both storage read-only metrics are `0`. The tunnel exposes raw APIs on your
workstation's loopback; close it when finished. No application logs or traces are
ingested by this installation, and verification never injects synthetic telemetry.
Grafana is the normal human-facing UI for Metrics, Logs and Traces; use its
port-3000 tunnel from Quick Start.

## Application repository contract

Commit `monitoring.toml` beside the application. `monitoring apply`, `app-verify`
and `app-status` read exactly `./monitoring.toml` unless `--config PATH` selects
another file. Missing files, unknown/duplicate keys and invalid values fail before
SSH. There is no interpolation, secret reference, raw YAML/LogsQL, include,
repository-name inference or search through parent directories.

```toml
version = 1

[application]
name = "example"
environment = "production"

[target]
ssh_host = "replace-me-application"

[station]
ssh_host = "replace-me-monitoring"

[[service]]
name = "web"
systemd = "app.service"

[service.logs]
enabled = true

[service.metrics]
url = "http://127.0.0.1:16000/metrics"

[service.traces]
enabled = false

[[probe]]
name = "website"
url = "https://service.example.com/healthz"

[[alert]]
name = "HighErrorRate"
source = "logs"
service = "web"
level = "error"
window = "5m"
threshold = 10
severity = "warning"
```

Replace the illustrative aliases, unit and endpoints. The
[Doers example](examples/doers-monitoring.toml) is illustrative too; production
service names and instrumentation have not been inspected.

| Field | v1 contract |
| --- | --- |
| `application.name`, `application.environment` | Both required; 1–63 ASCII letters/digits/`_`/`-`, starting with a letter/digit. Lower-case recommended. |
| `target.ssh_host`, `station.ssh_host` | Required native OpenSSH aliases; no connection credentials. |
| `service.name`, `service.systemd` | Unique service identity and exact canonical `.service` unit; no globs, aliases or journal namespaces. |
| `service.logs.enabled` | Optional boolean, defaults to `false`. Only enabled units are forwarded. |
| `service.metrics.url` | Optional private/loopback literal-IP or localhost HTTP(S) URL; no arbitrary DNS, credentials, redirects, query or fragment. |
| `service.traces.enabled` | Optional `false`; `true` fails because tracing is unavailable. |
| `probe.name`, `probe.url` | Unique named HTTP(S) URL, no credentials/query/fragment; fixed GET, verified TLS and expected 2xx. |
| `alert.source` | `logs` or `probe`; custom `metrics` alerts fail explicitly. |
| `alert.severity` | Required `warning` or `critical`. |
| Log alert | Required `name`, `level`, `window`, positive integer `threshold`; optional `service`, otherwise all logs-enabled services in this app. |
| Probe alert | Required `name`, `probe`, `severity`; optional `for` defaults to `2m`. Replaces the probe's default alert. |

Files are bounded to 64 KiB, with at most 64 services, probes and alerts each.
Durations are positive integer `s`, `m`, `h` or `d` values up to one day; thresholds
are at most 1,000,000,000. Levels are `debug`, `info`, `warn`, `warning`, `error`,
`critical` or `fatal`. Service/probe/alert names use the same identifier bounds;
systemd units must also be unique. A declared logs/metrics/traces table must
contain its supported key. Each probe permits only one alert override. Unknown
references and options fail validation.

Every application gets Vector host metrics, even with no services. Shared host
rules use the established CPU/memory/disk/inode thresholds, scoped by application,
environment and host. Every probe gets `ServiceProbeFailed`,
`probe_success == 0`, critical severity and a two-minute hold. Override its name,
severity or hold without creating a duplicate:

```toml
[[alert]]
name = "WebsiteDown"
source = "probe"
probe = "website"
severity = "critical"
for = "2m"
```

```bash
dragontool monitoring apply --plan
dragontool monitoring apply
dragontool monitoring app-verify
dragontool monitoring app-status
dragontool monitoring apply # Expected: No changes required.
```

Plan is local and shows validated public identities, signals, probes, alerts and
owned paths. Apply verifies recent agent signals, loaded probes and loaded rules.
A failing HTTP target is valid monitoring data; a broken probe pipeline fails.
Verify/status never resolve station secrets or send test notifications. Live
alert evaluation remains active independently.

Each application owns `/etc/dragontools/apps/<name>/` on the station. Its manifest
proves exact generated files before updates; a marker alone does not authorize
replacing edits. Removing an alert or probe updates only that app's files. Other
app directories, manual rules, Grafana assets and central secrets remain untouched.
Unmanaged conflicts fail; no global overwrite/adopt flag exists. An application
name is unique across a station and binds its environment and machine identity.
Use distinct names for different environments; namespace migration requires
deliberate operator recovery.

Applications on one target keep separate signal manifests and share Vector and
optional vmagent. Desired signals are merged deterministically; applying one app
preserves the others. Duplicate journal-unit ownership is refused. Host-wide
limits are 32 apps and 64 aggregate services/metrics targets. Legacy `monitoring
agents` registrations are not silently adopted. Alert/probe-only changes do not
restart agents; metrics-endpoint changes do not rewrite unrelated station rules.
Shared station loaders are integrated once; later app changes reload scraping or
restart only the affected evaluator. Failures preserve pending intent.

Trusted application/environment/host/service overwrite application log fields and
scrape labels. mTLS, bounded buffers, journald limits and signal freshness use the
agent policy below. Certificate rotation, custom metrics alerts, dashboards and
OTel deployment remain unavailable. See the [two-host application gate](tests/integration/README.md#application-contract-two-host-gate)
before claiming deployment validation.

## Application-host logs and metrics

`monitoring agents install` registers an existing application host with an existing
DragonTools station. It installs pinned **Vector 0.58.0** for selected journald
services and CPU/memory/filesystem/disk/network metrics. It installs pinned
**vmagent v1.152.0** only when application metrics targets are supplied. Both
support Linux amd64/arm64 and run as dedicated `dt-vector` / `dt-vmagent` users.
OTel Collector and tracing agents remain deferred; node_exporter is not installed.

Configure two replaceable OpenSSH aliases using verified host keys and root or
noninteractive sudo access. `--station` is the station alias, not a Victoria URL.
Its OpenSSH `HostName` must be a DNS name or IPv4 address reachable from the
application host; a controller-only jump-host address does not provide an agent
network route. DragonTools owns the fixed ingestion port. Both hosts require the
normal station prerequisites, Python 3 and OpenSSL; DragonTools does not install OS
packages or change the firewall. Permit **TCP 9443** from the application host to
the station in the operator-managed network firewall.

```bash
zig build
./zig-out/bin/dragontool monitoring agents install \
  --ssh-host replace-me-application --station replace-me-monitoring \
  --service app.service --service worker.service \
  --metrics-target app=http://127.0.0.1:16000/metrics --plan

./zig-out/bin/dragontool monitoring agents install \
  --ssh-host replace-me-application --station replace-me-monitoring \
  --service app.service --service worker.service \
  --metrics-target app=http://127.0.0.1:16000/metrics
./zig-out/bin/dragontool monitoring agents verify \
  --ssh-host replace-me-application --station replace-me-monitoring
./zig-out/bin/dragontool monitoring agents status \
  --ssh-host replace-me-application --station replace-me-monitoring

# Deliberate unchanged rerun, using the same aliases and selections.
./zig-out/bin/dragontool monitoring agents install \
  --ssh-host replace-me-application --station replace-me-monitoring \
  --service app.service --service worker.service \
  --metrics-target app=http://127.0.0.1:16000/metrics
```

Install requires at least one unique `.service` unit. The remote unit must exist,
its canonical systemd `Id` must exactly match the selection, and `LogNamespace`
must be empty; aliases and namespaced journals are refused before registration.
Selections are bounded to 64 services and 64 application targets, within a
64 KiB registration budget checked before SSH. Target names
are explicit, unique, at most 63 ASCII letters/digits/`_`/`-`, starting with a
letter/digit. URLs are at most 2048 bytes, HTTP/HTTPS, without credentials, query
strings or fragments. Only `localhost` or literal loopback/private/link-local
addresses are accepted; arbitrary DNS names and public addresses are rejected
before SSH. HTTPS certificate validation stays enabled and scrape redirects are
disabled. No targets means no unnecessary vmagent install. Removing all targets
stops/disables an existing managed vmagent while retaining its files and data. Verify/status may omit
selections to use the station's saved registration. `--plan`, help and completion
are local and resolve no secrets.

Only explicitly selected journal units are forwarded. Application fields such as
`timestamp`, `level`, `environment`, `request_id`, `event` and `duration_ms` are
preserved where present; trusted host/service identity cannot be overwritten by
application JSON. The stable host ID comes from the application machine ID.
Filesystem collection excludes immutable `squashfs` and `iso9660` images, whose
normal full utilization would produce false disk alerts. Ordinary filesystems
remain monitored when systemd mounts them read-only for service hardening.

Vector emits a small `type=dragontools_stream`, `level=info` metadata record per
selected service every 30 seconds, so a quiet stream can be verified without fake
errors or application traffic. These records are visible in Logs; filter on
`type=application` for application-only results. Unchanged installer reruns do
not emit an extra test event.

The station installs a narrow DragonTools Python ingestion service as `dt-ingest`
on IPv4 TCP **9443**. It requires a registered client certificate and TLS 1.2 or
newer, and exposes only fixed metrics/log writes plus an authenticated health
route. Raw VictoriaMetrics/VictoriaLogs stay on loopback; Grafana, Alertmanager and
VictoriaTraces gain no public route. CA material remains root-private on the
station. Per-host credentials cross protected SSH I/O and are installed as mode
0400 files readable only by their consuming service. They never enter argv,
ordinary configuration, progress or errors; equal credentials are unchanged.
The controller stores no state database. Registration records host ID, selected
services/targets and client-certificate identity on the station.

This authenticates hosts, not mutually untrusted tenants. A compromised
application root or agent credential can submit arbitrary metric content for its
authenticated host; do not treat mTLS as metric-content validation. The ingestion
route enforces host identity even when submitted metrics contain a forged host
label, verified against the pinned native VictoriaMetrics backend. Logs enforce registered service names. The station, controller,
OpenSSH configuration, host roots and station CA are trusted. Automatic certificate
rotation is not implemented; expiration or incompatible credential state fails
closed and requires deliberate operator recovery.

Vector uses two bounded disk buffers, **268435488 bytes per sink** (upstream's
minimum, approximately 256 MiB), with blocking backpressure, 10-second requests
and retry backoff from 1 second to 30 seconds. vmagent's remote-write queue is
bounded to **1 GiB**; at the limit upstream drops oldest queued blocks. During a
long outage Vector can stop consuming journal entries; journal retention can then
remove older logs. These limits bound disk use, not guarantee unlimited lossless
retention. Host/internal/metadata sources do not support end-to-end
acknowledgements; journal forwarding does. Internal Vector and vmagent forwarding/queue metrics are preserved;
Vector's API is disabled, its telemetry listener is `127.0.0.1:8686`, and vmagent
management is `127.0.0.1:8429`.

The installer inspects effective journald configuration, calculates byte limits
from the `/var/log` and `/run` filesystems, and adds only
`/etc/systemd/journald.conf.d/90-dragontools.conf` when needed:
`SystemMaxUse=min(1 GiB, 5%)`, `RuntimeMaxUse=min(256 MiB, 2%)`, and
`MaxRetentionSec=7day`. Existing stricter values stay stricter; unrelated files
and the main journald configuration remain untouched. Conflicting later overrides
are refused. These bounds do not cover applications writing their own log files.

Install verifies service/configuration/hardening, the secured endpoint, recent
host metrics, every selected log stream, and each app target's successful scrape
and recent non-scrape metric. Install/verify require samples newer than the current
agent process start as well as their freshness windows (90 seconds for metrics,
two minutes for logs), preventing old data from proving a changed URL works. Keep
both hosts' clocks synchronized because Vector timestamps originate on the agent.
Runtime readiness uses bounded retries; signal
arrival has a 45-second deadline. A station outage fails verification and keeps
restart intent for recovery. Successful unchanged reruns print
`No changes required.` without restarting agents, rewriting credentials, or
re-registering identical selections. Standalone verify/status do not mutate.
An isolated native Linux process fixture verified actual Vector/vmagent mTLS
ingestion into pinned VictoriaMetrics/VictoriaLogs and authenticated host-label
override. It replaced journald with a fixture source. Full disposable-host
installation, journal collection, outage recovery and systemd hardening remain
separate integration gates: see [the checklist](tests/integration/README.md).

## Command availability

| Command | This milestone |
| --- | --- |
| `monitoring apply` | Apply strict repository monitoring.toml; local plan available |
| `monitoring app-verify/app-status` | Read-only application agents, probes and rules |
| `wizard` / no arguments in a TTY | Local interactive frontend to the same commands |
| `completion bash/zsh/fish` | Print local shell completion scripts |
| `host install-oh-my-zsh` | Install missing shell tooling; explicit options for exact managed-config migration and login-shell changes |
| `monitoring install` | Eight concrete station services, local HTTP probes and fixed alert rules |
| `monitoring verify` | All eight checked; failed targets are valid telemetry; read-only |
| `monitoring status` | Service states and stored external-probe results |
| `monitoring notify-test` | Explicit test alert through Alertmanager; requires installed Telegram configuration |
| `monitoring agents install/verify/status` | Vector logs/host metrics, optional vmagent app metrics; station signal verification |
| `monitoring firewall` | Parsed; fails explicitly before SSH |

| Component/integration | Availability |
| --- | --- |
| VictoriaMetrics | Implemented |
| VictoriaLogs | Implemented; loopback only, with selected agent logs through mTLS ingestion |
| VictoriaTraces | Implemented; loopback only, without remote application OTLP ingestion |
| blackbox_exporter | Implemented HTTP/HTTPS GET probes through local VictoriaMetrics scraping |
| vmalert / Alertmanager | Implemented separate metrics/logs evaluation and grouped alert routing |
| Grafana OSS | Implemented; loopback:3000, local authentication, Metrics/Logs/Traces datasources |
| Grafana Logs datasource | Official plugin 0.32.0; authenticated health/query checks with configured references |
| Dashboards | Unavailable |
| Telegram | Optional configured SecretRefs; explicit `notify-test`, never automatic tests |
| Vector / vmagent | Implemented selected logs/host metrics and optional app metrics |
| OTel Collector | Unavailable; traces agent deferred |
| Agent ingestion | Registered client mTLS on station TCP 9443; fixed write routes only |
| Monitoring firewall / public Grafana TLS | Unavailable |

`--service` and `--metrics-target` are repeatable. Admin-IP, public TLS and 1Password private-key
reference flags are validated, then rejected as unavailable before any connection.
Telegram is configured through `[telegram]` in monitoring TOML; legacy roadmap
Telegram flags remain unavailable.
They are not silently ignored, including with `--plan`.
See `dragontool --help` and [examples](examples/).
Each level has contextual help, including `dragontool host --help`,
`dragontool host install-oh-my-zsh --help`, `dragontool monitoring --help`,
`dragontool monitoring install --help`, and `dragontool monitoring agents install --help`.
Upgrade, uninstall, and `monitoring tls renew` are future commands.

## Storage and operation

`src/monitoring/policy.zig` defines the fixed monitoring defaults:

| Signal | Retention and disk policy | Current availability |
| --- | --- | --- |
| Metrics | `90d` retention; 20% filesystem reserve | Installed and verified by the VictoriaMetrics workflow |
| Logs | Logical `100y` limit; native 75% setting budgets log partition bytes against total filesystem capacity | Installed VictoriaLogs native retention; see limitation below |
| Traces | Logical `100y` limit; native 75% setting budgets trace partition bytes against total filesystem capacity | Installed VictoriaTraces native retention; see limitation below |

VictoriaLogs `v1.52.0` and VictoriaTraces `v0.11.0` each receive
`-retentionPeriod=100y` and `-retention.maxDiskUsagePercent=75`. Their pinned storage
implementations compare **that backend's own partition bytes with 75% of total
filesystem capacity**. Other writers are excluded from this usage comparison.
Cleanup removes oldest partitions periodically (about every 10 seconds with
jitter) and preserves the newest two daily partitions, which can span more than
two calendar days when data has gaps.

These are independent partition budgets, not a combined filesystem-usage trigger
or hard 75% ceiling. Co-located backends and other writers can fill a shared disk
before either budget is reached. Size storage and headroom for their combined
load; `100y` does not promise 100 years of history. DragonTools performs no manual
storage deletion and never combines the percentage flag with its mutually
exclusive byte-based counterpart. These details follow the pinned implementations,
which are more specific than the upstream retention overview. [VictoriaLogs storage](https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.52.0/lib/logstorage/storage.go#L826-L871), [VictoriaTraces pinned storage dependency](https://github.com/VictoriaMetrics/VictoriaLogs/blob/6ae2da3c11f3/lib/logstorage/storage.go#L826-L871).

Disk states are **60% info, 70% warning, 80% critical**. They are separate from
the native logs/traces partition budgets. CPU, memory, disk and inode rules use
the pinned Vector metric contract; no host alert fires without matching agent
metrics. Service-state rules remain unavailable.

For example, `dragontool monitoring install --host monitor.example.com --plan`
prints all eight implemented component installations and their retention/listener
settings, then lists unavailable components. It performs no SSH. DragonTools owns
versions, paths, retention, binding, and hardening; no component-specific
configuration or new CLI options are needed for normal installation.

The VictoriaMetrics reserve remains `ceil(filesystem capacity / 5)`
using the data filesystem, passed to upstream `-storage.minFreeDiskSpaceBytes`.
VictoriaMetrics stops accepting new samples below the reserve. This is **not** a
hard free-space guarantee: merges and other writers can consume headroom. No data
is manually deleted. Rerun install after resizing the filesystem to update the
reserve; verify detects a stale policy. Use a dedicated filesystem where practical.

Paths:

- `/opt/dragontools/components/victoriametrics/v1.151.0/` and `current` symlink
- `/var/lib/dragontools/victoriametrics/` (service-owned data)
- `/etc/systemd/system/dragontools-victoriametrics.service`
- `/opt/dragontools/components/victorialogs/v1.52.0/` and `current` symlink
- `/var/lib/dragontools/victorialogs/` (owned by `dt-victorialogs`, mode 0750)
- `/etc/systemd/system/dragontools-victorialogs.service`
- `/opt/dragontools/components/victoriatraces/v0.11.0/` and `current` symlink
- `/var/lib/dragontools/victoriatraces/` (owned by `dt-victoriatraces`, mode 0750)
- `/etc/systemd/system/dragontools-victoriatraces.service`
- `/opt/dragontools/components/grafana/13.2.2/` and `current` symlink
- `/var/lib/dragontools/grafana/` (SQLite data; owned by `dt-grafana`, mode 0750)
- `/var/lib/dragontools/grafana/plugins-versions/victoriametrics-logs-datasource/0.32.0/` (root-owned signed plugin and catalog)
- `/var/lib/dragontools/grafana/plugins/victoriametrics-logs-datasource` (atomic active link; both plugin roots read-only to the service)
- `/etc/dragontools/grafana/grafana.ini` and `provisioning/datasources/dragontools.yaml`
- `/etc/systemd/system/dragontools-grafana.service`

Errors name the failed component, phase, and completed changes, stop later steps, and avoid
printing remote stderr or argument values. A failed step may have partially changed
the target. Fix the cause, inspect `journalctl -u dragontools-victoriametrics`
`journalctl -u dragontools-victorialogs`, or
`journalctl -u dragontools-victoriatraces`, or `journalctl -u dragontools-grafana`, then rerun. Each component retains its
own restart marker until verification succeeds. A later component failure
does not roll back components already verified in that run. No automatic rollback
or generic component-upgrade command is implemented. A reviewed future plugin pin
can be staged alongside the prior release and atomically selected; old plugin
releases remain available for operator recovery. Run one install
per target at a time. Do not replace managed paths with symlinks or locally edit the
managed unit; its content is reconciled. Unmanaged unit files and systemd drop-ins for the managed service are refused.
For `SshConnectionFailed`, check the host fingerprint, authentication and reachability
with ordinary SSH. For `MissingRemotePrerequisite`, install the listed Ubuntu packages
and rerun. For account/unit conflicts, inspect existing configuration before making
any manual change; DragonTools does not adopt it silently.

## Deployed alerts and deferred service-state policy

Alert policy is defined in `src/monitoring/policy.zig`. The fixed log pack and
ServiceProbeFailed are installed and evaluated by separate vmalert instances.
CPUHigh, MemoryPressure, DiskWarning, DiskCritical and InodesCritical use the
Vector 0.58.0 host metric contract verified in an isolated Linux fixture. CPU
pressure is above 90% for 10 minutes; memory pressure is above 90% for 5 minutes;
disk warning/critical are 70%/80% for 5 minutes; inode critical is 90% for 5 minutes.
The fixed host pack selects `agent="vector"`; without agent samples it is inactive.
HostDown, ServiceDown and ServiceRestartLoop remain deferred. Requested service
rule rendering still returns `ServiceMetricContractUnavailable`.

`renderLogs` supplies the deterministic VictoriaLogs `type: vlogs` pack;
installation marks and validates the managed rule document before activation. ErrorBurst groups normalized `level=error` events by service and requires at
least 5 within 5 minutes. CriticalLogEvent requires one normalized `critical` or
`fatal` event within 1 minute, without a hold period. The intended evaluation
interval is one minute. Both evaluators notify Alertmanager; Telegram delivery is
optional. Vector forwards selected application journal streams and preserves
normalized structured fields. Full two-host systemd ingestion, event-time behavior
and delivery remain real-host integration gates. See [design](design.md).

Generated log alerts have stable `severity` and `source` labels and summaries
without log messages, request IDs, or secrets. Rendering performs no SSH,
credential resolution, storage deletion, or service changes. Renderer tests do
not establish runtime or production compatibility.

## Next milestones

Dashboards, authenticated Metrics/Traces datasource query checks; OTel Collector
for application OTLP; safe monitoring firewall; public Grafana DNS-01 TLS;
oneshot maintenance; update/security checks and alerts.

[Architecture](architecture.md), [design and roadmap](design.md),
[contributing/testing](CONTRIBUTING.md), [security](SECURITY.md),
[changelog](CHANGELOG.md). Licensed under [MIT](LICENSE).

## Non-goals

No Kubernetes, Docker orchestration, generic configuration management, Windows,
non-systemd monitoring hosts, generic Linux distribution support, multi-node Victoria clusters,
HA monitoring, dynamic service discovery, generic cloud-provider management,
multiple alert providers, generic firewall management, a general plugin framework, public resource DSL,
hard multi-tenant isolation, per-agent API tokens, automatic monitoring-component
upgrades, automatic reboots, or arbitrary shell hooks.
