DragonTools is an opinionated Zig tool for minimalistic architecture enthusiasts who prefer a few well-understood Linux servers, systemd services, and explicit infrastructure over large orchestration stacks.

# DragonTools · v0.1 foundation

The current milestone installs **VictoriaMetrics, VictoriaLogs, VictoriaTraces,
Grafana OSS, blackbox_exporter, Alertmanager, vmalert-logs and vmalert-metrics**. Each has a dedicated Unix account, pinned versioned artifacts,
a hardened systemd service, and a loopback-only listener. Grafana provisions Metrics,
Logs and Traces datasources and provides a visual UI through SSH forwarding.
VictoriaMetrics keeps 90-day metrics with a disk reserve; VictoriaLogs and
VictoriaTraces keep disk-bound history with native cleanup. Healthy unchanged
processes remain running on reruns. External HTTP probes are scraped locally and
evaluated by vmalert-metrics; a separate vmalert-logs evaluates the fixed log pack.
Alertmanager optionally delivers grouped Telegram notifications. Agents, host/service
metric alerts, dashboards and remote application ingestion remain unavailable.

A separate `host install-oh-my-zsh` convenience command installs missing shell
tooling for an existing user. It does not change the monitoring stack.

## Quick Start: deploy the monitoring station

Controller: Zig **0.16.0**, OpenSSH, macOS or Linux, amd64 or arm64.
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
Local users on the target can reach them. There is no remote ingestion, TLS,
firewall management or maintenance timer. Use a provider firewall
as an outer layer.

`--ssh-host` delegates aliases, user, port, identities, agent paths, and jump hosts
to native OpenSSH configuration while enforcing strict host-key verification and
noninteractive authentication. It rejects direct connection overrides. Put those
settings in SSH configuration instead. This trusts your local configuration,
including proxy commands. The wizard currently assembles the direct form below.

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
such as domain/TLS, IP allowlists, agents, and firewall configuration
remain explicitly unavailable and fail before SSH, including in plan mode.
Station setup asks for host, SSH user/port, and authentication, then offers optional
roadmap settings with a default of no. Accepting that default produces a usable
eight-component install command. Metrics retention stays fixed at 90 days with a 20%
capacity reserve. Logs and traces use a logical 100-year limit and native 75%
partition budgets, as detailed below. Agent guidance accepts a numeric station IP (the current
`--station-ip` contract) and repeats validated `.service` names.

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

## Command availability

| Command | This milestone |
| --- | --- |
| `wizard` / no arguments in a TTY | Local interactive frontend to the same commands |
| `completion bash/zsh/fish` | Print local shell completion scripts |
| `host install-oh-my-zsh` | Install missing shell tooling; explicit options for exact managed-config migration and login-shell changes |
| `monitoring install` | Eight concrete station services, local HTTP probes and fixed alert rules |
| `monitoring verify` | All eight checked; failed targets are valid telemetry; read-only |
| `monitoring status` | Service states and stored external-probe results |
| `monitoring notify-test` | Explicit test alert through Alertmanager; requires installed Telegram configuration |
| `monitoring agents install/verify/status` | Parsed; fails explicitly before SSH |
| `monitoring firewall` | Parsed; fails explicitly before SSH |

| Component/integration | Availability |
| --- | --- |
| VictoriaMetrics | Implemented |
| VictoriaLogs | Implemented; loopback only, without application-host ingestion |
| VictoriaTraces | Implemented; loopback only, without remote application OTLP ingestion |
| blackbox_exporter | Implemented HTTP/HTTPS GET probes through local VictoriaMetrics scraping |
| vmalert / Alertmanager | Implemented separate metrics/logs evaluation and grouped alert routing |
| Grafana OSS | Implemented; loopback:3000, local authentication, Metrics/Logs/Traces datasources |
| Grafana Logs datasource | Official plugin 0.32.0; authenticated health/query checks with configured references |
| Dashboards | Unavailable |
| Telegram | Optional configured SecretRefs; explicit `notify-test`, never automatic tests |
| Vector / vmagent / OTel Collector / monitoring agents | Unavailable |
| Monitoring firewall / TLS | Unavailable |

`--service` is repeatable. Agent, admin-IP, TLS and 1Password private-key
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
the native logs/traces partition budgets. Alert policy is defined, but host
and service rules are unavailable until the agent metric contract is established.
No disk alerts are deployed.

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

## Deployed alerts and deferred host/service policy

Alert policy is defined in `src/monitoring/policy.zig`. The fixed log pack and
ServiceProbeFailed are installed and evaluated by separate vmalert instances.
Host and systemd-service metric rules remain deferred.
The future Vector agent slice must establish the actual host metric contract, and
the systemd service-state monitoring solution is intentionally deferred.

Host policy retains HostDown, CPUHigh, MemoryPressure, DiskWarning, DiskCritical,
and InodesCritical. CPU pressure is above 90% for 10 minutes; memory pressure is
above 90% for 5 minutes; disk warning/critical are 70%/80% for 5 minutes; inode
critical is 90% for 5 minutes. ServiceDown and ServiceRestartLoop remain policy
intent, with their signal sources still to be established.

`src/monitoring/rules.zig` refuses host rendering with
`HostMetricContractUnavailable` and requested service rendering with
`ServiceMetricContractUnavailable`. An empty service list yields no service rules.
It emits no guessed Vector expressions. These are internal Zig APIs; there is no
rule-export or rule-deployment CLI command.

`renderLogs` supplies the deterministic VictoriaLogs `type: vlogs` pack;
installation marks and validates the managed rule document before activation. ErrorBurst groups normalized `level=error` events by service and requires at
least 5 within 5 minutes. CriticalLogEvent requires one normalized `critical` or
`fatal` event within 1 minute, without a hold period. The intended evaluation
interval is one minute. Both evaluators notify Alertmanager; Telegram delivery is
optional. No application-host log collector is installed, so log alerts require
existing local structured data. End-to-end ingestion and event-time behavior remain
real-host integration gates. See [design](design.md).

Generated log alerts have stable `severity` and `source` labels and summaries
without log messages, request IDs, or secrets. Rendering performs no SSH,
credential resolution, storage deletion, or service changes. Renderer tests do
not establish runtime or production compatibility.

## Next milestones

Dashboards, authenticated Metrics/Traces datasource query checks; Vector for journald logs and host metrics, vmagent for
application `/metrics`, and OTel Collector for application OTLP;
bounded journald; restricted ingestion; safe monitoring firewall; DNS-01 TLS;
oneshot maintenance; update/security checks and alerts.

[Architecture](architecture.md), [design and roadmap](design.md),
[contributing/testing](CONTRIBUTING.md), [security](SECURITY.md),
[changelog](CHANGELOG.md). Licensed under [MIT](LICENSE).

## Non-goals

No Kubernetes, Docker orchestration, generic configuration management, Windows,
non-systemd monitoring hosts, generic Linux distribution support, multi-node Victoria clusters,
HA monitoring, dynamic service discovery, generic cloud-provider management,
multiple alert providers, generic firewall management, a general plugin framework, public resource DSL,
multi-tenant authentication, per-agent API tokens, mTLS, automatic monitoring-component
upgrades, automatic reboots, or arbitrary shell hooks.
