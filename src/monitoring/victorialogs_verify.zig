//! Read-only verification of the managed VictoriaLogs service and writable storage.
const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const host = @import("../system/host.zig");
const vl = @import("../components/victorialogs.zig");
const unit = @import("../components/victorialogs_unit.zig");
const policy = @import("policy.zig");

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    const command = try remote.shell(a, &.{
        "sh",                              "-eu",                                        "-c",
        \\expected=$1; unit=$2; version=$3; retention=$4; cleanup=$5
        \\check_property() {
        \\  actual=$(systemctl show -p "$1" --value dragontools-victorialogs.service)
        \\  test "$actual" = "$2"
        \\}
        \\check_property FragmentPath /etc/systemd/system/dragontools-victorialogs.service
        \\check_property NeedDaemonReload no
        \\check_property DropInPaths ""
        \\systemctl is-active --quiet dragontools-victorialogs.service
        \\enabled=$(systemctl is-enabled dragontools-victorialogs.service)
        \\test "$enabled" = enabled
        \\test ! -L /etc/systemd/system/dragontools-victorialogs.service
        \\test -f /etc/systemd/system/dragontools-victorialogs.service
        \\test "$(stat -c '%u:%g:%a' /etc/systemd/system/dragontools-victorialogs.service)" = 0:0:644
        \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-victorialogs.service
        \\check_property User dt-victorialogs
        \\check_property Group dt-victorialogs
        \\check_property ProtectSystem strict
        \\for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do
        \\  check_property "$property" yes
        \\done
        \\check_property CapabilityBoundingSet ""
        \\check_property AmbientCapabilities ""
        \\check_property ReadWritePaths /var/lib/dragontools/victorialogs
        \\for dir in /opt/dragontools /opt/dragontools/components /opt/dragontools/components/victorialogs "/opt/dragontools/components/victorialogs/$version" /var/lib/dragontools; do
        \\  test ! -L "$dir" && test -d "$dir"
        \\  test "$(stat -c '%u:%g:%a' "$dir")" = 0:0:755
        \\done
        \\test ! -L /var/lib/dragontools/victorialogs && test -d /var/lib/dragontools/victorialogs
        \\test "$(stat -c '%U:%G:%a' /var/lib/dragontools/victorialogs)" = dt-victorialogs:dt-victorialogs:750
        \\pid=$(systemctl show -p MainPID --value dragontools-victorialogs.service)
        \\test "$pid" -gt 0
        \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
        \\expected_args=$(printf '%s\n' /opt/dragontools/components/victorialogs/current/victoria-logs-prod -storageDataPath=/var/lib/dragontools/victorialogs -httpListenAddr=127.0.0.1:9428 "$retention" "$cleanup")
        \\test "$actual_args" = "$expected_args"
        \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
        \\test "$(readlink /opt/dragontools/components/victorialogs/current)" = "$version"
        \\test ! -L "/opt/dragontools/components/victorialogs/$version/victoria-logs-prod"
        \\test -f "/opt/dragontools/components/victorialogs/$version/victoria-logs-prod"
        \\test "$(stat -c '%u:%g:%a' "/opt/dragontools/components/victorialogs/$version/victoria-logs-prod")" = 0:0:755
        \\printf '%s  %s\n' "$expected" /opt/dragontools/components/victorialogs/current/victoria-logs-prod | sha256sum --check --status
        \\i=0
        \\until curl --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 http://127.0.0.1:9428/health >/dev/null; do i=$((i+1)); test "$i" -lt 15; sleep 1; done
        \\listeners=$(ss -H -ltnp 'sport = :9428')
        \\printf '%s\n' "$listeners" | grep -F "pid=$pid," | grep -Eq '[[:space:]]127[.]0[.]0[.]1:9428[[:space:]]'
        \\if printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:9428[[:space:]]' >/dev/null; then exit 1; fi
        \\# Return only application metrics for strict controller-side validation.
        \\curl --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:9428/metrics
        ,
        "dragontools-victorialogs-health", vl.artifact(arch).binary_sha256,              try unit.render(a),
        vl.version,                        "-retentionPeriod=" ++ policy.logs.retention, try std.fmt.allocPrint(a, "-retention.maxDiskUsagePercent={d}", .{policy.logs.cleanup_usage_percent}),
    });
    const output = try report.call(r, .health, command);
    try validateMetrics(output);
}

