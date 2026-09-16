const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const verify = @import("verify.zig");
const readiness = @import("readiness.zig");
const operation_count = @typeInfo(remote.Operation).@"enum".fields.len;
const check_count = @typeInfo(readiness.Check).@"enum".fields.len;
const components = [_]install.Component{ .victoriametrics, .victorialogs, .victoriatraces, .grafana };
const vm_metrics = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]}}";
const empty_vm_metrics = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[]}}";
const vl_metrics = "vl_storage_is_read_only{path=\"/var/lib/dragontools/victorialogs\"} 0\n";
const vt_metrics = "vt_storage_is_read_only{path=\"/var/lib/dragontools/victoriatraces\"} 0\n";

// Four concrete states exercise the control flow, not Linux shell execution.
// Mutations can complete before a simulated failure so retries cannot rely on
// the previous controller result. Real systemd/filesystem behavior needs a VM.
const ComponentState = struct {
    present: [operation_count]bool = @splat(false),
    calls: [operation_count]usize = @splat(0),
    writes: [operation_count]usize = @splat(0),
    metadata_drift: ?remote.Operation = null,
    restarts: usize = 0,
    starts: usize = 0,
    enables: usize = 0,
    reloads: usize = 0,
    downloads: usize = 0,
    dirty: bool = false,
    stale_unit: bool = false,
    loaded: bool = false,
    inactive: bool = true,
    disabled: bool = true,
    runtime_enabled: bool = false,
    fail: ?remote.Operation = null,
    fail_after: ?remote.Operation = null,
    fail_after_reload: bool = false,
    fail_after_enable: bool = false,
    failure_code: u8 = 1,
    health_output: ?[]const u8 = null,
    check_calls: [check_count]usize = @splat(0),
    not_ready: [check_count]usize = @splat(0),
    fail_check: ?readiness.Check = null,
    empty_self_scrapes: usize = 0,

    fn called(self: ComponentState, op: remote.Operation) usize {
        return self.calls[@intFromEnum(op)];
    }
    fn checked(self: ComponentState, check: readiness.Check) usize {
        return self.check_calls[@intFromEnum(check)];
    }
};
const Fake = struct {
    vm: ComponentState = .{},
    vl: ComponentState = .{},
    vt: ComponentState = .{},
    gf: ComponentState = .{},
    calls: usize = 0,
    detections: usize = 0,
    check_syntax: bool = false,
    // systemd 255 invalidates NeedDaemonReload globally after EnableUnitFiles.
    enable_state_outdated: bool = false,
    now_ms: i64 = 0,
    sleeps: [512]u32 = @splat(0),
    sleep_count: usize = 0,

    fn state(self: *Fake, component: install.Component) *ComponentState {
        return switch (component) {
            .victoriametrics => &self.vm,
            .victorialogs => &self.vl,
            .victoriatraces => &self.vt,
            .grafana => &self.gf,
        };
    }
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .clock = .{ .context = self, .now_ms = now, .sleep_ms = sleep } };
    }
    fn now(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now_ms;
    }
    fn sleep(ctx: *anyopaque, duration_ms: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expect(self.sleep_count < self.sleeps.len);
        self.sleeps[self.sleep_count] = duration_ms;
        self.sleep_count += 1;
        self.now_ms += duration_ms;
    }
    fn checkFor(command: []const u8) !readiness.Check {
        inline for (@typeInfo(readiness.Check).@"enum".fields) |field| {
            if (std.mem.indexOf(u8, command, "-" ++ field.name) != null) return @enumFromInt(field.value);
        }
        return error.MissingVerificationCheck;
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.check_syntax) {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            // The outer shell intercepts quoted sh wrappers; the inner shell
            // always has -n. No rendered mutation is executed by this test.
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
        const component: install.Component = if (std.mem.indexOf(u8, command, "grafana") != null)
            .grafana
        else if (std.mem.indexOf(u8, command, "victoriatraces") != null)
            .victoriatraces
        else if (std.mem.indexOf(u8, command, "victorialogs") != null)
            .victorialogs
        else if (std.mem.indexOf(u8, command, "victoriametrics") != null)
            .victoriametrics
        else
            return error.MissingComponentContext;
        const current = self.state(component);
        current.calls[@intFromEnum(op)] += 1;
        if (current.fail == op) return .{ .code = current.failure_code };
        var changed = false;
        switch (op) {
            .detect => unreachable,
            .capacity => {
                try std.testing.expectEqual(install.Component.victoriametrics, component);
                return .{ .code = 0, .output = "1000000 4096" };
            },
            .health => {
                const check = try checkFor(command);
                const index = @intFromEnum(check);
                current.check_calls[index] += 1;
                if (current.inactive or current.disabled or current.runtime_enabled or !current.loaded or current.stale_unit or self.enable_state_outdated) return .{ .code = 1 };
                if (current.fail_check == check) return .{ .code = 1 };
                if (current.not_ready[index] > 0) {
                    current.not_ready[index] -= 1;
                    return .{ .code = 75 };
                }
                if (check == .self_scrape_ready and current.empty_self_scrapes > 0) {
                    current.empty_self_scrapes -= 1;
                    return .{ .code = 0, .output = empty_vm_metrics };
                }
                const has_payload = switch (component) {
                    .victoriametrics => check == .self_scrape_ready,
                    .victorialogs, .victoriatraces => check == .storage_ready,
                    .grafana => check == .http_ready or check == .backend_ready,
                };
                return .{ .code = 0, .output = if (has_payload) current.health_output orelse switch (component) {
                    .victoriametrics => vm_metrics,
                    .victorialogs => vl_metrics,
                    .victoriatraces => vt_metrics,
                    .grafana => @import("grafana_verify.zig").healthy_fixture,
                } else "" };
            },
            .finalize => {
                current.dirty = false;
                return .{ .code = 0 };
            },
            .activate => {
                if (current.disabled or current.runtime_enabled) {
                    current.enables += 1;
                    current.disabled = false;
                    current.runtime_enabled = false;
                    self.enable_state_outdated = true;
                    changed = true;
                    if (current.fail_after_enable) return .{ .code = 1 };
                }
                if (current.stale_unit or !current.loaded or self.enable_state_outdated) {
                    current.reloads += 1;
                    for (components) |loaded_component| {
                        const loaded_state = self.state(loaded_component);
                        loaded_state.stale_unit = false;
                        loaded_state.loaded = loaded_state.present[@intFromEnum(remote.Operation.unit)];
                    }
                    self.enable_state_outdated = false;
                    changed = true;
                    if (current.fail_after_reload) return .{ .code = 1 };
                }
                if (current.dirty) {
                    current.restarts += 1;
                    current.inactive = false;
                    changed = true;
                } else if (current.inactive) {
                    current.starts += 1;
                    current.inactive = false;
                    changed = true;
                }
            },
            else => {
                const index = @intFromEnum(op);
                if (current.present[index]) {
                    if (current.metadata_drift != op) return .{ .code = 0, .output = "unchanged" };
                    current.metadata_drift = null;
                } else {
                    current.present[index] = true;
                    if (op == .binary) {
                        current.dirty = true;
                        current.downloads += 1;
                    }
                    if (op == .config or op == .provisioning) current.dirty = true;
                    if (op == .unit) {
                        current.dirty = true;
                        current.stale_unit = true;
                    }
                }
                current.writes[index] += 1;
                changed = true;
            },
        }
        if (current.fail_after == op) return .{ .code = 1 };
        return .{ .code = 0, .output = if (changed) "changed" else "unchanged" };
    }
};

