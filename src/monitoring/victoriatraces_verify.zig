//! Read-only deterministic verification followed by bounded startup readiness checks.
const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const host = @import("../system/host.zig");
const vt = @import("../components/victoriatraces.zig");
const unit = @import("../components/victoriatraces_unit.zig");
const policy = @import("policy.zig");
const readiness = @import("readiness.zig");

const managed_state =
    \\expected=$1; unit=$2; version=$3
    \\check_property() {
    \\  actual=$(systemctl show -p "$1" --value dragontools-victoriatraces.service)
    \\  test "$actual" = "$2"
    \\}
    \\check_property FragmentPath /etc/systemd/system/dragontools-victoriatraces.service
    \\check_property LoadState loaded
    \\check_property UnitFileState enabled
    \\check_property NeedDaemonReload no
    \\check_property DropInPaths ""
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
    \\test "$(readlink /opt/dragontools/components/victoriatraces/current)" = "$version"
    \\test ! -L "/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod"
    \\test -f "/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod"
    \\test "$(stat -c '%u:%g:%a' "/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod")" = 0:0:755
    \\printf '%s  %s\n' "$expected" /opt/dragontools/components/victoriatraces/current/victoria-traces-prod | sha256sum --check --status
;

const runtime_guard =
    \\expected=$1; retention=$2; cleanup=$3
    \\# A missing listener is temporary; a public or extra listener is never retried.
    \\listeners=$(ss -H -ltnp 'sport = :10428')
    \\if test -n "$listeners"; then
    \\  if printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:10428[[:space:]]' >/dev/null; then exit 1; fi
    \\fi
    \\pid=$(systemctl show -p MainPID --value dragontools-victoriatraces.service)
    \\case "$pid" in ''|*[!0-9]*) exit 1;; 0) exit 75;; esac
    \\test -d "/proc/$pid" || exit 75
    \\test "$(stat -c '%U:%G' "/proc/$pid")" = dt-victoriatraces:dt-victoriatraces
    \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
    \\expected_args=$(printf '%s\n' /opt/dragontools/components/victoriatraces/current/victoria-traces-prod -storageDataPath=/var/lib/dragontools/victoriatraces -httpListenAddr=127.0.0.1:10428 -otlpGRPCListenAddr= "$retention" "$cleanup")
    \\test "$actual_args" = "$expected_args"
    \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
    \\all_listeners=$(ss -H -ltnp)
    \\owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid," || :)
    \\if test -n "$owned"; then
    \\  if printf '%s\n' "$owned" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:10428[[:space:]]' >/dev/null; then exit 1; fi
    \\fi
    \\if test -n "$listeners"; then
    \\  printf '%s\n' "$listeners" | grep -F "pid=$pid," >/dev/null || exit 1
    \\fi
;

const listener_ready =
    \\test -n "$listeners" || exit 75
    \\systemctl is-active --quiet dragontools-victoriatraces.service || exit 75
;

fn runtimeCommand(a: std.mem.Allocator, arch: host.Arch, check: readiness.Check, tail: []const u8) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                                                                            "-eu",                           "-c",                                           try std.fmt.allocPrint(a, "{s}\n{s}", .{ runtime_guard, tail }),
        try std.fmt.allocPrint(a, "dragontools-victoriatraces-{s}", .{@tagName(check)}), vt.artifact(arch).binary_sha256, "-retentionPeriod=" ++ policy.traces.retention, try std.fmt.allocPrint(a, "-retention.maxDiskUsagePercent={d}", .{policy.traces.cleanup_usage_percent}),
    });
}

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    const managed = try remote.shell(a, &.{ "sh", "-eu", "-c", managed_state, "dragontools-victoriatraces-managed_state", vt.artifact(arch).binary_sha256, try unit.render(a), vt.version });
    _ = try readiness.deterministic(a, r, report, .managed_state, managed);
    const active = try runtimeCommand(a, arch, .service_active, "systemctl is-active --quiet dragontools-victoriatraces.service || exit 75");
    try readiness.poll(a, r, report, .service_active, readiness.active_ms, active, readiness.ready);
    const http = try runtimeCommand(a, arch, .http_ready, listener_ready ++ "\n" ++
        "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 http://127.0.0.1:10428/health >/dev/null || exit 75");
    try readiness.poll(a, r, report, .http_ready, readiness.http_ms, http, readiness.ready);
    const storage = try runtimeCommand(a, arch, .storage_ready, listener_ready ++ "\n" ++
        "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:10428/metrics || exit 75");
    try readiness.poll(a, r, report, .storage_ready, readiness.telemetry_ms, storage, validateReadyMetrics);
}

