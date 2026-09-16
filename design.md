# Design decisions and staged delivery

## Current milestone: metrics, logs, and traces implemented

The monitoring foundation delivers three concrete slices: VictoriaMetrics, VictoriaLogs, and
VictoriaTraces. Unfinished integrations fail before connecting. Exit 0 from install
means all three passed verification; it never means the full requested station exists.
`status` is a read-only service-state summary; use `verify` to test health.
Help and `--plan` require no SSH. No generic primitives are public commands.

Zig 0.16.0 and its standard library handle CLI parsing, process execution, memory,
formatting and JSON. Controller relies on OpenSSH; the remote uses reviewed small
shell fragments as system interfaces, not a configuration DSL. No third-party Zig
dependencies. Hostnames, users, paths, service units, IPs and secret references are
validated; dynamic values are independently shell-quoted. Unknown/duplicate scalar
flags fail. Repeated list flags are supported.

The monitoring target is Ubuntu 24.04/26.04, amd64/arm64; only those pass its detection.
Controller build targets are macOS/Linux amd64/arm64. Cross-compilation does not
prove remote runtime compatibility. No VM run is inferred from a passing unit test.

## Local CLI helper and completion

Interactive mode is a frontend to the regular DragonTools command model, not a
separate deployment engine. A small internal command/flag spec supplies hierarchy,
option contexts, value types, and enum choices for parsing, help, completion, and
wizard command generation. The parser performs final validation and the same
dispatch enforces availability and plan/apply behavior for both frontends. This
does not introduce a generic public CLI framework or a resource DSL.

The wizard offers monitoring install, agents, verify, status, firewall guidance,
architecture information, and command-line help. Station setup defaults to the
implemented VictoriaMetrics, VictoriaLogs, and VictoriaTraces slices; roadmap settings require explicit opt-in and
still fail before SSH. Agent station entry remains a numeric IP, matching
`--station-ip`. Unsupported components and protected-file credential inputs do not
become implemented merely because an interactive interface exists.

Prompts explain fixed storage defaults and distinguish current behavior from the
intended complete stack. They use ASCII with no color dependency and reuse CLI
validators on individual answers. Ordinary input errors are retried. Enter accepts
displayed defaults, `?` gives context, `back` returns where practical, and `quit`,
EOF, or Ctrl+C cancel. Both stdin and stdout must be terminals for the interactive
entry point; no-argument non-TTY calls print help and return without waiting.

Before a mutation the helper displays equivalent shell-quoted argv and a summary,
then offers regular `--plan`, Apply, Go back, or Cancel. Apply also requires an
explicit yes at `Continue? [y/N]`. Credential questions request references, not
tokens, and only validate reference syntax. Preview may include a reference but
never invokes a secret resolver. Information-only use performs no remote operation.

Shell completion is local, deterministic, side-effect free, and never contacts
remote hosts or secret providers. `completion bash|zsh|fish` writes a script to
stdout from the shared spec, with nested commands, only relevant flags, known enum
values, and native shell path completion. The controller gains no shell dependency.
Users install the generated file and configure their own shell; completion setup
never edits startup files. Contextual `--help` works for each command and command group.

Scripted input/output unit tests cover the helper without spawning terminals.
Completion metadata/rendering tests and CLI smoke tests cover hierarchy, enum and
flag contexts, non-TTY behavior, and local-only help/completion. These UX changes
leave the remote component and integration-validation boundary unchanged.

## Host utility: install Oh My Zsh

`host install-oh-my-zsh` is an independent convenience command for an existing
Ubuntu/Debian account. It does not enter `monitoring install`, manage services,
change a login shell, create users, or introduce a general package/dotfile system.
The shared CLI metadata provides parsing, help and completion; the command has a
small local plan, not a generic host-planning framework.

