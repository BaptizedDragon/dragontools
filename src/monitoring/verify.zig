const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const host = @import("../system/host.zig");
const vm = @import("../components/victoriametrics.zig");
const fs = @import("../system/filesystem.zig");
const policy = @import("policy.zig");
pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    const unit = try @import("../system/systemd.zig").render(a, report.reserve_bytes);
    const command = try remote.shell(a, &.{
        "sh",                                                      "-eu",                                           "-c",
        \\expected=$1; unit=$2; reserve=$3; retention=$4
        \\test -z "$(systemctl show -p DropInPaths --value dragontools-victoriametrics.service)"
        \\systemctl is-active --quiet dragontools-victoriametrics.service
        \\systemctl is-enabled --quiet dragontools-victoriametrics.service
        \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-victoriametrics.service
        \\test "$(systemctl show -p User --value dragontools-victoriametrics.service)" = dt-victoriametrics
        \\test "$(systemctl show -p ProtectSystem --value dragontools-victoriametrics.service)" = strict
        \\pid=$(systemctl show -p MainPID --value dragontools-victoriametrics.service)
        \\test "$pid" -gt 0
        \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
        \\expected_args=$(printf '%s\n' /opt/dragontools/components/victoriametrics/current/victoria-metrics-prod -storageDataPath=/var/lib/dragontools/victoriametrics "$retention" "-storage.minFreeDiskSpaceBytes=$reserve" -httpListenAddr=127.0.0.1:8428 -selfScrapeInterval=15s)
        \\test "$actual_args" = "$expected_args"
        \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
        \\test "$(readlink /opt/dragontools/components/victoriametrics/current)" = v1.151.0
        \\printf '%s  %s\n' "$expected" /opt/dragontools/components/victoriametrics/current/victoria-metrics-prod | sha256sum --check --status
        \\i=0
        \\until curl --noproxy '*' --fail --silent --max-time 5 http://127.0.0.1:8428/health >/dev/null; do i=$((i+1)); test "$i" -lt 15; sleep 1; done
        \\ss -H -ltnp 'sport = :8428' | grep -F "pid=$pid," | grep -q '127.0.0.1:8428'
        \\# Self-scraping proves the storage/query path, beyond systemd and HTTP liveness.
        \\i=0
        \\while :; do
        \\  result=$(curl --noproxy '*' --fail --silent --max-time 5 'http://127.0.0.1:8428/api/v1/query?query=vm_app_version')
        \\  case "$result" in *'"metric":'*) break;; esac
        \\  i=$((i+1)); test "$i" -lt 30; sleep 1
        \\done
        \\printf '%s' "$result"
        ,
        "dragontools-health",                                      vm.artifact(arch).binary_sha256,                 unit,
        try std.fmt.allocPrint(a, "{d}", .{report.reserve_bytes}), "-retentionPeriod=" ++ policy.metrics.retention,
    });
    const output = try report.call(r, .health, command);
    try validateMetrics(a, output);
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
    const result = data.object.get("result") orelse return error.InvalidHealthResponse;
    if (result != .array or result.array.items.len == 0) return error.NoMetricsVisible;
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *install.Report) !void {
    const machine = try host.parse(try report.call(r, .detect, host.detect_command));
    report.reserve_bytes = try fs.reserve(try fs.capacity(try report.call(r, .capacity, install.capacity_command)));
    try health(a, r, report, machine.arch);
}

test "health fails on malformed, error and empty query responses" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidHealthResponse, validateMetrics(a, "not-json"));
    try std.testing.expectError(error.InvalidHealthResponse, validateMetrics(a, "[]"));
    try std.testing.expectError(error.HealthCheckFailed, validateMetrics(a, "{\"status\":\"error\"}"));
    try std.testing.expectError(error.NoMetricsVisible, validateMetrics(a, "{\"status\":\"success\",\"data\":{\"result\":[]}}"));
}
