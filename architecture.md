# Architecture

> DragonTools should encode operational knowledge, not merely automate commands.

The public API is a set of monitoring workflows, not a generic resource DSL.
Small concrete Zig modules render controlled system commands. The controller is
short-lived and connects only via OpenSSH. Managed services run directly under
systemd. There is no persistent remote control daemon, container requirement,
provider abstraction, arbitrary shell configuration, or plugin system.

## Implemented boundary

`cli/parse.zig` validates all supplied inputs before SSH. `main.zig` rejects
unimplemented integrations. `monitoring/install.zig` detects the host once, then
installs and verifies VictoriaMetrics followed by VictoriaLogs. Each concrete
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
curl deadline. Non-root users require `sudo -n` and are checked for effective UID 0.
Raw stderr is suppressed and wiped; output summaries never echo arbitrary remote data.

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
and installation never edits startup files automatically.

## Monitoring policy and local rule generation

`monitoring/policy.zig` is the single source of truth for fixed storage and alert
defaults. Metrics retain `90d` with the existing overflow-safe
`ceil(filesystem capacity / 5)` reserve. Logs and traces each have a logical `100y`
retention limit and a native cleanup target of 75% filesystem usage. VictoriaLogs
now applies this policy; VictoriaTraces remains unavailable. The
operational disk states are 60% info, 70% warning, and 80% critical. Native cleanup
at 75% is separate from those alert thresholds; no manual deletion is introduced.
VictoriaLogs checks pressure periodically and preserves at least the newest two
days, so the target does not guarantee a hard usage ceiling.

`monitoring/rules.zig` is a pure, deterministic local renderer with small concrete
functions returning YAML. It emits Prometheus-compatible host/service rules and
a separate VictoriaLogs file with `type: vlogs`. It consumes an explicit validated
service-unit list; no services means no service rules. Unit identifiers are encoded
for PromQL and YAML without forming executable shell text. Annotations expose
conditions and signal context, never raw log contents or secrets. Rules have stable
severity/source labels and avoid request-level labels.

The generated pack comprises HostDown, CPUHigh, MemoryPressure, DiskWarning,
DiskCritical, InodesCritical, ServiceDown, ServiceRestartLoop, ErrorBurst, and
CriticalLogEvent. The informational disk state is modeled but does not add a
DiskInfo alert to this pack. Policy/rendering tests run without SSH or a real
evaluator. No CLI export command, remote rule installation, collector setup,
evaluation, or Alertmanager delivery is implemented by this module.

The ordinary install plan describes both available VictoriaMetrics and VictoriaLogs
workflows, including their private listeners and retention, then explicitly lists
unavailable components. A successful installation means both components passed
their checks; it does not imply traces or alerts are installed. Unsupported component paths and flags
still fail before SSH; generated YAML does not make a component available.

## Component layout and lifecycle

VictoriaMetrics `v1.151.0` and VictoriaLogs `v1.52.0` are pinned for both Linux
architectures. Archive digests come from official GitHub release metadata;
VictoriaLogs archives are also checked against their published release checksums.
Executable digests are computed from those verified archives. Literal archive and
binary hashes are embedded in each component module. Remote
curl downloads over HTTPS into a root-owned staging directory on the installation
filesystem. SHA-256 is checked before extracting the named executable and again
before installation. This trusts the reviewed catalog and upstream publishing
account; a checksum is not an independent publisher signature.

Each binary is installed as root:root 0755 inside a version directory; atomic rename
replaces the executable and stable `current` symlink. Existing matching binary hashes
and permissions avoid downloads. VictoriaLogs refuses a nested version mount that
would turn binary replacement into a cross-filesystem copy. Dedicated `dt-victoriametrics` and
`dt-victorialogs` system users/groups own their respective data directories (0750),
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
verification succeeds. Unchanged VictoriaMetrics stays running when VictoriaLogs
needs a repair or fails; the failure retains VictoriaLogs restart intent for retry.
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
blindly reuse that profile for Vector (journal access) or node_exporter. MemoryMax
is intentionally not imposed without capacity/workload testing. Systemd log rate
limits reduce service log storms but do not substitute for the future agent journal
capacity policy. Settings are renderer-tested; runtime validation on all supported
Ubuntu/architecture combinations remains an integration gate.

VictoriaLogs has its own concrete unit renderer and dedicated account, rather than
a generic service DSL. Its profile sets `NoNewPrivileges`, `PrivateTmp`,
`PrivateDevices`, `ProtectHome`, `ProtectSystem=strict`, `ProtectKernelTunables`,
`ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID`, and
`LockPersonality`. Both capability sets are empty. It restricts address families,
uses umask 0027 and TasksMax 512, and grants persistent writes only beneath
`/var/lib/dragontools/victorialogs`. Private temporary/device namespaces remain
available. Restart-on-failure has a delay; service journal rate limits are bounded.
All requested hardening directives are represented, with no intentional relaxation.
MemoryMax is omitted until workload/capacity testing establishes a safe bound.
The renderer and fake-remote checks do not prove compatibility under a real systemd
instance; supported Ubuntu/architecture VM runs remain required.

## Intended station and agent architecture (not installed yet)

Grafana is the only normal human-facing UI, with automatically provisioned
VictoriaMetrics, VictoriaLogs and VictoriaTraces datasources. vmalert sends to
Alertmanager, which optionally sends grouped Telegram warning/critical/resolved
notifications. Backend administrative APIs stay private. An ingestion gateway must
expose only approved write routes; allowlisting a raw VictoriaMetrics port would
also expose read/admin endpoints and is **not** an acceptable authorization boundary.

Agents map logs → Vector, metrics → vmagent, traces → OTel Collector.
node_exporter is the selected lightweight host/systemd metrics source. Selected
services must exist; the reusable service-check primitive rejects missing units.
Installing Vector alone is insufficient: inspect and bound journald, verify local
and remote health and signal arrival, monitor updates, alert on stalled pipelines,
and protect monitoring disk capacity.

Network authorization is source-IP based in v0.x: admins may reach SSH/Grafana;
agents may reach only ingestion. Provider firewall is an outer layer. A compromised
allowlisted host can submit telemetry. Grafana still requires user authentication.
No per-agent tokens or mTLS are claimed. Current slice avoids that unfinished
boundary by binding VictoriaMetrics and VictoriaLogs to 127.0.0.1 on ports 8428
and 9428. Installing VictoriaLogs does not configure application-host ingestion.

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
cover policy constants, deterministic host/service/log rule generation, thresholds,
stable labels, and service identifier validation/escaping. CLI smoke tests
check non-TTY behavior and the local help/completion boundary. Fake-remote tests
cover independent first/second runs, drift, failures and restart recovery for both
installed components;
these prove sequencing, not actual systemd behavior. Disposable Ubuntu integration
is documented separately and must verify the real runtime profile and no-op rerun.
The opt-in `tests/integration/victorialogs.sh` runner checks both services, listeners,
retention, writable logs storage, stable processes on reruns, VictoriaLogs-only
unit repair, and recovery from a persisted restart marker. It is not run by the
ordinary test target.
