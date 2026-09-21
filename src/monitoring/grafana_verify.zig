//! Read-only Grafana verification without storing or assuming administrator credentials.
const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const install = @import("install.zig");
const grafana = @import("../components/grafana.zig");
const config = @import("../components/grafana_config.zig");
const unit = @import("../components/grafana_unit.zig");
const readiness = @import("readiness.zig");
const plugin = @import("../components/grafana_victorialogs_plugin.zig");
pub const logs_backend_check = @embedFile("grafana_logs_backend.py");

// This only queries non-secret datasource metadata. No user/password/token or
// secure_json_data column is selected. Pinning the schema is intentional:
// https://github.com/grafana/grafana/blob/v13.2.2/pkg/services/sqlstore/migrations/datasource_mig.go
// editable:false maps to ReadOnly:true in this same release's
// pkg/services/provisioning/datasources/types.go. WAL is disabled in managed config
// and rejected here so a read connection cannot create WAL/SHM sidecars. mode=ro
// and query_only both reject database mutation; an authorizer narrows all SQL.
// sqlstore.go creates the database with 0640; database_config.go explicitly sets
// _journal_mode=DELETE when wal=false in this pinned version.
pub const database_check =
    \\import json, os, sqlite3, stat, sys, urllib.parse
    \\path = sys.argv[1]
    \\def require(ok):
    \\    if not ok:
    \\        raise ValueError("Grafana datasource verification failed")
    \\try:
    \\    info = os.lstat(path)
    \\    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
    \\    require(info.st_uid == os.geteuid() and info.st_gid == os.getegid())
    \\    require(stat.S_IMODE(info.st_mode) & 0o027 == 0)
    \\    require(not os.path.lexists(path + "-wal") and not os.path.lexists(path + "-shm"))
    \\    if os.path.lexists(path + "-journal"):
    \\        journal = os.lstat(path + "-journal")
    \\        require(stat.S_ISREG(journal.st_mode) and journal.st_uid == info.st_uid)
    \\    db = sqlite3.connect("file:" + urllib.parse.quote(path, safe="/") + "?mode=ro", uri=True, timeout=3)
    \\    db.execute("PRAGMA query_only=ON")
    \\    require(db.execute("PRAGMA journal_mode").fetchone() == ("delete",))
    \\    allowed = {"org_id", "uid", "name", "type", "access", "url", "is_default", "read_only", "basic_auth", "with_credentials", "json_data"}
    \\    def authorize(action, first, second, database, trigger):
    \\        if action == sqlite3.SQLITE_SELECT:
    \\            return sqlite3.SQLITE_OK
    \\        if action == sqlite3.SQLITE_READ and first == "data_source" and second in allowed and database == "main":
    \\            return sqlite3.SQLITE_OK
    \\        if action == sqlite3.SQLITE_FUNCTION and second == "json_extract":
    \\            return sqlite3.SQLITE_OK
    \\        return sqlite3.SQLITE_DENY
    \\    db.set_authorizer(authorize)
    \\    rows = db.execute("SELECT org_id, uid, name, type, access, url, is_default, read_only, basic_auth, with_credentials, json_extract(json_data, '$.httpMethod'), json_extract(json_data, '$.prometheusType'), json_extract(json_data, '$.prometheusVersion') FROM data_source WHERE uid IN ('dragontools-metrics', 'dragontools-logs', 'dragontools-traces') ORDER BY uid").fetchall()
    \\    expected = [
    \\        (1, "dragontools-logs", "Logs", "victoriametrics-logs-datasource", "proxy", "http://127.0.0.1:9428", 0, 1, 0, 0, None, None, None),
    \\        (1, "dragontools-metrics", "Metrics", "prometheus", "proxy", "http://127.0.0.1:8428", 1, 1, 0, 0, "POST", "Prometheus", "2.24.0"),
    \\        (1, "dragontools-traces", "Traces", "jaeger", "proxy", "http://127.0.0.1:10428/select/jaeger", 0, 1, 0, 0, None, None, None),
    \\    ]
    \\    # Missing rows are normal while first-start provisioning is in progress.
    \\    # An existing incompatible or duplicate row is policy drift, not readiness.
    \\    require(all(row in expected for row in rows) and len(set(rows)) == len(rows))
    \\    # v13.2.2 provisioning createInsertCommand/createUpdateCommand build an
    \\    # empty simplejson object when jsonData is omitted. Require that complete
    \\    # Logs policy, not just absence of the three built-in datasource keys.
    \\    # This excludes custom headers, tenant overrides, OAuth forwarding and
    \\    # custom query parameters without selecting any secret storage column.
    \\    for (raw,) in db.execute("SELECT json_data FROM data_source WHERE uid = 'dragontools-logs'").fetchall():
    \\        require(isinstance(raw, str) and json.loads(raw) == {})
    \\    if rows != expected:
    \\        sys.exit(75)
    \\    db.close()
    \\except FileNotFoundError:
    \\    sys.exit(75)
    \\except sqlite3.OperationalError as error:
    \\    code = getattr(error, "sqlite_errorcode", None)
    \\    # SQLITE_BUSY/LOCKED are bounded startup waits. Only the exact missing
    \\    # datasource-table error is an incomplete migration; other SQL errors fail.
    \\    sys.exit(75 if code in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED) or str(error) == "no such table: data_source" else 1)
    \\except Exception:
    \\    sys.exit(1)
