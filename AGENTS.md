# Working on DragonTools

Use Zig 0.16.0 and the standard library where practical. Keep monitoring workflows under
`dragontool monitoring`; the separate `host install-oh-my-zsh` utility installs
missing shell tooling for an existing account, with explicit options for its managed
configuration and login shell. `wizard` and `completion` are local UX entry points.
No generic resource DSL, shell hooks or provider framework.
Read README.md, architecture.md and design.md before changing workflow behavior.

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

Grafana uses loopback:3000 with local authentication enabled and provisioned Metrics/Traces.
Preserve its independent restart intent for binary, unit and configuration changes.
Do not retain administrator credentials for verification; distinguish read-only
provisioning/backend checks from authenticated Grafana datasource runtime validation.
The Logs datasource plugin and dashboards remain deferred.

Keep unsupported components explicitly unavailable. Never return installation
success for scaffolds. New components require reviewed pinned checksums, a dedicated
privilege profile, atomic installation, idempotency, and real health/signal checks.
Do not claim production/VM validation based on renderer or fake-remote tests.

The future agent topology is Vector for journald logs and host metrics, vmagent
for application Prometheus endpoints, and OTel Collector for application OTLP.
Host metric names and systemd service-state monitoring remain deferred until the
agent slice verifies their contracts. Do not invent replacement alert expressions
or treat provisional rule rendering as deployed alerting.

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
that the Grafana Logs datasource, dashboards, alerting, agents, or remote ingestion
are already available.
