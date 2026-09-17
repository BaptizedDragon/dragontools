//! Full controller ordering, composing core fixtures with the four new services.
//! This fake models remote state; it does not execute Linux services or probes.
const std = @import("std");
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
const readiness = @import("readiness.zig");
const probes = @import("probes.zig");
const Secret = @import("../secrets/secret.zig").Secret;
const extra = [_]workflow.Component{ .blackbox_exporter, .alertmanager, .vmalert_logs, .vmalert_metrics };
const operation_count = @typeInfo(remote.Operation).@"enum".fields.len;
const State = struct {
    present: [operation_count]bool = @splat(false),
    calls: [operation_count]usize = @splat(0),
    active: bool = false,
    pending: bool = false,
    restarts: usize = 0,
    downloads: usize = 0,
    config_writes: usize = 0,
    fail: ?readiness.Check = null,
    delayed: ?readiness.Check = null,
    attempts: usize = 0,
};
const Fake = struct {
    allocator: std.mem.Allocator,
    report: *workflow.Report,
    core: @import("tests.zig").Fake = .{},
    states: [4]State = @splat(.{}),
    now: i64 = 0,
    shared_binary: bool = false,
    scrape_digest: ?[32]u8 = null,
    scrape_pending: bool = false,
    scrape_writes: usize = 0,
    scrape_reloads: usize = 0,
    scrape_fail: bool = false,
    secret_bytes: ?[]const u8 = null,
    secret_writes: usize = 0,
    notify_calls: usize = 0,
    check_syntax: bool = false,

    fn state(self: *Fake, component: workflow.Component) *State {
        for (extra, 0..) |value, index| if (value == component) return &self.states[index];
        unreachable;
    }
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .execute_secret = secret, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
    }
    fn nowMs(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn sleepMs(ctx: *anyopaque, value: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.now += value;
    }
    fn secret(ctx: *anyopaque, op: remote.Operation, command: []const u8, payload: *const Secret, _: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(remote.Operation.credentials, op);
        try std.testing.expectEqual(workflow.Component.alertmanager, self.report.component.?);
        try std.testing.expect(std.mem.indexOf(u8, command, "PRIVATE-TELEGRAM") == null);
        const bytes = payload.protectedBytes();
        if (self.secret_bytes) |existing| if (std.mem.eql(u8, existing, bytes)) return .{ .code = 0, .output = "unchanged" };
        self.secret_bytes = try self.allocator.dupe(u8, bytes);
        self.secret_writes += 1;
        self.state(.alertmanager).pending = true;
        return .{ .code = 0, .output = "changed" };
    }
    fn scrape(self: *Fake, op: remote.Operation) !remote.Result {
        switch (op) {
            .config => {
                const config = try probes.renderScrape(self.allocator, self.report.probes);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(config, &digest, .{});
                if (self.scrape_digest) |old| if (std.mem.eql(u8, &old, &digest)) return .{ .code = 0, .output = "unchanged" };
                self.scrape_digest = digest;
                self.scrape_pending = true;
                self.scrape_writes += 1;
                return .{ .code = 0, .output = "changed" };
            },
            .activate => {
                if (!self.scrape_pending) return .{ .code = 0, .output = "unchanged" };
                self.scrape_reloads += 1;
                return .{ .code = 0, .output = "changed" };
            },
            .health => return .{ .code = if (self.scrape_fail and self.report.check == .probe_metrics_ready) 75 else 0 },
            .finalize => {
                self.scrape_pending = false;
                return .{ .code = 0 };
            },
            else => return error.UnexpectedScrapeOperation,
        }
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.check_syntax) {
            const wrapped = std.mem.startsWith(u8, command, "'sh' ");
            const script = if (wrapped) try std.fmt.allocPrint(self.allocator, "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command}) else command;
            const result = try std.process.run(self.allocator, std.testing.io, .{ .argv = if (wrapped) &.{ "/bin/sh", "-c", script } else &.{ "/bin/sh", "-n", "-c", script } });
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        }
        if (std.mem.indexOf(u8, command, "base64.b64decode(sys.argv.pop(1)") != null) return self.scrape(op);
        if (op == .detect) return self.core.asRemote().run(op, command);
        const component = self.report.component.?;
        if (@intFromEnum(component) < @intFromEnum(workflow.Component.blackbox_exporter)) return self.core.asRemote().run(op, command);
        const current = self.state(component);
        current.calls[@intFromEnum(op)] += 1;
        switch (op) {
            .notify_test => {
                self.notify_calls += 1;
                return .{ .code = 0 };
            },
            .health => {
                const check = self.report.check.?;
                if (current.fail == check) return .{ .code = 1 };
                if (current.delayed == check) {
                    current.attempts += 1;
                    if (current.attempts <= 2) return .{ .code = 75 };
                }
                try std.testing.expect(current.active);
                if (component == .blackbox_exporter) return .{ .code = 0, .output = switch (check) {
                    .http_ready => "Healthy",
                    .provisioning_ready => @import("blackbox_tests.zig").loaded_config,
                    .storage_ready => @import("blackbox_tests.zig").exporter_metrics,
                    else => "",
                } };
                if (component == .alertmanager and std.mem.indexOf(u8, command, " 'check' ") != null) return .{ .code = 0, .output = if (self.report.telegram_configured) "enabled" else "disabled" };
                return .{ .code = 0 };
            },
            .activate => {
                if (current.active and !current.pending) return .{ .code = 0, .output = "unchanged" };
                current.active = true;
                current.restarts += 1;
                return .{ .code = 0, .output = "changed" };
            },
            .finalize => {
                current.pending = false;
                return .{ .code = 0 };
            },
            .binary => if (component == .vmalert_logs or component == .vmalert_metrics) {
                if (self.shared_binary) return .{ .code = 0, .output = "unchanged" };
                self.shared_binary = true;
                self.state(.vmalert_logs).pending = true;
                self.state(.vmalert_metrics).pending = true;
                current.downloads += 1;
                return .{ .code = 0, .output = "changed" };
            },
            .config => if (std.mem.indexOf(u8, command, "dragontools-vmalert-dry-run") != null or std.mem.startsWith(u8, command, "runuser ")) return .{ .code = 0, .output = "unchanged" },
            else => {},
        }
        const index = @intFromEnum(op);
        if (current.present[index]) return .{ .code = 0, .output = "unchanged" };
        current.present[index] = true;
        if (op == .binary) current.downloads += 1;
        if (op == .config) current.config_writes += 1;
        if (op == .binary or op == .config or op == .unit) current.pending = true;
        return .{ .code = 0, .output = "changed" };
    }
};