;

// Static policy and full-tree integrity run once, outside the readiness budgets.
pub const managed_script =
    \\unit=$1; ini=$2; datasources=$3
    \\check_property() {
    \\  actual=$(systemctl show -p "$1" --value dragontools-grafana.service)
    \\  test "$actual" = "$2"
    \\}
    \\check_property FragmentPath /etc/systemd/system/dragontools-grafana.service
    \\check_property LoadState loaded
    \\check_property UnitFileState enabled
    \\check_property NeedDaemonReload no
    \\check_property DropInPaths ""
    \\check_property Environment ""
    \\check_property EnvironmentFiles ""
    \\test "$(systemctl is-enabled dragontools-grafana.service)" = enabled
    \\check_property User dt-grafana
    \\check_property Group dt-grafana
    \\check_property ProtectSystem strict
    \\for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do
    \\  check_property "$property" yes
    \\done
    \\check_property CapabilityBoundingSet ""
    \\check_property AmbientCapabilities ""
    \\check_property ReadWritePaths /var/lib/dragontools/grafana
    \\check_property ReadOnlyPaths '/var/lib/dragontools/grafana/plugins /var/lib/dragontools/grafana/plugins-versions'
    \\check_property WorkingDirectory /opt/dragontools/components/grafana/current
    \\for dir in /opt/dragontools /opt/dragontools/components /opt/dragontools/components/grafana /var/lib/dragontools /etc/dragontools /etc/dragontools/grafana /etc/dragontools/grafana/provisioning /etc/dragontools/grafana/provisioning/datasources /etc/dragontools/grafana/provisioning/dashboards; do
    \\  test ! -L "$dir" && test -d "$dir"
    \\  test "$(stat -c '%u:%g:%a' "$dir")" = 0:0:755
    \\done
    \\test ! -L /var/lib/dragontools/grafana && test -d /var/lib/dragontools/grafana
    \\test "$(stat -c '%U:%G:%a' /var/lib/dragontools/grafana)" = dt-grafana:dt-grafana:750
    \\for file in /etc/systemd/system/dragontools-grafana.service /etc/dragontools/grafana/grafana.ini /etc/dragontools/grafana/provisioning/datasources/dragontools.yaml; do
    \\  test ! -L "$file" && test -f "$file"
    \\  test "$(stat -c '%u:%g:%a' "$file")" = 0:0:644
    \\done
    \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-grafana.service
    \\printf '%s' "$ini" | cmp -s - /etc/dragontools/grafana/grafana.ini
    \\printf '%s' "$datasources" | cmp -s - /etc/dragontools/grafana/provisioning/datasources/dragontools.yaml
;

// Every runtime attempt rejects unsafe listeners and an incompatible running
// process immediately. Only an absent process/listener or inactive state is
// readiness, never a mismatching identity, argument, account or environment.
pub const runtime_guard =
    \\expected=$1
    \\check_listeners() {
    \\  listeners=$(ss -H -ltnp 'sport = :3000')
    \\  if test -n "$listeners" && printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:3000[[:space:]]' >/dev/null; then exit 1; fi
    \\  if test "$pid" -gt 0; then
    \\    all_listeners=$(ss -H -ltnp)
    \\    owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid," || :)
    \\    if test -n "$owned" && printf '%s\n' "$owned" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:3000[[:space:]]' >/dev/null; then exit 1; fi
    \\    if test -n "$listeners"; then printf '%s\n' "$listeners" | grep -F "pid=$pid," >/dev/null || exit 1; fi
    \\  fi
    \\}
    \\check_runtime() {
    \\  pid=$(systemctl show -p MainPID --value dragontools-grafana.service)
    \\  case "$pid" in ''|*[!0-9]*) exit 1;; esac
    \\  check_listeners
    \\  test "$pid" -gt 0 && test -d "/proc/$pid" || exit 75
    \\  test "$(stat -c '%U:%G' "/proc/$pid")" = dt-grafana:dt-grafana
    \\  # Manager DefaultEnvironment can override the ini without appearing in the unit.
    \\  # Match variable names only; never return, print, or capture environment values.
    \\  if grep -zq '^GF_' "/proc/$pid/environ" 2>/dev/null; then exit 1; else test "$?" = 1; fi
    \\  actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
    \\  expected_args=$(printf '%s\n' /opt/dragontools/components/grafana/current/bin/grafana server --homepath=/opt/dragontools/components/grafana/current --config=/etc/dragontools/grafana/grafana.ini)
    \\  test "$actual_args" = "$expected_args"
    \\  printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
    \\  systemctl is-active --quiet dragontools-grafana.service || exit 75
    \\  if test "$1" = listener; then test -n "$listeners" || exit 75; fi
    \\}
