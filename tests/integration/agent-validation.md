# Monitored-host slice: validation record, 2026-09-17

This records local validation of the repository changes. No user application or
monitoring host was contacted. **Disposable-host integration not run.**

## Final repository validation

All commands below passed on the macOS controller with Zig 0.16.0:

```sh
zig fmt build.zig src
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build test --summary all
git diff --check
```

Result: **283/283 Zig tests passed**. Python fixture suites are invoked by the Zig
suite: registered mTLS/PKI and protected import/export, nine temporary-filesystem
journald cases, five runtime/signal cases, and the existing station fixtures.
The mTLS tests bind ephemeral localhost ports; the desktop sandbox required an
approved test run outside that socket restriction. No platform-specific expected
results or skipped assertions were introduced.

```sh
PATH="/tmp/dragontools-fish-3.7.1/fish.app/Contents/Resources/base/usr/local/bin:$PATH" \
XDG_CONFIG_HOME=/tmp/dragontools-shell-xdg-config \
XDG_DATA_HOME=/tmp/dragontools-shell-xdg-data \
XDG_CACHE_HOME=/tmp/dragontools-shell-xdg-cache \
python3 tests/cli_smoke.py
```

Result: **213 CLI smoke checks passed**, including Bash, Zsh and Fish completion.
Smoke fixtures replace SSH and secret providers; they never contact hosts.

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-agents-aarch64-linux
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-agents-x86_64-linux
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-agents-aarch64-macos
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-agents-x86_64-macos
```

All four cross-builds passed. Cross-compilation does not execute another OS's tests.

The local plan command also passed without SSH:

```sh
./zig-out/bin/dragontool monitoring agents install \
  --ssh-host replace-me-application --station replace-me-monitoring \
  --service app.service --metrics-target app=http://127.0.0.1:16000/metrics --plan
```

## Native artifact and protocol checks

[The integration checklist](README.md#agent-artifact-and-isolated-process-review)
records the four exact archive audit commands and native Vector, vmagent and
vmalert validation. Both architectures' archives and extracted binaries matched
the committed SHA-256 values. Vector release metadata and SHA256SUMS, and the
VictoriaMetrics v1.152.0 release metadata, were the checksum provenance.

[The isolated native pipeline](README.md#isolated-native-mtls-pipeline-evidence)
records the exact sandboxed Docker command, image manifest and fixture setup. Its
five real-process checks passed against Vector 0.58.0, vmagent v1.152.0,
VictoriaMetrics v1.151.0 and VictoriaLogs v1.52.0: authenticated host-label
replacement, Vector host metrics, selected-service metadata, application metrics,
and current-process freshness query acceptance/rejection. It used an isolated
Linux/aarch64 container with no external network, read-only repository/root,
dropped capabilities and disposable certificates.

This confirms the observed metric/protocol contracts, not systemd hardening,
actual journal collection, SSH installation, two-host interruption recovery,
long-outage buffering or production readiness. Those remain explicit tests in the
[disposable-host checklist](README.md#monitored-host-logsmetrics-two-host-ubuntu-gate).
