# Caddy managed-state convergence — 2026-09-19

## Production evidence and boundary

The user authorized read-only SSH to `monitoring`. Initial authentication stalled
at the signing agent; inspection proceeded only after the user requested a retry.
Every SSH call used `BatchMode=yes` and `StrictHostKeyChecking=yes`.
No installation, service activation, permission repair, file publication or
private-key read occurred. No unrelated Grafana or Telegram secrets were inspected.

Observed host: **Ubuntu 26.04, systemd 259.5-0ubuntu3.4** (not systemd 260).
`systemctl status`, selected `systemctl show` properties, `systemctl cat`,
filtered `journalctl -u ... -n 200`, account lookup, file/directory metadata,
non-secret file hashes and `ss` established:

- `dragontools-caddy.service` active/running, enabled, loaded, no daemon reload
  needed and no drop-ins. PID **231027**, started **2026-09-19 12:38:12 UTC**.
  The journal contained only the two service-manager starting/started events.
- Account `dt-caddy`: uid **980**, primary gid **974**, expected service home and
  nologin shell. Its account group is only dt-caddy; the *unit's* effective
  supplementary group is dt-ingest, as intended for private socket access.
- Root-owned Caddy release/config directories `0755`; service state directory
  dt-caddy:dt-caddy `0750`; root-owned single-link binary `0755` and config/unit
  `0644`; `current -> v2.11.4`. No incompatible paths or metadata were found.
- Ingestion `server` root:dt-ingest `0750`; `pki` and `clients` root:root `0700`.
  The unit's `InaccessiblePaths` correctly hides all three canonical directories.
  Caddy has no RuntimeDirectory; the empty property and unused default mode
  `0755` are valid. Authorization owns the separate private runtime directory.
- Caddy owns exactly **0.0.0.0:9443 metrics** and **0.0.0.0:9444 logs**, with no
  extra TCP/UDP listener. Each routes through its fixed private Unix socket to
  authorization, then the matching loopback Victoria backend.
- The root-owned, empty, single-link `0600` Caddy restart marker remains present.
  The authorization restart marker is absent.

Exact matching non-secret files:

| File | Bytes | SHA256 |
| --- | ---: | --- |
| Caddy v2.11.4 amd64 binary | 48,521,378 | `b7105518e3ed1c0761f232e44fc09345535533c9cb0abf0e12809416c7ac64d9` |
| Caddyfile | 2,393 | `ac60cb630da25bc5ca32ff00e537db98d0aba34090ea071ea3f878cea59903c7` |
| Service unit | 1,365 | `4feaa42d22b56e5f145f5f9121350a60658d2fa1bdc780c525d801810b7c62ff` |

The unit and Caddyfile match the current renderer byte-for-byte. The pinned
`caddy adapt --config /etc/dragontools/caddy/Caddyfile --adapter caddyfile`
succeeded, producing two server definitions and a disabled admin endpoint.
Raw adapted output was not printed. Full `caddy validate` was not invoked: its
TLS provisioning loads private-key contents, and an ordinary shell does not
inherit the service's `CREDENTIALS_DIRECTORY`. No credentials were fabricated and
the unit was not weakened for manual validation.

## Exact defect

The original read-only verifier passed account, exact unit, directories, config
and runtime checks. Its systemd set comparison alone failed at `checks.py:77`.
This command reported a display placeholder, not the underlying mappings:

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monitoring \
  'systemctl show --all --property=LoadCredential dragontools-caddy.service'
# LoadCredential=[unprintable]
```

The typed query returned all three correct ID/source-path pairs:

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monitoring \
  'busctl --system --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/dragontools_2dcaddy_2eservice org.freedesktop.systemd1.Service LoadCredential'
```

```json
{"type":"a(ss)","data":[["ca.crt","/etc/dragontools/ingestion/server/ca.crt"],["server.crt","/etc/dragontools/ingestion/server/server.crt"],["server.key","/etc/dragontools/ingestion/server/server.key"]]}
```