;
pub const active_script = runtime_guard ++ "\ncheck_runtime process\n";
pub const http_script = runtime_guard ++ "\n" ++
    \\check_runtime listener
    \\grafana=$(curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:3000/api/health) || exit 75
    \\# Credential-free datasource access must stay denied after password changes.
    \\code=$(curl --disable --noproxy '*' --silent --connect-timeout 3 --max-time 5 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:3000/api/datasources) || exit 75
    \\case "$code" in 500|502|503|504) exit 75;; esac
    \\test "$code" = 401
    \\check_listeners
    \\printf '{"grafana":%s}' "$grafana"
;
pub const provisioning_script = runtime_guard ++ "\n" ++
    \\check_runtime listener
    \\runuser --user dt-grafana -- python3 -I -B -c "$2" /var/lib/dragontools/grafana/grafana.db
    \\check_listeners
;
pub const backend_script = runtime_guard ++ "\n" ++
    \\check_runtime listener
    \\# Real backend queries under the Grafana account, without Grafana credentials.
    \\metrics=$(runuser --user dt-grafana -- curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version') || exit 75
    \\traces=$(runuser --user dt-grafana -- curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:10428/select/jaeger/api/services) || exit 75
    \\check_listeners
    \\printf '{"metrics":%s,"traces":%s}' "$metrics" "$traces"
;
pub const logs_backend_script = runtime_guard ++ "\n" ++
    \\check_runtime listener
    \\runuser --user dt-grafana -- python3 -I -B -c "$2"
    \\check_listeners
;

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    const preflight = try remote.shell(a, &.{ "sh", "-eu", "-c", @import("grafana_install.zig").preflight, "dragontools-grafana-preflight" });
    defer a.free(preflight);
    const integrity = try grafana.integrityCommand(a, arch);
    defer a.free(integrity);
    const unit_text = try unit.render(a);
    defer a.free(unit_text);
    const policy = try remote.shell(a, &.{ "sh", "-eu", "-c", managed_script, "dragontools-grafana-policy", unit_text, config.ini, config.datasources });
    defer a.free(policy);
    const script = try std.fmt.allocPrint(a, "{s} && {s} && {s}", .{ preflight, integrity, policy });
    defer a.free(script);
    const managed = try remote.shell(a, &.{ "sh", "-eu", "-c", script, "dragontools-grafana-managed_state" });
    defer a.free(managed);
    _ = try readiness.deterministic(a, r, report, .managed_state, managed);
    const plugin_probe = try plugin.verifyCommand(a);
    defer a.free(plugin_probe);
    const plugin_integrity = try remote.shell(a, &.{ "sh", "-eu", "-c", plugin_probe, "dragontools-grafana-plugin_integrity" });
    defer a.free(plugin_integrity);
    _ = try readiness.deterministic(a, r, report, .plugin_integrity, plugin_integrity);

    const binary_hash = grafana.artifact(arch).binary_sha256;
    const active = try remote.shell(a, &.{ "sh", "-eu", "-c", active_script, "dragontools-grafana-service_active", binary_hash });
    defer a.free(active);
    try readiness.poll(a, r, report, .service_active, readiness.active_ms, active, readiness.ready);
    const http = try remote.shell(a, &.{ "sh", "-eu", "-c", http_script, "dragontools-grafana-http_ready", binary_hash });
    defer a.free(http);
    try readiness.poll(a, r, report, .http_ready, readiness.http_ms, http, validateHttp);
    const provisioning = try remote.shell(a, &.{ "sh", "-eu", "-c", provisioning_script, "dragontools-grafana-provisioning_ready", binary_hash, database_check });
    defer a.free(provisioning);
    try readiness.poll(a, r, report, .provisioning_ready, readiness.telemetry_ms, provisioning, readiness.ready);
    const backend = try remote.shell(a, &.{ "sh", "-eu", "-c", backend_script, "dragontools-grafana-backend_ready", binary_hash });
    defer a.free(backend);
    try readiness.poll(a, r, report, .backend_ready, readiness.telemetry_ms, backend, validateBackend);
    const logs_backend = try remote.shell(a, &.{ "sh", "-eu", "-c", logs_backend_script, "dragontools-grafana-logs_backend_ready", binary_hash, logs_backend_check });
    defer a.free(logs_backend);
    try readiness.poll(a, r, report, .logs_backend_ready, readiness.telemetry_ms, logs_backend, readiness.ready);
    if (report.station_enabled) try @import("dashboards/main.zig").verify(a, r, report, "{\"station\":true}");
}