fn validateReadyMetrics(_: std.mem.Allocator, output: []const u8) !void {
    validateMetrics(output) catch |err| switch (err) {
        error.VictoriaTracesMetricMissing => {
            // Empty/exposition-only startup output may acquire the storage gauge
            // later. An HTML/error body is not a readiness signal to retry.
            var lines = std.mem.splitScalar(u8, output, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const separator = std.mem.lastIndexOfAny(u8, line, " \t") orelse return error.InvalidVictoriaTracesMetrics;
                _ = std.fmt.parseFloat(f64, line[separator + 1 ..]) catch return error.InvalidVictoriaTracesMetrics;
            }
            return error.NotReady;
        },
        else => return err,
    };
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

test "VictoriaTraces readiness retries missing metric but rejects malformed or read-only storage" {
    try std.testing.expectError(error.NotReady, validateReadyMetrics(std.testing.allocator, "# still starting\n"));
    try validateReadyMetrics(std.testing.allocator, storage_metric ++ " 0\n");
    try std.testing.expectError(error.NotReady, validateReadyMetrics(std.testing.allocator, "other_metric 0\n"));
    try std.testing.expectError(error.InvalidVictoriaTracesMetrics, validateReadyMetrics(std.testing.allocator, "<html>healthy</html>"));
    try std.testing.expectError(error.InvalidVictoriaTracesMetrics, validateReadyMetrics(std.testing.allocator, metric_name ++ " 0\n"));
    try std.testing.expectError(error.InvalidVictoriaTracesMetrics, validateReadyMetrics(std.testing.allocator, metric_name ++ "{path=\"/wrong\"} 0\n"));
    try std.testing.expectError(error.VictoriaTracesReadOnly, validateReadyMetrics(std.testing.allocator, storage_metric ++ " 1\n"));
}

test "VictoriaTraces verification separates static policy from guarded bounded runtime checks" {
    const Capture = struct {
        commands: [4][]const u8 = undefined,
        count: usize = 0,

        fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(remote.Operation.health, op);
            if (self.count >= self.commands.len) return error.UnexpectedRetry;
            self.commands[self.count] = command;
            self.count += 1;
            return .{ .code = 0, .output = storage_metric ++ " 0\n" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var capture: Capture = .{};
    var report: install.Report = .{ .component = .victoriatraces };
    try health(a, .{ .context = &capture, .execute = Capture.execute }, &report, .arm64);
    try std.testing.expectEqual(@as(usize, 4), capture.count);
    const managed = capture.commands[0];
    for ([_][]const u8{
        "dragontools-victoriatraces-managed_state",
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
        ")\" = dt-victoriatraces:dt-victoriatraces:750",
        "/etc/systemd/system/dragontools-victoriatraces.service)\" = 0:0:644",
        "\"/opt/dragontools/components/victoriatraces/$version/victoria-traces-prod\")\" = 0:0:755",
        "readlink /opt/dragontools/components/victoriatraces/current",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, managed, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, managed, vt.artifact(.arm64).binary_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, managed, "is-active") == null);
    try std.testing.expect(std.mem.indexOf(u8, managed, "curl ") == null);
    for (capture.commands[1..]) |command| {
        for ([_][]const u8{ "test \"$actual_args\" = \"$expected_args\"", "all_listeners=$(ss -H -ltnp)", "owned=$(printf", "pid=$pid,", "/proc/$pid/exe", "dt-victoriatraces:dt-victoriatraces", "-retentionPeriod=100y", "-retention.maxDiskUsagePercent=75" }) |needle|
            try std.testing.expect(std.mem.indexOf(u8, command, needle) != null);
    }
    for (capture.commands, [_][]const u8{ "managed_state", "service_active", "http_ready", "storage_ready" }) |command, check| {
        try std.testing.expect(std.mem.indexOf(u8, command, try std.fmt.allocPrint(a, "dragontools-victoriatraces-{s}", .{check})) != null);
        for ([_][]const u8{ "systemctl daemon-reload", "systemctl restart", "systemctl start", "touch ", "rm -f ", "chmod ", "chown ", "install -", "sleep ", "until ", "while " }) |mutation|
            try std.testing.expect(std.mem.indexOf(u8, command, mutation) == null);
        const script = try std.fmt.allocPrint(a, "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command});
        const parsed = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
        try std.testing.expectEqualStrings("", parsed.stderr);
        try std.testing.expectEqual(@as(u8, 0), parsed.term.exited);
    }
    try std.testing.expectEqual(remote.Operation.health, report.phase);
    try std.testing.expectEqual(@as(usize, 4), report.completed);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
}

test "VictoriaTraces deterministic failure never reaches readiness polling" {
    const Failure = struct {
        calls: usize = 0,
        fn execute(ctx: *anyopaque, _: remote.Operation, _: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return .{ .code = 1 };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    var report: install.Report = .{ .component = .victoriatraces };
    try std.testing.expectError(error.RemoteOperationFailed, health(arena.allocator(), .{ .context = &failure, .execute = Failure.execute }, &report, .amd64));
    try std.testing.expectEqual(@as(usize, 1), failure.calls);
}

test "VictoriaTraces actual runtime guard distinguishes startup absence from invariant failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\set -eu
        \\scenario=$1; shift
        \\root=$(mktemp -d "${TMPDIR:-/tmp}/dragontools-storage-probe.XXXXXX")
        \\trap 'rm -rf "$root"' EXIT HUP INT TERM
        \\mkdir -p "$root/proc/123"
        \\printf '%s\000' /opt/dragontools/components/victoriatraces/current/victoria-traces-prod -storageDataPath=/var/lib/dragontools/victoriatraces -httpListenAddr=127.0.0.1:10428 -otlpGRPCListenAddr= -retentionPeriod=100y -retention.maxDiskUsagePercent=75 > "$root/proc/123/cmdline"
        \\if test "$scenario" = args; then printf unexpected > "$root/proc/123/cmdline"; fi
        \\ss() {
        \\  test "$scenario" != missing_listener || return 0
        \\  if test "$scenario" = public; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:10428 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  else
        \\    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:10428 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  fi
        \\  if test "$#" -eq 2 && test "$scenario" = extra; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9999 0.0.0.0:* users:("fixture",pid=123,fd=4)'
        \\  fi
        \\}
        \\systemctl() {
        \\  if test "$1" = is-active; then test "$scenario" != inactive; return; fi
        \\  if test "$scenario" = missing_pid; then printf 0; else printf 123; fi
        \\}
        \\stat() { if test "$scenario" = owner; then printf root:root; else printf dt-victoriatraces:dt-victoriatraces; fi; }
        \\sha256sum() { cat >/dev/null; test "$scenario" != checksum; }
    ;
    const guard = try std.mem.replaceOwned(u8, a, runtime_guard, "/proc/", "$root/proc/");
    const script = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\nprintf ready", .{ fixture, guard, listener_ready });
    const Case = struct { scenario: []const u8, code: u8 };
    for ([_]Case{
        .{ .scenario = "ready", .code = 0 },
        .{ .scenario = "missing_pid", .code = 75 },
        .{ .scenario = "missing_listener", .code = 75 },
        .{ .scenario = "inactive", .code = 75 },
        .{ .scenario = "public", .code = 1 },
        .{ .scenario = "extra", .code = 1 },
        .{ .scenario = "owner", .code = 1 },
        .{ .scenario = "args", .code = 1 },
        .{ .scenario = "checksum", .code = 1 },
    }) |case| {
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", case.scenario, "expected-hash", "-retentionPeriod=100y", "-retention.maxDiskUsagePercent=75" } });
        try std.testing.expectEqual(case.code, result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(if (case.code == 0) "ready" else "", result.stdout);
    }
}
