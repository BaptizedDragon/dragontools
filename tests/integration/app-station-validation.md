# Application station validation record

The local ownership fixtures and isolated Linux processes below were run for the
application contract iteration. They do not exercise SSH, Ubuntu/systemd service
hardening, real blackbox HTTP targets or notification delivery.

**Disposable-host integration not run.**

## Local fixtures

```bash
python3 -I -B tests/app_station_test.py
python3 -I -B tests/scrape_test.py
python3 -I -B tests/vmalert_test.py
```

Observed: 14 application ownership/API fixtures, 22 existing native scraper
fixtures and 6 evaluator API fixtures passed. Application fixtures cover exact
manifest ownership, local-edit/symlink/hardlink refusal, independent app namespaces,
manual rules/Grafana assets/station secrets untouched, removal, default probe
alert override, independent dirty services, interruption recovery and unchanged
publication, partial staging writes and first-generation staging outside native globs. Fake/temporary files are not host validation.

## Pinned native Linux processes

The existing reviewed Linux arm64 binaries were copied from earlier local artifact
fixtures into `/tmp/dragontools-app-fixture`: VictoriaMetrics **v1.151.0**,
VictoriaLogs **v1.52.0** and vmalert **v1.152.0**. Their archive and extracted-binary
checksums are pinned in the corresponding component modules; these are existing
station versions, not new or mutable downloads.

```bash
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 \
  --tmpfs /tmp:rw,size=1g --memory 1g \
  --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
  --mount type=bind,src=/tmp/dragontools-app-fixture,dst=/fixture,readonly \
  4f8d1afed6d5 python3 -I -B /repo/tests/integration/app_station_runtime.py /fixture
```

The existing official Python 3.12-slim local image corresponds to manifest
`sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea`.
Paths and the local image ID above describe the actual local run and must be
adapted on another machine. The test creates private temporary process state and
terminates its processes; the container has no outside network.

Observed native checks:

1. Native `scrape_config_files` app glob parses and produces the expected loaded
   scrape metric/label policy and target identity.
2. Native repeated `-rule`/app globs, scoped LogsQL/PromQL and positive startup delay
   load and evaluate successfully with the existing shared packs.
3. Exact empty app rule documents coexist with the nonempty shared packs;
   standalone native `-dryRun` is skipped only for these expression-free documents.
4. A stored app probe failure (`probe_success=0`, scraper `up=1`) passes the current
   freshness/query contract. The fixture imports this telemetry locally only to
   test query semantics. It does not contact a target, send a notification test or
   claim that a live blackbox probe was performed.

Primary source review:

- [VM v1.151.0 include loading](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.151.0/lib/promscrape/config.go):
  `scrape_config_files` files contain arrays of scrape configs; file globs are
  sorted, zero matches are accepted, includes merge into the loaded config, and
  duplicate job names fail.
- [vmalert v1.152.0 rule flags and reload](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.152.0/app/vmalert/main.go):
  native repeated rule locations/globs are supported; app changes preserve the
  existing independent evaluator restart intent and read-only rule API checks.
