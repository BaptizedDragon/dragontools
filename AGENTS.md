# Working on DragonTools

Use Zig 0.16.0 and the standard library where practical. Keep monitoring workflows under
`dragontool monitoring`; the separate `host install-oh-my-zsh` utility installs
missing shell tooling for an existing account, with explicit options for its managed
configuration and login shell. `wizard` and `completion` are local UX entry points.
No generic resource DSL, shell hooks or provider framework.
Read README.md, architecture.md and design.md before changing workflow behavior.

The primary application workflow is `monitoring apply` with strict version-1
`./monitoring.toml`, or one explicit `--config`. Keep application configuration
separate from central station configuration and secrets. Application/environment
identity is explicit, never inferred from repository paths. Logs default disabled;
host metrics always run; vmagent is conditional. Traces/custom metrics alert
declarations fail clearly while unsupported. app-verify/app-status are read-only.
Plan validates locally without SSH. Shared metadata drives CLI/help/completion
and wizard; wizard apply retains explicit default-No confirmation.

Each application owns only its namespace under `/etc/dragontools/apps/<name>/`.
Prove exact generated content against its manifest before reconciliation; preserve
other app files, manual rules, Grafana assets and central secrets. No global
overwrite/adopt. Names bind environment and machine identity. Preserve recoverable
publication generations and independent scraper reload / evaluator restart intent.
Shared-host signal manifests merge into one Vector/vmagent without dropping other
apps. Probe/alert-only changes never dirty agents. Trusted app/environment/host/
service labels must override incoming data. Use shared host rules and one default
or overridden alert per probe. Future dashboards require owned app folders and
deterministic UIDs; no arbitrary config/DSL injection.

Safe reruns are mandatory for every mutating command. Inspect actual remote state
on every run; never assume a previous deployment completed. Correct accounts,
directories, binaries and units are no-ops. Refuse incompatible accounts and
unexpected symlinks; repair only explicitly supported metadata. Do not redownload
valid pinned binaries or restart healthy unchanged services. Reload systemd only
when unit state requires it. Keep each component's restart intent independent,
preserve it through failures, and verify before finalization. Verification itself
must remain read-only. Do not add a controller-side state database.

Maintain small concrete modules and explicit argument validation. Dynamic remote
arguments must go through system/remote.zig quoting; never interpolate untrusted
input into executable shell text. Do not log raw remote stderr, command strings,
CLI values, or resolved secrets. The wizard's explicit local equivalent-command
preview may display validated options and safe credential references; it must never
resolve or print secret contents. Preserve strict SSH host-key checks.

Interactive mode is a frontend to the regular DragonTools command model, not a
separate deployment engine. Share command/flag metadata across parsing, help,
completion and wizard command generation; reuse validators and normal dispatch.
Wizard mutation requires an equivalent-command preview and explicit default-No
confirmation. Non-interactive CLI commands retain their existing semantics.
Keep no-argument non-TTY calls nonblocking and wizard tests driven by injectable
input/output, without real terminals.

Shell completion is local, deterministic, side-effect free, and never contacts
remote hosts or secret providers. Use native shell path completion for path options
and never modify shell startup files when installing completion.

Keep the host utility separate from monitoring. Let OpenSSH resolve `--ssh-host`
through native SSH configuration while preserving strict host-key checks. Inspect
the SSH login account and actual target home; never guess a home or create a user.
Install only missing zsh/Oh My Zsh and preserve existing Oh My Zsh. Preserve existing
`.zshrc` by default; `--update-managed-zshrc` may migrate only an exact known
DragonTools template. A marker alone never authorizes replacing local edits or
arbitrary files. New managed `.zshrc` must show user, hostname and directory with
Oh My Zsh and the git plugin enabled. Change a login shell only when explicitly
requested with `--set-default-shell`, after validating the discovered zsh path in
`/etc/shells`; never call chsh if already correct. Pin new
Oh My Zsh source, use private staging and safe publication, and refuse conflicting
paths. Do not add generic package/dotfile management or arbitrary shell hooks.

Grafana uses loopback:3000 with local authentication enabled and provisioned Metrics/Logs/Traces.
Preserve its independent restart intent for binary, unit and configuration changes.
Resolve configured administrator secret references locally before SSH; plans and
status never resolve them. Keep both resolved username and password opaque and
redacted, out of argv/configuration/logs, and transfer only through protected stdin.
Check desired authentication before credential mutation; unchanged credentials
must never trigger a reset or restart. Use supported Grafana interfaces, never
write its credential database directly. Standalone verify remains read-only.
Do not retain administrator plaintext after reconciliation. Distinguish the
read-only authenticated identity and Logs plugin health/query checks from
Metrics/Traces backend checks and browser UI validation. Monitoring configuration stays explicit
and narrow; CLI overrides file values. Progress carries fixed semantic events,
never arbitrary strings, commands or secret values.
The official VictoriaLogs datasource plugin is pinned, integrity-checked and stored
outside Grafana release binaries. Preserve its signature verification and independent
Grafana restart intent; plugin/provisioning changes never restart VM/VL/VT. Without
configured credentials, report that the authenticated Logs plugin query was not checked.
Dashboards remain deferred.

The station also runs blackbox_exporter, Alertmanager, vmalert-logs and
vmalert-metrics with dedicated accounts and loopback-only listeners on 9115,
9093, 8880 and 8881. Alertmanager clustering is disabled. The two evaluators share
one pinned binary but have independent restart intent; replacing that binary must
mark both before publication. Their alert state uses VictoriaMetrics remote
read/write and requires no local writable service path. Deploy the fixed
LogsQL, ServiceProbeFailed and verified Vector host-pressure packs. HostDown and
systemd service-state metric rules remain deferred.

