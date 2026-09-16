//! Read-only Grafana verification without storing or assuming administrator credentials.
const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const install = @import("install.zig");
const grafana = @import("../components/grafana.zig");
const config = @import("../components/grafana_config.zig");
const unit = @import("../components/grafana_unit.zig");

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
    \\import os, sqlite3, stat, sys, urllib.parse
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
    \\    rows = db.execute("SELECT uid, name, type, access, url, is_default, read_only, basic_auth, with_credentials, json_extract(json_data, '$.httpMethod'), json_extract(json_data, '$.prometheusType'), json_extract(json_data, '$.prometheusVersion') FROM data_source WHERE org_id = 1 AND uid IN ('dragontools-metrics', 'dragontools-traces') ORDER BY uid").fetchall()
    \\    require(rows == [
    \\        ("dragontools-metrics", "Metrics", "prometheus", "proxy", "http://127.0.0.1:8428", 1, 1, 0, 0, "POST", "Prometheus", "2.24.0"),
    \\        ("dragontools-traces", "Traces", "jaeger", "proxy", "http://127.0.0.1:10428/select/jaeger", 0, 1, 0, 0, None, None, None),
    \\    ])
    \\    db.close()
    \\except Exception:
    \\    sys.exit(1)
;

pub const health_script =
    \\expected=$1; unit=$2; version=$3; ini=$4; datasources=$5; database_check=$6
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
    \\systemctl is-active --quiet dragontools-grafana.service
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
    \\pid=$(systemctl show -p MainPID --value dragontools-grafana.service)
    \\test "$pid" -gt 0
    \\# Manager DefaultEnvironment can override the ini without appearing in the unit.
    \\# Match variable names only; never return, print, or capture environment values.
    \\if grep -zq '^GF_' "/proc/$pid/environ" 2>/dev/null; then exit 1; else test "$?" = 1; fi
    \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
    \\expected_args=$(printf '%s\n' /opt/dragontools/components/grafana/current/bin/grafana server --homepath=/opt/dragontools/components/grafana/current --config=/etc/dragontools/grafana/grafana.ini)
    \\test "$actual_args" = "$expected_args"
    \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
    \\test "$(readlink /opt/dragontools/components/grafana/current)" = "$version"
    \\i=0
    \\until grafana=$(curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:3000/api/health); do i=$((i+1)); test "$i" -lt 30; sleep 1; done
    \\listeners=$(ss -H -ltnp 'sport = :3000')
    \\printf '%s\n' "$listeners" | grep -F "pid=$pid," | grep -Eq '[[:space:]]127[.]0[.]0[.]1:3000[[:space:]]'
    \\if printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:3000[[:space:]]' >/dev/null; then exit 1; fi
    \\all_listeners=$(ss -H -ltnp)
    \\owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid,")
    \\if printf '%s\n' "$owned" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:3000[[:space:]]' >/dev/null; then exit 1; fi
    \\# A credential-free API request must be denied, even after the administrator changes their password.
    \\code=$(curl --disable --noproxy '*' --silent --connect-timeout 3 --max-time 5 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:3000/api/datasources)
    \\test "$code" = 401
    \\runuser --user dt-grafana -- python3 -I -B -c "$database_check" /var/lib/dragontools/grafana/grafana.db
    \\# These query real backend data under the Grafana account. They do not authenticate to Grafana's query API.
    \\metrics=$(runuser --user dt-grafana -- curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version')
    \\traces=$(runuser --user dt-grafana -- curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:10428/select/jaeger/api/services)
    \\printf '{"grafana":%s,"metrics":%s,"traces":%s,"provisioning":"verified"}' "$grafana" "$metrics" "$traces"
;

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    const preflight = try remote.shell(a, &.{ "sh", "-eu", "-c", @import("grafana_install.zig").preflight, "dragontools-grafana-verify-preflight" });
    defer a.free(preflight);
    const integrity = try grafana.integrityCommand(a, arch);
    defer a.free(integrity);
    const unit_text = try unit.render(a);
    defer a.free(unit_text);
    const health_command = try remote.shell(a, &.{ "sh", "-eu", "-c", health_script, "dragontools-grafana-health", grafana.artifact(arch).binary_sha256, unit_text, grafana.version, config.ini, config.datasources, database_check });
    defer a.free(health_command);
    const script = try std.fmt.allocPrint(a, "{s} && {s} && {s}", .{ preflight, integrity, health_command });
    defer a.free(script);
    const command = try remote.shell(a, &.{ "sh", "-eu", "-c", script, "dragontools-grafana-verification" });
    defer a.free(command);
    try validate(a, try report.call(r, .health, command));
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

    const metrics = try member(result, "metrics");
    if (!textIs(try member(metrics, "status"), "success")) return error.GrafanaMetricsQueryFailed;
    const data = try member(metrics, "data");
    if (!textIs(try member(data, "resultType"), "vector")) return error.GrafanaMetricsQueryFailed;
    const samples = try member(data, "result");
    if (samples != .array or samples.array.items.len == 0) return error.GrafanaMetricsQueryFailed;
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
