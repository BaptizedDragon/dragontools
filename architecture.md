# Architecture

> DragonTools should encode operational knowledge, not merely automate commands.

The public API consists of monitoring workflows and one separate shell-tooling
host utility, without a generic resource DSL.
Small concrete Zig modules render controlled system commands. The controller is
short-lived and connects only via OpenSSH. Managed services run directly under
systemd. There is no persistent remote control daemon, container requirement,
provider abstraction, arbitrary shell hooks, or general plugin framework.

## Implemented boundary

Application repositories use strict `monitoring.toml` v1 and `monitoring apply`.
The controller reads only the current directory's file or an explicit `--config`.
`app-verify` and `app-status` are read-only application commands; station
`install/verify/status` retain their separate central configuration and secrets.

`cli/parse.zig` merges explicit monitoring configuration and validates all supplied
inputs before SSH. CLI values override file values; the small version-1 TOML
schema contains an OpenSSH alias, Grafana/Telegram secret references and bounded HTTP probes. `main.zig` rejects
unimplemented integrations. `monitoring/install.zig` detects the host once, then
installs and verifies VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana,
blackbox_exporter, Alertmanager, vmalert-logs and vmalert-metrics. Each concrete
component workflow handles its account, directories, binary, unit, activation,
verification, and finalization; VictoriaMetrics also computes its capacity reserve.
Host detection checks OS and prerequisites once. Before changing a component,
its account phase checks that component's unit, drop-ins, and restart marker for
conflicts, so a refusal identifies the affected component.
A `Report` records the current component and phase, completed operations, and confirmed changed operations (not an
exact count of every filesystem mutation). Remote failures stop the sequence.
Verification also records a semantic check name, so a failure can identify
`self_scrape_ready` without exposing command text or remote stderr.
Its optional `monitoring/progress.zig` sink receives fixed component/phase enums;
CLI rendering writes each event promptly. Component names precede inspection,
changes are distinguished from verification, and completion reports changed or
unchanged from that component's confirmed change count. Readiness polling emits
one waiting event per component after roughly two seconds. The sink receives no
remote output, options, references or resolved values and cannot change results.

`system/remote.zig` is a minimal command boundary with injectable execution for
unit tests. It is an internal interface, not a public arbitrary execution API.
Every dynamic shell argument is POSIX single-quoted, including embedded quotes;
NUL is rejected. Small static shell fragments use positional parameters.
`system/ssh.zig` spawns argv directly with Zig 0.16 `std.process`; no local shell.
SSH is noninteractive, strict, with connection/keepalive limits and bounded output.
There is no absolute overall deployment deadline yet. Long downloads have their own
curl deadline. Monitoring supports native OpenSSH aliases with `--ssh-host`, or
isolated direct connections with `--host`. Alias mode resolves the actual login
UID remotely before choosing root or `sudo -n`; direct non-root users also require
`sudo -n`. Effective UID 0 is checked before monitoring mutation.
Raw stderr is suppressed and wiped; output summaries never echo arbitrary remote data.

The separate `host install-oh-my-zsh` command uses the same transport boundary
without elevating the initial SSH login session. Its `--ssh-host` mode lets OpenSSH
resolve the user's native configuration, including aliases, identity agents and
jump hosts, while enforcing strict host-key checks. The direct `--host` mode keeps
the existing explicit connection behavior. Host inspection resolves the actual
login account or requested existing target account before any package or home
mutation. It does not create users or invoke monitoring installation.
An absent `.zshrc` receives a marked server prompt with user, hostname and directory.
Existing files remain unchanged unless `--update-managed-zshrc` selects an exact
known DragonTools template; a marker alone does not authorize an update. The separate
`--set-default-shell` option validates the discovered zsh path in `/etc/shells`,
changes only a differing login shell and verifies the account record afterward.

## Current architecture

These components and datasource edges are implemented by monitoring today:

