DragonTools is an opinionated Zig tool for minimalistic architecture enthusiasts who prefer a few well-understood Linux servers, systemd services, and explicit infrastructure over large orchestration stacks.

# DragonTools · v0.1 foundation

The current milestone installs **VictoriaMetrics, VictoriaLogs, and VictoriaTraces**.
Each has a dedicated Unix user, a checksum-verified versioned executable, a hardened systemd
service, and a loopback-only listener. VictoriaMetrics keeps 90-day metrics with a
disk reserve; VictoriaLogs and VictoriaTraces keep disk-bound history with native
cleanup. Installation verifies all three components and preserves healthy,
unchanged processes on reruns. This is not a complete monitoring station: agents, alert evaluation,
dashboards, remote application ingestion, and frontend telemetry remain unavailable.

A separate `host install-oh-my-zsh` convenience command installs missing shell
tooling for an existing user. It does not change the monitoring stack.

## Quick Start: deploy metrics, logs, and traces now

Controller: Zig **0.16.0**, OpenSSH, macOS or Linux, amd64 or arm64.
Target: **Ubuntu 24.04 LTS or 26.04 LTS**, systemd, amd64 or arm64.
The target needs `curl`, CA certificates, `tar`, GNU coreutils, `util-linux`,
`iproute2`, `passwd`, and `grep` (normally present on Ubuntu server images).
The monitoring installer checks prerequisites; it does not install OS packages.
Use root or an account with noninteractive `sudo -n` access.

```bash
zig build -Doptimize=ReleaseSafe
zig build test

MONITOR_HOST="monitor.example.com"
# Enroll the server's verified host key in ~/.ssh/known_hosts first.
# Compare its fingerprint through a trusted provider console, not unverified ssh-keyscan.
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --plan
./zig-out/bin/dragontool monitoring install \
  --host "$MONITOR_HOST" --user root --ssh-sock "$SSH_AUTH_SOCK"
./zig-out/bin/dragontool monitoring verify \
  --host "$MONITOR_HOST" --user root --ssh-sock "$SSH_AUTH_SOCK"
./zig-out/bin/dragontool monitoring status \
  --host "$MONITOR_HOST" --user root --ssh-sock "$SSH_AUTH_SOCK"

# Deliberate safe rerun: healthy unchanged services keep running.
./zig-out/bin/dragontool monitoring install \
  --host "$MONITOR_HOST" --user root --ssh-sock "$SSH_AUTH_SOCK"
```

Expected: VictoriaMetrics `v1.151.0` runs at `127.0.0.1:8428` and VictoriaLogs
`v1.52.0` runs at `127.0.0.1:9428`; VictoriaTraces `v0.11.0` runs at
`127.0.0.1:10428` **on the server**.
Output reports the effective metrics reserve, logs/traces retention policy, and
unavailable integrations. An unchanged rerun reports:

```text
No changes required.
```

`verify` is read-only and fails if any component fails its checks. It checks
managed units, active executable hashes, hardening, local listeners, HTTP health,
stored VictoriaMetrics self-scraped metrics, and backend-specific writable storage
metrics: `vl_storage_is_read_only == 0` and `vt_storage_is_read_only == 0` for their
managed data paths. No synthetic application logs or traces are injected. It does
not claim that application telemetry has arrived. `status` reports all three
service states; use `verify` for health.

Security: no public service port is opened. Raw VictoriaMetrics, VictoriaLogs,
and VictoriaTraces APIs have no configured authentication and must remain
loopback-only. This slice has no remote agent
ingestion, Grafana, TLS, firewall management, alerts, or maintenance timer.
Local users on the target can reach loopback. Install does not claim those missing
protections or features are present. Use a provider firewall as an outer layer.

Advanced SSH options: `--port 2222`, `--user ops`, `--identity "$HOME/.ssh/id_ed25519"`.
Use one explicit authentication mode. `--ssh-sock` works with a normal or 1Password
SSH agent. With no mode, OpenSSH uses the environment agent and default identities.
Interactive identity-file passphrases are not prompted; use an agent.
For these direct monitoring commands, SSH config aliases, ProxyCommand and jump hosts are unsupported:
DragonTools passes `-F /dev/null`, strict host-key verification, and no forwarding.
Socket and identity paths must be absolute and contain no whitespace, quotes,
backslash, or OpenSSH `%` expansions.

## Install Oh My Zsh for a host user

This small convenience command ensures zsh and `~/.oh-my-zsh` exist on an
Ubuntu/Debian host. Existing Oh My Zsh installations are not updated, and an
existing `.zshrc` is preserved byte-for-byte even when it does not load Oh My Zsh.
If `.zshrc` is absent, DragonTools creates a minimal configuration using the
upstream `robbyrussell` theme and `git` plugin. The login shell is never changed.

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
./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host monitoring --plan
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring

# Deliberate rerun: unchanged state requires no mutation.
./zig-out/bin/dragontool host install-oh-my-zsh \
  --ssh-host monitoring
