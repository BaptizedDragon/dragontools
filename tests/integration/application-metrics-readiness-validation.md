# Application metrics readiness investigation — 2026-09-19

## Production access boundary

All production commands were read-only. No apply/install, service changes, file
publication, permission changes, telemetry injection or private-key output was
performed. SSH used the existing `softwarelanding` and `monitoring` aliases with
BatchMode and StrictHostKeyChecking. Existing application-host credentials were
used locally for a hostname/CA-verified HTTPS `GET /health` only.

`softwarelanding` was accessible. The `monitoring` signing agent repeatedly
failed to sign, so this iteration could not inspect station services/registration
or execute the old/new readiness queries against the production database. Do not
mistake the isolated process reproduction below for that missing production
observation. One initial inspection attempt was also rejected by automatic review
because it read the private authorization helper source for a checksum; that file
was omitted from the safer retry, which then encountered the signing failure.

## Observed application-host evidence

- Doers active, local `http://127.0.0.1:16005/metrics` HTTP 200, 49,445 bytes and
  375 Prometheus sample lines. Application metric families include counters and
  histogram sum/count pairs. No application payload/label values were retained.
  A second read found **44 groups of metric names with identical source labels**,
  including `doers_http_request_duration_seconds_sum`/`_count`. The new agent,
  source, TCP and remote-write checks all passed when executed in memory on the
  host; nothing was installed or written there.
- vmagent active as `dt-vmagent`, PID 453186 at inspection, started 13:46:08 UTC.
  Management listener `127.0.0.1:8429`; scrape interval 15s, timeout 5s.
- Target API reports the expected local Doers URL, `health=up`, no scrape error,
  `application=doers`, `environment=production`, `service=doers`, stable machine
  host identity, `agent=vmagent`, job `dragontools-app-5-doers-5-doers`, and instance
  `127.0.0.1:16005`. Generated target and metric relabeling set these identities.
- Runtime remote-write URL is HTTPS station port 9443 `/api/v1/write`, with
  explicit CA/client certificate/key paths and `forcePromProto=true`.
  No TLS bypass was present.
- vmagent telemetry: 207 successful 2XX requests, 89,596 rows pushed,
  2,434,645 bytes sent, zero errors/retries/dropped packets and zero queued bytes
  at the first observation. This is positive backend acceptance evidence, not
  a substitute for querying the station's stored application series.
- Vector active on loopback 8686. Its client certificate matches vmagent's public
  fingerprint and host URI. CA/client/key files are mode 0400 owned by each
  consumer. Only public certificate details and file metadata were inspected.
- Station DNS resolves, TCP 9443 connects, and authenticated `/health` returns 204
  with an empty body under strict CA and hostname verification. This proves the
  current certificate is accepted/authorized, without reading station registry.
- Agent journals contain only systemd lifecycle entries; service stdout/stderr
  are deliberately null. No raw journal messages were printed.

## Independently reproduced code defect

`agents/signals.py` applied `timestamp()` to every non-scrape metric matching the
trusted identity. The transform removed `__name__`. Distinct counters and
histogram sum/count series with identical other labels became duplicate output
series, causing VictoriaMetrics HTTP 422 and the opaque old
`application_metrics_ready` failure. This is consistent with the observed healthy
scraper/transport, but production query confirmation remains blocked by SSH.

The original process fixture exposed just one application metric and missed the
collision. It now exposes a counter plus histogram sum/count/bucket samples with
identical trusted identity and deliberately forged incoming identity labels.
The unchanged verifier failed that real pinned vmagent -> mTLS Caddy -> private
Unix authorization -> VictoriaMetrics regression. The corrected verifier passes,
and the fixture explicitly requires the old query to return 422 with the
`duplicate output timeseries` semantic error.

The fix uses `timestamp(...) keep_metric_names`, retains both post-process-start
and 90-second freshness constraints, and wraps the result in `count(...) > 0`.
It requires no application-specific metric name. See upstream
[MetricsQL metric-name preservation](https://docs.victoriametrics.com/metricsql/#keep_metric_names).

Separate read-only checks identify completed source scrape, active agent, TCP
reachability, authenticated mTLS, successful current-process remote writes and
stored application visibility. Down targets remain valid; historical error
counters need not reset. TLS and authorization policy, production renderers,
units, routes, credentials, retry intervals/deadlines and finalization are unchanged.

## Validation

Using Zig 0.16.0, with `ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache`:

```sh
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 tests/agent_checks_test.py
```

Results: 402/402 Zig tests, 309 CLI checks (two Fish checks skipped because Fish
is not installed), 15 Python runtime/signal tests. An initial Zig build caught a
missing integer type on the diagnostic deadline selection; corrected before the
successful build and full suite.

With the existing read-only fixture of checksum-verified pinned binaries and
**disposable localhost credentials**, the following ran locally (no production
SSH or external networking):

```sh
docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=1g \
  -v "$PWD:/work:ro" -v /tmp/dragontools-caddy-pipeline:/fixture:ro \
  -w /tmp dragontools-pki-test:ubuntu26.04 \
  python3 -I -B /work/tests/integration/doers_runtime.py /fixture --metrics-only
```

Passed: zero-app ingress/base rules, scoped application publication, real pinned
multi-metric remote writes, old-query failure/new-query success, new source/TCP/
acceptance checks, trusted labels, quiet logs and rejection of pre-start samples.
The complete Ubuntu 24.04 fixture also passed, including the explicit old-query
assertion, down-target source/readiness checks, the actual two-minute alert hold,
firing/recovery/resolution, unchanged publication, scoped probe removal and
preservation of Vector, Caddy, credentials and manual files:

```sh
docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=1g \
  -v "$PWD:/work:ro" -v /tmp/dragontools-caddy-pipeline:/fixture:ro \
  -w /tmp dragontools-pki-test:ubuntu24.04 \
  python3 -I -B /work/tests/integration/doers_runtime.py /fixture

docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=256m \
  -v "$PWD:/work:ro" -w /tmp dragontools-pki-test:ubuntu26.04 \
  python3 -I -B /work/tests/agent_checks_test.py
```

The latter portable Python suite passed 15/15 tests, matching macOS.
`zig fmt --check build.zig src` and `git diff --check` passed. GitHub Actions was
not dispatched. **Disposable-host integration not run.** Process fixtures do not
validate Ubuntu systemd deployment.

## Manual deployment after review

No station reinstall is required for this controller-only fix. Existing unfinished
vmagent intent may cause its own restart during apply; it must be retained until
successful verification. Working Vector/Caddy, CA/client identity and unrelated
namespaces should remain unchanged. Use the just-built binary rather than an
older PATH installation:

```sh
zig build -Doptimize=ReleaseSafe
DRAGONTOOL="$PWD/zig-out/bin/dragontool"
cd /replace/with/doers-repository
"$DRAGONTOOL" monitoring apply --plan
"$DRAGONTOOL" monitoring apply
"$DRAGONTOOL" monitoring app-verify
"$DRAGONTOOL" monitoring apply
```

Expected after successful reconciliation: final unchanged apply prints
`No changes required.`. This deployment was not performed during investigation.
