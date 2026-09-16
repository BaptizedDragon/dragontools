//! Read-only verification of the managed VictoriaTraces service and writable storage.
const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const host = @import("../system/host.zig");
const vt = @import("../components/victoriatraces.zig");
const unit = @import("../components/victoriatraces_unit.zig");
const policy = @import("policy.zig");

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    const command = try remote.shell(a, &.{
        "sh",                                "-eu",                                          "-c",
        \\expected=$1; unit=$2; version=$3; retention=$4; cleanup=$5; address=$6; port=$7
        \\check_property() {
        \\  actual=$(systemctl show -p "$1" --value dragontools-victoriatraces.service)
        \\  test "$actual" = "$2"
        \\}
        \\check_property FragmentPath /etc/systemd/system/dragontools-victoriatraces.service
        \\check_property LoadState loaded
        \\check_property UnitFileState enabled
        \\check_property NeedDaemonReload no
        \\check_property DropInPaths ""
        \\systemctl is-active --quiet dragontools-victoriatraces.service
        \\systemctl is-enabled --quiet dragontools-victoriatraces.service
        \\test ! -L /etc/systemd/system/dragontools-victoriatraces.service
        \\test -f /etc/systemd/system/dragontools-victoriatraces.service
        \\test "$(stat -c '%u:%g:%a' /etc/systemd/system/dragontools-victoriatraces.service)" = 0:0:644
        \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-victoriatraces.service
        \\check_property User dt-victoriatraces
        \\check_property Group dt-victoriatraces
        \\check_property ProtectSystem strict
        \\for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do
        \\  check_property "$property" yes
        \\done
        \\check_property CapabilityBoundingSet ""
        \\check_property AmbientCapabilities ""
        \\check_property ReadWritePaths /var/lib/dragontools/victoriatraces
        \\for dir in /opt/dragontools /opt/dragontools/components /opt/dragontools/components/victoriatraces "/opt/dragontools/components/victoriatraces/$version" /var/lib/dragontools; do
        \\  test ! -L "$dir" && test -d "$dir"
        \\  test "$(stat -c '%u:%g:%a' "$dir")" = 0:0:755
        \\done
        \\test ! -L /var/lib/dragontools/victoriatraces && test -d /var/lib/dragontools/victoriatraces
        \\test "$(stat -c '%U:%G:%a' /var/lib/dragontools/victoriatraces)" = dt-victoriatraces:dt-victoriatraces:750
        \\pid=$(systemctl show -p MainPID --value dragontools-victoriatraces.service)
        \\test "$pid" -gt 0
        \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
        \\expected_args=$(printf '%s\n' /opt/dragontools/components/victoriatraces/current/victoria-traces-prod -storageDataPath=/var/lib/dragontools/victoriatraces "-httpListenAddr=$address" -otlpGRPCListenAddr= "$retention" "$cleanup")
        \\test "$actual_args" = "$expected_args"
        \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
        \\test "$(readlink /opt/dragontools/components/victoriatraces/current)" = "$version"
        \\test ! -L "/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod"
        \\test -f "/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod"
        \\test "$(stat -c '%u:%g:%a' "/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod")" = 0:0:755
        \\printf '%s  %s\n' "$expected" /opt/dragontools/components/victoriatraces/current/victoria-traces-prod | sha256sum --check --status
        \\i=0
        \\until curl --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 "http://$address/health" >/dev/null; do i=$((i+1)); test "$i" -lt 15; sleep 1; done
        \\listeners=$(ss -H -ltnp "sport = :$port")
        \\printf '%s\n' "$listeners" | grep -F "pid=$pid," | grep -Eq "[[:space:]]127[.]0[.]0[.]1:$port[[:space:]]"
        \\if printf '%s\n' "$listeners" | grep -Ev "[[:space:]]127[.]0[.]0[.]1:$port[[:space:]]" >/dev/null; then exit 1; fi
        \\# The pinned single-node process has no additional TCP listener, including gRPC.
        \\all_listeners=$(ss -H -ltnp)
        \\owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid,")
        \\if printf '%s\n' "$owned" | grep -Ev "[[:space:]]127[.]0[.]0[.]1:$port[[:space:]]" >/dev/null; then exit 1; fi
        \\# Return only application metrics for strict controller-side validation.
        \\curl --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 "http://$address/metrics"
        ,
        "dragontools-victoriatraces-health", vt.artifact(arch).binary_sha256,                try unit.render(a),
        vt.version,                          "-retentionPeriod=" ++ policy.traces.retention, try std.fmt.allocPrint(a, "-retention.maxDiskUsagePercent={d}", .{policy.traces.cleanup_usage_percent}),
        vt.listen_address,                   try std.fmt.allocPrint(a, "{d}", .{vt.port}),
    });
    const output = try report.call(r, .health, command);
    try validateMetrics(output);
}