Substituting only those typed mappings into the former verifier **in memory**
made its complete managed check pass on the unchanged host. Upstream systemd
also documents this in code: `LoadCredential` is an
[`a(ss)` property](https://github.com/systemd/systemd/blob/v260/src/core/dbus-execute.c),
while the [display printer](https://github.com/systemd/systemd/blob/v260/src/shared/bus-print-properties.c)
uses `[unprintable]` for unsupported display types. No assumption about systemd
version numbers is needed in the fix.

Account, binary, link, directories, unit and config already match desired state.
On a rerun, their reconciliation returns unchanged; Caddy activation still sees
its pending restart marker and restarts it. The false verification failure
previously prevented finalization, retaining the marker for another restart.
There is no evidence of a Caddy startup, socket-permission, configuration or
credential-loading failure.

## Corrected behavior and read-only verification

The verifier reads the typed property and requires every exact mapping from the
rendered unit, once each, in any order. Missing, extra, duplicate, malformed and
wrong-source mappings fail deterministically. Query failures also fail closed;
there is no display-string fallback or ignored credential check. No credential
contents are requested. Separate fixed check IDs identify account, binary, unit,
config, directories, effective systemd policy, credentials, listener and TLS.

All **nine corrected Caddy checks passed read-only on production**, including
TLS server CA/hostname validation and rejection of certificate-less connections
on both ports. The TLS probe read only the public CA certificate and saved DNS
endpoint; it created no client identity and read no private keys. Native PKI
verification, which would open keys for pairing, was not invoked.

Caddy PID/start time and both restart-marker states were unchanged afterward.
The verifier ran in memory; no remote verifier/helper file was installed.
The production unit, Caddyfile, pinned version, credential layout and security
boundaries remain unchanged. Caddy pin provenance remains the
[official release record](../../design.md#caddy-ingress-pins-and-verification).

## Regression and validation

`tests/caddy_checks_test.py` uses the actual rendered unit/config and observed
systemd display plus typed mappings. It preserves the production uid/gid distinction.
Small fixture executable bytes stand in for the binary; the committed amd64 pin
and exact production unit/config hashes are independently asserted. The initial
regression failed with the former verifier and passed after the fix.

Other cases test strict mapping validation, redacted failures, each named managed
check, links/file integrity/hardening, and the actual generated activation and
finalization scripts in a private temporary directory. A retained marker triggers
one restart; failed verification retains it; successful verification permits
finalization and the next activation is unchanged. Controller tests cover all nine
semantic failures, full install/verify/install convergence, and independent Caddy
binary/unit/config/certificate changes without restarting other components.

Using Zig **0.16.0**, the following passed on macOS arm64:

```sh
export ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 tests/caddy_checks_test.py
python3 tests/ingress_managed_test.py
python3 tests/agent_checks_test.py
zig fmt --check build.zig src
git diff --check
```

Results: **401/401 Zig tests** (356 controller/fixture + 45 native lifecycle),
**309 CLI smoke checks**, **6 Caddy**, **7 authorization** and **10 runtime/signal**
Python tests. Fish checks were skipped because Fish is not installed. The full
suite ran with local socket access for the existing TLS fixtures.

The same three Python suites passed in existing local Ubuntu **24.04 and 26.04**
arm64 containers, with a Linux-compiled renderer helper:

```sh
zig build test-fixture -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe \
  --prefix /tmp/dragontools-caddy-checks-linux
for distro in 24.04 26.04; do
  docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=256m \
    -v "$PWD:/work:ro" -v /tmp/dragontools-caddy-checks-linux:/fixture:ro -w /tmp \
    -e DRAGONTOOLS_PKI_FIXTURE=/fixture/bin/dragontool-pki-fixture \
    "dragontools-pki-test:ubuntu$distro" sh -c \
    'python3 -I -B /work/tests/caddy_checks_test.py && python3 -I -B /work/tests/ingress_managed_test.py && python3 -I -B /work/tests/agent_checks_test.py' || exit
done
```

These containers exercise portable fakes, not real systemd/D-Bus. The typed query
was exercised against the real Ubuntu 26.04 station. GitHub Actions was not
dispatched for this local patch; its existing Linux/macOS matrix runs the new
fixtures through the normal test commands.

**Disposable-host integration not run.** Production mutation/convergence was not
performed. After review, the operator must build, run station install, verify,
and deliberately rerun unchanged install. The expected first change is completing
Caddy's retained restart intent; the expected final rerun is `No changes required.`