fn initialInstall(a: std.mem.Allocator, fake: *Fake) !void {
    var first: install.Report = .{};
    try install.install(a, fake.asRemote(), &first);
    try std.testing.expect(first.changes > 0);
    for (components) |component| {
        const current = fake.state(component);
        try std.testing.expect(!current.dirty and !current.inactive and !current.disabled);
    }
}
fn expectRestarts(fake: *Fake, affected: ?install.Component, affected_count: usize) !void {
    for (components) |component| {
        const expected: usize = if (component == affected) affected_count else 1;
        try std.testing.expectEqual(expected, fake.state(component).restarts);
    }
}

test "all four components converge once and inspect without mutation on a second run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    try initialInstall(arena.allocator(), &fake);
    try std.testing.expectEqual(@as(usize, 1), fake.detections);
    var second: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &second);
    try std.testing.expectEqual(@as(usize, 0), second.changes);
    for (components) |component| {
        const current = fake.state(component);
        try std.testing.expectEqual(@as(usize, 1), current.restarts);
        try std.testing.expectEqual(@as(usize, 0), current.starts);
        try std.testing.expectEqual(@as(usize, 1), current.enables);
        try std.testing.expectEqual(@as(usize, 1), current.reloads);
        try std.testing.expectEqual(@as(usize, 1), current.downloads);
        for ([_]remote.Operation{ .user, .directories, .binary, .unit }) |op| {
            try std.testing.expectEqual(@as(usize, 1), current.writes[@intFromEnum(op)]);
        }
        try std.testing.expectEqual(@as(usize, 2), current.checked(.managed_state));
        try std.testing.expectEqual(@as(usize, 2), current.checked(.http_ready));
        try std.testing.expect(!current.dirty);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.sleep_count);
    try std.testing.expectEqual(@as(usize, 2), fake.vm.called(.capacity));
    try std.testing.expectEqual(@as(usize, 0), fake.vl.called(.capacity));
    try std.testing.expectEqual(@as(usize, 0), fake.vt.called(.capacity));
    try std.testing.expectEqual(@as(usize, 0), fake.gf.called(.capacity));
    for ([_]remote.Operation{ .config, .provisioning }) |op| {
        try std.testing.expectEqual(@as(usize, 1), fake.gf.writes[@intFromEnum(op)]);
        try std.testing.expectEqual(@as(usize, 2), fake.gf.called(op));
        try std.testing.expectEqual(@as(usize, 0), fake.vm.called(op) + fake.vl.called(op) + fake.vt.called(op));
    }
}

