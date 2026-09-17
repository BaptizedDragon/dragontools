const std = @import("std");
const Secret = @import("../secrets/secret.zig").Secret;
pub const Operation = enum { detect, user, directories, capacity, binary, plugin, config, provisioning, unit, activate, health, credentials, finalize, status, notify_test, service_exists, host_inspect, host_packages, host_source, host_zshrc, host_verify, host_shell };
pub const Result = struct { code: u8, output: []const u8 = "" };
/// Monotonic readiness timing, injectable without real waiting in tests.
pub const Clock = struct {
    context: *anyopaque,
    now_ms: *const fn (*anyopaque) i64,
    sleep_ms: *const fn (*anyopaque, u32) anyerror!void,
};
/// Results are owned by the caller's operation arena. No stderr is surfaced.
pub const Remote = struct {
    context: *anyopaque,
    execute: *const fn (*anyopaque, Operation, []const u8) anyerror!Result,
    execute_timed: ?*const fn (*anyopaque, Operation, []const u8, u32) anyerror!Result = null,
    execute_secret: ?*const fn (*anyopaque, Operation, []const u8, *const Secret, u32) anyerror!Result = null,
    read_secret: ?*const fn (*anyopaque, []const u8, u32) anyerror!*Secret = null,
    clock: ?Clock = null,
    pub fn run(self: Remote, op: Operation, command: []const u8) !Result {
        return self.execute(self.context, op, command);
    }
    pub fn runTimed(self: Remote, op: Operation, command: []const u8, budget_ms: u32) !Result {
        if (self.execute_timed) |execute| return execute(self.context, op, command, budget_ms);
        return self.run(op, command);
    }
    pub fn runSecret(self: Remote, op: Operation, command: []const u8, payload: *const Secret, budget_ms: u32) !Result {
        const execute = self.execute_secret orelse return error.SecretTransportUnavailable;
        return execute(self.context, op, command, payload, budget_ms);
    }
    /// Dedicated bounded capture for station-issued agent credentials. Never
    /// route sensitive stdout through ordinary Result.output or an arena.
    pub fn readSecret(self: Remote, command: []const u8, budget_ms: u32) !*Secret {
        const read = self.read_secret orelse return error.SecretTransportUnavailable;
        return read(self.context, command, budget_ms);
    }
};
pub fn quote(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidArgument;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '\'');
    for (value) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}
pub fn shell(a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (argv, 0..) |arg, i| {
        const q = try quote(a, arg);
        defer a.free(q);
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, q);
    }
    return out.toOwnedSlice(a);
}
test "POSIX quoting" {
    const a = std.testing.allocator;
    const q = try shell(a, &.{ "printf", "%s", "a'$(touch /tmp/no);\n" });
    defer a.free(q);
    try std.testing.expectEqualStrings("'printf' '%s' 'a'\\''$(touch /tmp/no);\n'", q);
    try std.testing.expectError(error.InvalidArgument, quote(a, "x\x00y"));
}

test "quoted metacharacters survive real shell execution as literal data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = "single'quote\n$(printf injected); `printf injected` \\\" *";
    const command = try shell(a, &.{ "printf", "%s", value });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", command } });
    try std.testing.expectEqualStrings(value, result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