const one = [_]probes.Probe{.{ .name = "landing", .url = "https://landing.example/health" }};
const two = [_]probes.Probe{ one[0], .{ .name = "orders", .url = "https://orders.example/health" } };

test "eight service station installs then remains unchanged while probe add remove only reload scraping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: workflow.Report = .{ .station_enabled = true, .probes = &one };
    var fake: Fake = .{ .allocator = a, .report = &report, .check_syntax = true };
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expect(report.changes > 0);
    try std.testing.expectEqual(@as(usize, 1), fake.scrape_writes);
    try std.testing.expect(!fake.scrape_pending);
    fake.check_syntax = false;
    for ([_][]const probes.Probe{ &one, &two, &one, &one }) |targets| {
        const before = fake.scrape_writes;
        report = .{ .station_enabled = true, .probes = targets };
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(if (fake.scrape_writes == before) @as(usize, 0) else @as(usize, 2), report.changes);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vl.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vt.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.gf.restarts);
        for (fake.states) |state| {
            try std.testing.expectEqual(@as(usize, 1), state.restarts);
            try std.testing.expectEqual(@as(usize, 1), state.config_writes);
            try std.testing.expect(!state.pending);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), fake.scrape_writes);
    try std.testing.expectEqual(@as(usize, 3), fake.scrape_reloads);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vmalert_logs).downloads + fake.state(.vmalert_metrics).downloads);
    try std.testing.expectEqual(@as(usize, 0), fake.notify_calls);
}

test "station preserves independent evaluator restart intent across failure and readonly verify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: workflow.Report = .{ .station_enabled = true, .probes = &one };
    var fake: Fake = .{ .allocator = a, .report = &report };
    fake.state(.vmalert_metrics).fail = .rules_ready;
    try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
    try std.testing.expectEqual(workflow.Component.vmalert_metrics, report.component.?);
    try std.testing.expect(fake.state(.vmalert_metrics).pending);
    try std.testing.expect(!fake.state(.vmalert_logs).pending);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmalert_metrics).calls[@intFromEnum(remote.Operation.finalize)]);
    try std.testing.expectEqual(@as(i64, 0), fake.now);
    fake.state(.vmalert_metrics).fail = null;
    report = .{ .station_enabled = true, .probes = &one };
    try @import("verify.zig").verify(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expect(fake.state(.vmalert_metrics).pending);
    report = .{ .station_enabled = true, .probes = &one };
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vmalert_metrics).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vmalert_logs).restarts);
    try std.testing.expect(!fake.state(.vmalert_metrics).pending);
    report.changes = 0;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@as(usize, 0), fake.notify_calls);
}

test "station delayed evaluator readiness finalizes and unchanged install reuses Telegram secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const credentials = try Secret.init(std.testing.allocator, "PRIVATE-TELEGRAM-test-payload");
    defer credentials.deinit();
    var report: workflow.Report = .{ .station_enabled = true, .probes = &one, .telegram_credentials = credentials, .telegram_configured = true };
    var fake: Fake = .{ .allocator = a, .report = &report };
    fake.state(.vmalert_metrics).delayed = .rules_ready;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 3), fake.state(.vmalert_metrics).attempts);
    try std.testing.expectEqual(@as(i64, 1500), fake.now);
    try std.testing.expect(!fake.state(.vmalert_metrics).pending);
    report.changes = 0;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.secret_writes);
    try std.testing.expectEqual(@as(usize, 0), fake.notify_calls);
    report.telegram_credentials = null;
    try @import("verify.zig").verify(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 1), fake.secret_writes);
    try std.testing.expectEqual(@as(usize, 0), fake.notify_calls);
    try @import("alertmanager.zig").notifyTest(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 1), fake.notify_calls);
}

test "broken blackbox or missing stored metrics fail station without finalizing their intent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: workflow.Report = .{ .station_enabled = true, .probes = &one };
    var fake: Fake = .{ .allocator = a, .report = &report };
    fake.state(.blackbox_exporter).fail = .http_ready;
    try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
    try std.testing.expectEqual(workflow.Component.blackbox_exporter, report.component.?);
    try std.testing.expect(fake.state(.blackbox_exporter).pending and fake.scrape_pending);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.alertmanager).restarts);
    fake.state(.blackbox_exporter).fail = null;
    fake.scrape_fail = true;
    report = .{ .station_enabled = true, .probes = &one };
    try std.testing.expectError(error.ReadinessTimedOut, workflow.install(a, fake.asRemote(), &report));
    try std.testing.expectEqual(readiness.Check.probe_metrics_ready, report.check.?);
    try std.testing.expect(fake.scrape_pending);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
    fake.scrape_fail = false;
    report = .{ .station_enabled = true, .probes = &one };
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expect(!fake.scrape_pending);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
    report.changes = 0;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
}
