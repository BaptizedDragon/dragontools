# Contributing

Use Zig 0.16.0. No third-party Zig package manager dependencies are needed.

```bash
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
./zig-out/bin/dragontool --help
./zig-out/bin/dragontool monitoring install --host example.com --plan
```

Expected: formatting completes, build succeeds, unit/fake-remote tests pass, and the
plan makes no connection. On a sandboxed controller set
`ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache` if the usual cache is not writable.

## Test levels

1. Pure unit tests: CLI hierarchy and invalid inputs, shared command/flag metadata,
   contextual help, Bash/Zsh/Fish generation, enum and context-specific completion,
   scripted wizard defaults, retries, cancellation, command generation and reference
   handling; secret custom/structural
   redaction, POSIX quoting, systemd/file rendering, artifact pin ordering, actual POSIX shell quoting and generated-script syntax, storage
   arithmetic/overflow and update model parsing. Firewall generation tests belong
   with the future safe firewall implementation; no pretend rules ship today.
2. Fake remote: inject a stateful executor through `Remote`, exercise a first install,
   second no-op, changed configuration, existing resources, missing selected service
   and a binary-stage failure. The CLI smoke test uses Python 3 and a fake SSH executable to ensure help/plans,
   completion, non-TTY entry points and rejected integrations make no connection
   and errors do not echo values. It also checks generated scripts with available
   shells; a missing optional shell is reported as skipped. Wizard input/output
   tests feed scripted answers into the small abstraction, never a real terminal.
   These tests validate orchestration, not the shell's
   behavior on Ubuntu. Add failure/resume and command execution tests as components grow.
3. Disposable Ubuntu integration: [procedure](tests/integration/README.md) and opt-in
   [two-component runner](tests/integration/victorialogs.sh). Real host lifecycle, file ownership,
   listener behavior, health, unit hardening and no-op process stability are required
   before treating a platform combination as operationally validated.

Cross-build the four controller combinations with `zig build -Dtarget=...`:
`aarch64-macos`, `x86_64-macos`, `aarch64-linux`, `x86_64-linux`. CI builds these and
runs native tests on macOS/Linux. Integration requires separately supplied disposable
VM infrastructure and is not silently skipped inside a claimed successful VM test.

## Change review

Keep security changes small. Record upstream artifact/flag sources, verify archive
and executable digests for both architectures, test negative paths, and update the
availability matrix. Never put actual host addresses, private keys, tokens or
credential-bearing logs in fixtures. Do not enable shell tracing around secrets.

Future agent work must include journal bounds and remote signal arrival, not only
successful service starts. Update checks must preserve unknown/failed states rather
than treating unavailable metadata as up-to-date. No automatic component upgrades
or reboots. See AGENTS.md for coding rules and SECURITY.md for private reporting.
