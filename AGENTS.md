# Working on DragonTools

Use Zig 0.16.0 and the standard library where practical. Keep remote workflows under
`dragontool monitoring`; `wizard` and `completion` are local UX entry points.
No generic resource DSL, shell hooks or provider framework.
Read README.md, architecture.md and design.md before changing workflow behavior.

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
and never modify shell startup files automatically.

Keep unsupported components explicitly unavailable. Never return installation
success for scaffolds. New components require reviewed pinned checksums, a dedicated
privilege profile, atomic installation, idempotency, and real health/signal checks.
Do not claim production/VM validation based on renderer or fake-remote tests.

Run `zig fmt build.zig src`, `zig build`, and `zig build test`. Test failure paths
and second-run no-op behavior. Document major features with what/example/result/
security/options, update CHANGELOG.md, and keep examples aligned with availability.
Do not overwrite unrelated host configuration or broaden firewall access. No
credential handling via ordinary file primitives. Consult the integration checklist
before touching remote service hardening or binary installation.