test "each component retries two transient HTTP failures then finalizes and remains unchanged" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        const current = fake.state(component);
        current.not_ready[@intFromEnum(readiness.Check.http_ready)] = 2;
        try initialInstall(arena.allocator(), &fake);
        try std.testing.expectEqual(@as(usize, 3), current.checked(.http_ready));
        try std.testing.expectEqual(@as(usize, 1), current.checked(.managed_state));
        try std.testing.expectEqualSlices(u32, &.{ 500, 1000 }, fake.sleeps[0..fake.sleep_count]);
        try std.testing.expectEqual(@as(i64, 1500), fake.now_ms);
        try std.testing.expect(!current.dirty);
        try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
        var unchanged: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &unchanged);
        try std.testing.expectEqual(@as(usize, 0), unchanged.changes);
        try std.testing.expectEqual(@as(usize, 4), current.checked(.http_ready));
        try std.testing.expectEqual(@as(usize, 2), fake.sleep_count);
        try expectRestarts(&fake, null, 1);
        for (components) |checked_component| {
            try std.testing.expectEqual(@as(usize, 1), fake.state(checked_component).downloads);
        }
    }
}

test "VictoriaMetrics waits across the configured self-scrape interval for stored telemetry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    // Probes at 0, 0.5, 1.5, ... 14.5 seconds find an empty query result.
    // The first probe after the 15-second self-scrape can see vm_app_version.
    fake.vm.empty_self_scrapes = 16;
    try initialInstall(arena.allocator(), &fake);
    try std.testing.expectEqual(@as(usize, 17), fake.vm.checked(.self_scrape_ready));
    try std.testing.expectEqual(@as(usize, 1), fake.vm.checked(.http_ready));
    try std.testing.expectEqual(@as(i64, 15500), fake.now_ms);
    try std.testing.expectEqual(@as(u32, 500), fake.sleeps[0]);
    for (fake.sleeps[1..fake.sleep_count]) |duration| try std.testing.expectEqual(@as(u32, 1000), duration);
    try std.testing.expectEqual(@as(usize, 1), fake.vm.called(.finalize));
    try std.testing.expect(!fake.vm.dirty);
    var unchanged: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &unchanged);
    try std.testing.expectEqual(@as(usize, 0), unchanged.changes);
    try std.testing.expectEqual(@as(usize, 16), fake.sleep_count);
    try expectRestarts(&fake, null, 1);
}