`--ssh-host` is a native OpenSSH connection mode. DragonTools passes the alias to
OpenSSH and leaves HostName, User, Port, IdentityAgent, IdentityFile, ProxyJump and
other configuration resolution to it. This supports quoted agent socket paths
containing spaces without a Zig SSH-config parser. The user's SSH config is trusted,
including proxy commands. Strict host-key checks, noninteractive operation, and
suppression of raw remote stderr remain enforced. The direct `--host` fallback
retains explicit `--user`, `--port` and authentication options without inherited
config. Mixing alias and direct connection options fails before SSH.

Inspection runs as the SSH login user, so a default target is not accidentally
changed to root by transport-level sudo. Normal account lookup determines the
target UID, group, home and current shell, including for `--target-user`; home paths
are never inferred from account names. Missing accounts fail. Home writes run as
the target account. Missing packages require root or noninteractive `sudo -n`;
selecting another target requires root or suitable noninteractive sudo access.
The home must be an existing directory owned by that account. Its ancestors must
be owned by root or that account, with no symlink components or group/world-writable
directories (including `/`). Account home and shell
paths use conservative absolute ASCII path segments (letters, digits, `.`, `_`,
`-`), with no spaces or traversal segments. Conflicting `.oh-my-zsh` or `.zshrc` path types are
refused rather than replaced. Account policy and existing ownership remain intact.

zsh is installed only when missing, using noninteractive apt on Ubuntu/Debian.
The command also installs curl or CA certificates only when required for a missing
Oh My Zsh download. Apt indexes are refreshed only when a missing package requires
installation. Basic account and filesystem utilities, tar, and SHA-256 tooling
are prerequisites. This is concrete package handling for this command, not a
generic package manager abstraction.

