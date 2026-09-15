DragonTools is an opinionated Zig tool for minimalistic architecture enthusiasts who prefer a few well-understood Linux servers, systemd services, and explicit infrastructure over large orchestration stacks.

# DragonTools · v0.1 foundation

The current milestone installs **VictoriaMetrics and VictoriaLogs**. Each has a
dedicated Unix user, a checksum-verified versioned executable, a hardened systemd
service, and a loopback-only listener. VictoriaMetrics keeps 90-day metrics with a
disk reserve; VictoriaLogs keeps disk-bound log history with native cleanup.
Installation verifies both components and preserves healthy, unchanged processes
on reruns. This is not a complete monitoring station: agents, alert evaluation,
dashboards, and application-host log ingestion remain unavailable.

## Build and install metrics and logs

Controller: Zig **0.16.0**, OpenSSH, macOS or Linux, amd64 or arm64.
Target: **Ubuntu 24.04 LTS or 26.04 LTS**, systemd, amd64 or arm64.
The target needs `curl`, CA certificates, `tar`, GNU coreutils, `util-linux`,
`iproute2`, `passwd`, and `grep` (normally present on Ubuntu server images).
DragonTools checks prerequisites; it does not install OS packages in this milestone.
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
./zig-out/bin/dragontool monitoring verify --host "$MONITOR_HOST"
./zig-out/bin/dragontool monitoring status --host "$MONITOR_HOST"
```

Expected: VictoriaMetrics `v1.151.0` runs at `127.0.0.1:8428` and VictoriaLogs
`v1.52.0` runs at `127.0.0.1:9428` **on the server**.
Output reports the effective metrics reserve in bytes, the logs retention policy,
and explicitly lists unavailable
integrations. A second install prints `No changes required.` if no repairs were needed.
`verify` is read-only and fails if either component fails its checks. It checks
managed units, active executable hashes, hardening, local listeners, HTTP health,
stored VictoriaMetrics self-scraped metrics, and VictoriaLogs identity and writable
storage through `vl_storage_is_read_only == 0`. It does not claim that application
logs have arrived. `status` reports both service states; use `verify` for health.

Security: no public service port is opened. Raw VictoriaMetrics and VictoriaLogs
APIs have no configured authentication and must remain loopback-only. This slice has no remote agent
ingestion, Grafana, TLS, firewall management, alerts, or maintenance timer.
Local users on the target can reach loopback. Install does not claim those missing
protections or features are present. Use a provider firewall as an outer layer.

Advanced SSH options: `--port 2222`, `--user ops`, `--identity "$HOME/.ssh/id_ed25519"`.
Use one explicit authentication mode. `--ssh-sock` works with a normal or 1Password
SSH agent. With no mode, OpenSSH uses the environment agent and default identities.
Interactive identity-file passphrases are not prompted; use an agent.
SSH config aliases, ProxyCommand and jump hosts are intentionally unsupported:
DragonTools passes `-F /dev/null`, strict host-key verification, and no forwarding.
Socket and identity paths must be absolute and contain no whitespace, quotes,
backslash, or OpenSSH `%` expansions.

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
The current installer provides **VictoriaMetrics and VictoriaLogs**. Roadmap inputs
such as domain/TLS, IP allowlists, Telegram, agents, and firewall configuration
remain explicitly unavailable and fail before SSH, including in plan mode.
Station setup asks for host, SSH user/port, and authentication, then offers optional
roadmap settings with a default of no. Accepting that default produces a usable
metrics-and-logs command. Metrics retention stays fixed at 90 days with a 20%
capacity reserve. Logs use a logical 100-year limit and native cleanup at 75%
filesystem usage. Agent guidance accepts a numeric station IP (the current
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
lines too. You control these edits; DragonTools does not change shell startup files.

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

## Inspect metrics and logs health from your workstation

An explicit temporary SSH tunnel allows inspecting both installed components:

```bash
MONITOR_HOST="monitor.example.com"
ssh -o StrictHostKeyChecking=yes -N \
  -L 8428:127.0.0.1:8428 -L 9428:127.0.0.1:9428 "root@$MONITOR_HOST"