fn telemetryCheck(component: install.Component) readiness.Check {
    return switch (component) {
        .victoriametrics => .self_scrape_ready,
        .victorialogs, .victoriatraces => .storage_ready,
        .grafana => .provisioning_ready,
    };
}

test "readiness deadlines fail with semantic checks and preserve each component restart intent" {
    for (components) |component| {
        for ([_]readiness.Check{ .service_active, .http_ready, telemetryCheck(component) }) |check| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            const current = fake.state(component);
            current.not_ready[@intFromEnum(check)] = std.math.maxInt(usize);
            var failed: install.Report = .{};
            try std.testing.expectError(error.ReadinessTimedOut, install.install(arena.allocator(), fake.asRemote(), &failed));
            try std.testing.expectEqual(component, failed.component.?);
            try std.testing.expectEqual(remote.Operation.health, failed.phase);
            try std.testing.expectEqual(check, failed.check.?);
            try std.testing.expectEqual(@as(i64, switch (check) {
                .service_active => 15000,
                .http_ready => 30000,
                else => 45000,
            }), fake.now_ms);
            try std.testing.expect(current.checked(check) > 1);
            try std.testing.expect(current.dirty);
            try std.testing.expectEqual(@as(usize, 0), current.called(.finalize));
            // The next install inspects the persisted marker, recovers, then
            // finalizes; no artifact is downloaded a second time.
            current.not_ready[@intFromEnum(check)] = 0;
            var recovered: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &recovered);
            try std.testing.expect(!current.dirty);
            try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
            try std.testing.expectEqual(@as(usize, 1), current.downloads);
            try expectRestarts(&fake, component, 2);
            var unchanged: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &unchanged);
            try std.testing.expectEqual(@as(usize, 0), unchanged.changes);
            try expectRestarts(&fake, component, 2);
        }
    }
}

test "deterministic verification failures are attempted once without readiness waits" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        const current = fake.state(component);
        current.fail_check = .managed_state;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expectEqual(readiness.Check.managed_state, failed.check.?);
        try std.testing.expectEqual(@as(usize, 1), current.checked(.managed_state));
        try std.testing.expectEqual(@as(usize, 0), current.checked(.service_active));
        try std.testing.expectEqual(@as(usize, 0), fake.sleep_count);
        try std.testing.expect(current.dirty);
        try std.testing.expectEqual(@as(usize, 0), current.called(.finalize));
    }
}

test "runtime identity failures stop a readiness stage immediately rather than retrying" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        const current = fake.state(component);
        // Runtime stages recheck process identity and listener policy; their
        // ordinary nonzero failures must not be treated like exit 75 readiness.
        current.fail_check = .http_ready;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(readiness.Check.http_ready, failed.check.?);
        try std.testing.expectEqual(@as(usize, 1), current.checked(.http_ready));
        try std.testing.expectEqual(@as(usize, 0), fake.sleep_count);
        try std.testing.expect(current.dirty);
        try std.testing.expectEqual(@as(usize, 0), current.called(.finalize));
    }
}