```text
ADMIN LAPTOP                            MONITORING HOST
DragonTools -- strict OpenSSH :22 ----> systemd
  +-- explicit monitoring TOML
  +-- optional local 1Password CLI
      (secret refs -> protected stdin)
Browser 127.0.0.1:3000 -- SSH tunnel --> Grafana OSS 13.2.2
                                          127.0.0.1:3000; local authentication
                                          |
                                          +-- Metrics --> VictoriaMetrics v1.151.0
                                          |               127.0.0.1:8428
                                          |               90d; reserve: 20%
                                          +-- Logs ----> VictoriaLogs v1.52.0
                                          |               127.0.0.1:9428
                                          |               100y; partition budget: 75%
                                          +-- Traces --> VictoriaTraces v0.11.0
                                                          127.0.0.1:10428
                                                          100y; partition budget: 75%

HTTP/HTTPS targets <--- blackbox_exporter 0.28.0 [127.0.0.1:9115]
                              ^ /probe every 30s
                              |
                        VictoriaMetrics native scraper -> stored probe metrics
                              |
                 +------------+-------------------+
                 |                                |
             vmalert-metrics                  vmalert-logs
             127.0.0.1:8881                   127.0.0.1:8880
             datasource: VM                   datasource: VictoriaLogs
                 |                                |
                 +------------+-------------------+
                              v
                    Alertmanager v0.34.1 [127.0.0.1:9093]
                              |
                         Telegram [optional outbound HTTPS]

PUBLIC INBOUND: SSH :22 from administrators; agent ingestion :9443 from monitored
hosts after agent registration (operator-managed firewall, mTLS required).
```

The separate agent workflow adds the mTLS ingestion and logs/metrics path below.
OTel traces agents, dashboards, systemd-service state alerts, monitoring firewall,
public Grafana TLS and frontend telemetry remain unavailable. The controller exits
after each command and keeps no state database.

The independent host utility has no listener or connection to these services:

```text
LOCAL MACHINE                           REMOTE HOST
DragonTools host install-oh-my-zsh
    -- strict OpenSSH alias/direct ---> actual account home
                                          +-- .oh-my-zsh (install if absent)
                                          +-- .zshrc (create if absent;
                                          |   exact managed migration opt-in)
                                       zsh package (install if absent)
                                       login shell (explicit opt-in only)

MONITORING STACK: unchanged by this command
```

## Safe rerun contract

Every mutating command observes actual remote state each time. A first install
converges each concrete component; an unchanged run reuses correct accounts,
directories, pinned binaries, and identical units without unnecessary mutation.
Only supported owner/group/mode repairs are made. Incompatible accounts and
unexpected symlinks fail explicitly. Valid binaries are not redownloaded.

Unit/config/provisioning content changes and binary/current-link changes record restart intent before
activation. Metadata-only repair does not make a healthy service dirty. Activation
inspects loaded unit state and `NeedDaemonReload`; systemd reloads only when that
state requires it, and a binary-only change does not force a reload. Active,
persistently enabled, unchanged services stay running; inactive services start,
and disabled or runtime-only units gain persistent enablement independently.
One component's change never restarts the others.
Enabling uses a subsequent required reload without restarting an already running
service. Global `NeedDaemonReload` alone never creates per-component restart
intent. Out-of-band running configuration drift can fail verification and require
operator correction; it does not trigger a blanket restart of the station.

An interrupted run leaves narrowly scoped, root-owned restart markers. The next
run inspects actual files and service state, resumes pending activation, and clears
each marker only after that component verifies. Existing markers are not blindly
rewritten. Read-only `monitoring verify` never repairs files, reloads systemd,
restarts services, or clears restart intent. No prior run is assumed successful.

`monitoring/readiness.zig` separates one-shot deterministic verification from
bounded runtime probes. Managed units, artifact hashes, symlinks, service users,
hardening, actual process arguments and unexpected public listeners fail without
retry. Activation gets 15 seconds, HTTP readiness 30 seconds, and telemetry or
datasource readiness 45 seconds. Probes run immediately; only a not-ready result
schedules a 500 ms first retry, then 1-second intervals. The remote boundary has
an injectable clock so tests exercise deadlines without real sleeps. A successful
delayed probe follows ordinary finalization; a timeout keeps the component's
restart intent. No readiness probe mutates remote state.

## CLI metadata and interactive frontend