// The pinned release writes this one uint64 gauge with the explicit storage path:
// https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.52.0/app/vlstorage/main.go#L625-L637
// Check that precise identity rather than accepting arbitrary HTTP 200 or metrics.
const metric_name = "vl_storage_is_read_only";
const storage_metric = metric_name ++ "{path=\"/var/lib/dragontools/victorialogs\"}";
pub fn validateMetrics(output: []const u8) !void {
    var found = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, metric_name)) continue;
        // A different metric with this prefix is not application identity evidence.
        if (line.len > metric_name.len and line[metric_name.len] != '{' and line[metric_name.len] != ' ' and line[metric_name.len] != '\t') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse return error.InvalidVictoriaLogsMetrics;
        const value = fields.next() orelse return error.InvalidVictoriaLogsMetrics;
        if (!std.mem.eql(u8, name, storage_metric) or fields.next() != null or found) return error.InvalidVictoriaLogsMetrics;
        if (std.mem.eql(u8, value, "1")) return error.VictoriaLogsReadOnly;
        if (!std.mem.eql(u8, value, "0")) return error.InvalidVictoriaLogsMetrics;
        found = true;
    }
    if (!found) return error.VictoriaLogsMetricMissing;
}

test "VictoriaLogs health requires its own writable storage metric" {
    try validateMetrics("# TYPE vl_storage_is_read_only gauge\n" ++ storage_metric ++ " 0\nvl_partitions 0\n");
    try validateMetrics(storage_metric ++ "\t0\r\n");
    try std.testing.expectError(error.VictoriaLogsReadOnly, validateMetrics(storage_metric ++ " 1\n"));
    for ([_][]const u8{ "", "ok", "<html>healthy</html>", "up 1\n", "vl_storage_is_read_only_total 0\n", "# " ++ storage_metric ++ " 0\n" }) |response| {
        try std.testing.expectError(error.VictoriaLogsMetricMissing, validateMetrics(response));
    }
}

test "VictoriaLogs health rejects malformed, duplicate, and wrong-path samples" {
    for ([_][]const u8{
        metric_name ++ " 0\n",
        "vl_storage_is_read_only{path=\"/wrong/path\"} 0\n",
        storage_metric ++ "\n",
        storage_metric ++ " NaN\n",
        storage_metric ++ " -1\n",
        storage_metric ++ " 2\n",
        storage_metric ++ " 0 extra\n",
        storage_metric ++ " 0\n" ++ storage_metric ++ " 0\n",
        storage_metric ++ " 0\n" ++ storage_metric ++ " 1\n",
    }) |response| {
        try std.testing.expectError(error.InvalidVictoriaLogsMetrics, validateMetrics(response));
    }
}

test "VictoriaLogs verification checks effective systemd policy and managed path metadata without mutation" {
    const Capture = struct {
        command: []const u8 = "",

        fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(remote.Operation.health, op);
            self.command = command;
            return .{ .code = 0, .output = storage_metric ++ " 0\n" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: Capture = .{};
    var report: install.Report = .{ .component = .victorialogs };
    try health(arena.allocator(), .{ .context = &capture, .execute = Capture.execute }, &report, .arm64);
    // These assertions inspect the actual rendered command, not a second health
    // implementation. They cannot establish real systemd enforcement on Ubuntu.
    for ([_][]const u8{
        "actual=$(systemctl show -p \"$1\" --value dragontools-victorialogs.service)\n  test \"$actual\" = \"$2\"",
        "check_property FragmentPath /etc/systemd/system/dragontools-victorialogs.service",
        "check_property NeedDaemonReload no",
        "check_property DropInPaths \"\"",
        "check_property User dt-victorialogs",
        "check_property Group dt-victorialogs",
        "check_property ProtectSystem strict",
        "for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do\n  check_property \"$property\" yes",
        "check_property CapabilityBoundingSet \"\"",
        "check_property AmbientCapabilities \"\"",
        "check_property ReadWritePaths /var/lib/dragontools/victorialogs",
        "\"/opt/dragontools/components/victorialogs/$version\" /var/lib/dragontools; do\n  test ! -L \"$dir\" && test -d \"$dir\"",
        "test ! -L /var/lib/dragontools/victorialogs && test -d /var/lib/dragontools/victorialogs",
        ")\" = dt-victorialogs:dt-victorialogs:750",
        "/etc/systemd/system/dragontools-victorialogs.service)\" = 0:0:644",
        "\"/opt/dragontools/components/victorialogs/$version/victoria-logs-prod\")\" = 0:0:755",
        "test \"$actual_args\" = \"$expected_args\"",
        "-retentionPeriod=100y",
        "-retention.maxDiskUsagePercent=75",
        "--connect-timeout 3 --max-time 5",
        "--max-filesize 1048576",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, capture.command, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.command, vl.artifact(.arm64).binary_sha256) != null);
    for ([_][]const u8{ "systemctl daemon-reload", "systemctl restart", "systemctl start", "touch ", "rm -f ", "chmod ", "chown ", "install -" }) |mutation| {
        try std.testing.expect(std.mem.indexOf(u8, capture.command, mutation) == null);
    }
    try std.testing.expectEqual(remote.Operation.health, report.phase);
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
}
