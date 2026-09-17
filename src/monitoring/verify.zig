const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const host = @import("../system/host.zig");
const vm = @import("../components/victoriametrics.zig");
const fs = @import("../system/filesystem.zig");
const policy = @import("policy.zig");
const readiness = @import("readiness.zig");

pub const managed_script =
    \\expected=$1; unit=$2; reserve=$3; retention=$4
    \\check_property() { test "$(systemctl show -p "$1" --value dragontools-victoriametrics.service)" = "$2"; }
    \\check_property FragmentPath /etc/systemd/system/dragontools-victoriametrics.service
    \\check_property LoadState loaded
    \\check_property UnitFileState enabled
    \\check_property DropInPaths ""
    \\check_property NeedDaemonReload no
    \\test ! -L /etc/systemd/system/dragontools-victoriametrics.service
    \\test -f /etc/systemd/system/dragontools-victoriametrics.service
    \\test "$(stat -c '%u:%g:%a' /etc/systemd/system/dragontools-victoriametrics.service)" = 0:0:644
    \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-victoriametrics.service
    \\check_property User dt-victoriametrics
    \\check_property Group dt-victoriametrics
    \\check_property ProtectSystem strict
    \\for property in NoNewPrivileges PrivateTmp ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID; do check_property "$property" yes; done
    \\check_property CapabilityBoundingSet ""
    \\check_property AmbientCapabilities ""
    \\check_property ReadWritePaths /var/lib/dragontools/victoriametrics
    \\test "$(readlink /opt/dragontools/components/victoriametrics/current)" = v1.151.0
    \\test ! -L /opt/dragontools/components/victoriametrics/v1.151.0/victoria-metrics-prod
    \\printf '%s  %s\n' "$expected" /opt/dragontools/components/victoriametrics/current/victoria-metrics-prod | sha256sum --check --status
;

// A missing process/listener can be startup; a present but incorrect one is not.
// Recheck on every runtime probe so polling cannot hide an unsafe replacement.
pub const process_script =
    \\expected=$1; unit=$2; reserve=$3; retention=$4
    \\listeners=$(ss -H -ltnp 'sport = :8428')
    \\if test -n "$listeners" && printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:8428[[:space:]]' >/dev/null; then exit 1; fi
    \\pid=$(systemctl show -p MainPID --value dragontools-victoriametrics.service)
    \\case "$pid" in ''|*[!0-9]*) exit 1;; 0) exit 75;; esac
    \\test -d "/proc/$pid" || exit 75
    \\test "$(stat -c '%u:%g' "/proc/$pid")" = "$(id -u dt-victoriametrics):$(id -g dt-victoriametrics)"
    \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
    \\expected_args=$(printf '%s\n' /opt/dragontools/components/victoriametrics/current/victoria-metrics-prod -storageDataPath=/var/lib/dragontools/victoriametrics "$retention" "-storage.minFreeDiskSpaceBytes=$reserve" -httpListenAddr=127.0.0.1:8428 -selfScrapeInterval=15s)
    \\test "$actual_args" = "$expected_args"
    \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
    \\all_listeners=$(ss -H -ltnp)
    \\owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid," || :)
    \\if test -n "$owned" && printf '%s\n' "$owned" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:8428[[:space:]]' >/dev/null; then exit 1; fi
    \\if test -n "$listeners"; then printf '%s\n' "$listeners" | grep -F "pid=$pid," >/dev/null || exit 1; fi
    \\
;
pub const listener_ready =
    \\systemctl is-active --quiet dragontools-victoriametrics.service || exit 75
    \\printf '%s\n' "$listeners" | grep -F "pid=$pid," | grep -Eq '[[:space:]]127[.]0[.]0[.]1:8428[[:space:]]' || exit 75
    \\
;

fn command(a: std.mem.Allocator, arch: host.Arch, report: *install.Report, script: []const u8, check: readiness.Check) ![]const u8 {
    return remote.shell(a, &.{ "sh", "-eu", "-c", script, try std.fmt.allocPrint(a, "dragontools-victoriametrics-{s}", .{@tagName(check)}), vm.artifact(arch).binary_sha256, try @import("../system/systemd.zig").render(a, report.reserve_bytes), try std.fmt.allocPrint(a, "{d}", .{report.reserve_bytes}), "-retentionPeriod=" ++ policy.metrics.retention });
}

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    _ = try readiness.deterministic(a, r, report, .managed_state, try command(a, arch, report, managed_script, .managed_state));
    try readiness.poll(a, r, report, .service_active, readiness.active_ms, try command(a, arch, report, process_script ++ "systemctl is-active --quiet dragontools-victoriametrics.service || exit 75\n", .service_active), readiness.ready);
    try readiness.poll(a, r, report, .http_ready, readiness.http_ms, try command(a, arch, report, process_script ++ listener_ready ++ "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 http://127.0.0.1:8428/health >/dev/null || exit 75\n", .http_ready), readiness.ready);
    try readiness.poll(a, r, report, .self_scrape_ready, readiness.telemetry_ms, try command(a, arch, report, process_script ++ listener_ready ++ "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version' || exit 75\n", .self_scrape_ready), metricsReady);
}

