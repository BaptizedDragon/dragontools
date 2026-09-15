const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const verify = @import("verify.zig");
const operation_count = @typeInfo(remote.Operation).@"enum".fields.len;
const vm_metrics = "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]}}";
const vl_metrics = "vl_storage_is_read_only{path=\"/var/lib/dragontools/victorialogs\"} 0\n";

// Separate concrete states model sequencing, not execution of Ubuntu commands.
const ComponentState = struct {
    present: [operation_count]bool = @splat(false),
    calls: [operation_count]usize = @splat(0),
    restarts: usize = 0,
    starts: usize = 0,
    enables: usize = 0,
    dirty: bool = false,
    inactive: bool = true,
    disabled: bool = true,
    fail: ?remote.Operation = null,
    health_output: ?[]const u8 = null,

    fn called(self: ComponentState, op: remote.Operation) usize {
        return self.calls[@intFromEnum(op)];
    }
};
const Fake = struct {
    vm: ComponentState = .{},
    vl: ComponentState = .{},
    calls: usize = 0,
    detections: usize = 0,
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
            // Intercept quoted sh wrappers and parse their inner scripts too.
            // No mutation runs: the inner shell always receives -n.
            const wrapped = std.mem.startsWith(u8, command, "'sh' ");
            const script = if (wrapped) try std.fmt.allocPrint(a, "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command}) else command;
            const result = try std.process.run(a, std.testing.io, .{ .argv = if (wrapped) &.{ "/bin/sh", "-c", script } else &.{ "/bin/sh", "-n", "-c", script } });
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        }
        self.calls += 1;
        if (op == .detect) {
            self.detections += 1;
            return .{ .code = 0, .output = "ubuntu\n24.04\nx86_64\n" };
        }
        const is_logs = std.mem.indexOf(u8, command, "victorialogs") != null;
        try std.testing.expect(is_logs or std.mem.indexOf(u8, command, "victoriametrics") != null);
        const state = if (is_logs) &self.vl else &self.vm;
        state.calls[@intFromEnum(op)] += 1;
        if (state.fail == op) return .{ .code = 1 };
        switch (op) {
            .detect => unreachable,
            .capacity => {
                try std.testing.expect(!is_logs);
                return .{ .code = 0, .output = "1000000 4096" };
            },
            .health => {
                if (state.inactive or state.disabled) return .{ .code = 1 };
                return .{ .code = 0, .output = state.health_output orelse if (is_logs) vl_metrics else vm_metrics };
            },
            .finalize => {
                state.dirty = false;
                return .{ .code = 0 };
            },
            .activate => {
                var changed = false;
                if (state.dirty) {
                    state.restarts += 1;
                    state.inactive = false;
                    changed = true;
                } else if (state.inactive) {
                    state.starts += 1;
                    state.inactive = false;
                    changed = true;
                }
                if (state.disabled) {
                    state.enables += 1;
                    state.disabled = false;
                    changed = true;
                }
                return .{ .code = 0, .output = if (changed) "changed" else "unchanged" };
            },
            else => {
                const index = @intFromEnum(op);
                if (state.present[index]) return .{ .code = 0, .output = "unchanged" };
                state.present[index] = true;
                if (op == .binary or op == .unit) state.dirty = true;
                return .{ .code = 0, .output = "changed" };
            },
        }
    }
};

fn initialInstall(a: std.mem.Allocator, fake: *Fake) !void {
    var first: install.Report = .{};
    try install.install(a, fake.asRemote(), &first);
    try std.testing.expect(first.changes > 0);
    try std.testing.expect(!fake.vm.dirty and !fake.vl.dirty);
}

test "both components install once and second run is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    try std.testing.expectEqual(@as(usize, 1), fake.detections);
    var second: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &second);
    try std.testing.expectEqual(@as(usize, 0), second.changes);
    for ([_]ComponentState{ fake.vm, fake.vl }) |state| {
        try std.testing.expectEqual(@as(usize, 1), state.restarts);
        try std.testing.expectEqual(@as(usize, 0), state.starts);
        try std.testing.expectEqual(@as(usize, 1), state.enables);
        try std.testing.expectEqual(@as(usize, 2), state.called(.health));
        try std.testing.expectEqual(@as(usize, 2), state.called(.finalize));
        try std.testing.expect(!state.dirty and !state.inactive and !state.disabled);
    }
    try std.testing.expectEqual(@as(usize, 2), fake.vm.called(.capacity));
    try std.testing.expectEqual(@as(usize, 0), fake.vl.called(.capacity));
}

test "changed VictoriaMetrics unit restarts only VictoriaMetrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    fake.vm.present[@intFromEnum(remote.Operation.unit)] = false;
    var report: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 2), fake.vm.restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.vl.restarts);
}

test "changed VictoriaLogs binary or unit restarts only VictoriaLogs" {
    for ([_]remote.Operation{ .binary, .unit }) |changed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        fake.vl.present[@intFromEnum(changed)] = false;
        var repair: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &repair);
        try std.testing.expectEqual(@as(usize, 2), repair.changes);
        try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
        try std.testing.expectEqual(@as(usize, 2), fake.vl.restarts);
        var stable: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &stable);
        try std.testing.expectEqual(@as(usize, 0), stable.changes);
        try std.testing.expectEqual(@as(usize, 2), fake.vl.restarts);
    }
}

test "inactive VictoriaLogs starts without rewriting or restarting unchanged resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    fake.vl.inactive = true;
    var report: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 1), report.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.vl.starts);
    try std.testing.expectEqual(@as(usize, 1), fake.vl.restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
}

