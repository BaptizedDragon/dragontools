# Changelog

## 0.1.0-dev — unreleased

- Set `-group.maxStartDelay=1s` in both vmalert units. The pinned v1.152.0
  `Group.delayBeforeStart` calculation panics with a zero delay due to division by
  zero. Unit updates retain independent restart intent and unchanged reruns are
  no-ops after successful verification.

- Install pinned blackbox_exporter 0.28.0, Alertmanager v0.34.1 and independent
  vmalert-logs/vmalert-metrics v1.152.0 services, with dedicated accounts, reviewed
  archive/binary checksums, atomic publication and loopback-only listeners.
- Add bounded named HTTP/HTTPS probes in monitoring TOML. Use VictoriaMetrics'
  native 30-second scraper, verified TLS, fixed GET/2xx semantics and owned labels;
  constrain the reviewed exporter to HTTP/1.1 for its known HTTP/2 transport issue.
- Deploy ServiceProbeFailed with a two-minute hold and the fixed structured-log
  pack through separate evaluators. Collect probe durations without noisy latency
  alerts. Down applications produce valid failed telemetry and do not fail install.
- Reload only the native scrape configuration when probes change, preserving
  separate restart/reload intent and unchanged no-op behavior. The first upgrade
  enabling native scraping changes the VictoriaMetrics unit once.
- Verify the loaded scraper metric/label policy and recover stale reloads; accept
  bounded recent history from removed probes without confusing their identities.
- Keep maximum-size probe configurations below SSH argument limits by selecting
  elevation once and compressing fixed helper source with standard libraries.
- Add optional Telegram SecretRefs resolved locally during install; protected
  stdin transfers them to dedicated dt-alertmanager 0400 secret files. Unchanged
  values are not rewritten. Verification never sends test notifications;
  explicit notify-test submits a labeled Alertmanager alert without claiming receipt.
- Add a read-only opt-in disposable-host observer for fresh failed probe samples
  and the existing two-minute firing alert; local fixtures do not claim host validation.
- Status observes recorded probe samples without fresh target requests. Document
  eight-service boundaries, exact pins, source review and disposable-host gates;
  agents, host/service metric packs, dashboards and remote ingestion remain deferred.

- Drain stdin in checksum fixture mocks to avoid scheduling-dependent broken-pipe
  errors on macOS. Preserve production verification and empty-stderr assertions.

- Install the signed official `victoriametrics-logs-datasource` **0.32.0** from the
  versioned Grafana catalog ZIP. Pin its published SHA-256 and full file catalog;
  preserve its verified signature without enabling unsigned plugins or online
  installation. Keep root-owned persistent plugin versions outside Grafana server
  binaries, with atomic selection and service read-only mounts.
- Provision **Logs** at `http://127.0.0.1:9428` alongside Metrics and Traces. Verify
  plugin integrity, deterministic provisioning, datasource records and direct
  read-only LogsQL reachability. Configured Grafana references also verify plugin
  health and a read-only query through Grafana; unconfigured runs explicitly report
  that authenticated query as unchecked. Empty valid responses are accepted.
- Plugin/provisioning changes restart only Grafana and retain its restart intent
  through verification failures. Healthy unchanged reruns download nothing, rewrite
  nothing and restart nothing. Preserve prior plugin state for operator recovery,
  and let interrupted first-time plugin installations resume on rerun.
- Show all three datasource mappings in plans/status and calm plugin/provisioning
  progress. Status remains a lightweight service-state view, not query verification.
  Document SSH tunnel access and the still-unrun real-host/browser checklist.

- Add explicit version-1 monitoring TOML configuration for an OpenSSH alias and
  Grafana administrator secret references. CLI values override file values;
  local plans and status never resolve secrets. Literal passwords are rejected.
- Resolve optional Grafana username/password references with the local 1Password
  CLI through a small redacted secret boundary. Transfer secret values through
  protected stdin, suppress provider/remote output, and keep secrets out of
  configuration, units, argv and progress.
- Reconcile configured Grafana administrator credentials through supported
  Grafana interfaces, including existing manually changed passwords. Authenticate
  first so correct credentials skip resets and service restarts; configured verify
  authenticates read-only. Preserve the explicitly unmanaged path without refs.