New Oh My Zsh installations pin commit
`0ee67f042872d1dfab74270c31867771ca35aef4` from the
[official upstream repository](https://github.com/ohmyzsh/ohmyzsh/commit/0ee67f042872d1dfab74270c31867771ca35aef4).
The official immutable [source archive](https://codeload.github.com/ohmyzsh/ohmyzsh/tar.gz/0ee67f042872d1dfab74270c31867771ca35aef4)
has SHA-256 `73a7017cd5cde1d76b4044df9f100c6aeae0feb9820e8529f8c90063d2af3cb9`,
calculated locally from that archive. Upstream does not publish an independent
checksum for this source snapshot; this pin trusts the reviewed upstream account
and archive, not an independent publisher signature. Runtime installation uses
the literal revision and digest, HTTPS-only bounded downloads, and private staging.
The reviewed archive contains regular files, directories and nine internal relative
symlinks, with no hardlinks, devices, traversal or members beneath a symlink. The
digest is checked before extraction; unrecognized content is not accepted.
It never executes the upstream interactive installer or pipes a download to a shell.
The installed source has no `.git` checkout and is not updated by this command.

Recognizable existing Oh My Zsh directories are left untouched, including local
changes and branch state. Existing regular `.zshrc` files are preserved byte-for-byte,
with their ownership and permissions unchanged, even if they do not load Oh My Zsh.
An absent `.zshrc` receives only the usual `ZSH="$HOME/.oh-my-zsh"`,
`ZSH_THEME="robbyrussell"`, `plugins=(git)` and `source "$ZSH/oh-my-zsh.sh"`
configuration. Publication must not overwrite a file that appears concurrently.
The new `.zshrc` is owned by the target account with mode 0644.
The result reports the current shell and a manual `chsh` suggestion when appropriate;
DragonTools never runs it.

Each run inspects actual state. An unchanged run makes no package, download,
directory, file-content or ownership changes and reports `No changes required.`.
Private download/extraction staging prevents a partial final directory from being
mistaken for a complete installation. Rerunning after package or directory creation
continues from observed state and creates only missing pieces; it never deletes
unrelated temporary user data. Ordinary failures clean up their own private staging.
An uncatchable interruption can leave a unique `.oh-my-zsh.dragontool.*` or
`.zshrc.dragontool.*` directory; reruns use fresh staging and do not adopt or purge
those leftovers. Local `--plan` makes no SSH connection and therefore
does not claim to know the alias's resolved user, home, or existing remote state.

Local unit/fake-remote and CLI checks do not prove compatibility with a real apt
transaction, SSH configuration, or user's shell environment. Disposable-host
integration remains a separate validation gate described in the integration checklist.

## Storage

`src/monitoring/policy.zig` defines the fixed policy values consumed by the
three storage components, local alert rendering, and the install plan.

| Signal | Policy | State |
| --- | --- | --- |
| Metrics | `-retentionPeriod=90d`, `-storage.minFreeDiskSpaceBytes=ceil(capacity/5)` (20% reserve) | Implemented installation; existing behavior preserved |
| Logs | `-retentionPeriod=100y`, `-retention.maxDiskUsagePercent=75`; the pinned implementation budgets log partition bytes against total filesystem capacity | Implemented VictoriaLogs native retention |
| Traces | `-retentionPeriod=100y`, `-retention.maxDiskUsagePercent=75`; the pinned implementation budgets trace partition bytes against total filesystem capacity | Implemented VictoriaTraces native retention |

Capacity uses `stat -f` on the actual data directory; available space is not mistaken
for capacity. No automatic storage-file deletion. Reserve is a stop-ingestion
threshold, not a quota. A resized filesystem requires reinstallation; verification
recomputes the expected unit and catches a stale reserve. Shared-filesystem
capacity must be budgeted across all three backends. They share a filesystem unless the
operator mounts separate storage; their reserve and cleanup settings do not
isolate them from one another or from other writers.

Filesystem states: below 60% healthy; ≥60% informational; ≥70% warning; ≥80%
critical. The native logs/traces settings are both 75%, with the partition-budget
distinction described below. Logical
`100y` retention expresses a long maximum history, not a promise of 100 years of
stored data. No manual VictoriaLogs/VictoriaTraces file deletion is permitted.
VictoriaMetrics continues to use its free-space reserve and 90-day retention.

All disk alert states remain policy only: host rendering is unavailable until the
Vector metric contract is verified. No alert evaluation runs on the target.
`monitoring install --plan` describes all three installed components and lists
unavailable integrations separately.
There are no new CLI policy overrides or rule-deployment options.

Both VictoriaLogs `v1.52.0` and the storage dependency pinned by VictoriaTraces
`v0.11.0` implement the percentage setting as a budget: 75% of total filesystem
capacity compared with that backend's own partition bytes (compressed data and
indexes). The comparison excludes unrelated writers. Every roughly 10 seconds
with jitter, cleanup can remove oldest partitions while preserving the newest two
daily partitions; gaps can make these span more than two calendar days.

This corrects the previous broad description of a total-filesystem-usage trigger.
Neither pinned release implements that global trigger with this flag. Their
independent budgets can together exceed available storage, and unrelated writers
can fill the disk earlier. The policy goal remains long safely fitting history,
but the implemented control is a native partition budget, not a shared-disk
ceiling. `100y` is a logical limit, not a history guarantee. No mutually exclusive
byte-based retention setting or manual deletion is added. Capacity/headroom
planning remains necessary. [VictoriaLogs pinned implementation](https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.52.0/lib/logstorage/storage.go#L826-L871), [VictoriaTraces pinned storage dependency](https://github.com/VictoriaMetrics/VictoriaLogs/blob/6ae2da3c11f3/lib/logstorage/storage.go#L826-L871).

Verified upstream sources for implemented flags and artifact pins:

- [Single-node flags and capacity guidance](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/)
- [Retention examples](https://docs.victoriametrics.com/victoriametrics/quick-start/)
- [Pinned official release](https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.151.0)
- [Pinned release metadata](https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/tags/v1.151.0)
- [Pinned VictoriaLogs release](https://github.com/VictoriaMetrics/VictoriaLogs/releases/tag/v1.52.0)
- [VictoriaLogs release metadata](https://api.github.com/repos/VictoriaMetrics/VictoriaLogs/releases/tags/v1.52.0)
- [Pinned VictoriaTraces release](https://github.com/VictoriaMetrics/VictoriaTraces/releases/tag/v0.11.0)
- [VictoriaTraces release metadata](https://api.github.com/repos/VictoriaMetrics/VictoriaTraces/releases/tags/v0.11.0)

Checksums are embedded in `src/components/victoriametrics.zig`,
`src/components/victorialogs.zig`, and `src/components/victoriatraces.zig`. Each is a
deliberately reviewed release pin; installation never resolves mutable `latest` metadata or downloads
unchecked runtime checksum files. Version changes must
review both architectures and independently recheck archive and extracted binary
hashes. Health success alone is insufficient to approve a component version.

## VictoriaLogs installation and verification

The second component uses `/opt/dragontools/components/victorialogs/v1.52.0/` with
an atomic `current` symlink and the expected `victoria-logs-prod` executable.
Archive hashing precedes extraction of that one named regular file; executable
hashing precedes atomic installation. A dedicated `dt-victorialogs` account owns
only `/var/lib/dragontools/victorialogs` (0750). Root owns binaries, parent paths,
and the managed `dragontools-victorialogs.service`. Unexpected symlinks, unrelated
units, conflicting users and service drop-ins cause a safe refusal.

The concrete hardened unit passes the fixed storage/retention flags and binds
`-httpListenAddr=127.0.0.1:9428`. No authentication or external ingestion gateway
is configured. Private temporary/device namespaces are allowed, persistent writes
are limited to the data directory, and no capabilities are granted. The requested
hardening directives have no intentional relaxation; no MemoryMax is selected
without a workload-tested budget. Real systemd compatibility is an integration gate.

Changes set `/var/lib/dragontools/victorialogs-restart-required` before activation.
A failed verification leaves restart intent intact; a later install repairs and
restarts VictoriaLogs without restarting unchanged VictoriaMetrics. Inactive
services start, disabled services enable, and healthy matching components require
no restart. There is no whole-install rollback if VictoriaLogs fails after
VictoriaMetrics succeeds.

Verification compares the managed unit and running configuration against policy,
checks active and disk executable identity, effective service hardening, the loopback
listener, bounded HTTP health, and VictoriaLogs-specific `/metrics` output.
The loaded unit must use the managed path and need no daemon reload; managed
directories, binary, and unit must retain their expected types, owners, and modes.
`vl_storage_is_read_only` must be zero; missing identity or read-only storage fails
verification and cannot finalize the component. No synthetic log or remote
application ingestion is required, so success does not demonstrate an application
log pipeline. `monitoring verify` checks all three installed components; `status`
reports their service states without claiming full health or active alerts.

## VictoriaTraces installation and verification

VictoriaTraces `v0.11.0` is the third concrete component. Both amd64 and arm64
archives and their published checksum assets are verified against official release
metadata; the extracted regular `victoria-traces-prod` binary is independently
hashed. Runtime installation uses those literal pins, bounded HTTPS downloads,
expected-file-only extraction, and atomic binary/current-link replacement.
Previous version directories are retained. Root owns
`/opt/dragontools/components/victoriatraces/v0.11.0/`; the non-login
`dt-victoriatraces` user/group owns `/var/lib/dragontools/victoriatraces` (0750).

The dedicated `dragontools-victoriatraces.service` binds
`-httpListenAddr=127.0.0.1:10428` and explicitly disables the extra gRPC listener
with `-otlpGRPCListenAddr=`. It uses the policy's `100y`/`75` native retention flags,
never the mutually exclusive byte-based flag. It applies the full requested
hardening baseline without intentional relaxation, grants persistent writes only
to its own data path, and uses empty capability sets. Private temporary storage
and standard pseudo-devices remain available; MemoryMax is deferred pending
workload/capacity testing.

Verification checks active/enabled state, exact managed/loaded unit and running
arguments, pinned disk/running executable hashes, current link, loopback listener,
bounded HTTP health, effective hardening, and managed-path metadata. The exact
`vt_storage_is_read_only{path="/var/lib/dragontools/victoriatraces"}` metric must
exist once and equal zero. This proves the pinned application's reported writable
storage state, not application trace arrival or OTLP end-to-end behavior. No
synthetic traces are injected. [Pinned application metric source](https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.11.0/app/vtstorage/main.go#L639-L651).

## Safe reruns across all mutating workflows

The remote host is the source of observable state; there is no controller-side
state database. Every run inspects resources and service state rather than
assuming the previous deployment finished. Correct users, directories, valid
pinned binaries, and matching units are no-ops. Conflicting accounts and unexpected
symlinks fail. Supported metadata repair changes only required owner/group/mode,
without restarting healthy services. Valid binaries are reused without download.

Each component owns its restart marker, including
`/var/lib/dragontools/victoriatraces-restart-required`. Binary/current-link or unit
content changes preserve restart intent before activation. Activation reads
systemd's loaded unit state; `daemon-reload` happens only when needed, not merely
because a binary changed. Inactive services start; disabled services enable;
unchanged active/persistently enabled services keep their processes. Runtime-only
enablement is repaired persistently. A VM, VL, or VT change
cannot restart either unrelated healthy component.
Enabling a disabled unit changes global systemd state and requires a subsequent
reload, but must not restart the active service. A global `NeedDaemonReload` flag
alone never marks a component for restart. Manual drift in running configuration
may instead fail verification and require operator correction; automatic repair
of every out-of-band runtime change is not claimed.

Failed health and interrupted deployments retain restart intent. The next install
repairs/resumes from actual state and removes each marker only after successful
verification. Existing markers need not be rewritten. Standalone verification is
always read-only: it cannot repair files, reload/start/restart/enable services, or
clear restart markers. There is no whole-install rollback or automatic deletion;
operators serialize installs per host.

## Agents and local journal safety: next vertical slice

`monitoring agents install --service orderflow.service --service whoami.service`
will validate all units before mutation. Vector reads selected journal units;
Vector also collects host metrics for VictoriaMetrics; vmagent scrapes application
Prometheus `/metrics` endpoints and forwards them to VictoriaMetrics. OTel Collector
accepts application OTLP locally and forwards traces to VictoriaTraces. The exact
systemd service-state solution is deferred. No external trace listener is implied.

Before installing, inspect effective journald configuration/drop-ins, persistence,
`journalctl --disk-usage`, filesystem capacity and each selected service's
StandardOutput/StandardError and direct file logging. Proposed managed drop-in:
`/etc/systemd/journald.conf.d/90-dragontools.conf`, SystemMaxUse=512M,
SystemKeepFree=1G, RuntimeMaxUse=128M, RuntimeKeepFree=256M. Adapt to smaller volumes,
preserve stricter administrator bounds and refuse conflicting configuration until
resolved. Do not silently override unrelated settings or claim direct file logs
are bounded by journald. Inspect later-sorting drop-ins. Verify effective bounds,
forwarder health and actual station arrival after installation. This is deferred;
no agent install can succeed without it.

## Firewall and TLS: fail closed until complete

Own only monitoring rules, ideally one dedicated nftables table; do not flush
unrelated rules or casually change global policy. Inspect active SSH source and
port, verify requested admin allowance, stage a timed rollback and reconnect over a
new SSH connection before canceling it. Cover IPv4 and IPv6. Agent IPs must never
inherit access to Grafana, SSH or backend administrative routes. No rules are emitted
or applied in this milestone; a meaningful firewall-generation test awaits the
implementation instead of blessing an unsafe placeholder.

DNS-01 modes will be manual and Cloudflare DNS-only (proxy not required).
Manual flow displays the actual ACME TXT name/value, waits for propagation and
continues the challenge. Cloudflare uses a minimum-permission DNS-edit token scoped
to the monitoring zone, never a global API key. Both require real certificate
validation and renewal behavior before reporting success. No fake challenges or
self-signed certificate success. `monitoring tls renew` remains future work.

Persistent secrets will use `systemd-creds` encrypted root-only storage and
`LoadCredentialEncrypted=`; an explicit protected-file fallback would use
`LoadCredential=` and root:root 0600. TLS/notification consumers read only the systemd
credential path. The current opaque Secret infrastructure redacts and wipes; no
resolver/storage consumer exists, so relevant CLI options fail before SSH.

## Alert policy and partial rendering

The alert policy remains defined in `src/monitoring/policy.zig`. Host and service
rendering is deliberately unavailable until the agent slice establishes real
signal contracts. `renderHosts` returns `HostMetricContractUnavailable`.
`renderServices` returns `ServiceMetricContractUnavailable` for requested units;
an empty list returns `groups: []`. No stale collector-specific expressions or
unverified Vector metric names are emitted. Systemd service-state monitoring is
intentionally deferred.

The retained policy describes these intended alerts, not deployable rules:

| Group | Rule | Policy condition and hold duration |
| --- | --- | --- |
| Host | HostDown | Unavailable host signal for 2 minutes; exact signal deferred |
| Host | CPUHigh | Non-idle CPU usage >90% for 10 minutes |
| Host | MemoryPressure | Memory usage >90% for 5 minutes |
| Host | DiskWarning | Filesystem usage >=70% for 5 minutes |
| Host | DiskCritical | Filesystem usage >=80% for 5 minutes |
| Host | InodesCritical | Inode usage >=90% for 5 minutes |
| Service | ServiceDown | Selected service down for 2 minutes; state signal deferred |
| Service | ServiceRestartLoop | At least 3 restarts over 5 minutes, sustained for 1 minute; counter deferred |

The host metric contract will be established by the Vector agent implementation.
vmagent will scrape application Prometheus endpoints. Installing the three storage
backends does not supply host or service telemetry. The inode policy leaves 10%
headroom and waits 5 minutes to avoid transient notifications; actual filesystem
selection, label mapping, and signal availability must be verified later.

`renderLogs` remains a small deterministic local YAML renderer using the policy
module, without a template engine or SSH. Its separate `type: vlogs` group is
provisional until the ingestion and evaluator paths are verified:

| Rule | Condition |
| --- | --- |
| ErrorBurst | At least 5 normalized `error` events per service over 5 minutes; no additional hold |
| CriticalLogEvent | At least one normalized `critical` or `fatal` event per service over 1 minute; no additional hold |

These are internal APIs; no rule-export or deployment CLI command is introduced.
Alert policy is defined, rendering is partial/provisional, and alert runtime is
unavailable.

Log rules depend on normalized structured fields: `timestamp`, `level`, `service`,
`host`, `environment`, `request_id`, `event`, and `duration_ms`. Severity matches
exact structured values through `level:in(error)` and `level:in(critical,fatal)`;
arbitrary message text does not establish severity. The queries use `_time:5m`
or `_time:1m`, then group with `stats by (service) count()` and filter the count.
Counts combine events sharing the same service value across hosts; callers must
provide consistent service naming. Missing service values form one unnamed group
until the future ingestion path normalizes them. Log annotations identify the service and count,
without copying log messages, request IDs, or secret fields.

The provisional log group specifies evaluation every minute. CriticalLogEvent has
no `for:` delay and would fire on the next matching evaluation once deployed;
no evaluator or synchronous delivery is present now.
ErrorBurst avoids alerting for each ordinary error, though overlapping windows can
keep an alert active. Later Alertmanager grouping/deduplication controls delivery.
Generated log rules have stable `severity` and `source` labels and concise
service/count summaries.

Upstream supports `type: vlogs` and the log-query statistics/filter pipeline.
Each vmalert process uses a configured datasource URL, so metrics and logs must
eventually use separate evaluator instances or explicitly verified datasource
routing. A `vlogs` group alone does not route a query to VictoriaLogs. The explicit
`_time` windows are intended for live evaluation; upstream does not support those
custom windows for replay/backfill. [VictoriaLogs alerting documentation](https://docs.victoriametrics.com/victorialogs/vmalert/).

Unit tests cover policy values, explicit host/service-rendering refusal,
deterministic log YAML, thresholds, durations, labels, and basic structure. No
real evaluator or application log pipeline is exercised by renderer tests. A later
slice must verify the Vector host metric contract, the service-state solution,
expression syntax against pinned releases, datasource routing, event-time mapping,
ingestion latency/window boundaries, and end-to-end alert evaluation before
installing or claiming any pack is active.

## Grafana, alert deployment and Telegram: roadmap

Provision datasources for all three signal backends; dashboards: Host Overview,
Monitoring Station, Service Health, Storage, Updates / Security. A complete station
must verify datasource queries rather than only Grafana HTTP readiness.

No generated rules are deployed or evaluated by the current installation.
vmalert, Alertmanager, Grafana, Vector, vmagent, and OTel Collector installation
remain explicitly unavailable, as do Telegram, agents, firewall, and TLS.
Rendering rules does not install a complete monitoring station or enable alerts.

Beyond the defined host/service policy and provisional log pack, later rules will include:

| Group | Planned rules (not rendered yet) |
| --- | --- |
| Pipeline | LogsNotArriving, MetricsNotArriving, VectorForwardFailure, VmagentForwardFailure, MonitoringDiskPressure |
| Updates | SecurityUpdatesPending, CriticalSecurityUpdatePending, SecurityUpdateInstallFailed, RebootRequired, MonitoringComponentUpdateAvailable, MonitoringAgentUpdateAvailable, OSReleaseNearEndOfSupport, OSReleaseUnsupported, UpdateCheckFailed, UpdateCheckStale |

Optional Telegram: vmalert → Alertmanager → bot → channel/chat. Read bot token from
credentials, group/deduplicate warning and critical alerts, include resolved alerts,
and send a clearly labeled test alert during installation verification. API
acceptance alone must not be presented as proven delivery to a human. No first-class
notification providers beyond Telegram in v0.x.

## Update monitoring and maintenance: roadmap

Track VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana, vmalert, Alertmanager,
ingress/TLS and DragonTools helper releases; agent side vmagent, Vector, OTel and
host metrics/helper components. Use trusted upstream/distro metadata, bounded timeouts,
atomic results, last-success timestamps and explicit unknown/failure states.

OS categories: kernel, OpenSSH, OpenSSL, libc, systemd, CA certificates and Ubuntu
security origins; report reboot-required and lifecycle/EOL. Do not invent CVE
severity: CriticalSecurityUpdatePending requires authoritative data or remains
unknown/unavailable. No generic vulnerability scanner.

Default policy allows automatic OS security patches, not ordinary OS upgrades;
components notify only; automatic reboot disabled. Report successful installed
security patches, failed installations, reboot need, component availability, failed
or stale checks. Policy is documented/modelled only; no unattended-upgrades files
are modified yet. Future maintenance runs as a local oneshot/timer, with no listener
and no remote command channel. Future explicit upgrades must verify new artifacts,
preserve previous versions, restart affected services and verify before success.

## Complete-stack verification gate

Later station completion requires healthy VictoriaMetrics/Logs/Traces, Grafana,
vmalert and Alertmanager; working datasource queries; visible host metrics;
storage controls; active fresh update checks; Telegram test if configured; valid
TLS if configured. Agent completion requires Vector/vmagent/OTel health, bounded
journald, reachable station, actual logs and metrics arrival, a working trace path,
and fresh maintenance checks. These are not current test claims.

See README non-goals. The scope remains one node, systemd, trusted infrastructure,
network-based authorization and explicit workflows rather than generic management.
