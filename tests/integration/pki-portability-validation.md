# Station CA bootstrap and portability validation — 2026-09-18

CA validation checks X.509 PEM/private-key parsing, current validity, exact
CA:TRUE,pathlen:0 and keyCertSign,cRLSign, matching DER public keys and the
self-issued certificate's self-signature. Basic Constraints
and Key Usage use bounded DER inspection; OpenSSL verification uses explicit
`-purpose any -check_ss_sig` after extension validation. No platform branch or
output-wording expectation is used. Existing diagnostic redaction and Zig
empty-stderr assertions remain unchanged.

New bundles pass validation in private staging before publication. Failure
removes staging; rerun bootstraps from only empty pki/clients/registry parents.
New directory modes are explicit under umask 077. The fixed registry directory
repairs to 0750 only after proving root:dt-ingest ownership and its location under
the managed tree, including mode-0700 directories on populated stations.
Existing invalid CA material is preserved without rotation.

The pre-fix helper from Git HEAD reproduced the reported empty-parent layout
locally through the actual `main()` entrypoint: exit 86, registry mode 0700, and
`generate()` never called. The earlier direct fixtures used umask 022 and missed
this pre-CA failure. New entrypoint cases exercise the production umask, absent
parents, both empty-registry modes, failed validation cleanup, retry, no-op,
secret-free output and refusal to repair symlinks, other file types, foreign
ownership or paths escaping the owned tree. Populated-station migration preserves
file bytes and mtimes; the next correct-mode apply performs no chmod. Read-only
verification reports exit 89 without mutation or raw output. Controller fixtures
map that result to `ingestion / registry_permissions` without retries and prove
mode-only repair requests no service restart, followed by an unchanged rerun.

## Direct crypto and TLS checks

```sh
python3 -I -B tests/agent_pki_station_test.py
python3 -I -B tests/agent_pki_client_test.py
python3 -I -B tests/agent_ingestion_test.py
```

The direct station suite passed on macOS with Python 3.14.6 and Homebrew OpenSSL
3.6.3; ingestion and all 23 client lifecycle tests also passed directly and through
the full Zig suite. The station suite now has **40/40 tests**, preserving all 23 original
lifecycle tests. CA cases include malformed/missing/wrong-path-length extensions,
non-CA certificates, missing/extra signing usage, invalid/public-only/mismatched
keys, expiration, non-self-issued certificates and corrupted signatures.
Successful and refused validation leave certificate/key bytes and mtimes intact.

The initial Ubuntu 24.04 run exposed an existing CSR verification defect:
OpenSSL 3.0 `req -verify` returns status 0 for a corrupted signature. A focused
real-crypto reproduction confirmed it. CSR verification now uses explicit
`dgst -sha256 -verify` over the exact DER request info and already allowlisted
ECDSA/SHA-256 algorithm. The original rejection test is unchanged and passes.
Only public key/signature files are staged; no diagnostic wording is parsed.

All three Python suites passed on both supported Ubuntu versions:

| Environment | Python | OpenSSL | Station | Client | Ingestion |
| --- | --- | --- | --- | --- | --- |
| Ubuntu 24.04 arm64 | 3.12.3 | 3.0.13 | 40/40 | 23/23 | pass |
| Ubuntu 26.04 arm64 | 3.14.4 | 3.5.5 | 40/40 | 23/23 | pass |

Test images were built from official `ubuntu:24.04` and `ubuntu:26.04` with
distribution packages `python3 openssl`, then `zsh` for the full shell tests.
Package downloads happened only during image construction. All test runs used
no networking, no Linux capabilities and read-only repository mounts:

```sh
for version in 24.04 26.04; do
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 501:20 \
    --tmpfs /tmp:rw,size=256m --memory 512m \
    --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
    -w /repo "dragontools-pki-test:ubuntu$version" sh -ec '
      python3 -I -B tests/agent_pki_station_test.py
      python3 -I -B tests/agent_pki_client_test.py
      python3 -I -B tests/agent_ingestion_test.py'
done
```

The local mTLS fixture generates its own certificates; it passed unchanged, so
no separate ingestion fixture or gateway production change was made.

## Repository checks

```sh
zig fmt build.zig src
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig test src/main.zig --test-filter 'registry '
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build test --summary all
python3 -I -B tests/release_test.py
git diff --check
```

```sh
PATH="/tmp/dragontools-fish-3.7.1/fish.app/Contents/Resources/base/usr/local/bin:$PATH" \
XDG_CONFIG_HOME=/tmp/dragontools-shell-xdg-config \
XDG_DATA_HOME=/tmp/dragontools-shell-xdg-data \
XDG_CACHE_HOME=/tmp/dragontools-shell-xdg-cache \
python3 -I -B tests/cli_smoke.py
```

Formatting, the native build and all 15 filtered tests passed with Zig 0.16.0. Release packaging tests
passed **2/2**; CLI smoke passed **283 checks**, including Bash/Zsh/Fish completion.
The full macOS Zig suite passed **319/319 tests**, with **3/3 build steps**. This
includes the unchanged local mTLS wrapper and both the expanded 40-test station
suite and the existing 23-test client lifecycle suite. `git diff --check` passed.

The complete Zig suite was also compiled for Linux and executed in both Ubuntu
containers. Initial container-only failures came from a nonexistent numeric user
and noexec temporary mounts; the final harness uses the images' existing Ubuntu
user and executable temporary storage, without changing any assertion. One
remaining fixture used 65,536 quotes, expanding to a 262 KB `sh -c` argument;
a focused reproduction confirmed Linux rejects it with E2BIG. The test now uses
16,384 quotes, still above the compression threshold, preserving all literal
round-trip, protected-stdin and empty-stderr assertions. Production SSH code is
unchanged.

Final Linux result: **319/319 tests passed, zero skips**, independently on Ubuntu
24.04 and 26.04. This is execution of the complete cross-compiled arm64 test
binary, not a claim that the Zig compiler/build driver ran inside the containers.

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig test src/main.zig -target aarch64-linux --test-no-exec -femit-bin=/tmp/dragontools-registry-linux-tests
for version in 24.04 26.04; do
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 1000:1000 \
    --tmpfs /tmp:rw,exec,size=256m \
    --tmpfs /repo/.zig-cache:rw,exec,size=256m,mode=1777 --memory 768m \
    --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly \
    --mount type=bind,src=/tmp/dragontools-registry-linux-tests,dst=/fixture/test,readonly \
    -w /repo "dragontools-pki-test:ubuntu$version" /fixture/test
done
```

## Limits

These are real OpenSSL and local loopback TLS fixtures, not remote deployment
validation. No SSH host was contacted. **Disposable-host integration not run.**
GitHub Actions itself was not executed here; its unchanged Ubuntu 24.04/macOS 15
matrix runs the same full Zig suite, including both Python fixture wrappers and
the empty-stderr assertions. Containers do not validate SSH deployment, systemd
hardening, live monitored-host ingestion, firewall/DNS or real-host ownership.