- Add calm semantic component progress for install and verification, including
  unchanged completion and a single delayed readiness message per component.
  Preserve bounded retries, safe errors and independent restart finalization.

- Separate deterministic monitoring verification from bounded startup readiness
  for VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana. Retry active,
  HTTP and telemetry checks for up to 15/30/45 seconds, with a 500 ms first retry
  and then 1-second intervals; never delay an already-ready service or retry
  configuration/identity failures. Allow VictoriaMetrics' 15-second self-scrape
  interval before requiring stored `vm_app_version` samples.
- Retain per-component restart intent on readiness timeout and finalize normally
  after delayed success. Add safe semantic check diagnostics and injected-clock
  lifecycle tests for retries, failure, recovery and unchanged reruns.

- Add Grafana OSS 13.2.2 as the fourth independently converged station component,
  with reviewed Linux amd64/arm64 release integrity, dedicated `dt-grafana`, persistent
  SQLite state, versioned release files, hardened systemd and loopback:3000 only.
- Provision immutable Metrics (Prometheus) and Traces (Jaeger `/select/jaeger`)
  datasources. Keep local authentication enabled and document the upstream first-login
  password change. No administrator credential is embedded or retained by DragonTools.
  The initial slice deferred the VictoriaLogs plugin (implemented above); dashboards remain deferred.
- Verify Grafana identity, configuration, non-secret provisioned datasource database
  records and backend queries as the service UID without administrator credentials.
  Metrics/Traces query-engine and browser validation remain documented real-host gates.
- Preserve per-component restart intent for Grafana binary/unit/config/provisioning
  changes and failures; unchanged installs reuse resources without downloads, rewrites
  or service restarts. VM/VL/VT keep their existing independent behavior.
- Enable native `--ssh-host` for monitoring install/verify/status while retaining direct
  SSH and strict host-key checks. Update plans/help/wizard/status, alias tests, deployment
  and SSH-tunnel documentation; no firewall, TLS or public service port is added.

- Advance the generated `.zshrc` to v2 with a dynamic remote hostname, username and
  directory, plus Zsh's root `#` / ordinary-user `%` prompt ending. Keep exact v0
  and v1 migrations behind `--update-managed-zshrc` to honor default preservation;
  preserve original user/group/mode or refuse migration. Report old and new login
  shell paths and the need to reconnect after an explicit shell change.
- Add host-only `--set-default-shell`: validate discovered zsh against `/etc/shells`,
  change and verify only a differing login shell, and avoid `chsh` on unchanged reruns.
- Generate marked `.zshrc` files with an explicit user/hostname/directory prompt,
  Oh My Zsh and the git plugin. `--update-managed-zshrc` migrates only an exact
  known DragonTools template, including the previous unmarked v0 template; foreign
  files and local edits remain byte-for-byte preserved. Both options are explicit;
  ordinary reruns retain existing configuration and the login shell.
- Add the separate `host install-oh-my-zsh` convenience command with native OpenSSH
  alias support, explicit direct-SSH fallback, existing target-account lookup,
  contextual help/completion and a local plan. Strict host-key checks remain enabled.
- Install only missing zsh and pinned Oh My Zsh source; preserve existing Oh My Zsh
  directories and regular `.zshrc` files by default. Create a minimal `.zshrc` if
  absent, leave the login shell unchanged by default, and make unchanged reruns mutation-free.
  Private staging, checked source archives and path-conflict refusal support safe
  retries without broad package or dotfile management. Monitoring is unchanged.
- Add host parser, fake-remote, failure/recovery and CLI smoke coverage, plus an
  explicit disposable-host checklist. Local tests do not claim real-host validation.
- Install VictoriaTraces v0.11.0 as the third real backend, using reviewed amd64/arm64
  archive and extracted-binary pins, a dedicated account/data directory, atomic
  versioned binaries/current link, and a concrete hardened systemd unit. Bind HTTP
  to loopback:10428 and explicitly disable the extra gRPC listener.
- Verify traces application identity, reported writable storage, unit/argv, binaries,
  effective hardening, paths, and listener before finalization. Extend install,
  verify, status, plans, and wizard/help to all three independently managed components.
