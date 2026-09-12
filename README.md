DragonTools is an opinionated Zig tool for minimalistic architecture enthusiasts who prefer a few well-understood Linux servers, systemd services, and explicit infrastructure over large orchestration stacks.

# DragonTools · v0.1 foundation

This first milestone installs **VictoriaMetrics**, not a complete monitoring station.
It creates a dedicated Unix user, a checksum-verified versioned executable, a hardened
systemd service, 90-day retention, and a disk reserve. It verifies health and queries
self-scraped metrics. Repeating the same install leaves healthy, unchanged services running.

## Build and install your first component

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

Expected: VictoriaMetrics `v1.151.0` runs at `127.0.0.1:8428` **on the server**.
Output reports the effective reserve in bytes and explicitly lists unavailable
integrations. A second install prints `No changes required.` if no repairs were needed.
`verify` is read-only; it checks the managed unit, active executable hash, service
hardening, local listener, HTTP health, and stored self-scraped metrics.

Security: no public service port is opened. There is no authentication on raw
VictoriaMetrics; it must remain loopback-only. This slice has no remote agent
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
The current installer still provides **VictoriaMetrics only**. Roadmap inputs
such as domain/TLS, IP allowlists, Telegram, agents, and firewall configuration
remain explicitly unavailable and fail before SSH, including in plan mode.
Station setup asks for host, SSH user/port, and authentication, then offers optional
roadmap settings with a default of no. Accepting that default produces a usable
VictoriaMetrics command. Metrics retention stays fixed at 90 days with a 20%
capacity reserve. Agent guidance accepts a numeric station IP (the current
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

## Inspect metrics from your workstation

An explicit temporary SSH tunnel allows inspecting the installed component:

```bash
MONITOR_HOST="monitor.example.com"
ssh -o StrictHostKeyChecking=yes -N -L 8428:127.0.0.1:8428 "root@$MONITOR_HOST"
# In another terminal:
curl --fail http://127.0.0.1:8428/health
curl --fail 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version'
```

Expected: HTTP health succeeds and the query returns stored metrics. The tunnel
exposes the raw API on your workstation's loopback; close it when finished.
Grafana will become the normal human-facing UI in a later milestone.

## Command availability

| Command | This milestone |
| --- | --- |
| `wizard` / no arguments in a TTY | Local interactive frontend to the same commands |
| `completion bash/zsh/fish` | Print local shell completion scripts |
| `monitoring install` | VictoriaMetrics vertical slice |
| `monitoring verify` | VictoriaMetrics checks, nonzero on failure |
| `monitoring status` | Service state summary, not an end-to-end health check |
| `monitoring agents install/verify/status` | Parsed; fails explicitly before SSH |
| `monitoring firewall` | Parsed; fails explicitly before SSH |

`--service` is repeatable. Agent, admin-IP, TLS, Telegram and 1Password private-key
reference flags are validated, then rejected as unavailable before any connection.
They are not silently ignored, including with `--plan`.
See `dragontool --help` and [examples](examples/).
Each level has contextual help, for example `dragontool monitoring --help`,
`dragontool monitoring install --help`, and `dragontool monitoring agents install --help`.
Upgrade, uninstall, and `monitoring tls renew` are future commands.

## Storage and operation

Metrics retention is `90d`. The initial reserve is `ceil(filesystem capacity / 5)`
using the data filesystem, passed to upstream `-storage.minFreeDiskSpaceBytes`.
VictoriaMetrics stops accepting new samples below the reserve. This is **not** a
hard free-space guarantee: merges and other writers can consume headroom. No data
is manually deleted. Rerun install after resizing the filesystem to update the
reserve; verify detects a stale policy. Use a dedicated filesystem where practical.

Paths:

- `/opt/dragontools/components/victoriametrics/v1.151.0/` and `current` symlink
- `/var/lib/dragontools/victoriametrics/` (service-owned data)
- `/etc/systemd/system/dragontools-victoriametrics.service`

Errors name the failed phase and completed changes, stop later steps, and avoid
printing remote stderr or argument values. A failed step may have partially changed
the target. Fix the cause, inspect `journalctl -u dragontools-victoriametrics`, then
rerun. No automatic rollback or component upgrades are implemented. Run one install
per target at a time. Do not replace managed paths with symlinks or locally edit the
managed unit; its content is reconciled. Unmanaged unit files and systemd drop-ins for the managed service are refused.
For `SshConnectionFailed`, check the host fingerprint, authentication and reachability
with ordinary SSH. For `MissingRemotePrerequisite`, install the listed Ubuntu packages
and rerun. For account/unit conflicts, inspect existing configuration before making
any manual change; DragonTools does not adopt it silently.

## Next milestones

VictoriaLogs, VictoriaTraces, Grafana provisioned datasources/dashboards, vmalert,
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
