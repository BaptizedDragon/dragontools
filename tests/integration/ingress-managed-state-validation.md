# Ingress authorization convergence — 2026-09-19

## Read-only production evidence

The user authorized inspection of the real `monitoring` OpenSSH alias. All SSH
calls used `BatchMode=yes` and `StrictHostKeyChecking=yes`. No deployment, file
write, permission repair, service activation or private-key read was performed.
Unrelated Grafana/Telegram configuration and secrets were not inspected.

Metadata and non-secret file inspection confirmed:

- `dragontools-ingress-auth.service` active/enabled, `NeedDaemonReload=no`.
- `dt-ingest`: uid **981**, primary gid **975**, expected home and nologin shell;
  account uid and group gid must not be assumed equal.
- Root-owned ingestion tree `0755`; `pki`/`clients` root:root `0700`;
  `registry`/`server` root:dt-ingest `0750`; service state/runtime directories
  dt-ingest:dt-ingest `0750`; both private sockets dt-ingest:dt-ingest `0660`.
- Authorization helper root:root `0644`, single link, SHA256
  `c953d29666933442b76d5727f077f416dcd4b589c9b497f565eee184cb470d0b`.
- Unit root:root `0644`, single link, **953 bytes**, SHA256
  `657b327b45f377b1080021e8afad12c9d078a694031087f8dce6a6724aedd331`.
- Independent authorization and Caddy restart-intent markers exist, both
  root:root `0600`, single-link empty regular files.

The following safe queries illustrate the relevant evidence (not deployment):

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monitoring \
  'systemctl show --property=DropInPaths --property=CapabilityBoundingSet --property=AmbientCapabilities dragontools-ingress-auth.service'
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monitoring \
  'sha256sum /etc/systemd/system/dragontools-ingress-auth.service /opt/dragontools/ingress-auth/authorize.py'
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monitoring \
  'stat -c "%U:%G %a %F" /etc/dragontools/ingestion/registry /etc/dragontools/ingestion/server /var/lib/dragontools/ingress-auth-restart-required'
```

Explicit property selection reported all three values empty. In contrast, plain
`systemctl show UNIT` omitted all three properties. The former verifier's
`values.get(key) == ''` assertion therefore compared `None` with `''` and failed.
Executing the former verifier read-only identified precisely that assertion;
changing only the in-memory query to `show --all` passed both managed and runtime
verification on the same unchanged host.

The final seven named managed checks and the process/socket runtime check also
passed on this host using the local corrected verifier in memory. PID **221606**
and start time **2026-09-19 07:50:45 UTC** were unchanged after investigation.
No private CA/server files were opened: the added server check examines directory
metadata only. Full cryptographic station verification was not invoked.

## Why repeated installs changed state

Account, helper, unit and directory desired state already matched. The outstanding
authorization restart marker was the reason activation reported a change:
`activation("ingress-auth")` restarted the service. Verification then falsely
failed before finalization could unlink its marker, so the next install repeated
the restart. Repairing permissions or weakening `InaccessiblePaths` could not
resolve this query defect. Caddy's independent outstanding marker remained pending
because installation stopped before its stage.

The corrected verifier requests all properties, still rejects missing or nonempty
security properties, and derives effective policy from the same rendered unit
used by installation. Registry/server modes share the native PKI storage constants.
No unit, helper, PKI profile, listener, retry policy or restart policy changed.

## Local regression coverage

`tests/ingress_managed_test.py` obtains the real spec and activation/finalization
scripts from the test-only native fixture helper. Its observed-property snapshot
is independent of the renderer and simulates systemd's omission of empty values.
The initial production-state test was run against the former implementation and
failed, then passed with the fix. Additional cases cover missing/nonempty security
properties, list ordering, exact file hashes, unequal uid/gid, symlinks, ownership,
modes, individual semantic stages, retained intent on failure and no-op activation
after successful verification/finalization. No secret files exist in this fixture.

Controller tests exercise all seven failure IDs without retries, independent
intent and a complete install/verify/install sequence with no redundant file writes
or other-component restarts. CLI smoke cases prove the fixed semantic IDs reach
the user while remote stdout/stderr sentinels remain suppressed. The ordinary CI
test command runs these same fixtures on Linux and macOS without platform branches.

## Commands and results

Using Zig **0.16.0** on macOS arm64:

```sh
export ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache
zig fmt build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 tests/ingress_managed_test.py
python3 tests/agent_checks_test.py
zig fmt --check build.zig src
git diff --check
```

All passed: **400/400 Zig tests** (355 controller/fixture + 45 native lifecycle),
**300 CLI smoke checks**, **7 ingress managed-state tests**, and **10 existing
runtime/signal tests**. Fish checks were skipped because Fish is not installed.
The first sandboxed full run was **399/400**: an existing TLS fixture could not
bind its loopback socket. The full suite passed when rerun with local socket
access, without changing assertions or production behavior.

The same two Python fixtures also passed (**7 + 10 each**) in both existing local
Ubuntu 24.04 and 26.04 arm64 images, using the Linux-compiled renderer helper:

```sh
zig build test-fixture -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe \
  --prefix /tmp/dragontools-ingress-linux
for distro in 24.04 26.04; do
  docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,size=256m \
    -v "$PWD:/work:ro" -v /tmp/dragontools-ingress-linux:/fixture:ro -w /tmp \
    -e DRAGONTOOLS_PKI_FIXTURE=/fixture/bin/dragontool-pki-fixture \
    "dragontools-pki-test:ubuntu$distro" sh -c \
    'python3 -I -B /work/tests/ingress_managed_test.py && python3 -I -B /work/tests/agent_checks_test.py' || exit
done
```

GitHub Actions was not dispatched for this uncommitted local patch. Its existing
Linux/macOS matrix includes the new tests via `zig build test` and CLI smoke.

**Disposable-host integration not run.** Local fakes and read-only production
checks do not prove mutating systemd convergence or complete Caddy/application
signal flow. The operator must deploy the reviewed controller and finish station
install, then verify and deliberately rerun unchanged install. The expected final
result is `No changes required.`; it has not been claimed as a production result.
