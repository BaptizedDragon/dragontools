# Station-owned mTLS ingress — 2026-09-19

**Disposable-host integration not run.** No application/station SSH alias was
contacted. Containers and local TLS/process fixtures do not prove systemd runtime
hardening, real journald access or provider-firewall reachability. The remaining
[application deployment gate](application.md) starts with station install and
zero-client verification before any application is registered.

## Behavior checked

Station install owns ingestion/Caddy accounts, CA/server PKI, the native helper,
private authorization program/unit and Caddy binary/config/unit/activation.
Fresh stations use `--ingress-hostname` or `[ingress].hostname`; subsequent runs
can reuse an exactly managed saved server identity. No SSH hostname inference.
No application registration or client key is used for station health. Both
private sockets reject anonymous requests; both Caddy TLS ports verify the server
CA/hostname and reject certificate-less connections. Application apply inspects
base ingress read-only, refuses missing/drifted/pending state before enrollment,
and never finalizes station restart intent.

Controller fixtures cover empty stations, delayed TLS readiness, deadline failure,
deterministic invariant failure, independent Caddy restart/finalization, no-op
reruns and read-only verification. Native lifecycle fixtures retain bootstrap
interruption recovery, registry 0700-to-0750 migration, key locality, strict
profiles, renewal, no silent CA rotation and existing identity preservation.

Caddy remains **v2.11.4**, using the unchanged official-release archive/binary pins
and [recorded checksum provenance](../../design.md#caddy-ingress-pins-and-verification).
No service units, Caddyfile routing, agent configuration or alert definitions
changed for this ownership move. Public listeners remain IPv4 9443 metrics and
9444 logs; 9445 stays closed. Private authorization has Unix sockets only.

## Commands actually run

Zig **0.16.0**, macOS arm64. Zig commands used:

```sh
export ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 -I -B tests/agent_ingestion_test.py --caddy /tmp/dragontools-caddy-2.11.4
zig build test-binaries -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe \
  --prefix /tmp/dragontools-station-linux
```

Results: **388/388 Zig tests**, **269 CLI smoke checks**, and the real pinned-Caddy
TLS fixture passed. Fish completion checks were skipped because Fish is not
installed. An initial sandboxed run could not bind a loopback socket; the full
suite was rerun with local socket access. Intermediate fixture expectations were
updated for the ownership move; no assertions on sensitive output were weakened.

The following commands passed on both existing local Ubuntu images, Linux arm64:

```sh
for os in 24.04 26.04; do
  docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=256m \
    -v "$PWD:/work:ro" \
    -v /tmp/dragontools-station-linux:/fixture:ro \
    -v /tmp/dragontools-caddy-linux-native:/caddy:ro \
    -w /tmp -e DRAGONTOOLS_PKI_FIXTURE=/fixture/bin/dragontool-pki-fixture \
    "dragontools-pki-test:ubuntu$os" sh -c \
    '/fixture/tests/native-agent-tests && python3 -I -B /work/tests/agent_ingestion_test.py --caddy /caddy/caddy'
done
```

Each ran **41/41 native PKI/lifecycle tests** plus the real Caddy fixture, including
an empty registry before registration, hostname rejection, TLS authentication,
registered/unregistered identities, purpose/expiry, rollout, fixed port isolation,
forged headers, bounds and trusted labels. Containers had no external networking
and only temporary writable state. This is local evidence, not a GitHub Actions
run or an Ubuntu systemd deployment claim.
