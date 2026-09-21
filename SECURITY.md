# Security policy

Application repositories contain only the strict public `monitoring.toml`
contract. Station credentials/references belong in separately managed station
configuration. `monitoring apply` validates before SSH and binds app namespaces
to explicit application/environment/machine identity. Exact manifest ownership
protects generated files; edits, unmanaged files and rebinding fail rather than
being adopted. Other apps, manual rules and Grafana assets are preserved.
The controller and host roots remain trusted. Future dashboards require owned
deterministic UIDs/app folders; no arbitrary configuration upload is supported.

Do not report credential leaks or exploitable vulnerabilities in public issues.
Use the repository's **Security → Advisories → Report a vulnerability** private
reporting feature if enabled. If unavailable, ask the maintainer for a private
reporting channel without including exploit details, secrets, or affected hostnames.
No private email address is invented by this project. Rotate exposed credentials
through their provider and share only sanitized evidence.

This is an initial development milestone, not a claim of a security audit or full
monitoring coverage. Only the current development version is maintained.

## Trust model

DragonTools connects over SSH. Monitoring install requires administrator-level target access.
Strict known-host verification is mandatory; verify fingerprints out-of-band before
first use. The controller, its PATH/OpenSSH installation, known-hosts file, SSH agent,
target OS, trusted distro CA store and reviewed artifact pins are trusted.
Direct connections disable inherited local SSH config and forwarding. The monitoring and
host `--ssh-host` mode delegates alias, authentication and proxy resolution
to OpenSSH, so local SSH configuration and its configured proxy commands are also
trusted. Strict host-key checks remain enabled in both modes. SSH private keys
remain with the agent or OpenSSH identity file; 1Password itself is optional.

Agent telemetry requires per-host registered mTLS certificates on the separate
Caddy listeners :9443 (metrics) and :9444 (logs); :9445 is reserved and closed. Monitored hosts are trusted infrastructure; a
compromised registered host can submit arbitrary metric content for its own
authenticated identity; the ingestion route enforces the host label. This does not provide
hard multi-tenant isolation.
Grafana still needs user authentication. A provider firewall is recommended outside
the monitoring-only host rules. Raw administrative APIs must not be exposed to agent
networks. Current VictoriaMetrics, VictoriaLogs, and VictoriaTraces bind loopback
only on 8428, 9428, and 10428; authenticated Grafana binds 127.0.0.1:3000.
Blackbox exporter, Alertmanager, vmalert-logs and vmalert-metrics bind loopback on
9115, 9093, 8880 and 8881. Alertmanager clustering is disabled, including its
normally separate cluster listener. These administrative and probe APIs are
reachable by target-local users and explicitly established SSH tunnels. The agent ingress listener requires TLS 1.2+ and registered clients, permits only
fixed write routes plus authenticated health, and keeps raw backends private.
Operators permit TCP 9443 (metrics) and 9444 (selected logs) from monitored hosts; DragonTools changes no firewall.


Without configured administrator secret references, a fresh Grafana database uses
its upstream first-login flow. Change the standard initial password immediately
through the SSH tunnel; existing accounts remain unmanaged and are not reset.
Explicit references opt in to reconciliation and read-only authenticated identity
verification. Authentication is checked before mutation so correct credentials do
not trigger a reset or restart. Anonymous access, auth proxy and user signup remain
disabled. Target-local users can reach loopback and the target OS/administrators
remain trusted. Grafana setup adds no firewall ports, public TLS or ingestion;
agent mTLS is a separate workflow.
Grafana verification reads non-secret datasource fields from SQLite and queries local
backends as its service account. Configured credentials additionally check the
administrator identity and the official Logs plugin health/query path through
Grafana. These API checks are read-only, including the query POST; they neither
write log data nor modify datasource configuration. Unconfigured verification
reports the authenticated Logs query as unchecked. Browser validation remains a
separate disposable-host gate.

