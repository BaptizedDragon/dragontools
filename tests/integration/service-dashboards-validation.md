# Service resources and managed dashboards

The portable parser, ownership/publication, query and cgroup filesystem fixtures
run through `zig build test` on both CI operating systems. The Linux CI service
resource fixture uses the existing reviewed artifact pins and no outbound network:

```sh
zig build
zig build test-fixture
python3 -I -B tests/integration/render_doers.py /tmp/dt-service-fixture
python3 -I -B tools/fetch_doers_fixture.py --output /tmp/dt-service-fixture
sudo unshare --net sh -c 'ip link set lo up; exec python3 -I -B tests/integration/service_resources.py "$1" "$2" "$1"' fixture /tmp/dt-service-fixture "$PWD/zig-out/bin/dragontool-pki-fixture"
```

This exercises native cgroup file parsing, absolute floating-point JSON through
Vector 0.58.0, real remote write to VictoriaMetrics 1.151.0, the read-only service
signal check, a changed ControlGroup, an inactive service, and the dashboard's
projected warning/error query against VictoriaLogs 1.52.0. The filesystem and
systemd-property fixtures replace real systemd; loopback replaces mTLS here.
Existing Doers/Caddy fixtures cover that transport separately. No Ubuntu/systemd
or production validation follows from these isolated checks.

The opt-in `tests/integration/dashboards.py` takes the pinned binary directory,
an extracted Grafana **13.2.2** home (build 34846740809), and the rendered
Doers directory. Verify the archive and executable against `src/components/grafana.zig`
before using it. Run inside a disposable Linux network namespace/container with
no external network and loopback enabled. It checks the actual VMUI format/API,
Grafana file provider and unified resource store, nested DragonTools folders,
automatic dashboard update with unchanged process IDs, a subsequent no-op and
stored data for every station resource panel. It does not inspect a browser or
exercise authenticated VictoriaLogs plugin rendering.

## Real-host gate (operator-run; mutation requires explicit authorization)

Use the README upgrade/apply commands with a supported disposable station/target
first. Do not replace a production application's config with the example file.

1. Start with zero apps. Install and verify the station; inspect its separate VMUI
   and Grafana station dashboards. The unchanged install must be a no-op.
2. Apply a configured service. Confirm `systemctl show <unit> -p ControlGroup`
   resolves to the files being read under cgroup v2 as `dt-vector`. Confirm the
   existing hardening permits read-only systemd/D-Bus and cgroup access.
3. Compare live cpu.stat, memory.current, pids.current and io.stat with stored
   `dragontools_service_*` samples. Only the four trusted identity labels should
   remain. Check finite limits, an unlimited service, service restart and stop.
4. Inspect application VMUI and Grafana dashboards. Check CPU **cores**, finite
   limits, tasks (including threads), RPS/percentiles from the declared histogram,
   bounded status/route grouping, and useful projected warning/error log fields.
   Quiet services and zero traffic remain valid. Do not synthesize errors.
5. Run app-verify, then identical apply. Record agent/Caddy/Grafana/VM PIDs, cert
   fingerprints and owned file hashes/mtimes; none should change on this rerun.
6. Change only an HTTP panel mapping. Confirm dashboard files update and Grafana
   picks them up within its 15-second poll, with no agent or backend restart and
   no credential reissue. Restore the mapping using the same apply workflow.
7. Preserve manual dashboards and other apps. Refuse a manually edited managed
   file or foreign dashboard UID. Restore those fixtures manually; there is no
   automatic adoption or broad dashboard deletion.

The station only self-scrapes VM today. Resource panels for VL/VT/Grafana/
Alertmanager/vmalert/Caddy, FD counts, new resource alerts and tracing agents are
not claimed. Their existing station service health checks remain in place.
