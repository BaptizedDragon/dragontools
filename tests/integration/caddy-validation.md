# Caddy ingress validation — 2026-09-18

**Disposable-host integration not run.** No application/station SSH host was
contacted. The observations below are local macOS tests and isolated Linux
process fixtures, not systemd deployment, effective service credential mounts,
real journald access, provider-firewall reachability or notification delivery.
The [application two-host gate](application.md) remains required.

## Implementation and artifact scope

Caddy **v2.11.4**, official Linux amd64/arm64 artifacts, pinned archive and
extracted binary hashes. See [pins and provenance](../../design.md#caddy-ingress-pins-and-verification).
Native macOS fixture binaries are pinned separately in
`tools/fetch_caddy_fixture.py`. No Caddy plugin/custom build is used.

The production Caddyfile has two IPv4 TCP listeners: metrics 9443 -> metrics.sock,
logs 9444 -> logs.sock. The private authorization/normalization helper has one
backend per socket (VM 8428, VL 9428). Tracing 9445 is reserved and closed.
First app apply uses explicit station.hostname to install/verify these services
before client preparation. Base station install is independent of app identity.
The old public Python gateway unit is not restored; existing historical units
are refused for an operator-coordinated transport cutover.

## Local commands and results

Zig **0.16.0**, macOS arm64. Zig commands used
`ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache`.

```sh
zig fmt build.zig src
zig build
zig build -Doptimize=ReleaseSafe
zig build test --summary all
python3 tests/cli_smoke.py
python3 tests/version_test.py
python3 -I -B tests/release_test.py
python3 tools/verify_crypto_vendor.py
python3 -I -B tests/agent_checks_test.py
python3 -I -B tools/fetch_caddy_fixture.py --output /tmp/dragontools-caddy-2.11.4
python3 -I -B tests/agent_ingestion_test.py --caddy /tmp/dragontools-caddy-2.11.4
./zig-out/bin/dragontool monitoring apply --plan --config examples/doers-monitoring.toml
```

Results: **382/382 Zig tests**, **267 CLI smoke checks**, **8/8 runtime/signal
Python tests**, **2/2 release packaging tests**, version/redaction checks and
282-file vendor integrity checks passed. Fish completion syntax/behavior was
skipped because Fish is not installed. The fetch command verified the already
downloaded binary against its committed hash and did not redownload it.

The pinned-Caddy fixture passed with native certificates and native TLS health
on both ports: hostname, purpose, expiry, missing/unregistered certs, exact URI
SAN, extra SAN refusal, dynamic active/pending fingerprints and leases, legacy
CN-only fingerprint exception, forged peer headers, fixed port isolation, body
bounds, backend host-label override and trusted application log metadata.

Malformed framing/oversize rejection permits the helper's 400/413 or Caddy's
502 when the helper closes before proxy forwarding finishes. Closed connections
are accepted only for oversized-body rejection; timeouts/success are never
accepted. All rejected-request cases require zero additional backend writes.
No production verification semantics or empty-stderr assertions were weakened.

## Linux native fixtures

Built the native fixture/lifecycle tests with:

```sh
zig build test-binaries -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe \
  --prefix /tmp/dragontools-caddy-linux-fixture
```

The same Caddy TLS test passed in both existing local images
`dragontools-pki-test:ubuntu24.04` and `dragontools-pki-test:ubuntu26.04`, Linux
arm64. Native PKI/lifecycle tests additionally passed **40/40** on Ubuntu 26.04.
Containers had no external network, read-only mounts/root, no capabilities,
`no-new-privileges` and an unprivileged UID. Only private tmpfs was writable.

Exact TLS fixture commands (run once for each image):

```sh
for os in 24.04 26.04; do
  docker run --rm --network none --read-only --user 65534:65534 \
    --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:rw,exec,size=256m \
    --mount type=bind,src="$PWD",dst=/repo,readonly \
    --mount type=bind,src=/tmp/dragontools-caddy-linux-fixture,dst=/fixture,readonly \
    --mount type=bind,src=/tmp/dragontools-caddy-linux-native,dst=/caddy,readonly \
    -e DRAGONTOOLS_PKI_FIXTURE=/fixture/bin/dragontool-pki-fixture -w /repo \
    "dragontools-pki-test:ubuntu$os" \
    python3 -I -B tests/agent_ingestion_test.py --caddy /caddy/caddy
done

docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 --tmpfs /tmp:rw,exec,size=256m \
  --mount type=bind,src=/tmp/dragontools-caddy-linux-fixture,dst=/fixture,readonly \
  -w /tmp dragontools-pki-test:ubuntu26.04 /fixture/tests/native-agent-tests
```

`/tmp/dragontools-caddy-linux-native/caddy` was extracted from the verified official
Linux arm64 archive. No network downloads occurred inside the containers.
Linux/macOS GitHub Actions now run the same pinned-Caddy fixture after full unit
and CLI tests. No GitHub Actions run was triggered or observed during this work.

## Real local telemetry pipeline

Reused the previously reviewed Linux arm64 executables in
`/tmp/dragontools-ingestion-fixture`, copied into a new
`/tmp/dragontools-caddy-pipeline` fixture alongside pinned Caddy and the newly built
native helper. The runner checks binary pins before starting them. Versions:
Vector **0.58.0**, vmagent **v1.152.0**, VictoriaMetrics **v1.151.0**,
VictoriaLogs **v1.52.0**, Caddy **v2.11.4**. Fresh localhost-only fixture keys and
certificates were generated by the native test helper; no deployed key was read.

```sh
python3 -I -B tests/integration/agent_ingestion_pipeline.py \
  --prepare-credentials /tmp/dragontools-caddy-pipeline
python3 tests/integration/render_agent_apps.py /tmp/dragontools-caddy-pipeline

docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 \
  --tmpfs /tmp:rw,size=1g --memory 1g \
  --mount type=bind,src="$PWD",dst=/repo,readonly \
  --mount type=bind,src=/tmp/dragontools-caddy-pipeline,dst=/fixture,readonly \
  python:3.12-slim python3 -I -B \
  /repo/tests/integration/agent_ingestion_pipeline.py /fixture --applications
```

All six checks passed: authenticated host overrides forged remote-write labels;
Vector host metrics and selected logs traverse the separate Caddy ports; structured
log identities override forged fields; three app scopes preserve host-only support;
vmagent app metrics arrive with trusted identity; production freshness checks
accept current signals and reject pre-process samples. The real Vector binary
first validates production-rendered config. Only journald input, credential/data
paths and the native maintenance helper location are substituted for this local
fixture. This does not validate actual systemd journal access or two-host outages.

## Release validation

All four controller target builds passed, with matching Linux helpers:

```sh
for target in aarch64-macos x86_64-macos aarch64-linux x86_64-linux; do
  zig build -Dtarget="$target" -Doptimize=ReleaseSafe -Dversion=0.0.0-ci \
    --prefix "/tmp/dragontools-caddy-cross/$target"
done
```

Packaged these binaries with `tools/package_release.py package --version 0.0.0-ci`
using each matching `--target`, `--binary` and
`--output /tmp/dragontools-caddy-release-validation`; Linux helpers additionally
use `--agent`. The `checksums --version 0.0.0-ci` command verified the complete
six-archive set. These are local validation artifacts, not a published release.
The existing tagged release workflow still publishes four controller/two helper
archives and SHA256SUMS, so end users do not need Zig.
