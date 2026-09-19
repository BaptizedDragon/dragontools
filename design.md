# Design decisions and staged delivery

## Current milestone: station and monitored-host logs/metrics implemented

The monitoring foundation delivers ten concrete services: VictoriaMetrics,
VictoriaLogs, VictoriaTraces, Grafana OSS, blackbox_exporter, Alertmanager,
vmalert-logs, vmalert-metrics, Caddy and private ingress authorization. Unfinished integrations fail before connecting. Exit 0 from install
means all ten passed their documented verification; it never means the full requested station exists.
`status` reads service states and stored HTTP probe samples; use `verify` to test health.
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
implemented ten-service station; roadmap settings require explicit opt-in and
still fail before SSH. Agent setup uses application/station OpenSSH aliases, validated services and
optional private application metrics URLs. Unsupported components and protected-file credential inputs do not
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
create users, or introduce a general package/dotfile system. Login-shell changes
and migration of an existing generated `.zshrc` require separate explicit options.
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
with their ownership and permissions unchanged, by default. An absent file receives
this complete v2 template, owned by the target account with mode 0644:

```zsh
# DragonTools managed .zshrc v2
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME=""

plugins=(git)

source "$ZSH/oh-my-zsh.sh"

PROMPT='%n@%m %~ %# '
```

The prompt is set after loading Oh My Zsh and always includes the username, short
hostname and directory; for example, `root@monitoring ~ #` or `vasyl@monitoring ~ %`.
Zsh's `%m` expands the remote machine's actual short hostname at display time,
independently of the controller's OpenSSH alias. The hostname is not embedded in
the file and changes to the machine's hostname need no configuration rewrite.
The command never modifies `/etc/hostname`. Zsh's `%#` selects the appropriate
privilege-sensitive terminator. The empty theme avoids
depending on theme-specific hostname behavior, while Oh My Zsh and the git plugin
remain enabled. Initial publication never overwrites a file that appears concurrently.

`--update-managed-zshrc` remains explicit to preserve the established command
contract: ordinary installs fill missing pieces and leave an existing startup file
unchanged. It permits only exact template recognition. The complete prior
v0 bytes (`export ZSH="$HOME/.oh-my-zsh"`, blank lines, `ZSH_THEME="robbyrussell"`,
`plugins=(git)`, and `source "$ZSH/oh-my-zsh.sh"`, including its final newline) are
recognized as migratable, as are the exact marked v1 bytes with
`PROMPT='%n@%m %~ %% '`. Neither recognition uses fuzzy matching. A byte-identical
current v2 is a no-op. The file must
belong to the target account, have one hard link, and deny group/world writes
for migration. Migration preserves its user ID, group ID and mode, or refuses
publication if those metadata cannot be preserved. A matching marker with local
edits, extra lines or any other content is insufficient proof and remains untouched.
Ordinary reruns do not migrate either historical template.

Updates run as the target account, serialize DragonTools writers with an advisory
lock on the home-directory file descriptor, prepare replacement content in private
adjacent staging, then recheck exact content, inode, user/group, mode and link count before
atomic publication. No persistent lock file or controller state is introduced.
The advisory lock cannot serialize an unrelated editor, so do not edit `.zshrc`
concurrently with a managed migration. Foreign files are never adopted automatically:
the operator must first back up and manually move the existing file to a unique,
unused location before rerunning to create a fresh managed configuration.

`--set-default-shell` explicitly requests the discovered zsh path as the account's
login shell. The command requires an exact listed entry in `/etc/shells`, compares
the fresh account shell, invokes `chsh` only when different, and rereads the account
record to verify the result. It never changes `/etc/shells` automatically. A matching
shell never invokes `chsh`; without the flag no shell mutation is attempted.
Root or noninteractive sudo may be required
for the shell change. A successful change reports the old and new shell paths and
asks the operator to reconnect. The current SSH shell
is not replaced, but subsequent SSH commands and logins use the newly selected shell.
The rendered helpers do not explicitly source user configuration. OpenSSH still
invokes the account's shell to execute remote commands, so the next verification
connection may read zsh's `.zshenv` (normally not `.zshrc`). Noninteractive startup
must be silent and permit these commands. A successful `chsh` is not rolled back
if shell initialization prevents that later verification connection; once SSH
startup works again, rerunning inspects the committed account state and avoids a
second `chsh` when the shell already matches.

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

Disk warning/critical and inode rules now use the verified Vector host contract.
The fixed host pack joins the separate log/probe packs; without agent metrics it
has no inputs. HostDown and systemd service-state alerts remain deferred.
`monitoring install --plan` describes all ten installed services and lists
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
`-httpListenAddr=127.0.0.1:9428`. The raw backend has no authentication;
external agents use separate Caddy mTLS metrics/log listeners with private registry authorization. Private temporary/device namespaces are allowed, persistent writes
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
log pipeline. `monitoring verify` checks all ten installed services; `status`
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

## Grafana installation, provisioning and verification

Grafana OSS `13.2.2` is the fourth concrete station component. Linux amd64 and
arm64 artifacts are pinned in `src/components/grafana.zig`; runtime never resolves
`latest` or trusts freshly downloaded checksum metadata. The reviewed OSS release
build is `34846740809`. Both downloaded archives were locally hashed and matched
the SHA-256 values published on the official versioned OSS download page:

| Linux architecture | Committed archive SHA-256 |
| --- | --- |
| amd64 | `9662c838a09824fdb072e5f6fbdd45b62cf541b20f3d609ea5011e6e5f544c8f` |
| arm64 | `7268f9a576f919f14e6263b344a85b6ac8d768fbda247910c43ce4e12c747a72` |

