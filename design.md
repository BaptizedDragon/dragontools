# Design decisions and staged delivery

## Current milestone: metrics and logs implemented

The foundation delivers two concrete slices, VictoriaMetrics and VictoriaLogs,
while rejecting unfinished integrations before connecting. Exit 0 from install
means both passed verification; it never means the full requested station exists.
`status` is a read-only service-state summary; use `verify` to test health.
Help and `--plan` require no SSH. No generic primitives are public commands.

Zig 0.16.0 and its standard library handle CLI parsing, process execution, memory,
formatting and JSON. Controller relies on OpenSSH; the remote uses reviewed small
shell fragments as system interfaces, not a configuration DSL. No third-party Zig
dependencies. Hostnames, users, paths, service units, IPs and secret references are
validated; dynamic values are independently shell-quoted. Unknown/duplicate scalar
flags fail. Repeated list flags are supported.

The full target is Ubuntu 24.04/26.04, amd64/arm64; only those pass detection.
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
implemented VictoriaMetrics and VictoriaLogs slices; roadmap settings require explicit opt-in and
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
Users install the generated file and configure their own shell; v0.x never edits
startup files. Contextual `--help` works for each command and command group.

Scripted input/output unit tests cover the helper without spawning terminals.
Completion metadata/rendering tests and CLI smoke tests cover hierarchy, enum and
flag contexts, non-TTY behavior, and local-only help/completion. These UX changes
leave the remote component and integration-validation boundary unchanged.

## Storage

`src/monitoring/policy.zig` defines the fixed policy values consumed by the
VictoriaMetrics and VictoriaLogs components, local alert renderers, and install plan.

| Signal | Policy | State |
| --- | --- | --- |
| Metrics | `-retentionPeriod=90d`, `-storage.minFreeDiskSpaceBytes=ceil(capacity/5)` (20% reserve) | Implemented installation; existing behavior preserved |
| Logs | Maximum safely fitting history, `-retentionPeriod=100y`, `-retention.maxDiskUsagePercent=75` | Implemented VictoriaLogs native retention |
| Traces | Maximum safely fitting history, logical `100y` limit, native cleanup at 75% filesystem usage | Code-level policy only; installation and pinned native flags are deferred |

Capacity uses `stat -f` on the actual data directory; available space is not mistaken
for capacity. No automatic storage-file deletion. Reserve is a stop-ingestion
threshold, not a quota. A resized filesystem requires reinstallation; verification
recomputes the expected unit and catches a stale reserve. Future shared-filesystem
allocation must budget logs/traces together, rather than give each the same entire
free space budget. Metrics and logs currently share a filesystem unless the
operator mounts separate storage; their reserve and cleanup settings do not
isolate them from one another or from other writers.

Filesystem states: below 60% healthy; ≥60% informational; ≥70% warning; ≥80%
critical. The separate 75% cleanup target uses native VictoriaLogs retention;
VictoriaTraces support and its pinned flags are still deferred. Logical
`100y` retention expresses a long maximum history, not a promise of 100 years of
stored data. No manual VictoriaLogs/VictoriaTraces file deletion is permitted.
VictoriaMetrics continues to use its free-space reserve and 90-day retention.

The local renderer implements warning and critical disk rules; the informational
60% state is defined in policy but has no rule in this bounded pack. No alert
evaluation or traces cleanup runs on the target yet. `monitoring install --plan`
describes both installed components and lists unavailable integrations separately.
There are no new CLI policy overrides or rule-deployment options.

