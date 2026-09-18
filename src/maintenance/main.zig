//! Read-only Ubuntu observations. Unknown data is never reported as zero.
const std = @import("std");
pub const State = struct {
    supported: bool = false,
    package_metadata_fresh: bool = false,
    updates_pending: ?u32 = null,
    security_updates_pending: ?u32 = null,
    reboot_required: ?bool = null,
    automatic_security_updates_enabled: ?bool = null,
    automatic_security_updates_healthy: ?bool = null,
};
pub const Counts = struct { updates: u32, security: u32 };
pub fn counts(text: []const u8) !Counts {
    const value = std.mem.trim(u8, text, "\r\n");
    var parts = std.mem.splitScalar(u8, value, ';');
    const first = parts.next() orelse return error.InvalidCounts;
    const second = parts.next() orelse return error.InvalidCounts;
    if (parts.next() != null) return error.InvalidCounts;
    for ([_][]const u8{ first, second }) |number| {
        if (number.len == 0 or number.len > 7) return error.InvalidCounts;
        for (number) |c| if (!std.ascii.isDigit(c)) return error.InvalidCounts;
    }
    const result: Counts = .{ .updates = try std.fmt.parseInt(u32, first, 10), .security = try std.fmt.parseInt(u32, second, 10) };
    if (result.security > result.updates or result.updates > 1000000) return error.InvalidCounts;
    return result;
}
pub fn fresh(now: i64, timestamp: i64) bool {
    return timestamp > 0 and timestamp <= now and now - timestamp <= 48 * 3600;
}
fn field(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, name) and line.len > name.len and line[name.len] == '=') {
        if (found != null) return null;
        found = line[name.len + 1 ..];
    };
    return found;
}
fn positive(text: ?[]const u8) ?bool {
    const value = text orelse return false; // APT's absent default is disabled.
    const number = std.fmt.parseInt(u16, value, 10) catch return null;
    return number > 0;
}
pub fn automatic(config: []const u8, timer: ?[]const u8) ?bool {
    const upgrades = positive(field(config, "APT::Periodic::Unattended-Upgrade")) orelse return null;
    const refresh = positive(field(config, "APT::Periodic::Update-Package-Lists")) orelse return null;
    if (!upgrades or !refresh) return false;
    // Recognize explicit Ubuntu security origins; custom policies stay unknown.
    var security = false;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Unattended-Upgrade::Allowed-Origins::=")) {
            const value = line["Unattended-Upgrade::Allowed-Origins::=".len..];
            security = security or std.mem.eql(u8, value, "${distro_id}:${distro_codename}-security") or std.mem.eql(u8, value, "Ubuntu:noble-security") or std.mem.eql(u8, value, "Ubuntu:resolute-security");
        }
    }
    if (!security) return null;
    const state = timer orelse return null;
    const active = field(state, "ActiveState") orelse return null;
    const enabled = field(state, "UnitFileState") orelse return null;
    return std.mem.eql(u8, active, "active") and std.mem.eql(u8, enabled, "enabled");
}
pub fn healthy(text: []const u8) ?bool {
    const load = field(text, "LoadState") orelse return null;
    if (!std.mem.eql(u8, load, "loaded")) return null;
    const active = field(text, "ActiveState") orelse return null;
    const result = field(text, "Result") orelse return null;
    if (std.mem.eql(u8, active, "failed") or !std.mem.eql(u8, result, "success")) return false;
    const started = std.fmt.parseInt(u64, field(text, "ExecMainStartTimestampMonotonic") orelse return null, 10) catch return null;
    return if (started == 0) null else true;
}
const Runner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    fn run(self: Runner, argv: []const []const u8, seconds: u64) ?std.process.RunResult {
        var env: std.process.Environ.Map = .init(self.a);
        defer env.deinit();
        env.put("PATH", "/usr/sbin:/usr/bin:/sbin:/bin") catch return null;
        env.put("LC_ALL", "C") catch return null;
        env.put("PYTHONDONTWRITEBYTECODE", "1") catch return null;
        const result = std.process.run(self.a, self.io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(65536), .stderr_limit = .limited(1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(@intCast(seconds)), .clock = .awake } } }) catch return null;
        if (result.term != .exited or result.term.exited != 0) return null;
        return result;
    }
};
pub fn collect(a: std.mem.Allocator, io: std.Io) !State {
    var result: State = .{};
    const root = std.Io.Dir.cwd();
    const os = root.readFileAlloc(io, "/etc/os-release", a, .limited(8192)) catch return result;
    var ubuntu = false;
    var supported_version = false;
    var lines = std.mem.splitScalar(u8, os, '\n');
    while (lines.next()) |line| {
        ubuntu = ubuntu or std.mem.eql(u8, line, "ID=ubuntu") or std.mem.eql(u8, line, "ID=\"ubuntu\"");
        supported_version = supported_version or std.mem.eql(u8, line, "VERSION_ID=\"24.04\"") or std.mem.eql(u8, line, "VERSION_ID=\"26.04\"");
    }
    if (!ubuntu or !supported_version) return result;
    result.supported = true;
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (root.statFile(io, "/var/lib/apt/periodic/update-success-stamp", .{})) |stat| {
        result.package_metadata_fresh = fresh(now, stat.mtime.toSeconds());
    } else |_| {}
    const runner: Runner = .{ .a = a, .io = io };
    if (result.package_metadata_fresh) if (runner.run(&.{"/usr/lib/update-notifier/apt-check"}, 20)) |response| {
        if (response.stdout.len == 0) if (counts(response.stderr)) |value| {
            result.updates_pending = value.updates;
            result.security_updates_pending = value.security;
        } else |_| {};
    };
    if (root.statFile(io, "/run/reboot-required", .{ .follow_symlinks = false })) |stat| {
        if (stat.kind == .file) result.reboot_required = true;
    } else |err| if (err == error.FileNotFound) {
        result.reboot_required = false;
    }
    if (runner.run(&.{ "/usr/bin/apt-config", "dump", "--format", "%f=%v%n" }, 2)) |config| {
        const timer = runner.run(&.{ "/usr/bin/systemctl", "show", "apt-daily-upgrade.timer", "--property=ActiveState,UnitFileState" }, 2);
        result.automatic_security_updates_enabled = automatic(config.stdout, if (timer) |value| value.stdout else null);
    }
    if (runner.run(&.{ "/usr/bin/systemctl", "show", "apt-daily-upgrade.service", "--property=LoadState,ActiveState,Result,ExecMainStartTimestampMonotonic" }, 2)) |service| result.automatic_security_updates_healthy = healthy(service.stdout);
    return result;
}
pub fn json(a: std.mem.Allocator, state: State) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, state, .{ .whitespace = .indent_2 });
}
pub const gauges = .{ "updates_pending", "security_updates_pending", "reboot_required", "automatic_security_updates_enabled", "automatic_security_updates_healthy" };
pub fn metrics(a: std.mem.Allocator, state: State, version: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"dragontool_host_package_metadata_fresh\":{d},\"dragontool_agent_version_info\":1,\"version\":", .{@intFromBool(state.package_metadata_fresh)});
    try std.json.Stringify.value(version, .{}, w);
    inline for (gauges) |name| {
        if (@field(state, name)) |value| try w.print(",\"dragontool_host_{s}\":{d}", .{ name, if (@TypeOf(value) == bool) @as(u32, @intFromBool(value)) else value });
    }
    try w.writeAll("}\n");
    return out.toOwnedSlice();
}
test "maintenance numeric provider validates bounded security subset and rejects localized diagnostics" {
    const value = try counts("12;3\n");
    try std.testing.expectEqual(@as(u32, 12), value.updates);
    try std.testing.expectEqual(@as(u32, 3), value.security);
    _ = try counts("0;0");
    for ([_][]const u8{ "12 updates", "1;2", "-1;0", "1;0;0", "1;0\nwarning", "1000001;1", "1;", ";0" }) |bad| try std.testing.expectError(error.InvalidCounts, counts(bad));
}
test "maintenance unknown values stay absent from metrics and stale metadata is not zero" {
    try std.testing.expect(fresh(200000, 190000));
    try std.testing.expect(!fresh(200000, 100));
    try std.testing.expect(!fresh(200000, 200001));
    const output = try metrics(std.testing.allocator, .{}, "0.1.0-test");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "updates_pending") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dragontool_agent_version_info\":1") != null);
    const known = try metrics(std.testing.allocator, .{ .reboot_required = true, .security_updates_pending = 3, .updates_pending = 12 }, "0.1.0-test");
    defer std.testing.allocator.free(known);
    try std.testing.expect(std.mem.indexOf(u8, known, "dragontool_host_reboot_required\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, known, "dragontool_host_security_updates_pending\":3") != null);
}
test "unattended security upgrades distinguish disabled enabled failed and unknown policies" {
    const config = "APT::Periodic::Unattended-Upgrade=1\nAPT::Periodic::Update-Package-Lists=1\nUnattended-Upgrade::Allowed-Origins::=${distro_id}:${distro_codename}-security\n";
    try std.testing.expectEqual(@as(?bool, true), automatic(config, "ActiveState=active\nUnitFileState=enabled\n"));
    try std.testing.expectEqual(@as(?bool, false), automatic(config, "ActiveState=inactive\nUnitFileState=disabled\n"));
    try std.testing.expectEqual(@as(?bool, false), automatic("", null));
    try std.testing.expectEqual(@as(?bool, null), automatic(config, null));
    try std.testing.expectEqual(@as(?bool, true), healthy("LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStartTimestampMonotonic=1000\n"));
    try std.testing.expectEqual(@as(?bool, false), healthy("LoadState=loaded\nActiveState=failed\nResult=exit-code\n"));
    try std.testing.expectEqual(@as(?bool, null), healthy("LoadState=not-found\n"));
    try std.testing.expectEqual(@as(?bool, null), healthy("LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStartTimestampMonotonic=0\n"));
}