fn metricsReady(a: std.mem.Allocator, output: []const u8) !void {
    validateMetrics(a, output) catch |err| switch (err) {
        error.NoMetricsVisible => return error.NotReady,
        else => return err,
    };
}
pub fn validateMetrics(a: std.mem.Allocator, output: []const u8) !void {
    const json = std.json.parseFromSlice(std.json.Value, a, output, .{}) catch return error.InvalidHealthResponse;
    defer json.deinit();
    const value = json.value;
    if (value != .object) return error.InvalidHealthResponse;
    const status = value.object.get("status") orelse return error.InvalidHealthResponse;
    if (status != .string or !std.mem.eql(u8, status.string, "success")) return error.HealthCheckFailed;
    const data = value.object.get("data") orelse return error.InvalidHealthResponse;
    if (data != .object) return error.InvalidHealthResponse;
    const result_type = data.object.get("resultType") orelse return error.InvalidHealthResponse;
    if (result_type != .string or !std.mem.eql(u8, result_type.string, "vector")) return error.InvalidHealthResponse;
    const result = data.object.get("result") orelse return error.InvalidHealthResponse;
    if (result != .array) return error.InvalidHealthResponse;
    if (result.array.items.len == 0) return error.NoMetricsVisible;
    for (result.array.items) |sample| {
        if (sample != .object) return error.InvalidHealthResponse;
        const metric = sample.object.get("metric") orelse return error.InvalidHealthResponse;
        const point = sample.object.get("value") orelse return error.InvalidHealthResponse;
        if (metric != .object or point != .array or point.array.items.len != 2) return error.InvalidHealthResponse;
        const name = metric.object.get("__name__") orelse return error.InvalidHealthResponse;
        if (name != .string or !std.mem.eql(u8, name.string, "vm_app_version")) return error.InvalidHealthResponse;
        if (point.array.items[0] != .integer and point.array.items[0] != .float) return error.InvalidHealthResponse;
        const observed = point.array.items[1];
        if (observed != .string or !std.mem.eql(u8, observed.string, "1")) return error.InvalidHealthResponse;
    }
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *install.Report) !void {
    report.component = null;
    const machine = try host.parse(try report.call(r, .detect, host.detect_command));
    report.beginComponent(.victoriametrics);
    report.reserve_bytes = try fs.reserve(try fs.capacity(try report.call(r, .capacity, install.capacity_command)));
    try health(a, r, report, machine.arch);
    report.endComponent();
    report.beginComponent(.victorialogs);
    try @import("victorialogs_verify.zig").health(a, r, report, machine.arch);
    report.endComponent();
    report.beginComponent(.victoriatraces);
    try @import("victoriatraces_verify.zig").health(a, r, report, machine.arch);
    report.endComponent();
    report.beginComponent(.grafana);
    try @import("grafana_verify.zig").health(a, r, report, machine.arch);
    try @import("grafana_credentials.zig").verify(a, r, report);
    try @import("grafana_credentials.zig").verifyLogs(a, r, report);
    report.emit(if (report.logs_query_verified) .logs_query_verified else .logs_query_unchecked);
    report.endComponent();
}

test "health fails on malformed, error and empty query responses" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidHealthResponse, validateMetrics(a, "not-json"));
    try std.testing.expectError(error.InvalidHealthResponse, validateMetrics(a, "[]"));
    try std.testing.expectError(error.HealthCheckFailed, validateMetrics(a, "{\"status\":\"error\"}"));
    try std.testing.expectError(error.NoMetricsVisible, validateMetrics(a, "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[]}}"));
}

test "self scrape requires a valid vm_app_version vector rather than arbitrary nonempty data" {
    const a = std.testing.allocator;
    const valid = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]}}";
    try validateMetrics(a, valid);
    for ([_][]const u8{ "matrix", "null", "wrong_metric", "[1,\"NaN\"]" }, [_][]const u8{ "vector", "[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]", "vm_app_version", "[1,\"1\"]" }) |replacement, needle| {
        const altered = try std.mem.replaceOwned(u8, a, valid, needle, replacement);
        defer a.free(altered);
        try std.testing.expectError(error.InvalidHealthResponse, validateMetrics(a, altered));
    }
}

test {
    _ = @import("victoriametrics_verify_tests.zig");
}
