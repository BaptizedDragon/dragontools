# Doers reference hardening — 2026-09-19

**Disposable-host integration not run.** No `monitoring` or `softwarelanding` SSH
connection was made and the production Doers service was not stopped. This follows
the operator's instruction to finish locally and leave deployment validation to
them. Process fixtures do not prove real systemd hardening, journal access, DNS or
provider-firewall reachability.

## Reference and coverage

`render_doers.py` reads `examples/doers-monitoring.toml` with the production Zig
parser and renders Vector, vmagent, station documents and base rule packs. The
fixture checks the exact application/environment, SSH aliases, station DNS,
`doers.service`, `127.0.0.1:16005/metrics` and `https://doers.business/healthz`.
Only fixture runtime DNS/probe destinations and filesystem paths become local;
journal input becomes stdin because the container has no systemd journal. The
source TOML is unchanged. No production branch depends on the application name.

The network-isolated process gate runs the existing reviewed binaries:
VictoriaMetrics **v1.151.0**, VictoriaLogs **v1.52.0**, Caddy **v2.11.4**, Vector
**0.58.0**, vmagent/vmalert **v1.152.0**, blackbox_exporter **0.28.0**. Downloads use
archive and extracted-binary SHA-256 from the existing component modules. No pin
or service unit changes. A local discard HTTP sink receives vmalert notifications;
this fixture does not test Alertmanager delivery, Telegram or human receipt.

Observed checks:

- Empty client registry with absent, then empty, app directory; Caddy mTLS on
  fixture loopback 9443/9444 and both base rule packs verify without enrollment.
  Production IPv4 listener ownership is covered separately by runtime fixtures.
- Native app publication creates only `apps/doers`; app probes never become
  station probes. The loaded scraper and both evaluators accept the generated
  fragments. No app scrape match is valid before publication or after removal.
- Real Vector host metrics and vmagent payload traverse Caddy metrics ingress to
  VM; selected logs traverse logs ingress to VL. Forged application/environment/
  host/service labels are overwritten with the expected identities.
- Quiet metadata alone proves logs flow before any ordinary fixture event. It is
  `type=dragontools_stream`, level info; no synthetic application errors are used.
- Closing the local application listener yields real blackbox `probe_success=0`
  and vmagent `up=0`. Production readiness checks accept these fresh failed-target
  samples. The actual default **120-second** hold is preserved: the alert becomes
  pending, fires, then resolves after reopening the listener.
- Identical app publication leaves bytes and mtimes unchanged. Removing the
  probe changes only its scrape fragment, metrics rule and manifest, with only
  scraper/metrics-evaluator intent. Manual files outside app namespaces, logs
  rules, client credentials and agent/Caddy processes remain unchanged.

Controller/native/temp-file tests separately cover certificate enrollment no-op,
independent restart finalization, cross-app preservation and interrupted recovery.
The Doers fake-remote test checks one enrollment, one initial Vector/vmagent start,
zero base-ingress writes/restarts and no changes on an identical rerun. It is not
an SSH deployment test.

## Commands actually run

Local macOS arm64, Zig **0.16.0**:

```sh
export ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 -I -B tests/agent_checks_test.py
python3 -I -B tests/app_station_test.py
python3 -I -B tests/agent_journald_test.py
python3 -I -B tests/agent_ingestion_test.py
python3 -I -B tests/agent_ingestion_test.py --caddy /tmp/dragontools-caddy-2.11.4
python3 -I -B tests/release_test.py
python3 tools/verify_crypto_vendor.py
python3 tests/version_test.py
zig fmt --check build.zig src
git diff --check
python3 -I -B tests/integration/render_doers.py /tmp/dragontools-caddy-pipeline
python3 -I -B tools/fetch_doers_fixture.py --output /tmp/dragontools-caddy-pipeline --arch arm64
```

Results: **390/390 Zig tests**, **269 CLI checks** (Fish unavailable), **9 signal/
runtime**, **17 app station**, **9 journald lifecycle**, **2 release** tests; vendor
integrity and version/diagnostic checks passed. The first full macOS run exposed a
pre-existing race in the test-only TLS proxy: an upstream route rejection can
arrive before its body write completes. The fixture now reads and requires the
actual rejection response. Broken writes cannot count as success. Empty stderr
assertions and production ingress are unchanged.

The following ran against an existing local Ubuntu 24.04 arm64 fixture image:

```sh
docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=1g \
  -v "$PWD:/work:ro" -v /tmp/dragontools-caddy-pipeline:/fixture:ro \
  -w /tmp dragontools-pki-test:ubuntu24.04 \
  python3 -I -B /work/tests/integration/doers_runtime.py /fixture
```

All seven process gates above passed. All binaries and temporary localhost
credentials were supplied read-only; writable state was disposable `/tmp`.

## Deployment gate still required

Follow [the two-host procedure](application.md) using operator-approved hosts.
Record service PIDs/start times, public certificate fingerprints and owned file
hashes before/after the deliberate unchanged apply. Exercise actual journald
collection, stricter administrator limits and capacity on those hosts. Queue and
journal bounds constrain DragonTools-managed storage, not unrelated application
files or unlimited lossless retention; provision disk headroom for both Vector
buffers, vmagent's 1 GiB queue and the configured journal budget.