Interactive mode is a frontend to the regular DragonTools command model, not a
separate deployment engine. `cli/spec.zig` describes the command hierarchy, flag
contexts, value kinds, enum choices, and help text. Parsing, hierarchical help,
completion generation, and wizard command assembly share that metadata. The strict
parser remains authoritative: wizard answers use its validators, and the assembled
argv is parsed before the ordinary dispatch path handles availability, `--plan`,
or the existing remote workflow. No wizard-specific planner or installer exists.

`dragontool wizard` and a no-argument invocation with terminal stdin/stdout enter
the same helper. No arguments in a pipe print help without reading stdin; an explicit
wizard without both terminals fails promptly. Small injectable input/output
callbacks allow scripted wizard tests without creating a real terminal. Plain ASCII
prompts work with `NO_COLOR`, `TERM=dumb`, and without a terminal UI dependency.

The wizard previews shell-quoted equivalent argv and a human-readable summary.
Preview is a deliberate local UI surface for the user's validated choices; diagnostic
logs continue to suppress CLI values and remote command text. Credential references
may appear only as references, never expanded secrets. Information, preview, and
plan paths never SSH or resolve credentials. Mutation requires explicit Apply and a
separate default-No confirmation. EOF, `quit`, and Ctrl+C cancel cleanly; `back`
returns within the helper. Roadmap options retain the same before-SSH rejection as
normal CLI flags.

Shell completion is local, deterministic, side-effect free, and never contacts
remote hosts or secret providers. `cli/completion.zig` renders Bash, Zsh, and Fish
definitions from the shared spec; enum values and context-specific flags are not
maintained as independent command trees. Generated scripts use native shell path
completion for path-valued flags. Generation needs no shell executable or network,
and completion installation never edits startup files automatically.

The `host` command group participates in the shared parser/help/completion metadata.
It has a small local plan and regular dispatch, but is not an additional wizard
deployment path. Alias completion never invokes SSH or reads remote account data.

## Monitoring policy and local rule generation

`monitoring/policy.zig` is the single source of truth for fixed storage and alert
defaults. Metrics retain `90d` with the existing overflow-safe
`ceil(filesystem capacity / 5)` reserve. Logs and traces each have a logical `100y`
retention limit and a native 75% setting. In both pinned releases, the setting
budgets each backend's own partition bytes against total filesystem capacity;
other writers are excluded. The operational disk states are 60% info, 70% warning,
and 80% critical. They are policy thresholds, separate from native retention.
Cleanup checks run roughly every 10 seconds with jitter and keep the newest two
daily partitions, potentially spanning more than two days. The two budgets do not
provide a combined shared-filesystem usage ceiling. No manual deletion is added.

The fixed log/probe packs are installed and evaluated. `monitoring/rules.zig`
supplies deterministic VictoriaLogs `type: vlogs` YAML for ErrorBurst and
CriticalLogEvent; `monitoring/probes.zig` supplies ServiceProbeFailed. It includes
stable severity/source labels and concise service/count annotations, without log
payloads, request IDs, or secrets.

The fixed host pack uses the Vector 0.58.0 Prometheus metric contract observed in
an isolated Linux fixture. CPUHigh, MemoryPressure, DiskWarning, DiskCritical and
InodesCritical select `agent="vector"`; they have no input without matching host
metrics. Agent install reconciles the metrics evaluator after signal arrival;
station install also includes the pack. HostDown and systemd service-state rules
remain deferred. `renderServices` refuses requested service rules with
`ServiceMetricContractUnavailable`. Application log alerts and probe overrides
use the bounded application schema; arbitrary expressions and custom metrics
alerts remain unavailable. Renderer tests do not establish full-host
operation or notification delivery.

The ordinary install plan describes all eight available components,
including their private listeners and retention, then explicitly lists unavailable
integrations. A successful installation means all eight components passed their
checks; it does not install application-host agents or dashboards. Unsupported component paths and flags
still fail before SSH; generated YAML does not make a component available.

## Component layout and lifecycle

VictoriaMetrics `v1.151.0`, VictoriaLogs `v1.52.0`, and VictoriaTraces `v0.11.0`
are pinned for both Linux architectures. Archive digests come from official GitHub release metadata;
VictoriaLogs and VictoriaTraces archives are also checked against their published
release checksums.
Executable digests are computed from those verified archives. Literal archive and
binary hashes are embedded in each component module. Remote
curl downloads over HTTPS into a root-owned staging directory on the installation
filesystem. SHA-256 is checked before extracting the named executable and again
before installation. This trusts the reviewed catalog and upstream publishing
account; a checksum is not an independent publisher signature.