# In another terminal:
curl --fail http://127.0.0.1:8428/health
curl --fail 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version'
curl --fail http://127.0.0.1:9428/health
curl --fail http://127.0.0.1:9428/metrics | grep '^vl_storage_is_read_only'
```

Expected: both HTTP health checks succeed, the metrics query returns stored data,
and the VictoriaLogs read-only metric is `0`. The tunnel exposes raw APIs on your
workstation's loopback; close it when finished. No application logs are ingested by
this installation, and no synthetic log is required or written by verification.
Grafana will become the normal human-facing UI in a later milestone.

## Command availability

| Command | This milestone |
| --- | --- |
| `wizard` / no arguments in a TTY | Local interactive frontend to the same commands |
| `completion bash/zsh/fish` | Print local shell completion scripts |
| `monitoring install` | VictoriaMetrics and VictoriaLogs installation |
| `monitoring verify` | Both components checked; nonzero if either fails |
| `monitoring status` | Both service states, not an end-to-end health check |
| `monitoring agents install/verify/status` | Parsed; fails explicitly before SSH |
| `monitoring firewall` | Parsed; fails explicitly before SSH |

| Component/integration | Availability |
| --- | --- |
| VictoriaMetrics | Implemented |
| VictoriaLogs | Implemented; loopback only, without application-host ingestion |
| VictoriaTraces | Unavailable |
| vmalert / Alertmanager | Unavailable; rules are only rendered locally |
| Grafana / Telegram | Unavailable |
| Vector / vmagent / OTel Collector / node_exporter / monitoring agents | Unavailable |
| Monitoring firewall / TLS | Unavailable |

`--service` is repeatable. Agent, admin-IP, TLS, Telegram and 1Password private-key
reference flags are validated, then rejected as unavailable before any connection.
They are not silently ignored, including with `--plan`.
See `dragontool --help` and [examples](examples/).
Each level has contextual help, for example `dragontool monitoring --help`,
`dragontool monitoring install --help`, and `dragontool monitoring agents install --help`.
Upgrade, uninstall, and `monitoring tls renew` are future commands.

## Storage and operation

`src/monitoring/policy.zig` defines the fixed monitoring defaults:

| Signal | Retention and disk policy | Current availability |
| --- | --- | --- |
| Metrics | `90d` retention; 20% filesystem reserve | Installed and verified by the VictoriaMetrics workflow |
| Logs | Keep as much history as safely fits, with a logical `100y` limit and native cleanup around 75% filesystem usage | Installed VictoriaLogs native retention |
| Traces | Keep as much history as safely fits, with a logical `100y` limit and native cleanup around 75% filesystem usage | Policy only; VictoriaTraces is unavailable |

VictoriaLogs starts deleting the oldest daily partitions when filesystem usage
exceeds 75%, using `-retention.maxDiskUsagePercent=75` alongside
`-retentionPeriod=100y`. It retains at least the newest two days and checks disk
usage periodically, so filesystem usage can temporarily exceed that threshold.
This is a cleanup target, not a hard capacity ceiling. Size the monitoring
filesystem for incoming data, shared writers, and sufficient headroom; `100y`
does not promise 100 years of stored logs. DragonTools performs no manual storage
deletion and does not combine percentage retention with the mutually exclusive
`-retention.maxDiskSpaceUsageBytes` option. [VictoriaLogs retention](https://docs.victoriametrics.com/victorialogs/#retention).

Disk states are **60% info, 70% warning, 80% critical**. They are separate from
the native 75% logs cleanup threshold and the planned traces cleanup policy.
These alerts are not deployed. The 60% informational state is policy only;
the local renderer emits warning and critical disk alerts.

For example, `dragontool monitoring install --host monitor.example.com --plan`
prints both implemented component installations and their retention/listener
settings, then lists unavailable components. It performs no SSH. DragonTools owns
versions, paths, retention, binding, and hardening; no VictoriaLogs-specific
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

Errors name the failed component, phase, and completed changes, stop later steps, and avoid
printing remote stderr or argument values. A failed step may have partially changed
the target. Fix the cause, inspect `journalctl -u dragontools-victoriametrics`
or `journalctl -u dragontools-victorialogs`, then rerun. Each component retains its
own restart marker until verification succeeds. A VictoriaLogs failure does not
roll back an already verified VictoriaMetrics installation. No automatic rollback
or component upgrades are implemented. Run one install
per target at a time. Do not replace managed paths with symlinks or locally edit the
managed unit; its content is reconciled. Unmanaged unit files and systemd drop-ins for the managed service are refused.
For `SshConnectionFailed`, check the host fingerprint, authentication and reachability
with ordinary SSH. For `MissingRemotePrerequisite`, install the listed Ubuntu packages
and rerun. For account/unit conflicts, inspect existing configuration before making
any manual change; DragonTools does not adopt it silently.

## Default alert rule generation

`src/monitoring/rules.zig` locally renders deterministic vmalert rule YAML from
the policy module. Host/service metrics and VictoriaLogs rules use separate files.
This is an internal Zig API: there is no rule-export or deployment CLI command yet.
No rules are installed or evaluated by DragonTools, and neither vmalert nor
node_exporter is installed. Renderer tests do not prove runtime compatibility.

| Group | Generated defaults |
| --- | --- |
| Host | HostDown; CPUHigh; MemoryPressure; DiskWarning; DiskCritical; InodesCritical |
| Service | ServiceDown; ServiceRestartLoop, only for explicitly selected `.service` units |
| Logs | ErrorBurst; CriticalLogEvent |

CPUHigh uses non-idle CPU above 90% for 10 minutes. MemoryPressure uses
`MemAvailable` to detect usage above 90% for 5 minutes. DiskWarning and DiskCritical
use 70% and 80%, with a 5-minute hold; InodesCritical uses 90% for 5 minutes.
HostDown waits 2 minutes. ServiceDown waits 2 minutes; ServiceRestartLoop requires
at least 3 automatic restarts over 5 minutes, sustained for 1 minute. Temporary/pseudo
filesystems are excluded from the filesystem rules.

For example, a caller selecting `orderflow.service` and `whoami.service` receives
service rules only for those units; an empty list emits no service rules. Future
agent setup must enable node_exporter's systemd collector and its restart metric
before these rules can be deployed.

ErrorBurst groups normalized `level=error` events by service and requires at least
5 events within 5 minutes; ordinary errors do not each generate a notification.
CriticalLogEvent needs one normalized `critical` or `fatal` event within 1 minute
and has no hold period. Evaluation is every minute, so "immediate" means the next
evaluation, not synchronous delivery. Logs use the VictoriaLogs `vlogs` group type
and require a VictoriaLogs datasource when an evaluator is eventually installed.
Structured fields and future runtime prerequisites are described in [design](design.md).

Alerts carry stable `severity` and `source` labels and concise annotations with
host/service context where available. Log messages, request IDs, and secrets are
not copied into annotations. Rendering performs no SSH, credential resolution,
storage deletion, service changes, or notification delivery.

## Next milestones

VictoriaTraces, Grafana provisioned datasources/dashboards, vmalert,
Alertmanager/Telegram; Vector + vmagent + OTel Collector + node_exporter agents;
bounded journald; restricted ingestion; safe monitoring firewall; DNS-01 TLS;
oneshot maintenance; update/security checks and alerts.

[Architecture](architecture.md), [design and roadmap](design.md),
[contributing/testing](CONTRIBUTING.md), [security](SECURITY.md),
[changelog](CHANGELOG.md). Licensed under [MIT](LICENSE).

## Non-goals

No Kubernetes, Docker orchestration, generic configuration management, Windows,
non-systemd Linux, generic Linux distribution support, multi-node Victoria clusters,
HA monitoring, dynamic service discovery, generic cloud-provider management,
multiple alert providers, generic firewall management, plugins, public resource DSL,
multi-tenant authentication, per-agent API tokens, mTLS, automatic monitoring-component
upgrades, automatic reboots, or arbitrary shell hooks.