test "standalone verification retries readiness without mutating or clearing restart intent" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        const current = fake.state(component);
        current.dirty = true;
        current.not_ready[@intFromEnum(readiness.Check.http_ready)] = 2;
        var checked: install.Report = .{};
        try verify.verify(arena.allocator(), fake.asRemote(), &checked);
        try std.testing.expectEqual(@as(usize, 0), checked.changes);
        try std.testing.expect(current.dirty);
        try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
        try std.testing.expectEqual(@as(usize, 1), current.called(.activate));
        try std.testing.expectEqual(@as(usize, 4), current.checked(.http_ready));
        try std.testing.expectEqualSlices(u32, &.{ 500, 1000 }, fake.sleeps[0..fake.sleep_count]);
        try expectRestarts(&fake, null, 1);
    }
}

test "Grafana configuration and provisioning changes restart only Grafana without daemon reload" {
    for ([_]remote.Operation{ .config, .provisioning }) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        fake.gf.present[@intFromEnum(op)] = false;
        var repaired: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &repaired);
        try std.testing.expectEqual(@as(usize, 2), repaired.changes);
        try expectRestarts(&fake, .grafana, 2);
        try std.testing.expectEqual(@as(usize, 1), fake.gf.reloads);
        try std.testing.expectEqual(@as(usize, 1), fake.gf.downloads);
        var unchanged: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &unchanged);
        try std.testing.expectEqual(@as(usize, 0), unchanged.changes);
        try expectRestarts(&fake, .grafana, 2);
    }
}

test "interrupted Grafana config writes preserve restart intent through failed verification and retry" {
    for ([_]remote.Operation{ .config, .provisioning }) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        fake.gf.present[@intFromEnum(op)] = false;
        fake.gf.fail_after = op;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(install.Component.grafana, failed.component.?);
        try std.testing.expectEqual(op, failed.phase);
        try std.testing.expect(fake.gf.dirty);
        try expectRestarts(&fake, null, 1);
        fake.gf.fail_after = null;
        fake.gf.fail = .health;
        var failed_health: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed_health));
        try std.testing.expect(fake.gf.dirty);
        try std.testing.expectEqual(@as(usize, 1), fake.gf.called(.finalize));
        fake.gf.fail = null;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try expectRestarts(&fake, .grafana, 3);
        try std.testing.expect(!fake.gf.dirty);
        try std.testing.expectEqual(@as(usize, 2), fake.gf.writes[@intFromEnum(op)]);
        var unchanged: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &unchanged);
        try std.testing.expectEqual(@as(usize, 0), unchanged.changes);
        try expectRestarts(&fake, .grafana, 3);
    }
}

test "Grafana config metadata repairs do not restart services or download artifacts" {
    for ([_]remote.Operation{ .config, .provisioning }) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        fake.gf.metadata_drift = op;
        var repaired: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &repaired);
        try std.testing.expectEqual(@as(usize, 1), repaired.changes);
        try expectRestarts(&fake, null, 1);
        try std.testing.expectEqual(@as(usize, 1), fake.gf.downloads);
        try std.testing.expectEqual(@as(usize, 1), fake.gf.reloads);
    }
}

test "binary and unit changes restart only their component and reload only changed units" {
    for (components) |component| {
        for ([_]remote.Operation{ .binary, .unit }) |changed| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            try initialInstall(arena.allocator(), &fake);
            const current = fake.state(component);
            current.present[@intFromEnum(changed)] = false;
            var repair: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &repair);
            try std.testing.expectEqual(@as(usize, 2), repair.changes);
            try expectRestarts(&fake, component, 2);
            try std.testing.expectEqual(@as(usize, if (changed == .unit) 2 else 1), current.reloads);
            var stable: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &stable);
            try std.testing.expectEqual(@as(usize, 0), stable.changes);
            try expectRestarts(&fake, component, 2);
        }
    }
}

