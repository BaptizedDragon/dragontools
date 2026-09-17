# Application agent validation — 2026-09-17

This records local process evidence for the application-repository iteration.
**Disposable-host integration not run.** No application or station SSH host was
contacted. Actual systemd hardening, journald access, SSH installation and
cross-host failure/recovery are outside this evidence.

## Real application signal pipeline

Fixtures use the previously audited Linux/arm64 Vector **0.58.0**, vmagent
**v1.152.0**, VictoriaMetrics **v1.151.0** and VictoriaLogs **v1.52.0** binaries in
`/tmp/dragontools-ingestion-fixture`. The runner checks each executable's committed
SHA-256 pin before starting it. The fixture directory also contains disposable
localhost mTLS certificates, never a station CA or a user's credentials. The
existing [native pipeline checklist](README.md#isolated-native-mtls-pipeline-evidence)
records artifact/certificate preparation.

These exact commands passed:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache \
  python3 tests/integration/render_agent_apps.py /tmp/dragontools-ingestion-fixture

docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 \
  --tmpfs /tmp:rw,size=1g --memory 1g \
  --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
  --mount type=bind,src=/tmp/dragontools-ingestion-fixture,dst=/fixture,readonly \
  4f8d1afed6d5 python3 -I -B \
  /repo/tests/integration/agent_ingestion_pipeline.py /fixture --applications
```

The bind source is the validation machine's checkout; replace it for another
checkout. The local image is the previously recorded official Python 3.12-slim
image, manifest
`sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea`.
The container has no external network, a read-only root/repository, dropped
capabilities, an unprivileged UID, bounded memory and disposable tmpfs storage.
Desktop sandbox access to the local Docker socket required approval.

The renderer invokes the actual Zig configuration functions. Its temporary Zig
package root is removed after generation. The native runner first validates the
exact generated Vector YAML. Runtime replaces only journald with a JSON stdin
fixture and rewrites data/certificate paths to disposable fixture paths; actual
host collection, VRL transforms, disk buffers, TLS, remote write, vmagent scrapes,
Victoria query APIs and production freshness checks run normally.

Six checks passed:

1. Real VictoriaMetrics enforces the authenticated host over a forged submitted
   remote-write `host` label.
2. Native Vector host metrics traverse mTLS into real VictoriaMetrics with
   application/environment/host scopes.
3. Selected-service Vector metadata traverses mTLS into real VictoriaLogs.
4. A structured journal-fixture event with forged application, environment,
   service and host fields receives the registered trusted identity. Host metrics
   exist for `doers/production`, `orderflow/staging` and `hostonly/production`; the
   last application declares no services.
5. Native vmagent scrapes both application scopes through namespaced jobs and
   overrides forged host/application/environment/service metric labels before
   authenticated remote write.
6. Production application-scoped host/log/app freshness queries accept current
   samples and reject a future process-start boundary.

These are process/protocol checks, not real journald collection or a production
installation. Verification scopes arrival checks to the selected application while
checking the shared agent's complete managed configuration and runtime; an
unrelated application's target outage does not block this application's apply.

## Local regression coverage

The temporary-filesystem ownership fixture passed:

```sh
python3 -I -B tests/agent_apps_test.py
```

It covers independent application manifests on one host, deterministic merge,
unchanged byte/mtime preservation, removal of one application's optional signals,
service-free host collection, canonical-unit conflict refusal, rejection of raw
agent adoption, published-file edits/symlinks, and interrupted partial staging
recovery followed by a no-op. Private `.<application>.pending` files are reserved
staging within the proven managed directory; partial staging is never treated as
published application state.

The real Python verification entrypoint fixture passed **7/7 tests**:

```sh
python3 -I -B tests/agent_checks_test.py
```

The loopback TLS/PKI fixture also passed, with approval to bind ephemeral localhost
ports outside the desktop socket sandbox:

```sh
python3 -I -B tests/agent_ingestion_test.py
```

It includes registered application log identity enforcement and refusal to
silently adopt raw-host registration as application registration or vice versa.
The current full Zig/CLI/cross-build results are recorded separately by the
iteration's final validation report.

## Observed filesystem-free and network contract

A further native exporter observation passed after the pipeline run:

```sh
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user 501:20 \
  --tmpfs /tmp:rw,size=256m --memory 512m \
  --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
  --mount type=bind,src=/tmp/dragontools-ingestion-fixture,dst=/fixture,readonly \
  4f8d1afed6d5 python3 -I -B \
  /repo/tests/integration/vector_capacity_network.py
```

The actual pinned Vector Prometheus exporter emitted:

```text
# TYPE host_filesystem_free_bytes gauge
host_filesystem_free_bytes{collector="filesystem",device="overlay",filesystem="overlay",host="fixture-host",mountpoint="/"} 23703851008
# TYPE host_network_receive_bytes_total counter
host_network_receive_bytes_total{collector="network",device="lo",host="fixture-host"} 100
# TYPE host_network_transmit_bytes_total counter
host_network_transmit_bytes_total{collector="network",device="lo",host="fixture-host"} 100
```

The host label is anonymized and scrape timestamps are removed; names, types,
remaining labels and values are observed output. The fixture uses only loopback
networking, so these values are not a throughput/performance measurement. These
samples and constants are now included in the committed Vector metric contract;
no metric names were inferred from memory. A focused contract test passed:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache \
  zig test src/monitoring/agents/metric_contract.zig
```