[Official Grafana OSS 13.2.2 downloads](https://grafana.com/grafana/download/13.2.2?edition=oss).
The immutable HTTPS artifacts use
`https://dl.grafana.com/grafana/release/13.2.2/grafana_13.2.2_34846740809_linux_<arch>.tar.gz`.
Each reviewed archive contains 13,358 regular files and 1,689 directories, with no
symlinks, hardlinks, special entries, traversal or duplicate paths. Extracted binary
hashes and a canonical path/type/mode/content-hash catalog digest are computed from
these verified archives and committed alongside the archive pins. These trust the
upstream publishing account; they are not independent publisher signatures.

Installation includes the server, built-in plugins and static UI assets because a
server-only binary pin cannot establish full application integrity. Every run
verifies the catalog against its source pin, then verifies every live file and
expected path. Correct content needs no download. Unknown extra paths, links and
foreign trees cause refusal; only a recognized release tree is repairable. Metadata
is normalized to root:root, 0755 for directories/executables and 0644 for other files.
Private staging precedes Linux `renameat2` atomic directory publication/exchange and
atomic `current` replacement. No downloaded code executes during archive review.
See `src/components/grafana.zig` and its embedded Python standard-library helper for
the exact integrity and publication boundary; these local archive audits are not
Linux service-runtime validation. The archives are about 457.5 MB (amd64) and
427.2 MB (arm64); the amd64 extracted tree is about 1.36 GB. Stage space must fit
the archive and new tree, plus the old tree during repair. An unsupported atomic
exchange fails safely instead of falling back to a non-atomic replacement.
Read-only integrity verification hashes the full tree on every pass, so unchanged
runs can take time even without downloads, writes or restarts.

Root owns the versioned `/opt/dragontools/components/grafana/13.2.2/` release tree
and its `current` selection. `dt-grafana` owns only its persistent data directory,
`/var/lib/dragontools/grafana` (0750), holding SQLite and plugin state across releases.
No PostgreSQL or data under the versioned release is introduced.
`/etc/dragontools/grafana/grafana.ini` and datasource provisioning are deterministic,
root-owned and read-only to the service. Publication uses private adjacent staging,
atomic replacement, safe path checks and the managed-file ownership boundary;
unmanaged files and unexpected symlinks are refused.

The concrete configuration pins `http_addr = 127.0.0.1`, `http_port = 3000`, the data
and provisioning paths, SQLite, and console logging for journald. Local authentication
remains enabled; anonymous access, auth proxy and signup are explicitly disabled.
The signed official VictoriaLogs datasource plugin is installed from a separately
pinned artifact; no dashboard is provisioned.
The concrete unit uses `dt-grafana`, empty capabilities, no new privileges, private
tmp/devices, protected home/system/kernel/control groups, restricted SUID/SGID and
personality, and a sole persistent write path under the Grafana data directory.
Real systemd/runtime compatibility remains a disposable-host integration gate.

Without configured secret references, authentication uses upstream's normal
first-login administrator flow. A fresh SQLite database has the standard
`admin` / `admin` credentials; the operator must change the password immediately
through SSH forwarding. This mode reports administrator credentials as unmanaged
and never resets an existing account. Explicitly configured secret references
opt in to reconciliation described below; no plaintext administrator value is
embedded in generated configuration or units. The loopback
boundary still permits local users to reach bootstrap authentication; the target must
be trusted and initialized promptly. [Grafana first login](https://grafana.com/docs/grafana/latest/setup-grafana/sign-in-to-grafana/),
[pinned defaults](https://github.com/grafana/grafana/blob/v13.2.2/conf/defaults.ini).

Provisioned datasource definitions are fixed, deterministic and not UI-editable:

| Name | Datasource type | Local URL | Default |
| --- | --- | --- | --- |
| Metrics | Built-in `prometheus` | `http://127.0.0.1:8428` | Yes |
| Logs | Official `victoriametrics-logs-datasource` | `http://127.0.0.1:9428` | No |
| Traces | Built-in `jaeger` | `http://127.0.0.1:10428/select/jaeger` | No |

The Jaeger prefix follows both the documented Grafana integration and the pinned
VictoriaTraces handler. [VictoriaTraces Grafana integration](https://docs.victoriametrics.com/victoriatraces/querying/grafana/),
[pinned handler](https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.11.0/app/vtselect/main.go).
Logs uses the upstream-documented VictoriaLogs base URL with proxy access. No Loki
compatibility layer, credentials, public URL or additional path prefix is used.
The datasource has fixed UID `dragontools-logs`. [VictoriaLogs Grafana integration](https://docs.victoriametrics.com/victorialogs/integrations/grafana/).

Grafana's verifier remains read-only. Its base checks need no administrator
credential. It checks active/persistently-enabled systemd state, loaded and managed unit identity,
running/disk executable identity, full installation integrity, effective hardening,
managed path metadata, the process-owned loopback listener, and Grafana HTTP identity.
It refuses `GF_*` overrides in the actual process environment, including inherited
systemd manager settings, without printing or retaining their values.
It compares exact generated config/provisioning, then reads only the non-secret
Metrics, Logs and Traces datasource fields from SQLite through read-only mode as
`dt-grafana`. It issues a Metrics query, a bounded read-only LogsQL query and a
Jaeger service query as that same UID against the provisioned backend URLs and
validates their response contracts.
Read-only SQLite access depends on the pinned schema and explicitly disabled WAL;
Python 3's standard SQLite module is a checked prerequisite. [Pinned datasource schema](https://github.com/grafana/grafana/blob/v13.2.2/pkg/services/sqlstore/migrations/datasource_mig.go).

This establishes provisioned records and backend reachability after password
changes without weakening authentication or retaining credentials. Configured
secret references also verify administrator identity, Logs plugin health and the
Grafana-to-plugin-to-VictoriaLogs query path through authenticated API calls. These
are read-only checks even where HTTP POST is the supported query method; neither
logs nor configuration are written. Empty valid Logs results and empty Jaeger
services are accepted before application ingestion. No synthetic telemetry is injected.

Without references the authenticated Logs query is explicitly unchecked, while
the remaining integrity, provisioning and direct-backend checks still run.
Metrics/Traces requests through Grafana's query engine and browser Save & test/Explore
remain separate integration gates. Local fixture tests establish orchestration
and response validation, not real Grafana/plugin/systemd runtime behavior.

Grafana's binary/current link, plugin selection/content, unit, configuration, and datasource content changes
record `/var/lib/dragontools/grafana-restart-required` before publication. Only
Grafana restarts; a config-only change does not require daemon-reload unless unit
state needs it independently. Verification failure retains that marker, while a
successful install clears it. An unchanged rerun does not download, rewrite config,
restart Grafana, or disturb VM/VL/VT. No controller database or generalized service
framework is added.

`monitoring install`, `verify` and `status` accept the existing native `--ssh-host`
mode. It uses the alias's OpenSSH configuration and resolves the actual remote UID
before choosing root or noninteractive sudo. Direct `--host` mode remains isolated
from local SSH config. Aliases cannot be combined with direct user/port/authentication
overrides. Help, completion and local plans share the metadata and never connect.
The wizard continues to emit the supported direct command form.

Immediate access is `ssh -L 127.0.0.1:3000:127.0.0.1:3000 monitoring`, then
`http://127.0.0.1:3000` on the administrator's laptop. No firewall, Cloudflare, DNS,
or TLS configuration changes. Public inbound remains administrator-restricted SSH
only. A later HTTPS frontend for `monitoring.baptizeddragon.com` is not installed.

## Official VictoriaLogs datasource plugin

`src/components/grafana_victorialogs_plugin.zig` pins the official plugin separately
from the Grafana server release:

| Pin | Value |
| --- | --- |
| Plugin ID | `victoriametrics-logs-datasource` |
| Version | `0.32.0` |
| Archive SHA-256 | `8204d097b17f53b1c3a71761047734b7980bd983710c6cfcef8d938abe5eeef0` |
| Full file-catalog SHA-256 | `b251e3c695e333e4a22d4b8f1aeaee9893ff0e14e3a6170d356a74de2f97cadd` |
| Artifact | `https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.32.0/download` |
| Checksum provenance | Official version metadata, `packages.any.sha256` |

The downloaded ZIP hash was checked against [official version metadata](https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.32.0).
The [official catalog](https://grafana.com/grafana/plugins/victoriametrics-logs-datasource/)
and [upstream integration documentation](https://docs.victoriametrics.com/victorialogs/integrations/grafana/)
identify this plugin; its [tagged source](https://github.com/VictoriaMetrics/victorialogs-datasource/tree/v0.32.0)
provides the reviewed endpoint and query contracts. No online plugin installer,
mutable version selection or Loki substitution is used.

The single ZIP is a multi-platform bundle, **not architecture-independent backend
code**. It includes native executables; DragonTools supports only its existing
Linux amd64 and arm64 targets. The package contains 36 regular files and two
directories, with no symlinks. It is 78,122,569 compressed bytes and 222,316,035
uncompressed bytes. All signed contents, including unused platform binaries, stay
intact. A canonical catalog pins expected paths, normalized modes and each file's
SHA-256, and is checked against a source pin before live-tree verification.

`MANIFEST.txt` is preserved unchanged. The reviewed manifest has the commercial
signature type, publisher `victoriametrics`, and key ID `7e4d0c6a708866e7`. A local
GPG audit verified its signature using the static public key from pinned Grafana
13.2.2: fingerprint `F33B25B691074E84636570F37E4D0C6A708866E7`.
[Grafana's pinned static key](https://github.com/grafana/grafana/blob/v13.2.2/pkg/plugins/manager/signature/statickey/static_retriever.go)
and [key selection](https://github.com/grafana/grafana/blob/v13.2.2/pkg/services/pluginsintegration/keyretriever/retriever.go)
confirm that `public_key_retrieval_disabled = true` still uses this trusted embedded
key. Signature checking remains enabled and no `allow_loading_unsigned_plugins`
setting is added. The archive/catalog pins trust the reviewed official publisher;
they do not make a malicious publisher harmless. GPG is a review tool, not a target
prerequisite, and the audit did not execute downloaded plugin code.

Persistent storage is separate from Grafana server binaries:

```text
/var/lib/dragontools/grafana/
  plugins/
    victoriametrics-logs-datasource
      -> ../plugins-versions/victoriametrics-logs-datasource/0.32.0/content
  plugins-versions/
    victoriametrics-logs-datasource/
      0.32.0/
        .dragontools-plugin-catalog.json
        content/                 # intact signed plugin package
```

Plugin directories, catalog and content are root-owned, readable by `dt-grafana`;
executables/directories use 0755 and regular non-executables 0644. Grafana's data
parent remains service-owned for SQLite. Because a writable parent could otherwise
permit replacing root-owned children, the unit additionally mounts both plugin
roots read-only with `ReadOnlyPaths`. The service cannot install or edit its plugin
code. Grafana's configured plugin path is the active `plugins` directory. Pinned
Grafana discovery follows directory symlinks and roots the plugin filesystem at
the resolved content directory, excluding the sibling DragonTools catalog.
[Discovery implementation](https://github.com/grafana/grafana/blob/v13.2.2/pkg/plugins/manager/sources/source_local_disk.go),
[symlink walker](https://github.com/grafana/grafana/blob/v13.2.2/pkg/plugins/filepath.go).

Downloads use HTTPS and the committed archive checksum before extraction. Private
staging accepts only the expected plugin root/catalog entries and rejects traversal,
duplicates, symlinks, hardlinks, special files and unexpected content. Publication
uses an atomic version-directory operation and atomic active-symlink replacement.
The existing catalog must match a reviewed pin before replacement or repair of
known files; unexpected paths are refused. A future reviewed pin stages alongside older known
releases. A same-version repair retains the previous tree under a managed
`.previous.0.32.0.*` name. Prior state remains available for operator recovery;
there is no automatic rollback or automatic upgrade check.

Managed `grafana.ini` is established before plugin staging, so a failed fresh
download or interrupted publication can pass preflight and resume on rerun.
Plugin publication sets only Grafana's restart marker. After activation all normal
Grafana checks and configured Logs API checks must succeed before finalization can
clear it. A failed checksum/extraction never activates the staged plugin; a failed
readiness/query check keeps restart intent and leaves VM/VL/VT untouched. A correct
rerun hashes the installed tree but performs no plugin download, provisioning
rewrite or Grafana restart. Run one installer per target at a time.

The plugin is a Grafana child process using a Unix-domain socket on supported Linux
hosts, not another TCP service. Pinned plugin source calls the SDK's `backend.Manage`;
its pinned `hashicorp/go-plugin` 1.8.0 selects Unix sockets on non-Windows systems.
The existing AF_UNIX allowance and private temporary directory support that transport.
[Plugin entry point](https://github.com/VictoriaMetrics/victorialogs-datasource/blob/v0.32.0/pkg/main.go),
[plugin dependencies](https://github.com/VictoriaMetrics/victorialogs-datasource/blob/v0.32.0/go.mod),
[transport implementation](https://github.com/hashicorp/go-plugin/blob/v1.8.0/server.go).
Actual systemd sandbox compatibility, signature loading and browser behavior remain
explicit disposable-host integration checks.

### Authenticated Logs query contract

After the desired administrator login has been verified or reconciled, the existing
protected-stdin helper performs `GET /api/plugins/victoriametrics-logs-datasource/settings`
and requires the exact plugin ID, datasource type, pinned version and valid signature.
It then calls `GET /api/datasources/uid/dragontools-logs/health` and
`POST /api/ds/query` with organization 1. The single query uses UID `dragontools-logs`,
refId `A`, `queryType: instant`, a five-minute window and `* | fields _time`, with
`maxLines: 1`, `maxDataPoints: 1`, and `intervalMs: 1000`. This proves a valid query
path while avoiding retrieval of log messages. The response must contain the
expected valid logs frame; an empty frame is allowed, missing/malformed results are
not. Responses stay inside the remote helper and are never printed by DragonTools.

Plugin identity/signature failures and invalid credentials fail immediately.
Runtime health and query readiness each have a 45-second deadline with an immediate
probe, a 500 ms first retry and then 1-second retries. Timeout fails verification
and retains Grafana's pending restart intent. There is no fixed blind sleep and no
credential reset on this read-only path. Unconfigured compatibility mode instead
verifies the direct VictoriaLogs backend and reports the authenticated query as
unchecked; plans and status never resolve secrets or execute these API requests.

## Monitoring configuration and Grafana credentials

Station `--config PATH` is explicit and supported for monitoring install, verify
and status. That schema has no conventional-path search, includes or
interpolation; application config uses the separate contract above.
`config/monitoring.zig` accepts a bounded 64 KiB version-1 TOML subset:
`version = 1`, `[connection].ssh_host`, `[ingress].hostname`, and `[grafana]` username/password inline
`{ op = "op://vault/item/field" }` references. Single-line basic/literal strings,
basic escapes and comments are supported. Unknown or duplicate keys/tables,
literal secret values, array/dotted/nested/multiline forms and unsupported sources
fail without echoing their contents. The config contains references only and is
suitable for version control subject to vault/item-name disclosure policy.

Explicit CLI fields override the corresponding config fields. `--host` explicitly
selects direct SSH instead of a configured alias; direct user/port/authentication
overrides alone still conflict with alias mode. Username/password references must
be a complete pair after merging. `--grafana-user-op` and `--grafana-password-op`
are available for install and verify. Status can share the same file, but checks
only service state and does not resolve its credential references. Help does not
load the config. Plan reads and validates config/reference syntax, describes
credentials as configured via secret references, and never invokes `op` or SSH.

The small `SecretRef` boundary prevents Grafana from depending on `op` directly.
1Password is optional and controller-local. The concrete resolver spawns `op read`
with separate validated arguments, never through a shell. Both resolved fields are
opaque redacted values, held outside the operation arena and wiped after use.
Resolution failure, missing/unavailable `op`, empty values and provider subprocess
errors occur before remote mutation and suppress raw stderr and values. No
1Password credentials, executable or session state are uploaded to the host.

A configured installation checks desired authentication before credential mutation.
If those credentials identify the administrator already, reconciliation is a no-op;
it never resets the password or restarts Grafana merely because refs are present.
For existing installations with a manually changed password, privileged Grafana
CLI/API operations reconcile the desired account without requiring that old
password. The CLI always selects the pinned executable and the actual DragonTools
home/config/data paths, rather than defaulting to another SQLite database.
DragonTools does not directly write Grafana's credential database. Standalone
verification authenticates read-only and fails instead of reconciling a mismatch.

The concrete helper runs as `dt-grafana` with core dumps disabled and reads one
bounded JSON credential payload from protected stdin. It creates no secret tempfile.
For a missing or not-yet-initialized database, with the service inactive, it invokes
the pinned `current/bin/grafana cli --homepath=... --config=... admin
reset-admin-password --password-from-stdin --user-id 1`. The pinned Grafana CLI
performs initial database setup using the desired `GF_SECURITY_ADMIN_USER` and
`GF_SECURITY_ADMIN_PASSWORD` in that child process environment only. Both child
output streams are discarded; service startup never uses those environment
variables or a persistent EnvironmentFile, and never starts with default
credentials first. Home/config paths select the configured persistent SQLite DB.

Existing installations manage only the original local administrator, user ID 1.
Read-only account metadata inspection refuses a missing, disabled, non-admin,
external or service account, as well as a desired login/email collision. A
successful authenticated `GET /api/user` with the exact desired login skips all
credential mutation. Otherwise the supported CLI resets the password from stdin,
and supported `PUT /api/user` reconciles the login while preserving name, email and
theme. A password already corrected before an interrupted rename is not reset again.
The final authenticated identity check must succeed. No direct SQL credential
mutation or assumption that startup settings reset an existing password is used.
[Grafana CLI command](https://github.com/grafana/grafana/blob/v13.2.2/pkg/cmd/grafana-cli/commands/commands.go),
[password reset implementation](https://github.com/grafana/grafana/blob/v13.2.2/pkg/cmd/grafana-cli/commands/reset_password_command.go),
[initial database setup](https://github.com/grafana/grafana/blob/v13.2.2/pkg/services/sqlstore/sqlstore.go),
[user API](https://github.com/grafana/grafana/blob/v13.2.2/pkg/api/user.go).

Usernames must be valid UTF-8, at most 190 bytes, without a colon, control characters
or leading/trailing whitespace. Passwords are valid UTF-8, 4 bytes to 16 KiB, without
CR, LF or NUL because the supported CLI reads one input line. These limits are
validated without printing values. Standalone credential verification issues GET
only; Grafana may update its own authentication last-seen metadata as part of a
normal login. DragonTools makes no configuration or credential writes in verify.

DragonTools command arguments, progress, errors and helper output exclude both
resolved values. The helper discards the CLI's stdout/stderr. Grafana owns account
identity and authentication metadata, including its normal failed-login records.
Successful `/api/user` responses are not request-logged with the pinned default
router logging setting, and failed basic authentication uses fixed error text.
An authenticated HTTP error can still carry the username in Grafana's own request
context log. Operational/audit logging stays under Grafana's normal policy; the
helper never prints a password. These native boundaries were reviewed in
[the pinned context handler](https://github.com/grafana/grafana/blob/v13.2.2/pkg/services/contexthandler/contexthandler.go)
and [request logger](https://github.com/grafana/grafana/blob/v13.2.2/pkg/middleware/loggermw/logger.go),
without claiming disposable-host validation.

Resolved values travel through the protected SSH stdin path, never argv or rendered
shell commands. The normal `grafana.ini`, provisioning and systemd unit contain no
resolved administrator values. After successful reconciliation, only Grafana's
normal credential storage persists: DragonTools retains no remote plaintext admin
password. Credentials are verified before successful completion; interruption or
failure does not clear component restart intent or falsely report credentials as
current. Reruns inspect and authenticate actual state again.

Credential reconciliation is scoped to Grafana. VictoriaMetrics, VictoriaLogs and
VictoriaTraces keep their independent installation, readiness and restart markers.
Local fake resolver, transport and Grafana fixtures establish sequencing and
redaction, not live 1Password access or real Grafana/systemd runtime behavior.
Logs plugin health/query checks reuse the protected credential payload after the
identity check; no new provider or credential store is added. Authenticated
Metrics/Traces query-engine and browser UI validation remain separate integration
checks even when the administrator and Logs API checks succeed.

## Semantic monitoring progress

`Report` exposes an optional injectable event sink. Events contain only a fixed
component and phase enum; there is no string payload for CLI values, command text,
remote output or secrets. The CLI renders and writes each event immediately.
Installation and verification name each component before inspection, then report
required changes, verification and healthy changed/unchanged completion. Progress
is presentation only and never changes error categories or operation results.

The existing bounded readiness loop is unchanged in policy. After roughly two
seconds of unsuccessful readiness probes, it emits `waiting for readiness...`
once per component, never every retry. Immediate success adds no delay; deterministic
failure is still not retried. A successful delayed probe permits normal finalization,
and timeout still retains restart intent. The final unchanged install line remains
`No changes required.`

## Safe reruns across all mutating workflows

Verification has two distinct responsibilities. Managed configuration and artifact
identity are deterministic checks, performed without retries. Incorrect units,
checksums, links, service users, hardening, process arguments or public listeners
are failures even if the service is still starting. Runtime readiness is probed
immediately and retried only for explicitly recognized transient results. Each
stage has its own deadline: systemd active 15 seconds, HTTP 30 seconds, and
telemetry/self-observation or Grafana datasource readiness 45 seconds. The first
retry is after 500 ms, followed by 1-second intervals; successful probes never
incur a blind startup sleep. VictoriaMetrics' self-scrape check waits for a valid
`vm_app_version` query result within the telemetry deadline, respecting the
configured 15-second self-scrape interval. A missing sample during startup is not
treated as a permanent configuration error.

Timeouts still fail verification, preserve restart intent, and stop later phases.
Delayed success permits normal finalization; later unchanged installs remain
no-ops. Semantic names such as `service_active`, `http_ready` and
`self_scrape_ready` are safe failure diagnostics; arbitrary remote output remains
suppressed. Injected execution and clock fixtures cover retries, timeouts,
fail-fast configuration errors and restart-marker finalization. These tests do
not establish real systemd startup timings or disposable-host integration.

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
enablement is repaired persistently. A VM, VL, VT, or Grafana change
cannot restart another unrelated healthy component.
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

## Application monitoring.toml v1

`monitoring apply` is the primary app-repository command. It loads exactly
`./monitoring.toml`, or one explicit `--config PATH`. `app-verify` and `app-status`
use that same contract read-only. Parsing, help, completion and wizard command
generation share the normal CLI path; wizard mutation retains default-No approval.
The schema is deliberately separate from the station TOML used by
`monitoring install`. The app file accepts no station secrets or secret references.

Required tables are application (name and explicit environment), target and
station (`ssh_host` for OpenSSH administration and required `hostname` for TLS).
The hostname is 1–253 ASCII DNS bytes, with 1–63 byte labels bounded by letters
or digits and optional internal hyphens. Schemes, ports, paths, whitespace,
wildcards, empty/malformed labels and IP literals fail before SSH. Single-label
DNS names are accepted explicitly. No application command infers a hostname
from an alias or reads OpenSSH resolution for it. Repeated services name exact canonical `.service`
units. Logs default false, optional private HTTP(S) metrics enable vmagent, and
traces=false is accepted while traces=true fails before SSH. Zero services is
valid and still enables Vector host metrics. Repeated probes use the existing
credential-free HTTP GET/2xx/TLS policy. Repeated alerts support only structured
log count thresholds and overrides of default probe alerts. Raw expressions,
arbitrary labels/configuration and custom metrics alert sources are rejected.
The [README contract](README.md#application-repository-contract) lists complete
field bounds, required values and examples; unknown/duplicate fields fail.

Application names are station-wide namespaces, bound to environment and machine
identity. Rebinding fails rather than silently moving ownership. Per-app station
files live under `/etc/dragontools/apps/<application>/`; a manifest of exact
deterministically rendered content proves ownership. Edited/unmanaged content,
unexpected files, links or unsafe metadata fail closed. Interrupted generations
remain recognizable so a rerun can complete publication before finalization.
An app updates its own documents, not a monolithic rendered application registry.
Removing a declaration removes it only from that app's generated document.

The native scraper includes app scrape files and vmalert includes app rule files
through fixed owned globs. These shared loaders integrate once. An alert edit
marks only its evaluator; a probe target edit marks native scraping; metrics-only
edits leave unrelated rule files unchanged. Shared host rules use the existing
verified Vector contract and policy, with application/environment/host grouping.
All generated alerts carry managed_by=dragontools; application rules also carry
the immutable application/environment identity and applicable service/probe.

On a shared target, `/etc/dragontools/agent-apps/<application>.json` records only
that application's signal requirements. Deterministic merging preserves the
others when reconciling the one Vector/vmagent instance. Host metrics are tagged
for each app scope. Declared log fields and exported metric labels cannot override
trusted application/environment/service/host. App/legacy raw-agent mode conflicts
fail explicitly. The existing mTLS credential and disk/journald bounds apply.
Operators must serialize applies per shared target/station; concurrent distributed
transactions and automatic namespace migration are not implemented.

Local plan prints administrative aliases, the distinct ingestion hostname and
`https://hostname:9443` metrics and `https://hostname:9444` logs endpoints, signal selections, probes, alerts and app-owned paths;
it does not inspect remote conflicts. Apply verifies actual ownership and recent
signals before success. Probe target failures remain valid telemetry. Read-only
commands do not export credentials, repair configuration, clear pending markers
or send notifications. Full two-host Ubuntu deployment remains an integration
gate; local renderers and native process fixtures are narrower evidence.

Future dashboards must use `DragonTools / <application>` folders and deterministic
UIDs with explicit ownership. They must preserve manual assets and fail conflicts
without a specific adoption option. This iteration creates no dashboards, OTLP
collector, custom metrics alert engine or arbitrary configuration upload path.

## Monitored-host logs and metrics

`monitoring agents install --ssh-host application --station monitoring
--service app.service --metrics-target app=http://127.0.0.1:16000/metrics`
uses two native OpenSSH connections. `--station` resolves an effective DNS/IPv4
HostName locally with OpenSSH and uses fixed ports 9443 for metrics and 9444 for logs. The
application host must reach that address independently of controller SSH tunnels.
All services and optional private HTTP/HTTPS targets are validated before SSH;
remote selected units must exist with an exact canonical systemd `Id` and empty
`LogNamespace` before station preregistration. Aliases and namespaced journals are
refused. Install requires a service;
verify/status can read saved station registration. The stable machine-ID-derived
host identity is `dt-<32 lowercase hex>`. Target names and service lists are
bounded and unique. Metrics URLs prohibit credentials/query/fragment, arbitrary
DNS/public hosts and redirects. No auto-discovery, port scanning or node_exporter.

Vector 0.58.0 reads only selected journald units, keeps application fields useful
to log alerts, and overwrites host/service from trusted agent inputs. It uses
`host_metrics` for CPU/memory/filesystem/disk/network and `internal_metrics` for
forwarding/buffer telemetry. The API is disabled; telemetry binds 127.0.0.1:8686.
For quiet streams, a native source emits one `dragontools_stream` info-level
metadata record per selected service every 30 seconds. It is distinct from
application logs, generates no errors or journal/application traffic, and requires
no extra installer test event on rerun. vmagent v1.152.0 is installed only when
application targets exist, scrapes only those and itself, and binds management to
127.0.0.1:8429. OTel Collector/traces remain unavailable.
Filesystem type exclusions are exactly `squashfs` and `iso9660`: immutable images
can legitimately report 100% usage. No read-only mount filter is applied, so
`ProtectSystem=strict` does not hide ordinary root filesystem usage or inodes.
The pinned collector filters filesystem names and then reads `statvfs`.

Both agents have dedicated users, independently marked binary/config/unit changes,
atomic versioned binary publication, read-only checks and verification-gated
finalization. Vector-only changes do not restart vmagent; target-only changes do
not restart Vector. An unchanged install preserves running services, certificates
and registration. Failed station signal arrival remains failure with restart
intent intact; standalone verify/status cannot clear it.

### Pins and observed host metric contract

The Linux amd64/arm64 artifacts are pinned by archive and extracted-binary SHA-256.
Vector archive hashes were reviewed against official release metadata and
SHA256SUMS in the
[Vector 0.58.0 release](https://github.com/vectordotdev/vector/releases/tag/v0.58.0);
vmagent uses the exact vmutils archive in the
[VictoriaMetrics v1.152.0 release](https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.152.0).
Binary hashes were calculated from verified archives. This trusts the reviewed
upstream release accounts and HTTPS artifacts; it is not an independent signature.
The source pins are authoritative:

| Component/architecture | Archive SHA-256 | Extracted binary SHA-256 |
| --- | --- | --- |
| Vector 0.58.0 amd64 | `ad013ddc164b80e425cc403d2174e26b811673846d1125c80bc7b5024826ce39` | `889ae89eb81016c8f7b90daf435e17f56597b17ca4d154e64244382212896e73` |
| Vector 0.58.0 arm64 | `b21afc8ba23a6fca9aec049a313ba6da5e59b7fc2ed018839d83241de5ab95f7` | `3a5b3a66ca97387f23b074fea0cf11a1df136c698d9354fa9268473d98f03d6e` |
| vmagent v1.152.0 amd64 | `8eee4a98ff1665c60682475e8a8b292b8d718b63a2f023124384dd2f6a220c79` | `a9fa98b7447b94f6bcf93b1c43fd3192b8f0cb2e8c54940af144692274bf4711` |
| vmagent v1.152.0 arm64 | `57c567b262962a4cb8e35c0c34efe64629a3e1ea69ac0611d8d67e168df8b1e8` | `da7046c7310c39ce3a93dc67f8f9562fa77a7fc9ec3d95b0cf8d9dcb6321679d` |

The pinned Vector binary was run in an isolated non-root Linux/aarch64 fixture.
Captured Prometheus output is committed in
`src/monitoring/agents/vector_metrics_fixture.prom`, with the contract in
`metric_contract.zig`: `host_cpu_seconds_total` (`mode`, `cpu`),
`host_memory_available_bytes`, `host_memory_total_bytes`,
`host_filesystem_used_ratio`, `host_filesystem_inodes_used_ratio`,
`host_filesystem_inodes_total` (`mountpoint`, `filesystem`),
`host_filesystem_free_bytes`, `host_network_receive_bytes_total` and
`host_network_transmit_bytes_total` (captured from the pinned native exporter),
`vector_uptime_seconds` and `vector_buffer_size_bytes`. Prometheus namespace/name
encoding is shared by exporter and remote-write sinks. This observation enables
the five fixed host-pressure rules. A separate isolated native process fixture
also verified real Vector/vmagent mTLS forwarding into pinned VM/VL and trusted
host-label override. Its journald source was replaced with closed stdin; it is not
a two-host systemd deployment or outage/recovery test.
**Disposable-host integration not run.**

### Caddy ingress pins and verification

Official [Caddy v2.11.4 release](https://github.com/caddyserver/caddy/releases/tag/v2.11.4),
reviewed 2026-09-18. Archive hashes below were compared to the official GitHub
release API asset SHA-256 digests; binary hashes were derived from those verified
archives. This trusts the reviewed release account, not an independently verified
publisher signature. Installation uses committed pins, never latest metadata.

| Linux architecture | Archive SHA-256 | Extracted caddy SHA-256 |
| --- | --- | --- |
| amd64 | `527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9` | `b7105518e3ed1c0761f232e44fc09345535533c9cb0abf0e12809416c7ac64d9` |
| arm64 | `52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904` | `e1f904038fc11ca897ac5a12fdacfb2a7add02a8720c426d562a37f6fdad2afe` |

`src/components/caddy.zig` installs into `/opt/dragontools/components/caddy/v2.11.4`
with an atomic `current` link, private staging, archive/binary integrity checks
and its own restart marker. Correct state returns before downloading. Caddyfile
is generated, not user configurable, and validated with the pinned binary before
activation. Systemd `LoadCredential` supplies three local copies: CA certificate,
server certificate, server private key. Neither the CA private key nor app client
private keys are accessible to Caddy. Both service units hide canonical PKI,
legacy client and server storage with `InaccessiblePaths`; only Caddy receives
server credentials. Their stdout/stderr and core dumps are disabled.

The private Python authorization/normalization helper is retained because stock
Caddy does not implement registry fingerprints/rollout leases or trusted log
metadata rewriting. Caddy deletes incoming `X-DragonTools-*` headers before setting
verified SHA-256 fingerprint, subject and SAN assertions. Root-owned registry
records authorize each request. Private sockets are dt-ingest:dt-ingest 0660 in
0750 RuntimeDirectory; only Caddy's service supplementary group grants access.
The helper never terminates TLS or reads server keys. Local roots remain trusted.

Station install owns accounts, the native helper, CA/server PKI, Caddy and private
Unix-socket authorization. A fresh station requires explicit `--ingress-hostname`
or `[ingress].hostname`; an omitted value reuses only an exactly managed server
bundle's saved endpoint. CLI overrides the config; neither infers a TLS name from
SSH. Native `station-ensure` accepts only the endpoint, no app registration.
`station-verify` is read-only; the enrollment `ensure` action now only checks an
already provisioned station. Existing valid CA/key state remains unchanged.

Station health needs zero clients: validate strict PKI, exactly two IPv4 TCP
listeners, no UDP/admin/trace listener, exact process/user/binary/config/unit/
hardening and both protected Unix sockets. Private `/health` rejects anonymous
requests; Caddy proves server CA/hostname and rejects certificate-less TLS. No
synthetic client is enrolled. Absence retries within 15 seconds for active state
and 30 seconds for transport health; invariant drift fails immediately. Each
station service finalizes its own restart intent after its health proof, independent
of app telemetry. Application apply and app-verify check ingress read-only;
apply refuses unfinished station restart markers and directs repair to station
install. Application telemetry still uses 45-second readiness and gates agent
and client-enrollment finalization. No fixed startup sleep.

`tools/fetch_caddy_fixture.py` explicitly fetches/checks a native fixture binary;
normal builds/tests stay offline. Linux/macOS CI runs the same real-Caddy test
with native fixture certificates, port isolation, forged headers, wrong purpose,
expiry, SAN, registry rollout, request bounds and backend transformations. Loopback
fixture ports and credential paths replace production bindings only. This does
not prove Ubuntu systemd `LoadCredential`, Vector/vmagent forwarding or provider
firewall behavior. Disposable-host integration remains required before claiming
production deployment validation.

### mTLS ingestion and trust boundary

Caddy v2.11.4 runs as `dt-caddy` on IPv4 `0.0.0.0:9443` (metrics) and
`0.0.0.0:9444` (logs), with TLS 1.2+ and client certificates required. Caddy has
exactly one Unix-socket upstream per port. The private `dt-ingest` authorization
helper has no TCP listener and exposes only POST `/api/v1/write` on metrics.sock,
POST `/insert/jsonline` on logs.sock, plus authenticated GET/HEAD `/health` on both.
It never routes a log request through the metrics port or vice versa. Caddy's
admin API, auto HTTPS/ACME, config persistence and HTTP/2/3 are disabled. TCP 9445
is reserved and closed; no trace source or direct trace protocol is configured. Requests cap at 4 MiB, decoded
remote-write Snappy payloads at 16 MiB, 16 concurrent workers and a 10-second
connection deadline. Each request checks the root-owned registry by machine
CN, exact URI SAN and SHA-256 fingerprint; removed/changed registration takes effect without a proxy
restart. Incoming query strings and headers are never forwarded, and backend
destinations are fixed. Raw
VM/VL/VT administrative listeners remain loopback, and no Grafana/Alertmanager
route is added. No firewall is changed: operators allow TCP 9443 for metrics and
TCP 9444 for selected logs from monitored hosts and retain their SSH policy.
The original public Python gateway unit is never restored. A still-installed
historical unit fails `legacy_ingress_conflict` without being stopped or deleted;
an operator must coordinate that older port topology's cutover.

The station root owns the preserved ten-year CA (root:root 0400) and station
server key. The application host alone generates its P-256 client key. This mature
curve is supported by the Ubuntu OpenSSL/Python stack and the pinned agents. Each
host has one identity independent of its applications: machine-ID-derived CN
`dt-<32 lowercase hex>` and sole URI SAN `dragontools://hosts/<host-id>`. The
station's server certificate retains the configured DNS/IP SAN; Vector verifies
certificate and hostname, and vmagent retains normal strict TLS validation. This
private CA channel deliberately does not use Let's Encrypt.

Station CA validation parses X.509 PEM and a private key, and preserves the exact
CA:TRUE,pathlen:0 and keyCertSign,cRLSign extension policy, read from DER rather
than library-formatted text. Public keys must match as normalized DER. The CA
must be self-issued, and bundled Mbed TLS verifies its ECDSA/SHA-256 self-signature
with the exact P-256 profile. No OpenSSL executable or configuration is consulted.
An explicit expiry check also rejects a certificate at its notAfter boundary.
Invalid or malformed CA state remains a read-only failure; validation never
replaces keys, suppresses a failure or relies on platform-specific output text.

New CA material is fully validated in memory before root-private staging and atomic rename;
validation failure removes staging and leaves no published CA directory. Parent
directories may remain. New directories explicitly receive their requested mode
after creation under the helper's private umask. Apply reconciles the fixed
ingestion registry directory to root:dt-ingest 0750, including older mode-0700
directories on initialized stations. Directory handles opened without following
symlinks anchor the repair under the owned ingestion tree. Only mode is repaired
after root ownership and the dt-ingest group are proven; unsafe paths, other file
types and incompatible ownership fail with `ingestion / registry_permissions`.
Contents and credentials are preserved; no service restart is requested for a
mode-only repair, and correct permissions are a no-op. Read-only verification
reports drift without repairing it. Empty pki/clients/registry parents remain a
valid bootstrap starting point. An existing CA is never replaced on
validation failure; missing CA material on an initialized station still requires
explicit maintenance. Rerunning apply needs no manual cleanup of empty parents.

The bounded native stdin decoder treats Zig 0.16 `error.EndOfStream` as normal
request completion. It still rejects empty, malformed, oversized and unexpected
JSON envelopes before dispatch; it never prints request bytes. This fixes fresh
station enrollment failing before CA generation when the controller closes stdin.

`ingestion.zig` invokes the installed native helper using a fixed command and
bounded public JSON on stdin. SSH transports only public inspection, CSR and
certificate payloads. The root operation lock serializes local generations. A CSR is at most 8192 bytes and must be strict PEM
PKCS#10. The station checks its signature, P-256 public-key validity, exact CN and
sole host URI SAN with a narrow DER profile. Other requested extensions (including
CA/serverAuth), extra names and attributes fail before signing. Issuance never
copies CSR extensions: the station fixes critical CA:FALSE/digitalSignature,
clientAuth and the expected SAN. Private key bytes are handled only inside their
owning host's helper; no station client generator or private export command exists.
CSR proof of possession hashes the original DER CertificationRequestInfo and
verifies the ECDSA/SHA-256 signature with Mbed TLS/PSA. Malformed DER/PEM, duplicate
extensions, extra attributes, RSA and other curves fail closed. Generated leaf
extensions come only from policy. New certificates include noncritical SKI/AKI:
SHA-256 truncated to 160 bits per RFC 7093 method 1 avoids enabling SHA-1 merely
for key identifiers. When signing with an existing CA, its exact SKI is retained
as the leaf AKI for strict TLS interoperability. Existing valid certificate/key
bytes are preserved. Secret allocations use a wiping arena, core dumps are
disabled, private paths are bounded/no-follow, and errors return fixed codes.
The optional internal `--diagnostics` flag emits exactly `AgentStage` and
`AgentError` from closed enums, capped at 256 bytes. It never formats an arbitrary
Zig error or input. Controller requests carry a separate enrollment stage;
`ensure` is always `station_ensure`, including failures before a helper response.
SSH drains stderr concurrently within the existing process deadline, wipes its
fixed buffers and rejects any extra/unknown bytes. Only typed names and the exit
code reach the report. Registry refusal (89), CA maintenance (87), client state
(88), and endpoint errors (91–95) remain distinct; other failures (86) use
`agent_internal_error` plus the safe native stage/reason when available. CA/server
checkpoints track directory access, key/certificate creation, validation and
publication; no mutation, restart or retry policy changes. Rollback preserves the
original failure unless rollback itself fails.
The native TLS client checks server profile/hostname and local client identity;
DNS, TCP, TLS and HTTP phases have explicit four-second process deadlines. It
sends only the fixed authenticated health request and exposes no listener.

The canonical client identity lives under root:root 0700
`/etc/dragontools/monitoring-client/`, with four root-owned 0400 files:
`ca.crt`, `client.crt`, `client.key`, `identity.json`. Per-consumer Vector/vmagent
0400 copies are made locally, preserving the existing dedicated-user boundary.
This avoids giving either consumer access to the other's configuration or a
broader shared group. Root metadata, no-follow regular-file checks, bounded
content and cryptographic identity proof precede publication; a marker alone
cannot adopt unrelated credentials.

Enrollment/renewal is an explicit recoverable sequence:

1. Reconcile CA/server state and verify the station service/listener. Inspect public
   registration; a valid legacy client must authenticate from the application host.
   An expired legacy identity requires exact chain/key/fingerprint proof and is
   never treated as healthy. An already staged migration resumes its proven local
   transaction and refreshes candidate authorization before endpoint verification;
   it does not require a switched consumer to authenticate as the old identity.
2. Inspect the host identity. Reuse a valid key for renewal; create a new P-256 key
   for first enrollment or migration from a station-generated key. A private
   `.pending` generation retains the CSR and old generation across retries.
3. Validate/sign the public CSR. Atomically stage a registry lease for that exact
   certificate fingerprint/registration, expiring after 24 hours. A retry reuses
   the existing signed certificate by verified public key and identity and refreshes
   a lease only when less than one hour remains. The active identity is retained.
4. Stage and validate the public response against the local key and CA. Prove
   candidate mTLS before changing running consumers. Install only changed consumer
   copies, recording restart intent and exact private backups before publication.
5. Verify real running agent state, authenticated endpoint and fresh station
   telemetry. Only then promote the pending public registration, remove the
   legacy station `clients/<host>/client.key`, and commit/clean the local generation.
   Finalization is repeatable if interrupted at either host.

The private authorization helper accepts only an active registered fingerprint or the explicit bounded
rollout fingerprint, with the matching host SAN. A CA-signed unregistered client
is rejected. Legacy CN-only acceptance is restricted to its exact existing active
fingerprint while migration is pending; modern registrations require the URI SAN.
The lease permits real telemetry proof before revoking the old identity, not
open access to every certificate the CA has signed. Public registration fields
record certificate PEM, fingerprint and URI identity alongside existing host/app
metadata (serial and validity remain available from that certificate).

Signing and candidate-check failure cannot change installed consumer credentials.
Later rollout failure restores old consumer copies when available and preserves
restart intent/candidate state. A failure after attempting station finalization is
potentially ambiguous; do not restore an old key that may already be revoked.
Retain the working candidate and private backups until the next apply inspects
both hosts. The legacy key is unlinked only after successful proof/promotion;
normal unlink cannot guarantee physical-media erasure. No generic distributed
transaction, automatic CA replacement or controller state database is introduced.

Interrupted candidates that reach the renewal window are reissued with the same
local key. A bounded public certificate journal proves mixed publication states
and preserves the original private backups. Canonical-key recovery may reuse a
recorded historical consumer copy only after proving its identity, certificate
chain, recorded fingerprint and public-key match. When no matching local key
survives, an exact known public identity can re-enroll with a new local key and
the full candidate/telemetry proof. Conflicting or unprovable state is refused.

Application hostname changes use the same CA and existing station server key.
The signer validates the current managed bundle, then retains its existing DNS/IP
SANs and adds the explicitly configured DNS name, bounded to 16 names. The initial
`server/endpoint` remains provenance and must still be covered by the certificate.
Only one public certificate is atomically replaced, so interruption cannot leave
mismatched endpoint/certificate files. Restart intent precedes publication; retry
recognizes a successfully published certificate and does not issue another.
Old names continue to work for other registered hosts; automatic SAN pruning is
out of scope. A full SAN set fails safely and requires explicit maintenance.

Client `identity.json` and `.agent-identity` station fields record enrollment
provenance, not a mutable TLS destination. Their canonical format, valid origin,
machine identity, certificate/key pair and fingerprint still require proof;
preparation also compares the station's exact CA and active fingerprint. This
lets a hostname-only change reuse all credential bytes without a CSR or signature.
Consumer TLS uses the hostname in its exact rendered configuration. A pending
registration can carry the new hostname alongside the active old registration;
normal endpoint/telemetry proof gates its promotion. A simultaneous due renewal
uses the existing client key and the ordinary recoverable candidate generation.
Finish an existing enrollment transaction with its original config before starting
a different hostname change. On shared hosts, only the applying app's manifest
changes; other apps retain their signals and metadata. Keep their configured
hostnames consistent to avoid changing the shared agents' destination repeatedly.

Client/server certificates last 365 days. With more than 30 days remaining,
apply performs no CSR, signing, key regeneration, certificate rewrite, registry
rewrite or agent restart. At 30 days or less it renews using the same local key;
server-only renewal replaces only the server certificate and marks Caddy.
CA validity of 366 days or less causes `ca_maintenance`/`CaMaintenanceRequired`,
leaving CA material unchanged and requiring future explicit rollover. This avoids
issuing a full-year leaf beyond CA expiry. Read-only verify rejects expired
credentials and never renews or stages files.

`src/agent/endpoint.zig` and `src/pki/tls.zig` check host DNS, bounded TCP connection, trusted
server chain/hostname, client authentication and authenticated health in order,
after station service/listener verification. Fixed exit codes map to
`dns_unresolved`, `tcp_unreachable`, `server_tls_invalid`,
`client_certificate_rejected` and `ingestion_rejected`; the controller maps TCP
and request failures to `tcp_metrics_unreachable`/`tcp_logs_unreachable` and
`metrics_ingestion_rejected`/`logs_ingestion_rejected`. DNS/TCP/request absence
uses the ordinary bounded readiness policy; certificate failures are deterministic.
The helper never prints raw exceptions, commands or key material. Operators must
make TCP 9443 (metrics) and 9444 (selected logs) reachable and manage DNS/provider firewalls themselves. No provider
API, DNS edit, public ACME certificate or firewall rule is added.

The controller, station/application roots, OpenSSH configuration and CA are
trusted. A registered host can submit arbitrary metric content for its identity;
this is not hard multi-tenant isolation. Station ingestion overrides forged host
labels, demonstrated using the pinned VictoriaMetrics backend, and enforces
registered log application/service scope. Application namespaces, manual rules,
Grafana assets and the unsupported traces schema are unchanged.

### Bounded local storage and verification

Vector has separate logs/metrics disk buffers, each 268435488 bytes (its minimum,
approximately 256 MiB), `when_full: block`, acknowledgements, 10-second requests,
and backoff from one to 30 seconds. End-to-end acknowledgements are supported by
journald, not the host/internal/metadata sources; no lossless-source claim is made.
vmagent's on-disk queue caps at 1 GiB; upstream
can drop oldest queued blocks at the limit. A prolonged outage can cause journal
retention to expire entries while Vector blocks. Bounded storage is not a promise
of unlimited lossless delivery.

Effective journald configuration comes from `systemd-analyze cat-config`; the
installer evaluates later-sorting overrides and computes byte ceilings using
filesystem capacity. It creates only
`/etc/systemd/journald.conf.d/90-dragontools.conf` if required:
`SystemMaxUse=min(1 GiB, 5% of /var/log filesystem)`,
`RuntimeMaxUse=min(256 MiB, 2% of /run filesystem)`, `MaxRetentionSec=7day`.
Stricter administrator limits remain stricter; the main configuration and unrelated
drop-ins are untouched. Conflicting later overrides or unrecognized managed paths
are refused. A persisted journald restart marker permits interrupted recovery.
Read-only verify checks effective bounds and journal state. Direct application
file logs are outside this policy.

Deterministic binary/configuration/user/hardening/argument/listener errors fail
without retry. Runtime checks use the common bounded readiness policy (15 seconds
active, 30 seconds HTTP, 45 seconds signal checks; 500ms first retry then one
second). Station queries require host samples within 90 seconds, selected log
streams within two minutes, and each application's `up=1` plus a recent real
non-scrape metric. Install/verify require these samples to postdate the current
agent process start, so stale data cannot prove a changed target URL works. Both
host clocks must be synchronized; Vector uses agent-side timestamps. Install never
claims success for only local configuration.
A signal timeout retains restart intent; eventual recovery permits normal
finalization. Status reports bounded read-only observations without secrets.

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
credential path. The opaque Secret infrastructure redacts and wipes; Grafana now has a controller-local
1Password resolver and protected reconciliation consumer. Telegram now uses the
explicit protected-file exception below. Agent mTLS uses its separate dedicated
protected-file boundary; public Grafana/ACME TLS remains unavailable.

## External probing and alert runtime

The station runs blackbox_exporter, Alertmanager and two vmalert instances in
addition to the four existing storage/UI services. VictoriaMetrics' native
Prometheus scraper was chosen over a station vmagent: the pinned single-node
server already supports the full relabeling/target API needed here and writes
samples directly into its storage. No new polling daemon, persistent scrape queue
or scraper listener is needed. This does not deliver application-host vmagent.
See [the pinned native scraper](https://github.com/VictoriaMetrics/VictoriaMetrics/tree/v1.151.0/lib/promscrape)
and [the single-node integration](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.151.0/app/vminsert/main.go).

The component and listener boundary is fixed:

| Service | Account | Listener | Persistent write access |
| --- | --- | --- | --- |
| blackbox_exporter | `dt-blackbox` | `127.0.0.1:9115` | None; account home exists but service namespace is read-only |
| Alertmanager | `dt-alertmanager` | `127.0.0.1:9093` | `/var/lib/dragontools/alertmanager`; clustering disabled |
| vmalert-logs | `dt-vmalert-logs` | `127.0.0.1:8880` | None; alert state uses local VictoriaMetrics |
| vmalert-metrics | `dt-vmalert-metrics` | `127.0.0.1:8881` | None; alert state uses local VictoriaMetrics |

Each has dedicated nologin accounts, root-owned executable/configuration paths,
private temporary storage, empty capability sets, filesystem/kernel protections,
and ordinary AF_INET/AF_INET6/AF_UNIX only. No raw-socket privilege is granted;
ICMP, node_exporter and custom modules are absent. Blackbox needs outbound DNS and
HTTP/HTTPS, so its network namespace is not isolated from configured targets.

### Reviewed release pins

Reviewed on 2026-09-17. The official blackbox release is `0.28.0`, Alertmanager is
`v0.34.1`, and vmalert comes from VictoriaMetrics `v1.152.0` vmutils archives.
Archive hashes were checked against official GitHub release asset digests;
blackbox and Alertmanager additionally match their published `sha256sums.txt`.
Extracted binary hashes below were calculated from those verified regular archive
members without executing them. These trust the upstream release publishers;
they are not independent code signatures or a vulnerability audit.

- [blackbox release](https://github.com/prometheus/blackbox_exporter/releases/tag/v0.28.0),
  [published checksums](https://github.com/prometheus/blackbox_exporter/releases/download/v0.28.0/sha256sums.txt)
- [Alertmanager release](https://github.com/prometheus/alertmanager/releases/tag/v0.34.1),
  [published checksums](https://github.com/prometheus/alertmanager/releases/download/v0.34.1/sha256sums.txt)
- [VictoriaMetrics/vmutils release](https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.152.0),
  [official asset metadata](https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/tags/v1.152.0)

| Component | Architecture | Archive SHA256 | Extracted binary SHA256 |
| --- | --- | --- | --- |
| blackbox_exporter | amd64 | `caf5d242fb1cf6d5cb678f3f799f22703d4fafea26b03dcbbd7e1f1825e06329` | `b79da51dce26afbc787917a3bf884ac84dcf1af8862c4ab215ca23b7c327ca04` |
| blackbox_exporter | arm64 | `63312be0983d85e5109710a7dc93df3051157ae581853fa3655d171cc1b2806e` | `9132ceb241475206df4ea55a9174e79e563b6fb4fe188873bbb0519110ef8f57` |
| alertmanager | amd64 | `265b9d1e55ef0d5306a436018af6d2b686c2ce051f03d968f7464ecb1372a7e8` | `154890307c382a186d4ddf9354cfa0cab08771f818aac1e647d0cf277ecef854` |
| amtool (same archive) | amd64 | Same as Alertmanager | `1153b0dbf2a672fd54f7da597901b776a3d4e0daaa5c38f3710efc51b8c3b4c8` |
| alertmanager | arm64 | `d98d6cbaf52151c7e76e24355fec88b11cebcb9875d4cdd8b76ddce7a7e5535c` | `cfd1845106fe1c2e1966a60805cb6c7c7bd6fae1bf77423cc1e049ca5f80c62f` |
| amtool (same archive) | arm64 | Same as Alertmanager | `8391c16f27696ce5394b05fae09bb158cee97e38b03c2f409d3a6a0265ad30c9` |
| vmalert | amd64 | `8eee4a98ff1665c60682475e8a8b292b8d718b63a2f023124384dd2f6a220c79` | `be382c490ad6eb417a30ad4ef34a66bf531a98b70eded79aa1006ca4455d7bc5` |
| vmalert | arm64 | `57c567b262962a4cb8e35c0c34efe64629a3e1ea69ac0611d8d67e168df8b1e8` | `4d63b96d68f62ea1ca51e3544c35257038bf1b41e542434fe8fad02575017f3c` |

Pinned URLs use these exact versioned forms, with `amd64` or `arm64` in place of
`<arch>`; installation never fetches mutable latest metadata or runtime checksums:

```text
https://github.com/prometheus/blackbox_exporter/releases/download/v0.28.0/blackbox_exporter-0.28.0.linux-<arch>.tar.gz
https://github.com/prometheus/alertmanager/releases/download/v0.34.1/alertmanager-0.34.1.linux-<arch>.tar.gz
https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.152.0/vmutils-linux-<arch>-v1.152.0.tar.gz
```

Only the reviewed binary members are extracted after archive verification, into
private staging on the installation filesystem. Binary verification precedes
atomic publication and a relative `current` symlink switch. Prior version
directories remain for operator recovery. Correct pinned bytes are not downloaded
again; supported ownership/mode repair does not restart healthy services.

### HTTP module and metric contract

`/etc/dragontools/blackbox-exporter/blackbox.yml` contains only `http_2xx`:
HTTP GET, default 2xx success, timeout five seconds, IPv4 preference and family
fallback, redirects enabled and TLS certificate/hostname verification enabled.
The CLI exposes no authentication, headers, custom labels or module language.
HTTP/2 is explicitly disabled because this upstream release uses the transport
affected by [GO-2026-4918](https://pkg.go.dev/vuln/GO-2026-4918);
[pinned dependency](https://github.com/prometheus/blackbox_exporter/blob/v0.28.0/go.mod)
and [transport construction](https://github.com/prometheus/common/blob/v0.67.4/config/http_config.go)
were reviewed. This is an HTTP/1.1 availability slice, not a claim that the upstream
release is patched or every transitive vulnerability has been eliminated.
Normal redirects remain as upstream implements them. A family fallback selects
an available address family, not repeated attempts across every resolved address.

Probe TOML validation occurs before SSH: at most 64 probes, unique 1–63 byte
ASCII names, alphanumeric first byte then alphanumerics/underscore/hyphen; HTTP or
HTTPS URLs at most 2048 bytes. Credentials, query strings, fragments, controls and
obscured percent-encoded authorities are rejected. Scheme/hostname case, default
ports and empty paths are normalized without rewriting meaningful path bytes.
URLs must not contain secrets: the normalized configured target is a stored label.

The native scraper uses `/probe?module=http_2xx&target=...` on `127.0.0.1:9115`,
every 30 seconds with a five-second scrape deadline. The exporter subtracts its
normal 0.5-second response margin, leaving a probe deadline up to 4.5 seconds.
It returns `probe_success=0` on DNS/connect/TLS/status/timeout failure while the
scrape itself can succeed. This is the central mechanism for detecting complete
application disappearance, independent of logs or the application's metrics API.
[Probe result/timeout behavior](https://github.com/prometheus/blackbox_exporter/blob/v0.28.0/prober/handler.go).

Metric relabeling keeps the fixed availability, duration, HTTP status/TLS/redirect,
IP-family and certificate-expiry metrics. Only `job`, `instance`, `probe`, `target`
and the fixed timing `phase` remain; certificate fingerprints, subjects and
arbitrary response fields are discarded. `ServiceProbeFailed` selects the owned
job's `probe_success == 0`, holds two minutes, and sets critical/blackbox labels.
Its annotations identify the probe and target without response bodies. Latency
metrics are available for queries, but no default latency alert is installed.

### Reload, alert state and verification

The first upgrade enables VictoriaMetrics native scraping in its unit and may
restart only VictoriaMetrics for that unit change. Later probe additions/removals
atomically replace `/etc/dragontools/victoriametrics/prometheus.yml` and preserve
`victoriametrics-scrape-reload-required` before native reload. The generated
blackbox module and probe alert rule are independent of probe count, so those
changes do not restart blackbox, either vmalert or other services. An unchanged
rerun does not reload, rewrite, download or restart.

Both vmalert instances share `/opt/dragontools/components/vmalert/v1.152.0/` and
`current`, but use independent `/etc/dragontools/vmalert-{logs,metrics}/rules.yml`,
accounts, units and restart intent. Shared binary publication marks both instances
before changing bytes/selection. Each instance finalizes only after its own
verification. Remote read/write point to VictoriaMetrics `127.0.0.1:8428` for alert
state; the pinned [write client](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.152.0/app/vmalert/remotewrite/client.go)
uses bounded in-memory queues and HTTP, not a persistent spool. A crash can lose
unflushed state; local remote storage is not a stronger delivery guarantee.

Both generated units explicitly set `-group.maxStartDelay=1s`. VictoriaMetrics
vmalert v1.152.0 crashes with `0s`: `Group.delayBeforeStart` uses the minimum of
the group interval and this flag as a modulo divisor, so zero causes a
divide-by-zero panic. The positive one-second bound keeps this scheduling delay
within the readiness deadline. Updating either unit preserves restart intent only
for that instance; a successful restart and verification make the next install a no-op.
[Pinned startup-delay calculation](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.152.0/app/vmalert/rule/group.go#L515-L543).

The logs instance queries VictoriaLogs with the fixed ErrorBurst/CriticalLogEvent
pack; metrics queries VictoriaMetrics with ServiceProbeFailed. Both notify local
Alertmanager. `-dryRun` validates fixed rule syntax/templates before rule-file
publication; it exits before notifier startup. Runtime verification reads the
loaded rule API with `exclude_alerts=true`, validates the expected identities,
expressions, labels, intervals and recent successful evaluations. Pending/firing
alerts are valid station state, not verification failures. No synthetic telemetry
or test alerts are sent by verification.

Blackbox verification checks exact managed files/binaries/units, account metadata,
loaded module policy, exporter build/reload metrics, effective hardening and
PID-owned loopback listeners. The scraper verifies loaded definitions and recent
stored `probe_success` samples, accepting both zero and one. Status observes
stored data and returns unknown for missing/stale results rather than making new
requests to targets. Runtime checks have bounded readiness retries; deterministic
identity/configuration failures fail immediately and preserve restart/reload intent.

The scraper also checks the fixed loaded metric/relabel policy through
`/api/v1/status/config`; matching active targets cannot hide a stale policy reload.
Its narrow canonical YAML fixture was reproduced with the pinned `yaml.v2` 2.4.0
marshaller and the reviewed VictoriaMetrics types. This serialization check is
not execution of VictoriaMetrics or a substitute for disposable-host verification.
Recent removed-target samples are bounded separately from the 64 current probes.
Fixed helper source uses standard-library zlib compression for transport; target
data remains separately encoded and quoted. Tests exercise accepted 64 KiB TOML
at both 32 and 64 probes across mutation, verification and status SSH commands.

Telegram is optional: `[telegram]` contains two existing SecretRefs, resolved
locally during install and passed only through protected SSH stdin. The dedicated
consumer owns `/etc/dragontools/alertmanager/secrets/telegram-bot-token` and
`telegram-chat-id`, both `dt-alertmanager`, mode `0400`, under a protected directory.
The generated Alertmanager YAML uses only `bot_token_file` and `chat_id_file` paths.
No secret value enters ordinary file writers, YAML, units, argv, plans or output;
the remote host does not need `op`. Equal values preserve files and services.
Missing refs select a discard receiver. Configured warning/critical alerts are
grouped by configured identity and resolved notifications are enabled.

Alertmanager's pinned Telegram client propagates errors containing request URLs;
a network error can therefore expose the token in the `/bot<TOKEN>/sendMessage`
path. The unit sets `StandardOutput=null` and `StandardError=null`, and verification
checks both effective properties. Native Alertmanager journal diagnostics are
unavailable; systemd state, health/API/metrics and fixed controller errors remain.
This suppression is specific to the secret-bearing native notifier and does not
change verification fixture stderr assertions. [Pinned notifier](https://github.com/prometheus/alertmanager/blob/v0.34.1/notify/telegram/telegram.go),
[client request construction](https://github.com/tucnak/telebot/blob/v3.3.8/api.go),
[client error wrapping](https://github.com/tucnak/telebot/blob/v3.3.8/errors.go).

`monitoring notify-test` is the only explicit synthetic notification path. It
submits a clearly identified short-lived alert to installed Alertmanager; it never
creates a failed probe target or resolves Telegram refs again. API acceptance is
not evidence that a human received Telegram. Normal live evaluators can send real
alerts independently while install/verify runs. Local tests cover redaction,
rendering, retries and reruns; supported-host systemd, real TLS targets, actual
rule evaluation timing and Telegram receipt remain separate integration gates.
**Disposable-host integration not run.**

## Alert policy and partial rendering

The alert policy remains defined in `src/monitoring/policy.zig`. CPUHigh,
MemoryPressure, DiskWarning, DiskCritical and InodesCritical now use the verified
Vector metric contract. The fixed host pack selects `agent="vector"`; it is
installed by station setup and reconciled after agent signal verification, and
has no inputs before matching host metrics arrive. HostDown remains deferred.
`renderServices` returns `ServiceMetricContractUnavailable` for requested units;
an empty list returns `groups: []`. Systemd service-state monitoring remains
intentionally deferred.

The host-pressure rules are deployed; HostDown and service-state entries remain policy:

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

The host metric contract is captured from pinned Vector output and tested locally.
The inode policy leaves 10% headroom and waits five minutes. Storage installation
alone does not generate application-host metrics; use `monitoring agents`.

`renderLogs` remains a small deterministic local YAML renderer using the policy
module, without a template engine or SSH. Its separate `type: vlogs` group is
used by the installed logs evaluator and selected Vector application streams:

| Rule | Condition |
| --- | --- |
| ErrorBurst | At least 5 normalized `error` events per service over 5 minutes; no additional hold |
| CriticalLogEvent | At least one normalized `critical` or `fatal` event per service over 1 minute; no additional hold |

These are internal APIs; no rule-export or deployment CLI command is introduced.
The installed workflow validates and deploys the log pack and the separate probe
rule and verified host pack. Service-state metric alert rendering remains unavailable.

Log rules depend on normalized structured fields: `timestamp`, `level`, `service`,
`host`, `environment`, `request_id`, `event`, and `duration_ms`. Severity matches
exact structured values through `level:in(error)` and `level:in(critical,fatal)`;
arbitrary message text does not establish severity. The queries use `_time:5m`
or `_time:1m`, then group with `stats by (service) count()` and filter the count.
Counts combine events sharing the same service value across hosts; callers must
provide consistent service naming. Missing service values form one unnamed group
for unmanaged producers; managed Vector streams always supply trusted service identity. Log annotations identify the service and count,
without copying log messages, request IDs, or secret fields.

The installed log group evaluates every minute. CriticalLogEvent has no `for:`
delay and fires on the next matching evaluation; notification delivery remains
asynchronous through Alertmanager.
Station readiness checks only the base groups and their exact loaded policy,
healthy evaluation and freshness. It never enumerates application rule files or
requires positive `lastSamples`. The optional wildcard may match nothing, even
when `/etc/dragontools/apps` does not exist. Application apply/app-verify check
only their own expected managed rules separately. Missing groups or rules are
retryable startup absence within the 45-second rule deadline; invalid policy is
a deterministic failure. Application apply retains restart intent until its
scoped rule readiness succeeds. Units, rule paths and alert definitions are
unchanged by this separation.
ErrorBurst avoids alerting for each ordinary error, though overlapping windows can
keep an alert active. Alertmanager grouping/deduplication controls delivery.
Generated log rules have stable `severity` and `source` labels and concise
service/count summaries.

Upstream supports `type: vlogs` and the log-query statistics/filter pipeline.
Each vmalert process uses a configured datasource URL, so metrics and logs must
use the separate installed evaluator instances with explicit datasource routing. A `vlogs` group alone does not route a query to VictoriaLogs. The explicit
`_time` windows are intended for live evaluation; upstream does not support those
custom windows for replay/backfill. [VictoriaLogs alerting documentation](https://docs.victoriametrics.com/victorialogs/vmalert/).

Unit tests cover policy values, the captured host metric contract, service-rendering refusal,
deterministic log YAML, thresholds, durations, labels, and basic structure. No
real evaluator or application log pipeline is exercised by renderer tests. A later
integration run must verify the service-state solution when implemented,
event-time mapping, ingestion latency/window boundaries and end-to-end alert
delivery. Pin validation and API rule checks establish narrower local contracts;
fake-remote/renderer tests do not prove live evaluation or Telegram receipt.

## Dashboards and additional alert packs: roadmap

Add dashboards: Host Overview,
Monitoring Station, Service Health, Storage, Updates / Security. Metrics, Logs and
Traces are provisioned now. Configured credentials exercise the Logs query path;
Metrics/Traces query-engine checks and browser UI validation remain integration gates.

The current installation deploys fixed log, external-probe and verified host packs.
Vector and optional vmagent are implemented by the separate agents workflow.
OTel Collector, service-state alerts, firewall and public Grafana TLS remain
unavailable. The station-local native scraper is separate from app-host vmagent.

Beyond the installed probe/log/host packs and deferred service-state policy, later rules will include:

| Group | Planned rules (not rendered yet) |
| --- | --- |
| Pipeline | LogsNotArriving, MetricsNotArriving, VectorForwardFailure, VmagentForwardFailure, MonitoringDiskPressure |
| Updates | CriticalSecurityUpdatePending, SecurityUpdateInstallFailed, MonitoringComponentUpdateAvailable, MonitoringAgentUpdateAvailable, OSReleaseNearEndOfSupport, OSReleaseUnsupported, UpdateCheckFailed, UpdateCheckStale |

SecurityUpdatesPending and RebootRequired are already rendered in the host pack,
using the verified native-agent/Vector metric contract and a 24-hour warning delay.

Optional Telegram now uses vmalert → Alertmanager → bot → channel/chat with
protected credential files and grouped warning/critical/resolved notifications.
Only explicit `monitoring notify-test` submits a test alert. Installation and
verification never send test notifications. API acceptance alone is not proof of
Telegram delivery to a human. No other notification provider is exposed.

## Read-only maintenance and future update policy

Future component release monitoring will track VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana, vmalert, Alertmanager,
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
or stale checks. This future mutation policy is not implemented. Current `maintenance check` and
Vector-scheduled agent metrics only inspect Ubuntu state; no unattended-upgrades
files are modified, no package index refresh occurs, and no upgrades or reboots
are run. The implemented SecurityUpdatesPending/RebootRequired warnings wait
24 hours. There is no separate timer, listener or arbitrary remote command channel. Future explicit upgrades must verify new artifacts,
preserve previous versions, restart affected services and verify before success.

## Complete-stack verification gate

Later station completion requires healthy VictoriaMetrics/Logs/Traces, Grafana,
vmalert and Alertmanager; working datasource queries; visible host metrics;
storage controls; active fresh update checks; Telegram test if configured; valid
public Grafana TLS if configured. The current agent slice requires Vector and any
configured vmagent health, bounded journald, authenticated station reachability and
actual logs/metrics arrival. Later full-stack completion adds OTel traces and fresh
maintenance checks. These are not current integration-test claims.

See README non-goals. The scope remains one node, systemd, trusted infrastructure,
per-host mTLS ingestion and explicit workflows rather than generic management.
