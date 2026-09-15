# Changelog

## 0.1.0-dev — unreleased

- Install VictoriaLogs v1.52.0 alongside VictoriaMetrics using reviewed amd64/arm64
  archive and executable pins, a dedicated account/data directory, an atomic
  versioned binary, a separate hardened unit, and loopback:9428 binding.
- Apply VictoriaLogs `100y` logical retention and native cleanup at 75% filesystem
  usage from existing policy. Document periodic checks, newest-two-days retention,
  and the need for capacity/headroom beyond this cleanup target.
- Verify VictoriaLogs health, application metrics, writable storage, managed unit,
  running binary/configuration, and listener before clearing per-component restart
  intent. Keep unchanged VictoriaMetrics running during VictoriaLogs repair/failure.
- Extend install, verify, status, plans, wizard/help and availability docs to both
  components. Add per-component failure/idempotency tests and an opt-in disposable
  Ubuntu lifecycle runner. Application-host ingestion, agents, traces, dashboards,
  alert evaluation/delivery, firewall, and TLS remain unavailable; no VM runtime
  validation is inferred from unit/fake-remote tests.
- Add a single monitoring policy module for metrics `90d` retention and 20%
  filesystem reserve, logs/traces `100y` logical retention with native
  cleanup at 75% usage, and 60/70/80% operational disk states. Preserve the existing
  VictoriaMetrics reserve calculation and installation behavior.
- Add deterministic local vmalert YAML renderers for six host alerts, selected-unit
  ServiceDown/ServiceRestartLoop alerts, and a separate VictoriaLogs `vlogs` pack
  for ErrorBurst and CriticalLogEvent. Share policy defaults, validate/escape unit
  names, and keep log contents and secrets out of annotations.
- Extend install plans and documentation with explicit storage and alert policy.
  Rule generation is implemented; rule deployment/evaluation,
  collector setup, traces installation, and notification delivery remain
  unavailable. Add policy and renderer tests without claiming runtime validation.
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