The official VictoriaLogs datasource plugin is executable third-party code within
Grafana's existing `dt-grafana` service boundary. Its exact versioned HTTPS archive,
per-file catalog and preserved signed manifest are checked; arbitrary unsigned
plugins are not allowed. Plugin trees and their active selection are root-owned,
with both persistent plugin roots mounted read-only in the service namespace.
Private staging rejects unsafe archive entries and unrecognized existing trees.
Atomic publication preserves the previous release for operator recovery and keeps
Grafana restart intent through failed verification. No plugin TCP listener or
public backend access is added on supported Linux targets. The checksum and
signature trust the reviewed publisher; this is not a third-party-code security
audit. See [the exact pins and source review](design.md#official-victorialogs-datasource-plugin).


The station retains only its root-private CA key and local server key. Client
P-256 keys are generated only on monitored hosts. The controller transports bounded
public CSRs and signed certificates, never private keys. A root-private canonical
machine identity supplies service-owned 0400 copies locally. Strict CSR policy
fixes the machine CN/URI SAN, CA:FALSE, digitalSignature and clientAuth. The private authorization helper
requires the exact registered fingerprint and machine identity in addition to TLS
chain/purpose checks; CA-signed unregistered clients are denied.

Renewal at 30 days reuses existing local keys. The CA is preserved and requires
explicit maintenance near expiry; automatic CA rollover is unavailable. Legacy
migration retains working credentials while an explicit 24-hour candidate lease
permits mTLS/telemetry proof. Only successful finalization promotes the new
registration and unlinks the old station client key; unlink does not guarantee
physical-media erasure. Recoverable private local generations remain after
interruption. Read-only verification never repairs or renews credentials. See
[the PKI lifecycle](design.md#mtls-ingestion-and-trust-boundary) for rollback and
uncertain-finalization behavior.

Logs enforce registered service identities and overwrite host identity; metrics
are not a fully validated multi-tenant content boundary. Vector has access to the
journal group but its generated configuration selects only named units;
application/agent root remains trusted. See the agent design for bounded buffering,
journal retention and explicit data-loss limits during outages.

## Secrets and privileges

Secret handles redact formatted output and wipe owned memory. Resolved secrets must
never enter ordinary command strings, process arguments, systemd Environment lines,
world-readable files, DragonTools logs, errors or plans. Generic file writing is non-secret only.
The optional local 1Password resolver reads explicit Grafana references before
SSH. Both username and password are sensitive, opaque and redacted; provider stderr
is suppressed. References can be committed without secret values, but may reveal
vault/item names. Plans, status, help and completion never resolve them. The host
receives resolved values only through protected SSH stdin; no `op` binary, session
or provider credentials are uploaded. Successful reconciliation leaves Grafana's
normal credential hash and no DragonTools plaintext password on the host.
The credential helper discards all Grafana CLI stdout/stderr and returns fixed
semantic results. Grafana itself retains account identities and authentication
metadata; upstream operational/audit logging may include a username, including
on authenticated HTTP errors. This is separate from DragonTools' redacted output.
The helper never logs the password. Native Grafana logging has been reviewed in
pinned source; disposable-host credential integration has not been run.
Optional Telegram references resolve locally during install only. The dedicated
protected stdin consumer stores the token and chat ID in service-owned mode-0400
files under `/etc/dragontools/alertmanager/secrets`, with restrictive parent access.
These persistent plaintext files are required by this explicitly configured
consumer: they are readable by root and `dt-alertmanager`, never by ordinary file
writers or through generated YAML, argv, units or DragonTools output. References
are the only values retained in the controller configuration. Verification and
status inspect installed policy without resolving Telegram references. The
explicit `notify-test` submits a short-lived alert to Alertmanager; acceptance
does not establish human receipt. Live rule evaluation may send real notifications
independently of an install or verify invocation.

The pinned Alertmanager Telegram error path can include the bot token in its HTTP
URL. Its service therefore sets both `StandardOutput=null` and
`StandardError=null`, and verification requires those effective values. Native
Alertmanager journal logs are unavailable. Use systemd state, health/API/metrics
and fixed semantic controller errors for diagnosis. This is not global stderr
suppression and does not weaken shell fixture assertions. See the
[pinned client source review](design.md#external-probing-and-alert-runtime).

Future persistent TLS consumers must use systemd credentials as described in
architecture.md, with encrypted root-only sources and a reviewed plaintext
fallback only when explicitly selected. The Telegram consumer above is an
explicit, separately reviewed protected-file exception.

Service hardening limits privileges and filesystem writes. It is not protection
against an already-compromised root account or controller. An artifact digest verifies
agreement with the reviewed upstream release; it does not protect against a malicious
publisher. Managed root directories must not be shared with untrusted writers.

External HTTP/HTTPS probes are outbound requests issued as `dt-blackbox` without
raw-socket privileges. Configuration accepts bounded names and URLs but no URL
credentials, query strings, fragments, headers or custom labels. Names, target
URLs and paths are non-secret metadata: they are stored with metrics, may appear
in status, and identify failing alerts. Do not place secrets in URL paths.
The generated module follows redirects and permits trusted configured destinations
to resolve or redirect to private addresses; no egress sandbox or SSRF filter is
claimed. Only trusted administrators should configure probes or access the local
exporter's probe API. Targets and their responses are otherwise untrusted.

The five-second HTTP module verifies TLS certificates, prefers IPv4 with DNS-family
fallback, and disables HTTP/2. The reviewed blackbox 0.28.0 release contains a
dependency affected by GO-2026-4918; disabling HTTP/2 avoids the affected transport
for this fixed module, but does not claim the upstream release has been patched.
There is no ICMP module. Probe history is disabled and ordinary probe logs are
restricted to errors. Prometheus relabeling retains only the reviewed metric and
label sets; target failure is recorded as `probe_success=0`, not a station failure.
See the [exact pins and HTTP transport review](design.md#external-probing-and-alert-runtime).

The host utility inspects the SSH login account before elevation and writes home
content as the target account. Missing packages or switching to another target may
require noninteractive sudo. It refuses conflicting paths and preserves existing
Oh My Zsh and regular `.zshrc` files by default. `--update-managed-zshrc` may replace
only an exact known DragonTools template owned by the target account with one hard
link; a marker alone cannot authorize overwriting user edits. New source is pinned and checksum-verified;
an existing user installation is deliberately not audited, repaired or updated.
`--set-default-shell` is required to change the login shell; it validates the
discovered zsh path against `/etc/shells` and avoids `chsh` if already correct.
Managed migration uses private staging, fresh content/identity checks and atomic
publication; do not edit `.zshrc` concurrently with that explicit operation.
The command never executes the upstream installer.

## Failure and recovery

A failed install may have created accounts/directories or replaced a binary/unit.
Later phases stop; no destructive rollback is attempted. Output reports confirmed
progress and the failed component/phase. Inspect the unit/journal locally, fix the
cause, and rerun. Each component preserves its restart-intent marker until
verification succeeds; unchanged healthy services are not restarted. Standalone
verification is read-only and never clears markers. No controller-side state
database is used. Do not post raw command output or secret-bearing logs publicly.
Keep storage backups independently; a free-space threshold does not replace them.

## Embedded cryptography maintenance

Pinned **Mbed TLS 4.2.0**, official release archive (includes TF-PSA-Crypto 1.2.0):
https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.2.0/mbedtls-4.2.0.tar.bz2
SHA-256 `2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea`.
The upstream release digest and downloaded archive were reviewed on 2026-09-18;
this is dated provenance, not a permanent claim of freshness or a security audit.
Vendored upstream files remain unmodified and have an offline SHA-256 manifest.
The reviewed feature subset and licenses are in `vendor/mbedtls/README.md` and
`THIRD_PARTY_NOTICES`. Controller/helper metadata exposes the compiled version,
source digest and code-reviewed **minimum approved version 4.2.0**.

Weekly/manual `crypto-maintenance.yml` verifies the official archive against the
vendored subset and checks upstream stable releases. Unreachable feeds fail that
maintenance check, not normal installation/verification. A newer release flags
review; it never changes pins. Maintainers review release/security advisories,
update the approved floor, version, source/hash/config and notices intentionally,
run native PKI, malformed corpus, filesystem lifecycle and real local mTLS tests
on Linux/macOS, cross-build all four controllers and both helpers, and release
matching binaries. Do not infer trusted security decisions from scraped CVE prose.

Native PKI has no Python/OpenSSL CLI/openssl.cnf dependency. Pinned Caddy v2.11.4
terminates mTLS; the private Python authorization/normalization helper uses only
protected Unix sockets. It cannot read CA/server keys and does not terminate TLS.
Caddy strips caller identity headers and replaces them with verified certificate
assertions. Registry fingerprint/URI checks and trusted log labels remain enforced;
CA signature alone is insufficient. Each port has exactly one socket/backend and
no arbitrary proxy route, Caddy admin API, ACME or unconfigured trace listener.
The historical public Python gateway is not installed or revived.
The native enrollment helper has no listener; its internal interface accepts only fixed operations,
bounded public envelopes and fixed managed paths, never arbitrary command text.
It keeps CA/server keys on the station and client keys on the host, with root
canonical state and service-local copies. Protected directories, exclusive private
staging, file metadata checks, local serialization and independent restart intent
remain required; a generated-file marker alone is not an ownership proof.

Read-only maintenance uses bounded distro providers and emits no package names,
command output, raw stderr or credentials. Missing providers, stale APT metadata
and unrecognized automatic-update policy remain unknown. The optional Ubuntu
apt-check provider can depend on distro Python; it is not part of the PKI backend.
No automated installation, security-policy mutation, reboot or vulnerability scan
is implemented. The controller and host roots remain trusted.