test "inactive services start and disabled services enable with only a required reload" {
    for (components) |component| {
        for ([_]bool{ false, true }) |disable| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            try initialInstall(arena.allocator(), &fake);
            const current = fake.state(component);
            if (disable) current.disabled = true else current.inactive = true;
            var report: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &report);
            try std.testing.expectEqual(@as(usize, 1), report.changes);
            try expectRestarts(&fake, null, 1);
            try std.testing.expectEqual(@as(usize, if (disable) 0 else 1), current.starts);
            try std.testing.expectEqual(@as(usize, if (disable) 2 else 1), current.enables);
            try std.testing.expectEqual(@as(usize, if (disable) 2 else 1), current.reloads);
        }
    }
}

test "metadata-only repair does not redownload or restart matching binaries and units" {
    for (components) |component| {
        for ([_]remote.Operation{ .directories, .binary, .unit }) |op| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            try initialInstall(arena.allocator(), &fake);
            const current = fake.state(component);
            current.metadata_drift = op;
            var report: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &report);
            try std.testing.expectEqual(@as(usize, 1), report.changes);
            try expectRestarts(&fake, null, 1);
            try std.testing.expectEqual(@as(usize, 1), current.downloads);
            try std.testing.expectEqual(@as(usize, 1), current.reloads);
        }
    }
}

test "runtime-only enablement converges to persistent enabled state without restart" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        const current = fake.state(component);
        current.runtime_enabled = true;
        var report: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 1), report.changes);
        try std.testing.expectEqual(@as(usize, 2), current.enables);
        try std.testing.expectEqual(@as(usize, 2), current.reloads);
        try std.testing.expect(!current.runtime_enabled);
        try expectRestarts(&fake, null, 1);
    }
}

test "interrupted binary mutation leaves observable bytes and marker for retry without redownload" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        const current = fake.state(component);
        current.present[@intFromEnum(remote.Operation.binary)] = false;
        current.fail_after = .binary;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expectEqual(remote.Operation.binary, failed.phase);
        try std.testing.expect(current.present[@intFromEnum(remote.Operation.binary)] and current.dirty);
        try std.testing.expectEqual(@as(usize, 1), current.called(.unit));
        current.fail_after = null;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try std.testing.expectEqual(@as(usize, 1), recovered.changes);
        try std.testing.expectEqual(@as(usize, 2), current.downloads);
        try std.testing.expectEqual(@as(usize, 1), current.reloads);
        try expectRestarts(&fake, component, 2);
        try std.testing.expect(!current.dirty);
    }
}

test "interrupted unit mutation reloads once while interrupted reload resumes with only restart" {
    for (components) |component| {
        for ([_]bool{ false, true }) |after_reload| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            try initialInstall(arena.allocator(), &fake);
            const current = fake.state(component);
            current.present[@intFromEnum(remote.Operation.unit)] = false;
            if (after_reload) current.fail_after_reload = true else current.fail_after = .unit;
            var failed: install.Report = .{};
            try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
            try std.testing.expect(current.dirty);
            try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
            current.fail_after = null;
            current.fail_after_reload = false;
            var recovered: install.Report = .{};
            try install.install(arena.allocator(), fake.asRemote(), &recovered);
            try std.testing.expectEqual(@as(usize, 2), current.reloads);
            try expectRestarts(&fake, component, 2);
            try std.testing.expect(!current.dirty);
        }
    }
}

test "stale loaded unit state reloads without inventing component restart intent" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        const current = fake.state(component);
        current.stale_unit = true;
        var report: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 1), report.changes);
        try std.testing.expectEqual(@as(usize, 2), current.reloads);
        try expectRestarts(&fake, null, 1);
        try std.testing.expect(!current.dirty);
    }
}

test "interrupted enable recovers global reload state without restarting any component" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        const current = fake.state(component);
        current.disabled = true;
        current.fail_after_enable = true;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expect(!current.disabled and !current.dirty and fake.enable_state_outdated);
        try expectRestarts(&fake, null, 1);
        current.fail_after_enable = false;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try std.testing.expectEqual(@as(usize, 1), recovered.changes);
        try std.testing.expectEqual(@as(usize, 2), current.enables);
        try std.testing.expectEqual(@as(usize, 5), fake.vm.reloads + fake.vl.reloads + fake.vt.reloads + fake.gf.reloads);
        try std.testing.expect(!fake.enable_state_outdated);
        try expectRestarts(&fake, null, 1);
        var stable: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &stable);
        try std.testing.expectEqual(@as(usize, 0), stable.changes);
    }
}