test "disabled VictoriaLogs is enabled without restarting a healthy service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    fake.vl.disabled = true;
    var report: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 1), report.changes);
    try std.testing.expectEqual(@as(usize, 2), fake.vl.enables);
    try std.testing.expectEqual(@as(usize, 1), fake.vl.restarts);
    try std.testing.expectEqual(@as(usize, 0), fake.vl.starts);
    try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
}

test "existing VictoriaMetrics user remains unchanged and binary failure stops later components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    fake.vm.fail = .binary;
    fake.vm.present[@intFromEnum(remote.Operation.user)] = true;
    var report: install.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &report));
    try std.testing.expectEqual(remote.Operation.binary, report.phase);
    try std.testing.expectEqual(install.Component.victoriametrics, report.component.?);
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.vm.restarts);
    try std.testing.expectEqual(@as(usize, 0), fake.vl.called(.user));
}

test "failed VictoriaLogs binary stops its later steps and leaves VictoriaMetrics unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    fake.vl.present[@intFromEnum(remote.Operation.binary)] = false;
    fake.vl.fail = .binary;
    var report: install.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &report));
    try std.testing.expectEqual(remote.Operation.binary, report.phase);
    try std.testing.expectEqual(install.Component.victorialogs, report.component.?);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.vl.called(.unit));
    try std.testing.expectEqual(@as(usize, 1), fake.vl.called(.activate));
    try std.testing.expectEqual(@as(usize, 1), fake.vl.called(.health));
    try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
    try std.testing.expectEqual(@as(usize, 2), fake.vm.called(.health));
    try std.testing.expect(!fake.vm.dirty and !fake.vm.inactive);
}

test "interrupted activation retains each component restart marker and retry recovers" {
    for ([_]install.Component{ .victoriametrics, .victorialogs }) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        const affected = if (component == .victorialogs) &fake.vl else &fake.vm;
        affected.fail = .activate;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expect(affected.dirty);
        try std.testing.expectEqual(@as(usize, 0), affected.called(.health));
        try std.testing.expectEqual(@as(usize, 0), affected.called(.finalize));
        affected.fail = null;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.vl.restarts);
        try std.testing.expect(!fake.vm.dirty and !fake.vl.dirty);
    }
}

test "remote health failure never finalizes either component and retries preserve healthy peers" {
    for ([_]install.Component{ .victoriametrics, .victorialogs }) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        const affected = if (component == .victorialogs) &fake.vl else &fake.vm;
        affected.fail = .health;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(remote.Operation.health, failed.phase);
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expect(affected.dirty);
        try std.testing.expectEqual(@as(usize, 0), affected.called(.finalize));
        if (component == .victorialogs) try std.testing.expect(!fake.vm.dirty and !fake.vm.inactive);
        affected.fail = null;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try std.testing.expectEqual(@as(usize, 2), affected.restarts);
        try std.testing.expect(!affected.dirty);
        if (component == .victorialogs) try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
    }
}

test "invalid VictoriaLogs metrics and read-only storage prevent controller finalization" {
    const cases = .{
        .{ "ok", error.VictoriaLogsMetricMissing },
        .{ "vl_storage_is_read_only{path=\"/var/lib/dragontools/victorialogs\"} NaN\n", error.InvalidVictoriaLogsMetrics },
        .{ "vl_storage_is_read_only{path=\"/var/lib/dragontools/victorialogs\"} 1\n", error.VictoriaLogsReadOnly },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        fake.vl.health_output = case[0];
        var report: install.Report = .{};
        try std.testing.expectError(case[1], install.install(arena.allocator(), fake.asRemote(), &report));
        try std.testing.expectEqual(install.Component.victorialogs, report.component.?);
        try std.testing.expectEqual(remote.Operation.health, report.phase);
        try std.testing.expect(fake.vl.dirty);
        try std.testing.expectEqual(@as(usize, 0), fake.vl.called(.finalize));
        try std.testing.expectEqual(@as(usize, 1), fake.vm.called(.finalize));
        try std.testing.expect(!fake.vm.dirty and !fake.vm.inactive);
        fake.vl.health_output = null;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try std.testing.expect(!fake.vl.dirty);
        try std.testing.expectEqual(@as(usize, 1), fake.vm.restarts);
        try std.testing.expectEqual(@as(usize, 2), fake.vl.restarts);
    }
}

test "verify checks both components without mutation and fails on unhealthy VictoriaLogs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    var report: install.Report = .{};
    try verify.verify(arena.allocator(), fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    for ([_]ComponentState{ fake.vm, fake.vl }) |state| {
        try std.testing.expectEqual(@as(usize, 2), state.called(.health));
        try std.testing.expectEqual(@as(usize, 1), state.called(.activate));
        try std.testing.expectEqual(@as(usize, 1), state.called(.finalize));
    }
    fake.vl.health_output = "vl_storage_is_read_only{path=\"/var/lib/dragontools/victorialogs\"} 1\n";
    var failed: install.Report = .{};
    try std.testing.expectError(error.VictoriaLogsReadOnly, verify.verify(arena.allocator(), fake.asRemote(), &failed));
    try std.testing.expectEqual(install.Component.victorialogs, failed.component.?);
    try std.testing.expectEqual(remote.Operation.health, failed.phase);
    try std.testing.expectEqual(@as(usize, 1), fake.vl.called(.finalize));
}

test "every rendered remote shell fragment parses without executing mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .check_syntax = true };
    var report: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &report);
}