External probes use the pinned VictoriaMetrics native scraper and a static,
unprivileged blackbox HTTP module. Keep GET, TLS verification, redirects, the
five-second timeout and IPv4 preference with DNS-family fallback. HTTP/2 is
explicitly disabled for the reviewed release's known dependency constraint.
Accept only bounded named credential-free HTTP/HTTPS URLs through the explicit
TOML schema. Keep metric names and labels allowlisted. Probe edits reload only the
native scraper after its initial unit integration; preserve its independent reload
intent through failures. Verify stored fresh probe samples and mechanism state,
not target availability: probe_success=0 is valid telemetry and must not fail
station installation. Status reads stored metrics and never contacts targets.

Optional Telegram SecretRefs resolve locally during install only. Its dedicated
protected stdin consumer manages service-owned mode-0400 token/chat files;
ordinary file primitives must never receive their contents. Equal credentials are
a no-op. Because the pinned native Telegram error path can include the bot-token
URL, Alertmanager StandardOutput and StandardError must remain null and their
effective values must be verified. Use its health/API/metrics and fixed semantic
errors for diagnosis. Verify and status never resolve Telegram refs or send
notifications. notify-test is an explicit short-lived Alertmanager alert and must
not claim human delivery; normal live rule evaluation remains active independently.

Keep unsupported components explicitly unavailable. Never return installation
success for scaffolds. New components require reviewed pinned checksums, a dedicated
privilege profile, atomic installation, idempotency, and real health/signal checks.
Do not claim production/VM validation based on renderer or fake-remote tests.

The monitored-host workflow installs pinned Vector 0.58.0 for selected journald
logs and host metrics; vmagent v1.152.0 is installed only for explicit application
Prometheus targets. OTel Collector/traces remain unavailable. Use required
application/station OpenSSH connections. Application config requires a distinct
DNS-only station.hostname for ingestion/TLS, never inferred from station.ssh_host.
The legacy agents command resolves its station alias to a DNS/IPv4 endpoint.
Neither accepts a caller-supplied Victoria URL. Validate bounded unique services
and named local/private credential-free HTTP(S) targets before SSH; disable scrape
redirects and do not auto-discover ports. Use the committed observed Vector metric
contract for CPU/memory/filesystem/inode rules; never guess collector names.

Agent ingestion uses the narrow managed mTLS service on IPv4 :9443, dedicated
`dt-ingest`, fixed write routes and authenticated health only. Keep raw VM/VL and
all administrative services loopback-only. Require a registered client identity;
station root owns CA/server keys and monitored hosts generate their own P-256
client keys. Only bounded public CSRs/certificates cross SSH; private client keys
never leave their host. Keep the root-private canonical machine identity and
locally derived service-owned 0400 copies, exact host URI SAN/clientAuth and
registered fingerprints. Preserve working credentials through explicit bounded
rollout authorization, mTLS/telemetry proof and resumable finalization. Unlink
legacy station client keys only after successful migration. Renew leaf certificates
at 30 days using the same key; near-expiry CA requires explicit maintenance,
never automatic rollover. Read-only verify never renews. Equal credentials and
registration are no-ops.
Preserve independent ingestion/Vector/vmagent restart intent. The controller and
host roots are trusted; this is not hard multi-tenant metric-content isolation.
The ingestion route must enforce authenticated host identity even on forged input.
Do not broaden firewall rules or imply automatic CA rollover.

Vector selects only named journal units, overwrites application-provided host and
service identity, and uses bounded disk buffers with blocking backpressure. Keep
its API disabled and telemetry on loopback:8686; vmagent management is loopback:8429
with a bounded 1 GiB remote-write queue. Quiet log stream metadata is bounded,
info-level and distinctly typed; never synthesize application errors or extra
installer events on unchanged reruns. Inspect effective journald configuration;
manage only its dedicated drop-in when necessary, preserve stricter limits and
reject later conflicting overrides. Direct application file logs are out of scope.
Require selected services to have an exact canonical Id and empty LogNamespace
before preregistration; aliases and namespaced journals are unsupported.
Read-only verification must prove recent host/log/app signal arrival on the station
after the current agent process start, with bounded readiness retries and
synchronized host clocks. Missing station signals fail installation and
retain restart intent. No real Ubuntu/systemd integration claim follows from the
isolated Linux metric-contract fixture or fake-remote tests.

Run `zig fmt build.zig src`, `zig build`, and `zig build test`. Test failure paths
and second-run no-op behavior. Document major features with what/example/result/
security/options, update CHANGELOG.md, and keep examples aligned with availability.
Do not overwrite unrelated host configuration or broaden firewall access. No
credential handling via ordinary file primitives. Consult the integration checklist
before touching remote service hardening or binary installation.

## Required completion report

End this and every future Codex iteration with these five sections:

1. **What changed**: briefly list implemented behavior and affected files.
2. **Tests actually run**: give exact commands and pass/fail/skip results. State
   `Disposable-host integration not run.` when no real supported test host was used.
   Never describe fake-remote or renderer tests as production or VM validation.
3. **Run this now**: provide valid copy-pasteable commands for the current build
   and implementation. For a deployment change, include build, install, verify,
   and a deliberate unchanged install rerun with consistent SSH authentication.
   Use an explicitly replaceable example host; do not claim it was contacted.
4. **Expected outcome**: quote output that matches the implementation, including
   `No changes required.` for an unchanged install. Distinguish expected results
   from results actually observed during validation.
5. **Current architecture**: include a compact ASCII diagram of implemented
   components and their actual listeners. List unavailable components and edges
   separately; never display future integrations as installed.

When adding a component, report its exact pinned version, checksum provenance,
and remaining verification limits. Keep deployment useful now without implying
that dashboards, HostDown/service-state alerts, tracing agents, automatic
CA rollover or hard tenant isolation are already available.