test "failed health retains each component marker until successful retry" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        const current = fake.state(component);
        current.present[@intFromEnum(remote.Operation.binary)] = false;
        current.fail = .health;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expectEqual(remote.Operation.health, failed.phase);
        try std.testing.expect(current.dirty);
        try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
        current.fail = null;
        var recovered: install.Report = .{};
        try install.install(arena.allocator(), fake.asRemote(), &recovered);
        try expectRestarts(&fake, component, 3);
        try std.testing.expectEqual(@as(usize, 1), current.reloads);
        try std.testing.expect(!current.dirty);
    }
}

test "binary or activation failure stops later phases and preserves other components" {
    for (components) |component| {
        for ([_]remote.Operation{ .binary, .activate }) |op| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            try initialInstall(arena.allocator(), &fake);
            const current = fake.state(component);
            current.present[@intFromEnum(remote.Operation.binary)] = false;
            current.fail = op;
            var failed: install.Report = .{};
            try std.testing.expectError(error.RemoteOperationFailed, install.install(arena.allocator(), fake.asRemote(), &failed));
            try std.testing.expectEqual(component, failed.component.?);
            try std.testing.expectEqual(op, failed.phase);
            try std.testing.expectEqual(@as(usize, 1), current.checked(.managed_state));
            try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
            try expectRestarts(&fake, null, 1);
            if (op == .activate) try std.testing.expect(current.dirty);
        }
    }
}

test "conflicting users and unexpected directory symlinks fail explicitly before later phases" {
    for (components) |component| {
        for ([_]remote.Operation{ .user, .directories }) |op| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var fake: Fake = .{};
            try initialInstall(arena.allocator(), &fake);
            const current = fake.state(component);
            current.fail = op;
            current.failure_code = if (op == .user) 41 else 43;
            var failed: install.Report = .{};
            const expected = if (op == .user) error.ServiceAccountConflict else error.UnexpectedManagedSymlink;
            try std.testing.expectError(expected, install.install(arena.allocator(), fake.asRemote(), &failed));
            try std.testing.expectEqual(component, failed.component.?);
            try std.testing.expectEqual(@as(usize, 1), current.called(.binary));
            try std.testing.expectEqual(@as(usize, 0), failed.changes);
        }
    }
}

test "controller rejection of invalid application metrics prevents finalization" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        const current = fake.state(component);
        current.health_output = switch (component) {
            .victoriametrics, .grafana => "not application metrics",
            .victorialogs => "vl_storage_is_read_only{path=\"/var/lib/dragontools/victorialogs\"} invalid\n",
            .victoriatraces => "vt_storage_is_read_only{path=\"/var/lib/dragontools/victoriatraces\"} invalid\n",
        };
        var report: install.Report = .{};
        const result = install.install(arena.allocator(), fake.asRemote(), &report);
        try std.testing.expectError(switch (component) {
            .victoriametrics => error.InvalidHealthResponse,
            .victorialogs => error.InvalidVictoriaLogsMetrics,
            .victoriatraces => error.InvalidVictoriaTracesMetrics,
            .grafana => error.InvalidGrafanaHealthResponse,
        }, result);
        try std.testing.expectEqual(component, report.component.?);
        try std.testing.expectEqual(remote.Operation.health, report.phase);
        try std.testing.expect(current.dirty);
        try std.testing.expectEqual(@as(usize, 0), current.called(.finalize));
        try std.testing.expectEqual(@as(usize, 0), fake.sleep_count);
    }
}

