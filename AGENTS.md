# Working on DragonTools

Use Zig 0.16.0 and the standard library where practical. Keep the public CLI under
`dragontool monitoring`; no generic resource DSL, shell hooks or provider framework.
Read README.md, architecture.md and design.md before changing workflow behavior.

Maintain small concrete modules and explicit argument validation. Dynamic remote
arguments must go through system/remote.zig quoting; never interpolate untrusted
input into executable shell text. Do not log raw remote stderr, command strings,
CLI values, or resolved secrets. Preserve strict SSH host-key checks.

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