Each binary is installed as root:root 0755 inside a version directory; atomic rename
replaces the executable and stable `current` symlink. Existing matching binary hashes
and permissions avoid downloads. VictoriaLogs refuses a nested version mount that
would turn binary replacement into a cross-filesystem copy. Dedicated `dt-victoriametrics`,
`dt-victorialogs`, and `dt-victoriatraces` system users/groups own their respective data directories (0750),
with `/usr/sbin/nologin`. Parent and binary directories stay root-owned. An existing account
must match the expected home, shell and group and have a nonzero UID; otherwise the
installer refuses it. There is no recursive chown of existing storage.

Each root-owned managed unit is compared byte-for-byte and atomically renamed using
an adjacent temporary file. Unmarked preexisting units are refused. A root-owned
restart marker per component is set **before** binary/unit activation changes, so interrupted
installs do not lose the need for a reload/restart. Only changed or inactive services
restart/start. `enable` is called only if needed. Verification confirms the unit,
active process hash/arguments, disk binary hash, service properties, listener, and
health. VictoriaMetrics additionally queries stored self-scraped metrics.
`monitoring/victorialogs_verify.zig` validates the VictoriaLogs application metric
and requires writable storage (`vl_storage_is_read_only == 0`); an arbitrary HTTP
200 is insufficient. It verifies the running retention flags and does not ingest
synthetic application logs. Its read-only checks also reject stale loaded units,
verify the effective hardening properties, and check managed path ownership,
permissions, and unexpected symlinks. Each marker clears only after its component's
verification succeeds. VictoriaTraces uses the analogous dedicated verifier and
requires `vt_storage_is_read_only == 0` for its managed storage path. Verification
is read-only and injects no synthetic traces. A repair or failure leaves unrelated
healthy services running; each component retains its own restart intent for retry.
There is no full transactional rollback. Version directories permit future rollback,
but this release will not silently select a different component version.

Binary staging has a bounded `flock`; the complete multi-connection workflow is not
transaction-locked. Operators must serialize installs per host. Root-controlled
system directories and a trusted target OS are prerequisites. Hardening protects the
service boundary, not a machine already controlled by a malicious administrator.

## Grafana layout, authentication and verification

Grafana OSS `13.2.2` uses a dedicated `dt-grafana` user/group. Its pinned archive
contains the server, built-in datasource implementations and static UI assets;
the integrity boundary covers the full reviewed release tree, not only the Go
executable. Release assets stay root-owned under
`/opt/dragontools/components/grafana/13.2.2/`, selected through `current`.
SQLite, plugins and other persistent state live under `/var/lib/dragontools/grafana`.
Root-owned deterministic files under `/etc/dragontools/grafana` configure the
explicit `127.0.0.1:3000` listener, console logging to journald, local authentication,
and Metrics/Logs/Traces provisioning. The official VictoriaLogs datasource plugin
0.32.0 is pinned independently of Grafana; no dashboard is installed.

