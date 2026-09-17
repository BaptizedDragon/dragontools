# Explicit station hostname validation — 2026-09-17

Application `station.ssh_host` remains the administrative SSH alias;
`station.hostname` is now the required DNS-only ingestion/TLS name. Tests run
locally with Zig 0.16.0. No application/station SSH host was contacted.
**Disposable-host integration not run.**

## Commands

```sh
zig fmt build.zig src
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build test --summary all
python3 -I -B tests/release_test.py
git diff --check
```

All commands above passed. The final macOS suite reported **317/317 Zig tests
passed**, 3/3 build steps. Its embedded real-crypto suites include **23 station
and 23 client tests**. Formatting and the native build passed with Zig 0.16.0.

The local TLS fixture requires permission to bind ephemeral loopback listeners.
No production stderr suppression, TLS validation relaxation, sleeps or
platform-specific test expectations were introduced.

```sh
PATH="/tmp/dragontools-fish-3.7.1/fish.app/Contents/Resources/base/usr/local/bin:$PATH" \
XDG_CONFIG_HOME=/tmp/dragontools-shell-xdg-config \
XDG_DATA_HOME=/tmp/dragontools-shell-xdg-data \
XDG_CACHE_HOME=/tmp/dragontools-shell-xdg-cache \
python3 tests/cli_smoke.py
```

CLI smoke passed **283 checks**, including Bash/Zsh/Fish completion and rejection
of missing, misspelled, URL, port, path, whitespace and IP hostnames before SSH
for apply/app-verify/app-status. Release packaging fixtures passed **2/2**.

Additional focused commands passed:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig test src/main.zig --test-filter 'config.application' --test-filter 'application local plan' --test-filter 'application ownership'
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig test src/main.zig --test-filter 'hostname' --test-filter 'station summary'
python3 -I -B tests/agent_apps_test.py
python3 -I -B tests/agent_pki_client_test.py test_hostname_change_preserves_client_identity_and_public_registration_finalizes test_renewal_after_hostname_change_reuses_key_and_recovers
./zig-out/bin/dragontool monitoring apply --config examples/doers-monitoring.toml --plan
```

The two focused Zig runs passed **23/23** and **18/18**, including imported test
declarations. The focused client crypto tests passed **2/2**; application-manifest
ownership and local plan checks passed. The complete suite includes the final
OpenSSL station/client fixtures and an actual loopback TLS hostname mismatch
classified as `server_tls_invalid`, without raw exception output.

## Evidence and limits

The final station and client helpers also passed **23/23 + 23/23** real OpenSSL
tests in the cached local Linux container, with networking disabled and no package
installation:

```sh
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --user 501:20 --tmpfs /tmp:rw,size=256m --memory 512m --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly 4f8d1afed6d5 python3 -I -B /repo/tests/agent_pki_station_test.py
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --user 501:20 --tmpfs /tmp:rw,size=256m --memory 512m --mount type=bind,src=/Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools,dst=/repo,readonly 4f8d1afed6d5 python3 -I -B /repo/tests/agent_pki_client_test.py
```

Station fixtures prove a new DNS SAN, retained existing SANs, stable CA/server
keys, server-certificate-only atomic publication, retained restart intent after
interruption and no reissue on recovery. Client fixtures prove no key, certificate,
CSR or credential-file change for a hostname-only update, stable CA binding,
same-key due renewal and rollback/retry. Controller fake-remote tests prove only
ingestion/affected agents restart and the following install is a no-op. Manifest
fixtures prove another application's files stay byte-identical.

These are crypto, local TLS and fake-service checks, not live DNS, provider
firewall, SSH/systemd or two-host deployment evidence. The remaining procedure is
the [explicit hostname gate](application.md#explicit-station-hostname-gate).
No new component or artifact pin was added. Traces, dashboards, automatic CA
rollover and DNS/firewall management remain unavailable.