VictoriaLogs deletes oldest daily partitions when the containing filesystem
exceeds 75% usage. Its periodic checks and retention of at least the newest two
days mean usage can exceed the target. A full disk can leave storage read-only,
so adequate capacity and headroom remain necessary. DragonTools does not enable
the mutually exclusive byte-based retention option or manually remove partitions.
These controls keep the longest useful history that fits; they do not guarantee
100 years or a strict 75% ceiling. [Upstream retention controls and limitations](https://docs.victoriametrics.com/victorialogs/#retention-by-disk-space-usage).

Verified upstream sources for implemented flags and artifact pins:

- [Single-node flags and capacity guidance](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/)
- [Retention examples](https://docs.victoriametrics.com/victoriametrics/quick-start/)
- [Pinned official release](https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.151.0)
- [Pinned release metadata](https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/tags/v1.151.0)
- [Pinned VictoriaLogs release](https://github.com/VictoriaMetrics/VictoriaLogs/releases/tag/v1.52.0)
- [VictoriaLogs release metadata](https://api.github.com/repos/VictoriaMetrics/VictoriaLogs/releases/tags/v1.52.0)

Checksums are embedded in `src/components/victoriametrics.zig` and
`src/components/victorialogs.zig`. VictoriaLogs `v1.52.0` is a deliberately reviewed
stable pin; installation never resolves mutable `latest` metadata or downloads
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
log pipeline. `monitoring verify` checks both installed components; `status`
reports both service states without claiming full health or active alerts.

## Agents and local journal safety: next vertical slice

`monitoring agents install --service orderflow.service --service whoami.service`
will validate all units before mutation. Vector reads selected journal units;
vmagent scrapes loopback node_exporter and forwards metrics; OTel accepts application
OTLP locally and forwards traces. No external trace listener is implied.

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

## Default alert rule generation: implemented locally

`src/monitoring/rules.zig` uses small explicit Zig render functions, with no template
engine or remote execution. `renderHosts`, `renderServices`, and `renderLogs`
return deterministic YAML. Metrics rules use Prometheus-compatible expressions;
log rules form a separate VictoriaLogs `type: vlogs` group. These functions are
internal APIs; no new rule-export CLI command is introduced.

The generated pack uses the policy module for these defaults:

| Group | Rule | Condition and hold duration |
| --- | --- | --- |
| Host | HostDown | `up == 0` for 2 minutes |
| Host | CPUHigh | Non-idle node_exporter CPU usage >90% for 10 minutes |
| Host | MemoryPressure | Memory usage from `MemAvailable` >90% for 5 minutes |
| Host | DiskWarning | Filesystem usage ≥70% for 5 minutes |
| Host | DiskCritical | Filesystem usage ≥80% for 5 minutes |
| Host | InodesCritical | Inode usage ≥90% for 5 minutes |
| Service | ServiceDown | Selected systemd unit's active-state signal is zero for 2 minutes |
| Service | ServiceRestartLoop | At least 3 automatic restarts over 5 minutes, sustained for 1 minute |
| Logs | ErrorBurst | At least 5 normalized `error` events per service over 5 minutes; no additional hold |
| Logs | CriticalLogEvent | At least one normalized `critical` or `fatal` event per service over 1 minute; no additional hold |

The inode default leaves 10% headroom and waits 5 minutes to avoid transient
notifications. Filesystem expressions exclude temporary/pseudo filesystems and
compute disk usage as `100 × (1 − available bytes / filesystem size)`.
HostDown covers reported failed scrape
targets; an absent time series or a target removed from scrape configuration is
not the same as `up == 0`. Missing signals and stalled pipelines need later alerts.

`renderServices` accepts an explicit unit list, for example `orderflow.service`
and `whoami.service`. It validates with the existing CLI service validator,
sorts/deduplicates the units, emits exact PromQL name selectors and quoted YAML
service labels, and produces `groups: []` for an empty list. It never discovers
services or interpolates units into executable shell text. Agent installation and
the existing `--service` CLI path remain unavailable.

Future agents must enable `--collector.systemd` and
`--collector.systemd.enable-restarts-metrics` before deploying these service rules.
The source exposes `node_systemd_unit_state` and
`node_systemd_service_restart_total{name="..."}`; the latter comes from systemd's
`NRestarts` property and requires systemd ≥235. These are planned collector
requirements, not currently configured agent behavior. [node_exporter systemd collector source](https://github.com/prometheus/node_exporter/blob/master/collector/systemd_linux.go).
The counter represents automatic restarts, not an audit of every manual restart. [systemd restart counter scope](https://github.com/systemd/systemd/issues/29348).

Log rules depend on normalized structured fields: `timestamp`, `level`, `service`,
`host`, `environment`, `request_id`, `event`, and `duration_ms`. Severity matches
exact structured values through `level:in(error)` and `level:in(critical,fatal)`;
arbitrary message text does not establish severity. The queries use `_time:5m`
or `_time:1m`, then group with `stats by (service) count()` and filter the count.
Counts combine events sharing the same service value across hosts; callers must
provide consistent service naming. Log annotations identify the service and count,
without copying log messages, request IDs, or secret fields.

The log group evaluates every minute. CriticalLogEvent has no `for:` delay and
fires on the next evaluation with a matching event; it is not synchronous delivery.
ErrorBurst avoids alerting for each ordinary error, though overlapping windows can
keep an alert active. Later Alertmanager grouping/deduplication controls delivery.
Every rule has stable `severity` and `source` labels and a concise summary with
host/service context and the signal where practical.

Upstream supports `type: vlogs` and the log-query statistics/filter pipeline.
Each vmalert process uses a configured datasource URL, so metrics and logs must
eventually use separate evaluator instances or explicitly verified datasource
routing. A `vlogs` group alone does not route a query to VictoriaLogs. The explicit
`_time` windows are intended for live evaluation; upstream does not support those
custom windows for replay/backfill. [VictoriaLogs alerting documentation](https://docs.victoriametrics.com/victorialogs/vmalert/).

Unit tests cover policy values, deterministic output, requested-service selection,
escaping, thresholds, durations, labels, and basic YAML structure. No real
VictoriaLogs, node_exporter, or vmalert runtime is exercised by these renderer
tests. A later vertical slice must verify collector flags and labels, actual
automatic restart signals, expression syntax against pinned releases, datasource
routing, event-time mapping, ingestion latency/window boundaries, and end-to-end
alert evaluation before installing or claiming this pack is active.

## Grafana, alert deployment and Telegram: roadmap

Provision datasources for all three signal backends; dashboards: Host Overview,
Monitoring Station, Service Health, Storage, Updates / Security. A complete station
must verify datasource queries rather than only Grafana HTTP readiness.

No generated rules are deployed or evaluated by the current installation.
VictoriaTraces, vmalert, Alertmanager, Grafana, Vector, vmagent,
OTel Collector, and node_exporter installation remain explicitly unavailable.
Rendering rules does not install a complete monitoring station or enable alerts.

Beyond the locally generated host/service/log pack, later rules will include:

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