```

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

The first run installs only missing pieces. An unchanged rerun reports
`No changes required.` without reinstalling zsh, downloading Oh My Zsh, rewriting
`.zshrc`, or repairing ownership of an existing installation. The result also
reports the current login shell; changing it remains an explicit manual action.
An existing `.zshrc` may still need manual configuration to load Oh My Zsh.

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
The current installer provides **VictoriaMetrics, VictoriaLogs, and VictoriaTraces**. Roadmap inputs
such as domain/TLS, IP allowlists, Telegram, agents, and firewall configuration
remain explicitly unavailable and fail before SSH, including in plan mode.
Station setup asks for host, SSH user/port, and authentication, then offers optional
roadmap settings with a default of no. Accepting that default produces a usable
three-component install command. Metrics retention stays fixed at 90 days with a 20%
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

An explicit temporary SSH tunnel allows inspecting the three installed components:

```bash
MONITOR_HOST="monitor.example.com"
ssh -o StrictHostKeyChecking=yes -N \
  -L 8428:127.0.0.1:8428 -L 9428:127.0.0.1:9428 \
  -L 10428:127.0.0.1:10428 "root@$MONITOR_HOST"
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
Grafana will become the normal human-facing UI in a later milestone.

## Command availability

| Command | This milestone |
| --- | --- |
| `wizard` / no arguments in a TTY | Local interactive frontend to the same commands |
| `completion bash/zsh/fish` | Print local shell completion scripts |
| `host install-oh-my-zsh` | Install missing shell tooling for an existing Ubuntu/Debian user; preserve existing setup |
| `monitoring install` | VictoriaMetrics, VictoriaLogs, and VictoriaTraces installation |
| `monitoring verify` | All three checked; nonzero if any fails; read-only |
| `monitoring status` | All three service states, not an end-to-end health check |
| `monitoring agents install/verify/status` | Parsed; fails explicitly before SSH |
| `monitoring firewall` | Parsed; fails explicitly before SSH |

| Component/integration | Availability |
| --- | --- |
| VictoriaMetrics | Implemented |
| VictoriaLogs | Implemented; loopback only, without application-host ingestion |
| VictoriaTraces | Implemented; loopback only, without remote application OTLP ingestion |
| vmalert / Alertmanager | Unavailable; rules are only rendered locally |
| Grafana / Telegram | Unavailable |
| Vector / vmagent / OTel Collector / monitoring agents | Unavailable |
| Monitoring firewall / TLS | Unavailable |

`--service` is repeatable. Agent, admin-IP, TLS, Telegram and 1Password private-key
reference flags are validated, then rejected as unavailable before any connection.
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
prints all three implemented component installations and their retention/listener
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

Errors name the failed component, phase, and completed changes, stop later steps, and avoid
printing remote stderr or argument values. A failed step may have partially changed
the target. Fix the cause, inspect `journalctl -u dragontools-victoriametrics`
`journalctl -u dragontools-victorialogs`, or
`journalctl -u dragontools-victoriatraces`, then rerun. Each component retains its
own restart marker until verification succeeds. A later component failure
does not roll back components already verified in that run. No automatic rollback
or component upgrades are implemented. Run one install
per target at a time. Do not replace managed paths with symlinks or locally edit the
managed unit; its content is reconciled. Unmanaged unit files and systemd drop-ins for the managed service are refused.
For `SshConnectionFailed`, check the host fingerprint, authentication and reachability
with ordinary SSH. For `MissingRemotePrerequisite`, install the listed Ubuntu packages
and rerun. For account/unit conflicts, inspect existing configuration before making
any manual change; DragonTools does not adopt it silently.

## Alert policy and provisional rendering

Alert policy is defined in `src/monitoring/policy.zig`; rendering is partial and
provisional; alert runtime is unavailable. No rules are installed or evaluated.
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

`renderLogs` still emits deterministic provisional VictoriaLogs `type: vlogs`
YAML. ErrorBurst groups normalized `level=error` events by service and requires at
least 5 within 5 minutes. CriticalLogEvent requires one normalized `critical` or
`fatal` event within 1 minute, without a hold period. The intended evaluation
interval is one minute; no notifications are currently delivered. Structured log
fields, datasource routing, and event-time behavior need verification with the
future agents and evaluator. See [design](design.md).

Generated log alerts have stable `severity` and `source` labels and summaries
without log messages, request IDs, or secrets. Rendering performs no SSH,
credential resolution, storage deletion, or service changes. Renderer tests do
not establish runtime or production compatibility.

## Next milestones

Grafana provisioned datasources/dashboards, vmalert,
Alertmanager/Telegram; Vector for journald logs and host metrics, vmagent for
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
multiple alert providers, generic firewall management, plugins, public resource DSL,
multi-tenant authentication, per-agent API tokens, mTLS, automatic monitoring-component
upgrades, automatic reboots, or arbitrary shell hooks.
