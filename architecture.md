# Architecture

> DragonTools should encode operational knowledge, not merely automate commands.

The public API consists of monitoring workflows and one separate shell-tooling
host utility, without a generic resource DSL.
Small concrete Zig modules render controlled system commands. The controller is
short-lived and connects only via OpenSSH. Managed services run directly under
systemd. There is no persistent remote control daemon, container requirement,
provider abstraction, arbitrary shell hooks, or plugin system.

## Implemented boundary

`cli/parse.zig` validates all supplied inputs before SSH. `main.zig` rejects
unimplemented integrations. `monitoring/install.zig` detects the host once, then
installs and verifies VictoriaMetrics, VictoriaLogs, then VictoriaTraces. Each concrete
component workflow handles its account, directories, binary, unit, activation,
verification, and finalization; VictoriaMetrics also computes its capacity reserve.
Host detection checks OS and prerequisites once. Before changing a component,
its account phase checks that component's unit, drop-ins, and restart marker for
conflicts, so a refusal identifies the affected component.
A `Report` records the current component and phase, completed operations, and confirmed changed operations (not an
exact count of every filesystem mutation). Remote failures stop the sequence.

`system/remote.zig` is a minimal command boundary with injectable execution for
unit tests. It is an internal interface, not a public arbitrary execution API.
Every dynamic shell argument is POSIX single-quoted, including embedded quotes;
NUL is rejected. Small static shell fragments use positional parameters.
`system/ssh.zig` spawns argv directly with Zig 0.16 `std.process`; no local shell.
SSH is noninteractive, strict, with connection/keepalive limits and bounded output.
There is no absolute overall deployment deadline yet. Long downloads have their own
curl deadline. Monitoring commands use direct connections without local SSH config;
non-root monitoring users require `sudo -n` and are checked for effective UID 0.
Raw stderr is suppressed and wiped; output summaries never echo arbitrary remote data.

The separate `host install-oh-my-zsh` command uses the same transport boundary
without elevating the initial SSH login session. Its `--ssh-host` mode lets OpenSSH
resolve the user's native configuration, including aliases, identity agents and
jump hosts, while enforcing strict host-key checks. The direct `--host` mode keeps
the existing explicit connection behavior. Host inspection resolves the actual
login account or requested existing target account before any package or home
mutation. It does not create users or invoke monitoring installation.

## Current architecture

Only these storage components are installed by monitoring today:

```text
CONTROLLER                              REMOTE MONITORING HOST
DragonTools -- strict OpenSSH --------> systemd
                                          |
                                          +-- VictoriaMetrics v1.151.0
                                          |   127.0.0.1:8428
                                          |   metrics: 90d; reserve: 20%
                                          |
                                          +-- VictoriaLogs v1.52.0
                                          |   127.0.0.1:9428
                                          |   logical: 100y; partition budget: 75%
                                          |
                                          +-- VictoriaTraces v0.11.0
                                              127.0.0.1:10428
                                              logical: 100y; partition budget: 75%
```

Agents, remote ingestion, dashboards, alert evaluation/delivery, monitoring
firewall, TLS, and frontend telemetry are unavailable. The controller exits after
the command; no controller-side state database or resident remote agent is added.

The independent host utility has no listener or connection to these services:

```text
LOCAL MACHINE                           REMOTE HOST
DragonTools host install-oh-my-zsh
    -- strict OpenSSH alias/direct ---> actual account home
                                          +-- .oh-my-zsh (install if absent)
                                          +-- .zshrc (create if absent)
                                       zsh package (install if absent)

MONITORING STACK: unchanged by this command
```

## Safe rerun contract

Every mutating command observes actual remote state each time. A first install
converges each concrete component; an unchanged run reuses correct accounts,
directories, pinned binaries, and identical units without unnecessary mutation.
Only supported owner/group/mode repairs are made. Incompatible accounts and
unexpected symlinks fail explicitly. Valid binaries are not redownloaded.

Unit content changes and binary/current-link changes record restart intent before
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

Alert policy is defined; rendering is partial/provisional; alert runtime is
unavailable. `monitoring/rules.zig` renders only deterministic provisional
VictoriaLogs `type: vlogs` YAML for ErrorBurst and CriticalLogEvent. It includes
stable severity/source labels and concise service/count annotations, without log
payloads, request IDs, or secrets.

Host and service rules are unavailable until real metric contracts exist.
`renderHosts` returns `HostMetricContractUnavailable`; requested service rendering
returns `ServiceMetricContractUnavailable`, while an empty service list yields an
empty rules document. No replacement host expressions are guessed. Vector will
supply host metrics in the agent slice; the systemd service-state solution is
deferred. Policy and renderer tests involve no SSH or real evaluator. There is no
CLI export command, rule installation, or alert delivery.