- Strengthen safe reruns: reuse matching resources without downloads or unit rewrites,
  repair only required metadata, reload only stale unit state, and isolate starts,
  enables, restarts, and pending-marker recovery per component. Verification stays
  read-only; no controller-side state database is added.
- Correct native retention documentation for both pinned logs/traces releases:
  `100y` logical retention and native 75% partition budgets against total filesystem
  capacity, excluding other writers. Periodic cleanup preserves two newest daily
  partitions; it does not impose a combined shared-disk usage ceiling.
- Plan Vector for journald logs and host metrics, vmagent for application Prometheus
  endpoints, and OTel Collector for application OTLP. Disable host/service rule
  rendering until verified metric contracts exist; keep log rendering provisional
  and all alert runtime unavailable.
- Add a three-component disposable-host integration runner and explicit rerun
  examples. Require future Codex completion reports to show exact tests, runnable
  commands, expected output, and the current ASCII architecture.
- Install VictoriaLogs v1.52.0 alongside VictoriaMetrics using reviewed amd64/arm64
  archive and executable pins, a dedicated account/data directory, an atomic
  versioned binary, a separate hardened unit, and loopback:9428 binding.
- Apply VictoriaLogs `100y` logical retention and a native 75% partition budget
  from existing policy. Document periodic checks, newest-two-partitions retention,
  and the need for capacity/headroom beyond this cleanup target.
- Verify VictoriaLogs health, application metrics, writable storage, managed unit,
  running binary/configuration, and listener before clearing per-component restart
  intent. Keep unchanged VictoriaMetrics running during VictoriaLogs repair/failure.
- Extend install, verify, status, plans, wizard/help and availability docs to the installed
  components. Add per-component failure/idempotency tests and an opt-in disposable
  Ubuntu lifecycle runner. Application-host ingestion, agents, dashboards,
  alert evaluation/delivery, firewall, and TLS remain unavailable; no VM runtime
  validation is inferred from unit/fake-remote tests.
- Add a single monitoring policy module for metrics `90d` retention and 20%
  filesystem reserve, logs/traces `100y` logical retention with a native 75%
  setting, and 60/70/80% operational disk states. Preserve the existing
  VictoriaMetrics reserve calculation and installation behavior.
- Define host/service alert policy and render a separate provisional VictoriaLogs
  `vlogs` pack for ErrorBurst and CriticalLogEvent. Keep log contents and secrets
  out of annotations; host/service expressions await verified agent contracts.
- Document explicit storage/alert policy and distinguish partial rendering from
  unavailable rule deployment, evaluator/collector setup, and notification delivery.
  Add policy and renderer tests without claiming runtime validation.
- Add a shared command/flag model, contextual help, and local Bash, Zsh, and Fish
  completion with nested commands, relevant options, enum values, and native path
  completion. Document user-managed completion installation without startup edits.
- Add `wizard` and the no-argument terminal helper with shared CLI validation and
  dispatch, architecture guidance, equivalent-command previews, regular `--plan`,
  and explicit default-No mutation confirmation. Non-TTY no-argument calls return
  help immediately; explicit non-TTY wizard calls fail without waiting for input.
- Add scripted wizard and CLI UX coverage; preserve the implemented-component
  implementation boundary and before-SSH rejection of roadmap settings.
- Add Zig 0.16 controller, monitoring CLI hierarchy, validation, strict OpenSSH
  transport and an injectable remote boundary.
- Add opaque redacting/wiping secret infrastructure; optional secret resolution
  remains unavailable.
- Install pinned VictoriaMetrics v1.151.0 on Ubuntu 24.04/26.04 amd64/arm64 with
  archive/executable checksums, dedicated user, versioned binary, hardened systemd
  unit, 90d retention, 20% disk reserve and loopback binding.
- Add atomic non-secret file writing, host detection, service-existence checks,
  health/query verification, read-only status and change-aware restart recovery.
- Add unit/fake-remote tests, CI and disposable Ubuntu integration procedure.
- Document the remaining station/agent, firewall, TLS, alerts, Telegram, journald
  and update-maintenance work as unavailable scaffolds, not installed features.
