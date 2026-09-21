# Host-events activation investigation — 2026-09-21

Production investigation was read-only on the explicitly authorized SSH alias
`softwarelanding` (Ubuntu 26.04, systemd 259, x86_64). No station mutation, service
restart/start/enable/reload, permission repair, reboot-marker change or application
apply was performed. The fixed build has not been deployed.

## Observed evidence

- `systemctl show dragontools-host-events.service`: `Type=oneshot` in the installed
  unit, static, failed, `Result=exit-code`, `ExecMainCode=1`, `ExecMainStatus=86`.
  The journal records that exit, with no helper stderr (`StandardError=null`).
- The timer was loaded, disabled and inactive; its target was exactly
  `dragontools-host-events.service`. Both units had no drop-ins and needed no
  daemon reload. Activation stopped at synchronous `systemctl start` of the
  service, before timer restart/enable.
- Helper digest matched the controller's existing Linux/amd64 artifact:
  `c20704338e8f89bee2955a0250aa42b8999c228e64bf7267eadd343a5c8cf926`.
  Service and timer file hashes matched the repository byte-for-byte:
  `7918c61a8c4b6150d577868f174cda362838eba8fe0265976b49661992aa037d`
  and `64b1d63526f29b5048056bcecc39d3a2b15fcd4df40302f3abd5880ffe3cad3b`.
- `dt-host-events` had UID 979/GID 974, its own primary group only, the expected
  home and nologin shell. State directory: service-owned 0700, no state/staging
  file. Parent: root:root 0755. Pending marker: root:root 0600.
- Effective `ProtectSystem=strict` and `ReadWritePaths` matched the intended state
  directory. The service account could traverse parents and read inputs; no
  host-events-specific kernel denial was observed. These checks do not prove a
  successful systemd sandbox execution of the fixed binary.
- No reboot marker existed. `/etc/machine-id` passed format validation without
  disclosure. `/proc/sys/kernel/osrelease` and `/proc/uptime` were readable,
  regular procfs files reporting **stat size 0** while returning 17 and 18 bytes.
- Only the documented `maintenance events-verify` mode was invoked manually;
  it returned 86 because state had not been published. No `maintenance events`
  invocation was made on production.

## Defect and reproduction

Zig 0.16's allocating writer calls `File.Reader.getSize()` and returns EOF at
size zero. The observer used `Dir.readFileAlloc` for kernel/uptime, so the real
procfs reads returned empty buffers. Uptime parsing then returned
`HostEventStateRefused`, mapped to exit 86, before the first state publication.
Ordinary-file fixtures had nonzero sizes and missed this case.

A new native fixture uses real Linux procfs with a synthetic machine identity,
absent reboot marker and empty private state directory. It failed against the
unchanged helper and passed after switching the observer to explicit bounded
streaming reads. The fixed helper also retains all transition/no-op checks.
The activation-shell fixture models the observed failed oneshot, disabled timer
and retained intent, recovery, successful inactive oneshot, active/enabled timer,
verification and finalized unchanged rerun. It is a fake systemd fixture, not a
real systemd deployment.

Production next step is manual application apply with the locally built fixed
controller, followed by read-only app-verify and a deliberate unchanged apply.
**Disposable-host integration not run.** Isolated Linux process/fixture results
must not be described as verification of the fixed production deployment.

## Validation commands

Zig 0.16.0, with `ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache`:

```sh
zig fmt --check build.zig src
zig build
zig build test --summary all
python3 tests/cli_smoke.py
python3 -I -B tests/host_events_test.py
python3 -I -B tests/host_events_checks_test.py
python3 -I -B tests/host_events_activation_test.py
python3 -I -B tests/agent_checks_test.py
```

The macOS Zig suite passed 421/421. Direct Python suites: observer 5 passed/1
real-procfs case skipped on macOS; checks 7 passed; activation 4 passed; signal and
runtime checks 17 passed. The real-procfs case ran on Linux as follows:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/dragontools-zig-cache zig build test-fixture -Dtarget=aarch64-linux --prefix /tmp/dragontools-host-events-fixed
docker run --rm --network none -v "$PWD:/work:ro" -v /tmp/dragontools-host-events-fixed:/fixture:ro -w /work -e DRAGONTOOLS_PKI_FIXTURE=/fixture/bin/dragontool-pki-fixture dragontools-pki-test:ubuntu26.04 python3 -I -B tests/host_events_test.py
```

All six Linux observer tests passed. Before the fix the same new real-procfs test
failed against `/tmp/dragontools-host-events-old/bin/dragontool-pki-fixture`.

The release helper itself was also exercised under UID 979/GID 974 with real
procfs, no capabilities, no network, a read-only root and only private state
writable. Both existing local Ubuntu 24.04 and 26.04 fixture images passed:

```sh
python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/dragontools-host-events-machine-id')
p.write_text('a' * 32 + '\n')
p.chmod(0o644)
PY
for image in ubuntu24.04 ubuntu26.04; do
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 979:974 \
    --tmpfs /var/lib/dragontools/host-events:rw,noexec,nosuid,mode=0700,uid=979,gid=974 \
    -v "$PWD:/work:ro" \
    -v /tmp/dragontools-host-events-machine-id:/etc/machine-id:ro \
    --entrypoint sh "dragontools-pki-test:$image" -c '
      set -e
      /work/zig-out/libexec/linux-arm64/dragontool-agent maintenance events
      before=$(stat -c "%Y:%s" /var/lib/dragontools/host-events/reboot-required.state)
      /work/zig-out/libexec/linux-arm64/dragontool-agent maintenance events-verify
      /work/zig-out/libexec/linux-arm64/dragontool-agent maintenance events
      test "$before" = "$(stat -c "%Y:%s" /var/lib/dragontools/host-events/reboot-required.state)"
      stat -c "%u:%g:%a" /var/lib/dragontools/host-events/reboot-required.state'
done
```

These are temporary local fixture files and containers. They do not mutate the
production host, emulate systemd, or establish Telegram delivery. GitHub Actions
was not dispatched; Linux/macOS workflow definitions were unchanged.

CLI smoke completed successfully: 309 checks plus 19 UI tunnel lifecycle tests.
Fish completion checks were skipped because Fish is unavailable. `git diff --check`
and the final `zig fmt --check build.zig src` passed. The service/timer unit files
and their hardening bytes are unchanged by this patch.