The ordinary install plan describes all three available storage components,
including their private listeners and retention, then explicitly lists unavailable
integrations. A successful installation means all three components passed their
checks; it does not imply agents or alerts are installed. Unsupported component paths and flags
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

## Service hardening

The VictoriaMetrics profile uses an empty capability set, no new privileges,
private temporary files, protected home/system/kernel/control groups, restricted
address families, a single data write path, umask 0027, and TasksMax 512. It does not
blindly reuse that profile for Vector, which needs journal access. MemoryMax
is intentionally not imposed without capacity/workload testing. Systemd log rate
limits reduce service log storms but do not substitute for the future agent journal
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

## Target near-term architecture (not implemented)

The storage backends on the right exist today. All application-host collectors,
network ingestion edges, alert evaluators/delivery, and Grafana below are targets:

```text
APPLICATION HOST                        MONITORING HOST
(all collectors unavailable)            (VM / VL / VT installed)

journald
   |
 Vector -- logs ----------------------> VictoriaLogs
   |
   +------ host metrics --------------> VictoriaMetrics

application /metrics
   |
 vmagent -----------------------------> VictoriaMetrics

application OTLP
   |
 OTel Collector ----------------------> VictoriaTraces

                                        vmalert [unavailable]
                                           |
                                        Alertmanager [unavailable]
                                           |
                                        Telegram [unavailable]

                                        Grafana [unavailable]
                                         /  |  \
                                        VM  VL  VT
```

These edges require later verified ingestion, network authorization, and collector
configuration. Host metric names will be established by Vector implementation;
systemd service-state monitoring is deferred. No frontend telemetry is included.

Grafana is the only normal human-facing UI, with automatically provisioned
VictoriaMetrics, VictoriaLogs and VictoriaTraces datasources. vmalert sends to
Alertmanager, which optionally sends grouped Telegram warning/critical/resolved
notifications. Backend administrative APIs stay private. An ingestion gateway must
expose only approved write routes; allowlisting a raw VictoriaMetrics port would
also expose read/admin endpoints and is **not** an acceptable authorization boundary.

Vector is planned for selected journald logs and host metrics. vmagent is planned
for application Prometheus endpoints; OTel Collector is planned for application
OTLP. The systemd service-state monitoring solution is deferred. Selected services
must exist; the reusable service-check primitive rejects missing units.
Installing Vector alone is insufficient: inspect and bound journald, verify local
and remote health and signal arrival, monitor updates, alert on stalled pipelines,
and protect monitoring disk capacity.

Network authorization is source-IP based in v0.x: admins may reach SSH/Grafana;
agents may reach only ingestion. Provider firewall is an outer layer. A compromised
allowlisted host can submit telemetry. Grafana still requires user authentication.
No per-agent tokens or mTLS are claimed. Current slice avoids that unfinished
boundary by binding VictoriaMetrics, VictoriaLogs, and VictoriaTraces to 127.0.0.1
on ports 8428, 9428, and 10428. VictoriaTraces explicitly disables its additional
gRPC listener with `-otlpGRPCListenAddr=`. No public OTLP or application-host
ingestion path is installed.

## Secret handling and credentials

Implemented `Secret` is an opaque heap allocation, with custom `[REDACTED]`
formatting and no byte getter. Structural formatting cannot enumerate its storage.
Destruction uses `std.crypto.secureZero` before freeing. Resolved secrets must be
owned outside the long-lived operation arena; the constructor copies its input,
so the resolver must also wipe its original buffer. This limits accidental exposure,
not privileged process memory inspection, swap or crash dumps. Zig has no enforced
private fields; code review must prohibit pointer casts that bypass the boundary.
No current operation resolves, transmits or persists a secret.

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
config. Cloudflare DNS-scoped tokens and Telegram tokens require their own consumers;
the current CLI refuses these options rather than store them insecurely.

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
cover policy constants, explicit unavailable host/service rendering, deterministic
provisional log rules, thresholds, and stable labels. CLI smoke tests
check non-TTY behavior and the local help/completion boundary. Fake-remote tests
cover independent first/second runs, drift, failures, and restart recovery for all
three installed components;
these prove sequencing, not actual systemd behavior. Disposable Ubuntu integration
is documented separately and must verify the real runtime profile and no-op rerun.
The opt-in `tests/integration/victoriatraces.sh` runner checks all three services,
listeners, retention, writable backend storage, stable processes on reruns,
VictoriaTraces-only unit repair, and recovery from a persisted restart marker. It is not run by the
ordinary test target.

Host utility tests separately cover account selection, missing/present packages,
source and `.zshrc` preservation, path conflicts and interrupted runs. The CLI smoke
harness exercises alias/direct dispatch through fake SSH and ensures local plans,
help and rejected arguments never connect. See the host section of the same
integration checklist for real SSH/apt, account, byte-preservation and rerun checks;
local checks do not establish disposable-host validation.