fn member(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidGrafanaHealthResponse;
    return value.object.get(name) orelse error.InvalidGrafanaHealthResponse;
}

fn textIs(value: std.json.Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}

pub fn validate(a: std.mem.Allocator, output: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, output, .{}) catch return error.InvalidGrafanaHealthResponse;
    defer parsed.deinit();
    const result = parsed.value;
    const app = try member(result, "grafana");
    if (!textIs(try member(app, "version"), grafana.version) or !textIs(try member(app, "database"), "ok")) return error.GrafanaIdentityOrDatabaseFailed;
    if (!textIs(try member(result, "provisioning"), "verified")) return error.GrafanaProvisioningFailed;
    try validateBackends(result, false);
}

pub fn validateHttp(a: std.mem.Allocator, output: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, output, .{}) catch return error.InvalidGrafanaHealthResponse;
    defer parsed.deinit();
    const app = try member(parsed.value, "grafana");
    if (!textIs(try member(app, "version"), grafana.version)) return error.GrafanaIdentityOrDatabaseFailed;
    const database = try member(app, "database");
    if (database != .string) return error.InvalidGrafanaHealthResponse;
    if (!textIs(database, "ok")) return error.NotReady;
}

pub fn validateBackend(a: std.mem.Allocator, output: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, output, .{}) catch return error.InvalidGrafanaHealthResponse;
    defer parsed.deinit();
    try validateBackends(parsed.value, true);
}

fn validateBackends(result: std.json.Value, allow_startup: bool) !void {
    const metrics = try member(result, "metrics");
    if (!textIs(try member(metrics, "status"), "success")) return error.GrafanaMetricsQueryFailed;
    const data = try member(metrics, "data");
    if (!textIs(try member(data, "resultType"), "vector")) return error.GrafanaMetricsQueryFailed;
    const samples = try member(data, "result");
    if (samples != .array) return error.GrafanaMetricsQueryFailed;
    if (samples.array.items.len == 0) return if (allow_startup) error.NotReady else error.GrafanaMetricsQueryFailed;
    var identified = false;
    for (samples.array.items) |sample| {
        const metric = try member(sample, "metric");
        const value = try member(sample, "value");
        if (value != .array or value.array.items.len != 2) return error.GrafanaMetricsQueryFailed;
        if (value.array.items[0] != .integer and value.array.items[0] != .float) return error.GrafanaMetricsQueryFailed;
        if (!textIs(try member(metric, "__name__"), "vm_app_version") or !textIs(value.array.items[1], "1")) return error.GrafanaMetricsQueryFailed;
        identified = true;
    }
    if (!identified) return error.GrafanaMetricsQueryFailed;

    const traces = try member(result, "traces");
    const services = try member(traces, "data");
    if (services != .array) return error.GrafanaTracesQueryFailed;
    for (services.array.items) |service| if (service != .string) return error.GrafanaTracesQueryFailed;
    // Exact pinned Jaeger service-list envelope, including the valid empty case:
    // VictoriaTraces/v0.11.0/app/vtselect/traces/jaeger/jaeger.qtpl
    if (try member(traces, "errors") != .null) return error.GrafanaTracesQueryFailed;
    const total = try member(traces, "total");
    if (total != .integer or total.integer < 0 or total.integer != services.array.items.len) return error.GrafanaTracesQueryFailed;
    for ([_][]const u8{ "limit", "offset" }) |name| {
        const field = try member(traces, name);
        if (field != .integer or field.integer != 0) return error.GrafanaTracesQueryFailed;
    }
}

pub const healthy_fixture = "{\"grafana\":{\"database\":\"ok\",\"version\":\"" ++ grafana.version ++ "\"},\"metrics\":{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]}},\"traces\":{\"data\":[],\"errors\":null,\"total\":0,\"limit\":0,\"offset\":0},\"provisioning\":\"verified\"}";

test {
    _ = @import("grafana_verify_tests.zig");
}
