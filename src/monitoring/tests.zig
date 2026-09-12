const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const Fake = struct {
    present: [@typeInfo(remote.Operation).@"enum".fields.len]bool = @splat(false),
    calls: usize = 0,
    restarts: usize = 0,
    dirty: bool = false,
    fail: ?remote.Operation = null,
    inactive: bool = true,
    check_syntax: bool = false,
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute };
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.check_syntax) {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            // For a quoted sh wrapper, intercept it and parse its inner script too.
            // Raw commands use sh -n directly; no remote command is executed here.
            const wrapped = std.mem.startsWith(u8, command, "'sh' ");
            const script = if (wrapped) try std.fmt.allocPrint(a, "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command}) else command;
            const result = try std.process.run(a, std.testing.io, .{ .argv = if (wrapped) &.{ "/bin/sh", "-c", script } else &.{ "/bin/sh", "-n", "-c", script } });
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        }
        self.calls += 1;
        if (self.fail == op) return .{ .code = 1 };
        switch (op) {
            .detect => return .{ .code = 0, .output = "ubuntu\n24.04\nx86_64\n" },
            .capacity => return .{ .code = 0, .output = "1000000 4096" },
            .health => return .{ .code = 0, .output = "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]}}" },
            .finalize => {
                self.dirty = false;
                return .{ .code = 0 };
            },
            .activate => {
                if (self.dirty or self.inactive) {
                    self.restarts += 1;
                    self.inactive = false;
                    return .{ .code = 0, .output = "changed" };
                }
                return .{ .code = 0, .output = "unchanged" };
            },
            else => {
                const index = @intFromEnum(op);
                if (self.present[index]) return .{ .code = 0, .output = "unchanged" };
                self.present[index] = true;
                if (op == .binary or op == .unit) self.dirty = true;
                return .{ .code = 0, .output = "changed" };
            },
        }
    }
};
test "install twice is no-op; changed unit restarts only affected service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var first: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &first);
    try std.testing.expect(first.changes > 0);
    var second: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &second);
    try std.testing.expectEqual(@as(usize, 0), second.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    fake.present[@intFromEnum(remote.Operation.unit)] = false;
    var third: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &third);
    try std.testing.expectEqual(@as(usize, 2), fake.restarts);
}
test "existing user/binary are unchanged; failure stops later steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .fail = .binary };
    fake.present[@intFromEnum(remote.Operation.user)] = true;
    var report: install.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &report));
    try std.testing.expectEqual(remote.Operation.binary, report.phase);
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.restarts);
}

test "interrupted activation preserves restart intent on no-op resource rerun" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .fail = .activate };
    var failed: install.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
    try std.testing.expect(fake.dirty);
    fake.fail = null;
    var recovered: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &recovered);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    try std.testing.expect(!fake.dirty);
    fake.inactive = true;
    var restarted: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &restarted);
    try std.testing.expectEqual(@as(usize, 2), fake.restarts);
}
test "failed health never finalizes a deployment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .fail = .health };
    var report: install.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &report));
    try std.testing.expect(fake.dirty);
    try std.testing.expectEqual(remote.Operation.health, report.phase);
}

test "every rendered remote shell fragment parses without executing mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .check_syntax = true };
    var report: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &report);
}