test "verify checks all four without mutation and fails on any unhealthy component" {
    for (components) |component| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fake: Fake = .{};
        try initialInstall(arena.allocator(), &fake);
        var report: install.Report = .{};
        try verify.verify(arena.allocator(), fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 0), report.changes);
        for (components) |checked| {
            const current = fake.state(checked);
            try std.testing.expectEqual(@as(usize, 2), current.checked(.managed_state));
            try std.testing.expectEqual(@as(usize, 2), current.checked(.http_ready));
            try std.testing.expectEqual(@as(usize, 1), current.called(.activate));
            try std.testing.expectEqual(@as(usize, 1), current.called(.finalize));
        }
        fake.state(component).fail = .health;
        var failed: install.Report = .{};
        try std.testing.expectError(error.RemoteOperationFailed, verify.verify(arena.allocator(), fake.asRemote(), &failed));
        try std.testing.expectEqual(component, failed.component.?);
        try std.testing.expectEqual(remote.Operation.health, failed.phase);
        try expectRestarts(&fake, null, 1);
    }
}

test "every rendered remote shell fragment parses without executing mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .check_syntax = true };
    var report: install.Report = .{};
    try install.install(arena.allocator(), fake.asRemote(), &report);
}

test "rendered activation shell orders enable reload and isolated restart using safe command substitutes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ install.activate, install.activate_victorialogs, install.activate_victoriatraces, install.activate_grafana }) |activation| {
        // Execute only activation, with a private temporary marker path and
        // shell functions replacing systemctl/stat. This checks shell ordering,
        // not actual systemd behavior or privileged filesystem installation.
        const body = try std.mem.replaceOwned(u8, a, activation, "/var/lib/dragontools/", "$DRAGONTOOLS_TEST_TMP/");
        const script = try std.fmt.allocPrint(a,
            \\set -eu
            \\DRAGONTOOLS_TEST_TMP=$(mktemp -d "${{TMPDIR:-/tmp}}/dragontools-activation.XXXXXX")
            \\trap 'rm -rf "$DRAGONTOOLS_TEST_TMP"' EXIT
            \\stat() {{ test "$1" = -c; printf 0:0; }}
            \\systemctl() {{
            \\  case "$1" in
            \\    is-enabled) case "$enabled" in yes) printf enabled;; runtime) printf enabled-runtime;; no) printf disabled; return 1;; *) return 99;; esac ;;
            \\    is-active) test "$active" = yes ;;
            \\    enable) test "$2" = --no-reload; enabled=yes; reload=yes; calls="$calls enable" ;;
            \\    daemon-reload) reload=no; loaded=loaded; calls="$calls reload" ;;
            \\    restart) test "$reload" = no; active=yes; calls="$calls restart" ;;
            \\    start) test "$reload" = no; active=yes; calls="$calls start" ;;
            \\    show) case "$3" in NeedDaemonReload) printf '%s' "$reload";; LoadState) printf '%s' "$loaded";; *) return 99;; esac ;;
            \\    *) return 99 ;;
            \\  esac
            \\}}
            \\activation() {{
            \\{s}
            \\}}
            \\enabled=yes; active=yes; reload=no; loaded=loaded; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$(cat "$DRAGONTOOLS_TEST_TMP/output")" = unchanged
            \\test -z "$calls"
            \\enabled=no; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$(cat "$DRAGONTOOLS_TEST_TMP/output")" = changed
            \\test "$calls" = ' enable reload'
            \\test ! -e "$pending"
            \\enabled=runtime; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$calls" = ' enable reload'
            \\test ! -e "$pending"
            \\reload=yes; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$calls" = ' reload'
            \\test ! -e "$pending"
            \\: > "$pending"; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$calls" = ' restart'
            \\test -f "$pending"
            \\reload=yes; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$calls" = ' reload restart'
            \\rm "$pending"
            \\active=no; calls=''
            \\activation > "$DRAGONTOOLS_TEST_TMP/output"
            \\test "$calls" = ' start'
        , .{body});
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
}
