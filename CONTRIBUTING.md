# Contributing

Use Zig 0.16.0. Mbed TLS sources are vendored and integrity-checked; no system crypto library is used.

```bash
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 -I -B tests/release_test.py
python3 tools/verify_crypto_vendor.py
python3 tests/version_test.py
./zig-out/bin/dragontool --help
./zig-out/bin/dragontool monitoring install --host example.com --plan
./zig-out/bin/dragontool host install-oh-my-zsh --ssh-host monitoring --plan
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
   second no-op, and component-isolated binary/unit changes for VM, VL, VT and Grafana.
   Grafana additionally covers deterministic config/provisioning, full-tree artifact
   inspection, SQLite datasource metadata and service-account backend query checks.
   Check starts, enables, restarts, reloads, failed-health marker retention, and
   interrupted-change recovery separately. Standalone verification must make no
   mutations. Existing resources, conflicts, and failure paths remain covered. The CLI smoke test uses Python 3 and a fake SSH executable to ensure help/plans,
   completion, non-TTY entry points and rejected integrations make no connection
   and errors do not echo values. It also checks generated scripts with available
   shells; a missing optional shell is reported as skipped. Wizard input/output
   tests feed scripted answers into the small abstraction, never a real terminal.
   These tests validate orchestration, not the shell's
   behavior on Ubuntu. Add failure/resume and command execution tests as components grow.
   The separate host utility also needs actual-login target selection, package
   no-ops, preserved home content, path conflicts, missing users, unsupported OS,
   interrupted staging, and a mutation-free second run. Fake SSH covers alias/direct
   dispatch and sanitized errors without contacting a host.
3. Disposable Ubuntu integration: [procedure](tests/integration/README.md) and opt-in
   [storage-backend runner](tests/integration/victoriatraces.sh), plus the
   [Grafana checklist](tests/integration/README.md#grafana-fourth-component-checklist).
   Real authenticated Grafana datasource queries, lifecycle, file ownership,
   listener behavior, health, unit hardening and no-op process stability are required
   before treating a platform combination as operationally validated.

Cross-build the four controller combinations with `zig build -Dtarget=...`:
`aarch64-macos`, `x86_64-macos`, `aarch64-linux`, `x86_64-linux`. CI builds these and
runs native tests on macOS/Linux. Integration requires separately supplied disposable
VM infrastructure and is not silently skipped inside a claimed successful VM test.

CI packages four controller targets and two Linux helper targets. `.github/workflows/release.yml` runs native
Linux/macOS tests before building tagged release archives and `SHA256SUMS`.
`tools/package_release.py` creates deterministic tar metadata and rejects incomplete
archive sets; only the publish job receives repository write permission. A tag
must already exist (`gh release create --verify-tag`); existing releases are not
silently overwritten. Users of release binaries need OpenSSH, not a runtime Zig
installation. Publishing is separate from local packaging validation.

Application tests must cover missing/invalid config before SSH, per-app ownership,
shared-host merge, rule removal, fresh scoped signal checks and unchanged reruns.
Retain empty-stderr assertions and stdin-draining pipeline fixtures on both OSes.
The [two-host application gate](tests/integration/README.md#application-contract-two-host-gate)
includes real journal collection, failed-target alerting and process stability.

## Change review

Keep security changes small. Record upstream artifact/flag sources, verify archive
and executable digests for both architectures, test negative paths, and update the
availability matrix. Never put actual host addresses, private keys, tokens or
credential-bearing logs in fixtures. Do not enable shell tracing around secrets.

Agent changes must preserve journal bounds and remote signal arrival, not only
successful service starts. Update checks must preserve unknown/failed states rather
than treating unavailable metadata as up-to-date. No automatic component upgrades
or reboots. See AGENTS.md for coding rules and SECURITY.md for private reporting.

Codex completion reports must follow the five-section format in AGENTS.md: What
changed, Tests actually run, Run this now, Expected outcome, and Current
architecture. Include current copy-pasteable commands and an ASCII diagram, with
expected output distinct from observed validation and unavailable integrations
clearly separated.
