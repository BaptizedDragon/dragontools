# Changelog

## 0.1.0-dev — unreleased

- Add the separate `host install-oh-my-zsh` convenience command with native OpenSSH
  alias support, explicit direct-SSH fallback, existing target-account lookup,
  contextual help/completion and a local plan. Strict host-key checks remain enabled.
- Install only missing zsh and pinned Oh My Zsh source; preserve existing Oh My Zsh
  directories and regular `.zshrc` files. Create a minimal `.zshrc` only if absent,
  leave the login shell unchanged, and make unchanged reruns mutation-free.
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
