# Application contract validation — 2026-09-17

This records validation of the application monitoring.toml iteration on the local
macOS controller with Zig 0.16.0. No application/station SSH host was contacted.
**Disposable-host integration not run.** GitHub Actions jobs and release publishing
were not executed; the workflows and local build/package outputs were checked.

## Repository checks

These exact commands passed on the final code:

```sh
zig fmt build.zig src
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build test --summary all
git diff --check
python3 -I -B tests/release_test.py
```

Result: **304/304 Zig tests passed**, including the Python ownership, journal,
signal, TLS, scraper and evaluator fixtures imported by the suite. The separate
release packaging suite passed **2/2 tests**. The TLS fixture needed approval to
bind ephemeral loopback sockets outside the desktop sandbox; no external host was
contacted. Runtime assertions, checksum checks and empty-stderr assertions remain.

The added ownership preflight initially exposed five station-fixture crashes:
the fixture assumed all verification happens after activation. A distinct
`application_ownership` deterministic check now models this early check without
weakening runtime-active checks. The final complete suite above passed afterward.

```sh
PATH="/tmp/dragontools-fish-3.7.1/fish.app/Contents/Resources/base/usr/local/bin:$PATH" \
XDG_CONFIG_HOME=/tmp/dragontools-shell-xdg-config \
XDG_DATA_HOME=/tmp/dragontools-shell-xdg-data \
XDG_CACHE_HOME=/tmp/dragontools-shell-xdg-cache \
python3 tests/cli_smoke.py
```

Result: **262 CLI smoke checks passed**, including Bash, Zsh and Fish completion,
default/explicit/missing app config, local plans, unknown keys and unsupported
traces/custom metrics alerts. SSH and secret providers are fixtures, not hosts.

The following local help/plan checks also passed:

```sh
./zig-out/bin/dragontool monitoring apply --help
./zig-out/bin/dragontool monitoring app-verify --help
/tmp/dragontools-apps-aarch64-macos/bin/dragontool monitoring apply --config examples/doers-monitoring.toml --plan
```

## Four release targets

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-apps-aarch64-linux
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe --prefix /tmp/dragontools-apps-x86_64-linux
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-apps-aarch64-macos
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe --prefix /tmp/dragontools-apps-x86_64-macos
```

All four passed. `file /tmp/dragontools-apps-*/bin/dragontool` identified the expected
Mach-O arm64/x86_64 binaries and statically linked Linux aarch64/x86-64 ELF binaries.
Cross-building does not execute each platform's native test suite.

Each binary was packaged with the following exact commands:

```sh
python3 tools/package_release.py package --version 0.1.0-dev --target aarch64-linux --binary /tmp/dragontools-apps-aarch64-linux/bin/dragontool --output /tmp/dragontools-app-release
python3 tools/package_release.py package --version 0.1.0-dev --target x86_64-linux --binary /tmp/dragontools-apps-x86_64-linux/bin/dragontool --output /tmp/dragontools-app-release
python3 tools/package_release.py package --version 0.1.0-dev --target aarch64-macos --binary /tmp/dragontools-apps-aarch64-macos/bin/dragontool --output /tmp/dragontools-app-release
python3 tools/package_release.py package --version 0.1.0-dev --target x86_64-macos --binary /tmp/dragontools-apps-x86_64-macos/bin/dragontool --output /tmp/dragontools-app-release
```

From `/tmp/dragontools-app-release`, these passed with all four archives reporting OK:

```sh
python3 /Users/vasylosypchuk/golang/src/github.com/baptizeddragon/dragontools/tools/package_release.py checksums --version 0.1.0-dev --output /tmp/dragontools-app-release
shasum -a 256 -c SHA256SUMS
```

Workflow YAML syntax passed the available Ruby standard-library parser:

```sh
ruby -e 'require "yaml"; Dir[".github/workflows/*.yml"].each { |p| YAML.load_file(p) }; puts "Workflow YAML syntax valid"'
```

This is syntax validation, not an executed Actions release. The tag workflow gates
publication on native Linux/macOS tests and four successful builds. Publishing
uses [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create)
with `--verify-tag`, no automatic tag creation or overwrite of existing releases.

## Native process evidence and remaining gates

- [Application agent evidence](app-agents-validation.md): six real native mTLS
  pipeline checks passed, including trusted scoped labels, multiple apps, host-only
  collection and current-process freshness; additional observed filesystem-free
  and network metrics extend the committed contract.
- [Application station evidence](app-station-validation.md): four native checks
  passed for include loading, scoped rule evaluation, empty application groups and
  valid failed-probe telemetry. Temporary-filesystem fixtures cover ownership,
  partial writes, interrupted generations and unrelated-file preservation.
- [Disposable Ubuntu procedure](application.md): actual SSH deployment, systemd
  hardening, real journal collection, live failed-target alert firing/resolution,
  long-outage buffering and unchanged process stability remain unrun.
