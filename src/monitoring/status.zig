const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const traces = @import("../components/victoriatraces.zig");

fn property(output: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, expected)) return true;
    }
    return false;
}

fn state(output: []const u8) []const u8 {
    // Never echo arbitrary remote text or terminal control sequences.
    if (property(output, "LoadState=not-found")) return "not installed";
    if (property(output, "LoadState=loaded")) {
        if (property(output, "ActiveState=active") and property(output, "SubState=running")) return "active";
        return "inactive or unhealthy";
    }
    return "unknown";
}

fn enabled(output: []const u8) []const u8 {
    if (property(output, "LoadState=not-found")) return "not installed";
    if (property(output, "UnitFileState=enabled")) return "yes";
    if (property(output, "UnitFileState=enabled-runtime")) return "runtime only";
    if (property(output, "UnitFileState=disabled")) return "no";
    if (property(output, "UnitFileState=masked")) return "masked";
    return "unknown";
}

pub fn status(a: std.mem.Allocator, r: remote.Remote, report: *install.Report) ![]const u8 {
    report.component = .victoriametrics;
    const vm = try report.call(r, .status, "systemctl show dragontools-victoriametrics.service --property=LoadState,ActiveState,SubState,UnitFileState --no-pager");
    report.component = .victorialogs;
    const vl = try report.call(r, .status, "systemctl show dragontools-victorialogs.service --property=LoadState,ActiveState,SubState,UnitFileState --no-pager");
    report.component = .victoriatraces;
    const vt = try report.call(r, .status, "systemctl show dragontools-victoriatraces.service --property=LoadState,ActiveState,SubState,UnitFileState --no-pager");
    return std.fmt.allocPrint(a, "VictoriaMetrics: loopback:8428\n  state: {s}\n  enabled: {s}\nVictoriaLogs: loopback:9428\n  state: {s}\n  enabled: {s}\nVictoriaTraces: loopback:{d}\n  state: {s}\n  enabled: {s}\nListeners above are the managed policy. Run monitoring verify to check effective policy, health, identity and storage.\n", .{ state(vm), enabled(vm), state(vl), enabled(vl), traces.port, state(vt), enabled(vt) });
}

test "status recognizes exact properties without exposing remote text" {
    try std.testing.expectEqualStrings("not installed", state("LoadState=not-found\n"));
    try std.testing.expectEqualStrings("active", state("LoadState=loaded\nActiveState=active\nSubState=running\n"));
    try std.testing.expectEqualStrings("inactive or unhealthy", state("LoadState=loaded\nActiveState=inactive\n"));
    try std.testing.expectEqualStrings("unknown", state("arbitrary ActiveState=active\n\x1b[31m"));
}

test "status reports all three components and enablement independently" {
    const Fake = struct {
        fn execute(_: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
            try std.testing.expectEqual(remote.Operation.status, op);
            return .{ .code = 0, .output = if (std.mem.indexOf(u8, command, "victorialogs") != null) "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n" else if (std.mem.indexOf(u8, command, "victoriatraces") != null) "LoadState=not-found\n" else "LoadState=loaded\nActiveState=active\nSubState=running\nUnitFileState=enabled\n" };
        }
    };
    var context: u8 = 0;
    var report: install.Report = .{};
    const output = try status(std.testing.allocator, .{ .context = &context, .execute = Fake.execute }, &report);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "VictoriaMetrics: loopback:8428\n  state: active\n  enabled: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VictoriaLogs: loopback:9428\n  state: inactive or unhealthy\n  enabled: no") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VictoriaTraces: loopback:10428\n  state: not installed\n  enabled: not installed") != null);
    try std.testing.expectEqual(@as(usize, 3), report.completed);
}
