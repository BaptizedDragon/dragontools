# Host-local PKI validation — 2026-09-17

> Historical evidence for the retired Python/OpenSSL PKI backend. These recorded
> commands are not current instructions. Run `zig build test-agent` and the native
> TLS fixtures described in [README](README.md#native-pki-and-maintenance-fixture-gate)
> for the current implementation.

This iteration changes enrollment and certificate lifecycle, without changing
application ownership, rule files, datasource URLs, Grafana or the traces schema.
Validation ran on the local macOS controller with Zig 0.16.0, plus isolated local
Linux containers. No application/station SSH host was contacted.
**Disposable-host integration not run.** GitHub Actions and release publishing
were not executed. The unchanged workflows run the same suite on Ubuntu 24.04
and macOS 15 and build all four controller targets.

## Repository checks

```sh
zig fmt build.zig src
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build test --summary all
git diff --check
python3 -I -B tests/release_test.py
```

All repository checks above passed. The final full suite reported **313/313 Zig
tests passed** (3/3 build steps); the release packaging fixtures passed **2/2**.
The full Zig suite embeds the real
OpenSSL PKI fixtures and local TLS authorization tests; its loopback listeners
needed sandbox approval. Assertions still require empty fixture stderr.

```sh
PATH="/tmp/dragontools-fish-3.7.1/fish.app/Contents/Resources/base/usr/local/bin:$PATH" \
XDG_CONFIG_HOME=/tmp/dragontools-shell-xdg-config \
XDG_DATA_HOME=/tmp/dragontools-shell-xdg-data \
XDG_CACHE_HOME=/tmp/dragontools-shell-xdg-cache \
python3 tests/cli_smoke.py
```

Result: **262 CLI smoke checks passed**, including Bash, Zsh and Fish completion.
These use fake SSH/secret providers and do not deploy monitoring.

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-pki-aarch64-macos
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-pki-x86_64-macos
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-pki-aarch64-linux
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-pki-x86_64-linux
```

All four ReleaseSafe builds passed with the final embedded helpers.
Cross-building does not execute each target's native test suite.

## Cryptographic and recovery fixtures

```sh
python3 -I -B tests/agent_pki_station_test.py
python3 -I -B tests/agent_pki_client_test.py
python3 -I -B tests/agent_checks_test.py
python3 -I -B tests/agent_ingestion_test.py
```

Passed on macOS: **20 station PKI tests**, **21 client PKI tests**, **12 diagnostic
tests**, and the local TLS gateway authorization fixture. Tests use real OpenSSL
CSRs/certificates, temporary filesystem trees and fake service controls. They
exercise public-only exchange, exact SAN/purpose/fingerprint authorization,
malformed/privileged CSR rejection, same-key renewal, legacy migration, signing
and TLS failure preservation, missing-key recovery, expired credentials,
interrupted publication/finalization and unchanged reruns.

Controller fake-remote tests additionally prove independent restart intent,
telemetry-gated finalization, rollback only while the old identity remains active,
expired rollout-lease recovery, bounded diagnostics and no-op subsequent applies.
An initial full run exposed an expired-certificate fixture using unsupported
`openssl x509 -days -1`; it now uses `-days 0` with an explicit expiry assertion.
No production expiry check or empty-stderr assertion was weakened.

The same **20 station + 21 client tests passed on Linux**, using Python 3.12.14
and OpenSSL 3.5.7 in the already cached image (no package installation):

```sh
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --user 501:20 --tmpfs /tmp:rw,size=256m --memory 512m --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly 4f8d1afed6d5 python3 -I -B /repo/tests/agent_pki_station_test.py
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --user 501:20 --tmpfs /tmp:rw,size=256m --memory 512m --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly 4f8d1afed6d5 python3 -I -B /repo/tests/agent_pki_client_test.py
```

Image ID:
`sha256:4f8d1afed6d58037c680221ca6dd9fb4737b7ecfa7d4809ca809fdc0c7d9b786`.
Station/client runtimes were approximately 15/93 seconds. These are helper
compatibility tests, not the complete Linux Zig suite or Ubuntu integration.

## Native Linux telemetry fixture

The existing pinned Vector/vmagent/VM/VL process fixture was updated to use the
machine URI SAN and modern registered fingerprint. This exact command passed
**6/6 checks** with locally cached binaries and no external networking:

```sh
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 \
  --tmpfs /tmp:rw,size=1g --memory 1g \
  --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
  --mount type=bind,src=/tmp/dragontools-uri-pipeline-0mau76az,dst=/fixture,readonly \
  4f8d1afed6d5 python3 -I -B /repo/tests/integration/agent_ingestion_pipeline.py /fixture --applications
```

Checks cover forced host labels, Vector host metrics, selected log metadata,
structured application logs with trusted labels, three application host scopes
including host-only collection, vmagent application metrics, and production
freshness queries. The six-check harness groups these assertions. The cached
Python 3.12 slim image manifest was
`sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea`.
Fixture inputs came from the production Zig renderers; journald was replaced by
stdin. This validates native process interoperability with the new certificate
identity, not SSH deployment, systemd hardening or an end-to-end live renewal.

## Remaining gate

Run the [two-host Ubuntu procedure](application.md#host-local-pki-migration-and-renewal-gate)
before claiming deployment validation. Actual SSH authentication, real systemd
permissions/restarts, live journald, remote firewalls/DNS, migration on an existing
station and uninterrupted telemetry across a live renewal remain untested here.
The implementation neither configures DNS/firewalls nor provides automatic CA
rollover, dashboards, OTel traces, HostDown or service-state metric alerts.