The plugin lives under root-owned `plugins-versions/victoriametrics-logs-datasource/`
inside the persistent data area, with an atomically selected link in `plugins/`.
Both roots are read-only in the service mount namespace even though SQLite's parent
is writable. The signed multi-platform package is retained intact and its full
catalog is checked on every run. Grafana's embedded signature key accepts the
reviewed manifest without online key retrieval or an unsigned-plugin exception.
A pinned plugin change records only Grafana restart intent; old releases remain
available after atomic replacement. [Exact plugin pins and trust boundary](design.md#official-victorialogs-datasource-plugin).

Without configured secret references, Grafana's standard `admin` / `admin` fresh
bootstrap flow applies, followed by an immediate password change through the SSH
tunnel. This compatible mode explicitly reports unmanaged administrator credentials
and preserves existing accounts. Configured credentials instead resolve locally
and are authenticated before mutation. Correct credentials require no reset or
restart; a mismatch uses supported Grafana administrator interfaces and is verified
before completion. No plaintext credential is embedded in the unit or ordinary
configuration, and none remains remotely after successful reconciliation. Fresh
setup passes desired values only in the pinned CLI child's environment and stdin before service startup; existing setup authenticates, then
uses CLI password reset and the user API only if needed. The original local
administrator (ID 1) is the explicit account boundary; incompatible accounts or
login collisions fail. No secret temporary files or service EnvironmentFile exist.
Anonymous access, auth proxy and signup remain disabled. Target-local users can
reach loopback, so initialize promptly on a trusted host.

Metrics uses Grafana's built-in Prometheus datasource at `127.0.0.1:8428`;
Logs uses the signed `victoriametrics-logs-datasource` plugin at `127.0.0.1:9428`;
Traces uses the built-in Jaeger datasource at `127.0.0.1:10428/select/jaeger`.
The stores remain independently usable and loopback-only. Grafana provisioning adds no public ingress or firewall rule; the separate
agent workflow manages only its narrowly scoped mTLS ingestion edge.

Grafana changes set only `/var/lib/dragontools/grafana-restart-required` before
publication. Config/provisioning changes require Grafana restart but do not
require a systemd daemon reload unless unit state independently needs one.
Verification checks service state, unit and running identity, installation integrity,
private listener ownership, HTTP identity, configuration, and non-secret datasource
records through read-only SQLite. Queries to the provisioned backend endpoints run
as `dt-grafana`, proving reachability and response contracts. With configured
credentials, verification additionally authenticates a read-only Grafana identity
request and confirms administrator privileges, checks Logs plugin health, then
executes a bounded read-only LogsQL query through Grafana. Empty results are valid.
Verification never changes accounts, resets passwords, writes logs or changes
datasources. Unconfigured verification checks public health, plugin integrity,
managed provisioning and private backend access while explicitly leaving the
authenticated Logs query unchecked. Metrics/Traces query-engine and browser
Save & test/Explore checks remain disposable-host integration gates. Lightweight
status reports expected datasource policy, not authenticated query success.

## Service hardening

The VictoriaMetrics profile uses an empty capability set, no new privileges,
private temporary files, protected home/system/kernel/control groups, restricted
address families, a single data write path, umask 0027, and TasksMax 512. It does not
blindly reuse that profile for Vector, which needs journal access. MemoryMax
is intentionally not imposed without capacity/workload testing. Systemd log rate
limits reduce service log storms but do not substitute for the managed agent journal
capacity policy. Settings are renderer-tested; runtime validation on all supported
Ubuntu/architecture combinations remains an integration gate.

VictoriaLogs and VictoriaTraces have their own concrete unit renderers and accounts, rather than
a generic service DSL. Each profile sets `NoNewPrivileges`, `PrivateTmp`,
`PrivateDevices`, `ProtectHome`, `ProtectSystem=strict`, `ProtectKernelTunables`,
`ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID`, and
`LockPersonality`. Both capability sets are empty. It restricts address families,
uses umask 0027 and TasksMax 512, and grants persistent writes only beneath its
respective `/var/lib/dragontools/victorialogs` or
`/var/lib/dragontools/victoriatraces` data path. Private temporary/device namespaces remain
available. Restart-on-failure has a delay; service journal rate limits are bounded.
All requested hardening directives are represented, with no intentional relaxation.
MemoryMax is omitted until workload/capacity testing establishes a safe bound.
The renderer and fake-remote checks do not prove compatibility under a real systemd
instance; supported Ubuntu/architecture VM runs remain required.

## External probing and alert runtime

Black-box monitoring observes configured HTTP/HTTPS endpoints from the station.
The existing VictoriaMetrics single-node native Prometheus scraper queries local
blackbox `/probe` and directly stores the result. No extra scraper listener,
station vmagent service or custom polling daemon is introduced. Application-host
logs/metrics use the separate agent workflow; tracing remains deferred.

The narrow TOML has at most 64 unique named probes with normalized, query-free,
credential-free HTTP/HTTPS URLs. A generated static blackbox module enforces GET,
2xx success, IPv4 preference/fallback, five-second timeout and verified TLS.
HTTP/2 is explicitly disabled for the reviewed release's transport advisory;
redirects remain enabled. Metric relabeling retains only owned identities and
fixed timing phases, excluding dynamic certificate/response labels.

VictoriaMetrics gains `-promscrape.config` once. Subsequent target changes write
`/etc/dragontools/victoriametrics/prometheus.yml`, preserve a separate scrape-reload
marker and use native `/-/reload`; they do not restart the VM process. Reload intent
is finalized only after loaded targets and fresh stored samples are verified.
Both success and failure samples prove the mechanism; down applications must not
make station installation fail. Status queries stored samples and never triggers
fresh probes. Missing/stale results remain unknown rather than inferred healthy.

Both dedicated vmalert services use the same pinned binary but independent users,
units, rule files and restart markers. A binary replacement marks both instances;
a rule/unit change affects only its own instance. Metrics evaluates the real probe
contract; logs evaluates the fixed structured-log pack against VictoriaLogs.
Remote read/write stores alert state in local VictoriaMetrics, with an in-memory
write queue and no persistent writable path for either evaluator.

Alertmanager runs without clustering and has only its loopback HTTP listener.
Without Telegram refs it uses a discard receiver. Configured install resolves the
bot token/chat ID locally and uses a dedicated protected stdin/file consumer;
ordinary file primitives never receive secret values. Secret files are owned by
`dt-alertmanager`, `0400`, in a protected root-owned directory. Unchanged values
are compared without being printed or rewritten. Standalone verification checks
installed policy without resolving Telegram refs. Only explicit `notify-test`
submits a test alert; verification never does. Normal evaluators may independently
notify genuine firing alerts while installation or verification is running.
The pinned Telegram error path can include the token-bearing request URL, so
Alertmanager's native stdout/stderr are disabled and their effective values are
verified. Systemd state, health/API/metrics and fixed controller errors remain
available; native Alertmanager journal diagnostics are not retained.

## Application ownership and repository workflow

The primary application interface is `monitoring apply`, with read-only
`app-verify` and `app-status`. The strict application schema is distinct from
central station configuration; an application file cannot contain Grafana,
Telegram or other station credentials. Only `./monitoring.toml` is implicit.
An explicit environment and application identity avoid deriving identity from the
repository name. Plan parses locally and displays only validated public config.

Each station namespace `/etc/dragontools/apps/<application>/` has an immutable
application/environment/machine binding, an ownership manifest and generated
`logs.rules.yml`, `metrics.rules.yml` and `scrape.yml`. Ownership requires exact
reproduction from the manifest, not only a comment marker. A recorded previous
generation permits interrupted publication to resume; unrelated files and
unrecognized content are conflicts. Application updates never re-render another
application's documents, central secret configuration or manual Grafana assets.
Removing an alert/probe reconciles only the current application's generated files.

The shared native scraper and two evaluators include narrow app-file globs.
Their initial integration may change shared generated loader configuration;
subsequent changes retain independent VM reload / evaluator restart intent.
Only changed consumers activate, and read-only readiness gates finalization.
Global station install preserves and validates registered application files.
Manual rules elsewhere are never adopted, deleted or rewritten by apply.

Each target has independent app signal manifests under
`/etc/dragontools/agent-apps/`. Only the shared agent configuration is merged from
these target-local files: selected units, private metrics targets and trusted
application identities. Other applications' signal selections survive an apply.
Alert/probe edits do not affect agent desired state. Zero logs/metrics selections
still collect host metrics. Legacy raw agent registrations and repository app
registrations cannot silently adopt each other. Operators serialize applies to a
shared station/target; this is not a distributed transaction or controller database.

Vector/vmagent overwrite application, environment, service and host identity.
The shared Vector host rules preserve application/environment/host grouping;
application log rules use exact scoped fields and bounded counts/windows. Each
probe has one default alert or one explicit override. Native probe telemetry with
`probe_success=0` is a successful monitoring mechanism, not apply failure.
No notification tests or synthetic application errors run during apply/verify.

Dashboards remain unimplemented. Future generated dashboards must use folder
`DragonTools / <application>` and deterministic UIDs, with explicit ownership.
Manual assets outside that folder/UID are untouched; unmanaged conflicts fail
until a specific opt-in adoption mechanism exists. Arbitrary Grafana JSON upload
is not part of the application contract.

## Monitored-host architecture: logs and metrics implemented

```text
CONTROLLER                     APPLICATION HOST                 STATION
OpenSSH aliases ----------->   systemd + selected units          systemd
                          +-----------------------------------> registration/CA
                               journald -> Vector 0.58.0 --mTLS---+
                               host_metrics + internal_metrics -+|
                               app /metrics -> vmagent v1.152.0 -+|
                                                                v
                                            ingestion [0.0.0.0:9443, mTLS]
                                               /api/v1/write -> VM:8428
                                               /insert/jsonline -> VL:9428

App-only listeners: Vector telemetry 127.0.0.1:8686; vmagent 127.0.0.1:8429.
All station backends, Grafana and alert listeners remain loopback-only.
Unavailable edge: application OTLP -> OTel Collector -> VictoriaTraces.
```

`cli/parse.zig` validates required station aliases, bounded unique service names,
and explicit private application targets before SSH. Remote services must match
the selected canonical systemd `Id` and have no `LogNamespace`, checked before
registration. Station aliases resolve via
native OpenSSH configuration; their effective DNS/IPv4 `HostName` becomes the
agent-reachable endpoint. The controller contacts both hosts with verified keys.
The application machine ID supplies stable `dt-<32 hex>` identity. A small
station registration records services, targets and certificate fingerprint; there
is no controller state database or discovery system.

Vector reads only configured journald units and rewrites host/service identity
from trusted inputs while preserving selected structured application fields. It
also emits bounded stream metadata every 30 seconds, distinct from application
logs, to prove quiet-stream arrival without synthetic error events. It gathers
CPU, memory, filesystem/disk and network metrics with its native host source, and
forwards internal delivery/buffer telemetry. Its API is disabled; the loopback
exporter exposes internal telemetry. vmagent exists only for explicit application
endpoints, scrapes itself for queue/failure telemetry, disables redirect following
and uses trusted host/app labels. No port/process discovery or node_exporter exists.

Dedicated accounts and separate restart markers isolate Vector, vmagent and the
ingestion service. Binary publication is pinned, checksum verified and atomic.
Unit/config/certificate changes mark only their consumer before publication.
Actual configuration is checked on each run. Activation, read-only verification
and finalization remain separate; timeout retains intent. Standalone verify and
status read saved registration when selections are omitted and never repair it.
Signal verification queries station storage, requiring host samples younger than
90 seconds, selected-service log streams within two minutes, and app target
`up=1` plus a recent real metric. Install/verify additionally require samples after
the current agent process start; old samples cannot validate a changed scrape URL.
The hosts need synchronized clocks because Vector supplies agent timestamps.
These use the ordinary 45-second telemetry
readiness budget, not fixed sleeps. Missing signals fail installation.

The station ingestion service runs as `dt-ingest`, requires TLS 1.2+ and a
registered client certificate, and permits fixed write routes plus authenticated
health. It never forwards arbitrary methods, paths, URLs or request headers. Logs
must name a registered service; host identity comes from registration. The metrics
route supplies the authenticated host label. Raw storage/admin APIs remain on
loopback, including VictoriaTraces with its extra gRPC listener disabled. Neither
Grafana nor Alertmanager is exposed. The operator must allow TCP 9443 from
monitored hosts; DragonTools performs no firewall mutation.

CA/private issuance material stays root-private on the station. Each service
receives only its client bundle via protected SSH output, opaque wiped controller
memory and protected stdin; mode-0400 private keys never enter ordinary file
primitives, arguments or logs. Equal bundles and registrations are no-ops. Existing
unrecognized paths/credentials are refused. Automatic certificate rotation and
hard tenant isolation are deferred: the controller/station/app roots and CA are
trusted, and a compromised registered agent can submit arbitrary metric content
for its own authenticated host. The station enforces host identity even against a
forged submitted label, verified with the pinned native backend.

The application journal is bounded by a managed drop-in only when effective
administrator settings are insufficient. Limits are calculated from filesystem
capacity: min(1 GiB, 5%) persistent, min(256 MiB, 2%) runtime, seven-day retention.
Stricter existing limits and unrelated configuration are preserved. Two Vector
disk sinks each cap at 268435488 bytes and block when full; vmagent's queue caps
at 1 GiB and may drop oldest blocks. A prolonged outage can lose data as buffers
or journal retention expire, while disk usage stays bounded. Direct application
file logs are outside this policy.

## Secret handling and credentials

Implemented `Secret` is an opaque heap allocation, with custom `[REDACTED]`
formatting and no byte getter. Structural formatting cannot enumerate its storage.
Destruction uses `std.crypto.secureZero` before freeing. Resolved secrets must be
owned outside the long-lived operation arena; the constructor copies its input,
so the resolver must also wipe its original buffer. This limits accidental exposure,
not privileged process memory inspection, swap or crash dumps. Zig has no enforced
private fields; code review must prohibit pointer casts that bypass the boundary.
Grafana is the first protected consumer: `SecretRef` represents a source without
resolving it, and the concrete local 1Password resolver uses spawned argv for
`op read`. Both username and password remain sensitive. Resolution precedes SSH;
empty or unavailable values fail with safe categories and suppressed stderr.
Plans, help, completion and status never resolve secret values. Only the protected
transport path may access secret bytes to write stdin; it does not render them into
remote shell text or command arguments. Credential reconciliation uses supported
Grafana interfaces and keeps only Grafana's normal credential hash persistently.
No general provider/plugin framework or controller state store is added.

Normal and 1Password SSH agents work through a socket; an explicit identity file is
passed to OpenSSH. Optional `op://` private-key references are modeled but rejected.
Future support should feed a temporary isolated SSH agent through stdin and destroy
it after use. Never serialize private keys in command arguments or ordinary files.

Chosen future persistent credential mechanism: encrypted systemd credentials via
`systemd-creds encrypt`, stored root-only under `/etc/credstore.encrypted/`, consumed
by `LoadCredentialEncrypted=`. Plaintext exists only in the service credential
runtime directory. If host encryption is unavailable, require an explicitly chosen
root:root 0600 credential source plus `LoadCredential=`; do not silently weaken the
policy. No plaintext `/etc/environment`, `Environment=`, argv, plans or ordinary
config. This remains the future public Grafana TLS policy. Telegram and agent
mTLS now have separate explicit protected-file consumers; no generic
credential-file mechanism is added.

## Maintenance and testing

`dragontools-maintenance` is a reserved, uninstalled module. It will be a oneshot
plus timer, exit after checks, listen on no port and accept no remote commands.
Station checks: TLS, OS/security and component metadata, helper health metrics.
Agent checks: OS/security and agent metadata, helper health metrics. Updates are
notify-only for components and normal OS upgrades. Security installation is allowed
by policy; automatic reboot is disabled. None of this policy changes hosts yet.

Unit tests cover parsing, redaction, quoting, units, storage, artifact plans and
update-state parsing, as well as CLI metadata, completion, contextual help and
scripted wizard validation/defaults/cancellation/command previews. Monitoring tests
cover policy constants, verified host metric names, explicit unavailable service
rendering, deterministic log/probe/host rules, thresholds, and stable labels. CLI smoke tests
check non-TTY behavior and the local help/completion boundary. Fake-remote tests
cover independent first/second runs, drift, failures, and restart recovery for all
eight installed components;
these prove sequencing, not actual systemd behavior. Separate isolated Linux
process fixtures verified the pinned host metric contract and real mTLS forwarding
into VM/VL, including authenticated host-label override. Their journal input was
a fixture, and they did not exercise SSH, systemd or full installer recovery.
Disposable Ubuntu integration
is documented separately and must verify the real runtime profile and no-op rerun.
The opt-in `tests/integration/victoriatraces.sh` runner checks the three storage services,
listeners, retention, writable backend storage, stable processes on reruns,
VictoriaTraces-only unit repair, and recovery from a persisted restart marker. It is not run by the
ordinary test target. The integration README adds Grafana UI, authenticated datasource,
four-process stability and Grafana-only recovery checks; those remain unrun until
a real supported disposable host is supplied.

Host utility tests separately cover account selection, missing/present packages,
source and `.zshrc` preservation, exact managed-template migration, the server
prompt, explicit shell changes and unchanged-shell no-ops, path conflicts and
interrupted runs. The CLI smoke
harness exercises alias/direct dispatch through fake SSH and ensures local plans,
help and rejected arguments never connect. See the host section of the same
integration checklist for real SSH/apt, account, byte-preservation and rerun checks;
local checks do not establish disposable-host validation.
