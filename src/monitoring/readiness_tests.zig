const std = @import("std");
const readiness = @import("readiness.zig");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");

const Fake = struct {
    milliseconds: i64 = 0,
    calls: usize = 0,
    failures: usize = 0,
    code: u8 = 75,
    cost_ms: u32 = 0,
    budgets: [100]u32 = @splat(0),
    sleeps: [100]u32 = @splat(0),
    sleep_count: usize = 0,
    transport_error: bool = false,
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .execute_timed = timed, .clock = .{ .context = self, .now_ms = now, .sleep_ms = sleep } };
    }
    fn now(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.milliseconds;
    }
    fn sleep(ctx: *anyopaque, ms: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.sleeps[self.sleep_count] = ms;
        self.sleep_count += 1;
        self.milliseconds += ms;
    }
    fn timed(ctx: *anyopaque, op: remote.Operation, cmd: []const u8, budget_ms: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.budgets[self.calls] = budget_ms;
        if (self.cost_ms >= budget_ms) {
            self.milliseconds += budget_ms;
            self.calls += 1;
            return error.Timeout;
        }
        self.milliseconds += self.cost_ms;
        return execute(ctx, op, cmd);
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, _: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(remote.Operation.health, op);
        self.calls += 1;
        if (self.transport_error) return error.SshConnectionFailed;
        if (self.calls <= self.failures) return .{ .code = self.code, .output = "not-yet" };
        return .{ .code = 0, .output = "ready" };
    }
};

fn validate(_: std.mem.Allocator, output: []const u8) !void {
    if (!std.mem.eql(u8, output, "ready")) return error.NotReady;
}

test "readiness checks immediately then waits 500ms and one second only after failure" {
    var fake: Fake = .{ .failures = 2 };
    var report: install.Report = .{};
    try readiness.poll(std.testing.allocator, fake.asRemote(), &report, .http_ready, 30_000, "probe", validate);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualSlices(u32, &.{ 500, 1000 }, fake.sleeps[0..fake.sleep_count]);
    try std.testing.expectEqualSlices(u32, &.{ 30_000, 29_500, 28_500 }, fake.budgets[0..fake.calls]);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    var immediate: Fake = .{};
    try readiness.poll(std.testing.allocator, immediate.asRemote(), &report, .http_ready, 30_000, "probe", validate);
    try std.testing.expectEqual(@as(usize, 0), immediate.sleep_count);
}

test "readiness retries validated missing telemetry within the 45s self scrape budget" {
    var fake: Fake = .{ .failures = 17, .code = 0 };
    var report: install.Report = .{};
    try readiness.poll(std.testing.allocator, fake.asRemote(), &report, .self_scrape_ready, 45_000, "probe", validate);
    try std.testing.expectEqual(@as(usize, 18), fake.calls);
    try std.testing.expectEqual(@as(i64, 16_500), fake.milliseconds);
    try std.testing.expectEqual(readiness.Check.self_scrape_ready, report.check.?);
}

test "readiness deadline includes probe duration and clips final wait" {
    var fake: Fake = .{ .failures = 100 };
    var report: install.Report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, readiness.poll(std.testing.allocator, fake.asRemote(), &report, .service_active, 15_000, "probe", validate));
    try std.testing.expectEqual(@as(i64, 15_000), fake.milliseconds);
    try std.testing.expectEqual(@as(usize, 16), fake.calls);
    var slow: Fake = .{ .failures = 100, .cost_ms = 7_000 };
    try std.testing.expectError(error.ReadinessTimedOut, readiness.poll(std.testing.allocator, slow.asRemote(), &report, .service_active, 15_000, "probe", validate));
    try std.testing.expectEqual(@as(i64, 15_000), slow.milliseconds);
    try std.testing.expectEqual(@as(usize, 2), slow.calls);
    var late: Fake = .{ .cost_ms = 30_000 };
    try std.testing.expectError(error.ReadinessTimedOut, readiness.poll(std.testing.allocator, late.asRemote(), &report, .http_ready, 30_000, "probe", validate));
}

test "deterministic and transport failures fail once with no wait" {
    for ([_]u8{ 1, 40, 41, 42, 43, 255 }) |code| {
        var fake: Fake = .{ .failures = 100, .code = code };
        var report: install.Report = .{};
        readiness.poll(std.testing.allocator, fake.asRemote(), &report, .http_ready, 30_000, "probe", validate) catch {};
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.sleep_count);
    }
    var fake: Fake = .{ .failures = 100, .code = 1 };
    var report: install.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, readiness.deterministic(std.testing.allocator, fake.asRemote(), &report, .managed_state, "probe"));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.sleep_count);
    var disconnected: Fake = .{ .transport_error = true };
    try std.testing.expectError(error.SshConnectionFailed, readiness.poll(std.testing.allocator, disconnected.asRemote(), &report, .http_ready, 30_000, "probe", validate));
    try std.testing.expectEqual(@as(usize, 1), disconnected.calls);
}
