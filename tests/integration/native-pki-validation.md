# Native PKI and maintenance validation — 2026-09-18

This records local macOS arm64 tests and isolated Linux process/filesystem tests.
It does not establish a real SSH/systemd deployment or a successful GitHub Actions
run. **Disposable-host integration not run.** The two-host gate in README.md
remains required before making deployment-level claims.

## Source and build

Zig 0.16.0 statically compiles the reviewed Mbed TLS 4.2.0 subset, including
TF-PSA-Crypto 1.2.0. The official release archive is:

https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.2.0/mbedtls-4.2.0.tar.bz2

SHA-256: `2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea`.
The GitHub release digest/checksum and the downloaded archive matched. The
offline verifier checked all 282 vendored files byte-for-byte against that
archive. `tools/check_crypto_release.py` observed 4.2.0 as the latest stable
release on this date; that is a release-feed check, not an advisory assessment.

Commands run from the repository, with
`ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache`:

```bash
zig fmt build.zig src
zig fmt --check build.zig src
zig build
zig build test --summary all
zig build test-agent --summary all
zig build test-pki --summary all
python3 tests/cli_smoke.py
python3 tests/version_test.py
python3 -I -B tests/agent_checks_test.py
python3 -I -B tests/agent_ingestion_test.py
python3 -I -B tests/release_test.py
python3 tools/verify_crypto_vendor.py --archive /tmp/dragontools-mbedtls-4.2.0.tar.bz2
python3 tools/check_crypto_release.py
git diff --check
```

Final full suite: **357/357** (325 controller/fake-remote tests and 32 native
crypto/lifecycle/maintenance tests). The native-only lifecycle run passed 32/32;
crypto-only passed 11/11. CLI smoke passed 260 checks; two Fish checks were
skipped because Fish was not installed. The retained Python runtime-check suite
passed 7/7, release packaging tests 2/2, and version/closed-protocol checks passed.
The direct Python gateway suite passed real loopback TLS authorization, fixed
routes, expiry, hostname/purpose rejection, registration and endpoint diagnostics
with native-created certificates. Its certificates are test-only local material.

An initial sandboxed full-suite rerun failed because local socket bind was denied.
The unchanged TLS fixture and full suite passed with loopback access. No stderr
assertion was weakened and no production check was suppressed.

## Linux native execution

The same native lifecycle/crypto/maintenance fixtures passed **32/32** as an
x86_64 Linux ReleaseSafe executable, with no executable crypto tools on PATH and
an unusable OPENSSL_CONF. The test-only cross-build was:

```bash
zig build test-binaries -Dtarget=x86_64-linux -Doptimize=ReleaseSafe \
  --prefix /tmp/dragontools-linux-amd64-release
docker run --rm --network none --read-only --cap-drop ALL --user 501:20 \
  --ulimit core=0 --tmpfs /tmp:rw,nosuid,exec,size=128m -w /tmp \
  -e PATH=/no-external-crypto-tools -e OPENSSL_CONF=/nonexistent/unusable.cnf \
  -v /tmp/dragontools-linux-amd64-release:/native:ro \
  dragontools-native-test:qemu \
  /usr/bin/qemu-x86_64-static /native/tests/native-agent-tests
```

`dragontools-native-test:qemu` is a local Ubuntu 24.04 arm64 test image with
Ubuntu's qemu-user-static installed. This is x86_64 user-mode emulation, not
native amd64 hardware. Docker Desktop's Rosetta loader rejected the ReleaseSafe
ELF with `bss_size overflow`; QEMU ran it without a production workaround.
An earlier test launch from the read-only container root could not create
`.zig-cache`; running in writable `/tmp` corrected the harness location.

The real Python-gateway/native-client TLS suite also passed in Ubuntu 24.04 and
26.04 containers. Both used the native x86_64 ReleaseSafe fixture through QEMU,
read-only mounts, dropped capabilities, no external network, and invalid
OPENSSL_CONF. The commands inside those containers were:

```bash
DRAGONTOOLS_PKI_FIXTURE=/native/bin/dragontool-pki-fixture \
DRAGONTOOLS_PKI_RUNNER=/usr/bin/qemu-x86_64-static \
OPENSSL_CONF=/nonexistent/unusable.cnf \
python3 -I -B tests/agent_ingestion_test.py
```

## Helper installation and actual Vector metrics

Linux arm64 Ubuntu 24.04 fixtures passed with the final matching helper and
native fixture. The repository and fixture directories were mounted read-only;
only `/tmp` was writable and executable. No actual `/opt`, account, unit or host
configuration was changed. Commands inside the isolated containers:

```bash
python3 -I -B tests/helper_install_test.py \
  --fixture /fixture/native/bin/dragontool-pki-fixture \
  --agent /native/bin/dragontool-agent
python3 -I -B tests/integration/maintenance_metrics.py \
  --vector /fixture/vector/vector \
  --fixture /fixture/native/bin/dragontool-pki-fixture \
  --agent /native/bin/dragontool-agent --config /fixture/apps-vector.yaml
```

The first executed the actual production helper installer: initial upload,
bad/truncated checksum rejection, no-op, version switch, retained previous
release, wrong metadata and symlink refusal. The second validated the full
production-rendered Vector configuration, then ran the production exec source,
JSON-to-metric transform and trusted-label transform with a local capture sink.
Pinned Vector 0.58.0 emitted all seven gauges recorded in
`src/monitoring/agents/maintenance_fixture.prom`. No actual package upgrade or
24-hour live alert evaluation was performed. Vector's existing warning about
source acknowledgements remains; this test does not promise lossless telemetry.

## Release targets

ReleaseSafe builds passed for all four targets:

```bash
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-cross/linux-amd64
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-cross/linux-arm64
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-cross/darwin-amd64
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-cross/darwin-arm64
```

The packager produced four controller and two Linux helper archives locally;
each checksum was recomputed and every archive contained THIRD_PARTY_NOTICES and
both crypto license files. `file` confirmed both Linux architectures are static
ELFs and both macOS architectures are Mach-O. `otool -L` showed only libSystem
for the macOS controller, with no external crypto library. The stripped Linux
helpers are approximately 1.1 MiB amd64 and 910 KiB arm64. No release was published.
Both CI workflows run the same core suite on Ubuntu 24.04 and macOS 15; their
remote results have not been observed in this iteration.