// The pinned release writes this one uint64 gauge with the explicit storage path:
// https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.11.0/app/vtstorage/main.go#L639-L651
// Check that precise identity rather than accepting arbitrary HTTP 200 or metrics.
const metric_name = "vt_storage_is_read_only";
const storage_metric = metric_name ++ "{path=\"/var/lib/dragontools/victoriatraces\"}";
pub fn validateMetrics(output: []const u8) !void {
    var found = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, metric_name)) continue;
        // A different metric with this prefix is not application identity evidence.
        if (line.len > metric_name.len and line[metric_name.len] != '{' and line[metric_name.len] != ' ' and line[metric_name.len] != '\t') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse return error.InvalidVictoriaTracesMetrics;
        const value = fields.next() orelse return error.InvalidVictoriaTracesMetrics;
        if (!std.mem.eql(u8, name, storage_metric) or fields.next() != null or found) return error.InvalidVictoriaTracesMetrics;
        if (std.mem.eql(u8, value, "1")) return error.VictoriaTracesReadOnly;
        if (!std.mem.eql(u8, value, "0")) return error.InvalidVictoriaTracesMetrics;
        found = true;
    }
    if (!found) return error.VictoriaTracesMetricMissing;
}

test "VictoriaTraces health requires its own writable storage metric" {
    try validateMetrics("# TYPE vt_storage_is_read_only gauge\n" ++ storage_metric ++ " 0\nvt_partitions 0\n");
    try validateMetrics(storage_metric ++ "\t0\r\n");
    try std.testing.expectError(error.VictoriaTracesReadOnly, validateMetrics(storage_metric ++ " 1\n"));
    for ([_][]const u8{ "", "ok", "<html>healthy</html>", "up 1\n", "vl_storage_is_read_only{path=\"/var/lib/dragontools/victoriatraces\"} 0\n", "vt_storage_is_read_only_total 0\n", "# " ++ storage_metric ++ " 0\n" }) |response| {
        try std.testing.expectError(error.VictoriaTracesMetricMissing, validateMetrics(response));
    }
}

test "VictoriaTraces health rejects malformed, duplicate, and wrong-path samples" {
    for ([_][]const u8{
        metric_name ++ " 0\n",
        "vt_storage_is_read_only{path=\"/wrong/path\"} 0\n",
        storage_metric ++ "\n",
        storage_metric ++ " NaN\n",
        storage_metric ++ " -1\n",
        storage_metric ++ " 2\n",
        storage_metric ++ " 0 extra\n",
        storage_metric ++ " 0\n" ++ storage_metric ++ " 0\n",
        storage_metric ++ " 0\n" ++ storage_metric ++ " 1\n",
    }) |response| {
        try std.testing.expectError(error.InvalidVictoriaTracesMetrics, validateMetrics(response));
    }
}

test "VictoriaTraces verification checks effective systemd policy and managed path metadata without mutation" {
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
    var report: install.Report = .{ .component = .victoriatraces };
    try health(arena.allocator(), .{ .context = &capture, .execute = Capture.execute }, &report, .arm64);
    // These assertions inspect the actual rendered command, not a second health
    // implementation. They cannot establish real systemd enforcement on Ubuntu.
    for ([_][]const u8{
        "actual=$(systemctl show -p \"$1\" --value dragontools-victoriatraces.service)\n  test \"$actual\" = \"$2\"",
        "check_property FragmentPath /etc/systemd/system/dragontools-victoriatraces.service",
        "check_property LoadState loaded",
        "check_property UnitFileState enabled",
        "check_property NeedDaemonReload no",
        "check_property DropInPaths \"\"",
        "check_property User dt-victoriatraces",
        "check_property Group dt-victoriatraces",
        "check_property ProtectSystem strict",
        "for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do\n  check_property \"$property\" yes",
        "check_property CapabilityBoundingSet \"\"",
        "check_property AmbientCapabilities \"\"",
        "check_property ReadWritePaths /var/lib/dragontools/victoriatraces",
        "\"/opt/dragontools/components/victoriatraces/$version\" /var/lib/dragontools; do\n  test ! -L \"$dir\" && test -d \"$dir\"",
        "test ! -L /var/lib/dragontools/victoriatraces && test -d /var/lib/dragontools/victoriatraces",
        ")\" = dt-victoriatraces:dt-victoriatraces:750",
        "/etc/systemd/system/dragontools-victoriatraces.service)\" = 0:0:644",
        "\"/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod\")\" = 0:0:755",
        "test \"$actual_args\" = \"$expected_args\"",
        "-otlpGRPCListenAddr=",
        "-retentionPeriod=100y",
        "-retention.maxDiskUsagePercent=75",
        "--connect-timeout 3 --max-time 5",
        "--max-filesize 1048576",
        "test \"$i\" -lt 15",
        "all_listeners=$(ss -H -ltnp)",
        "owned=$(printf",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, capture.command, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.command, vt.artifact(.arm64).binary_sha256) != null);
    for ([_][]const u8{ "systemctl daemon-reload", "systemctl restart", "systemctl start", "touch ", "rm -f ", "chmod ", "chown ", "install -" }) |mutation| {
        try std.testing.expect(std.mem.indexOf(u8, capture.command, mutation) == null);
    }
    try std.testing.expectEqual(remote.Operation.health, report.phase);
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    // Parse the real generated shell without executing any systemd/network action.
    const script = try std.fmt.allocPrint(arena.allocator(), "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{capture.command});
    const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
