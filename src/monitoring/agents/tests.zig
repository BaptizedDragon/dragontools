//! Controller-state fixtures are not Linux/systemd or two-host integration.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const model = @import("model.zig");
const install = @import("install.zig");
const verify = @import("verify.zig");
const readiness = @import("../readiness.zig");
const Secret = @import("../../secrets/secret.zig").Secret;
const operations = @typeInfo(remote.Operation).@"enum".fields.len;
const State = struct {
    commands: [operations]?[]const u8 = @splat(null),
    pending: bool = false,
    active: bool = false,
    restarts: usize = 0,
    downloads: usize = 0,
    secret_writes: usize = 0,
};
const Fake = struct {
    allocator: std.mem.Allocator,
    report: *model.Report,
    states: [8]State = @splat(.{}),
    now: i64 = 0,
    delayed: ?readiness.Check = null,
    fail: ?readiness.Check = null,
    attempts: usize = 0,
    mutations: usize = 0,
    secret_reads: usize = 0,
    timeout: bool = false,
    station_unreachable: bool = false,
    fail_vector_binary: bool = false,
    ingestion_directory: bool = false,
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .execute_secret = secret, .read_secret = readSecret, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
    }
    fn state(self: *Fake, component: model.Component) *State {
        return &self.states[@intFromEnum(component)];
    }
    fn nowMs(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn sleepMs(ctx: *anyopaque, delay: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.now += delay;
    }
    fn readSecret(ctx: *anyopaque, _: []const u8, _: u32) !*Secret {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.secret_reads += 1;
        return Secret.init(std.testing.allocator, "PRIVATE-CERTIFICATE-SENTINEL");
    }
    fn secret(ctx: *anyopaque, op: remote.Operation, command: []const u8, payload: *const Secret, _: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(remote.Operation.credentials, op);
        try std.testing.expectEqualStrings("PRIVATE-CERTIFICATE-SENTINEL", payload.protectedBytes());
        try std.testing.expect(std.mem.indexOf(u8, command, payload.protectedBytes()) == null);
        const current = self.state(self.report.component);
        if (current.secret_writes != 0) return .{ .code = 0, .output = "unchanged" };
        current.secret_writes += 1;
        current.pending = true;
        self.mutations += 1;
        return .{ .code = 0, .output = "changed" };
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expect(std.mem.indexOf(u8, command, "PRIVATE-CERTIFICATE-SENTINEL") == null);
        if (op == .detect) return .{ .code = 0, .output = if (std.mem.eql(u8, command, "cat /etc/machine-id")) "0123456789abcdef0123456789abcdef\n" else "ubuntu\n24.04\naarch64\n" };
        if (op == .status and std.mem.indexOf(u8, command, "ExecMainStartTimestampMonotonic") != null) return .{ .code = 0, .output = "1000" };
        if (op == .service_exists) return .{ .code = 0, .output = "loaded\n" };
        const current = self.state(self.report.component);
        if (op == .directories and std.mem.indexOf(u8, command, "path=/opt/dragontools/ingestion") != null) {
            if (self.ingestion_directory) return .{ .code = 0, .output = "unchanged" };
            self.ingestion_directory = true;
            self.mutations += 1;
            return .{ .code = 0, .output = "changed" };
        }
        if (op == .health) {
            if (self.report.state.check) |check| {
                if (self.station_unreachable and check == .host_metrics_ready) return .{ .code = 255 };
                if (self.fail == check) {
                    self.attempts += 1;
                    return .{ .code = 1 };
                }
                if (self.delayed == check) {
                    self.attempts += 1;
                    if (self.timeout or self.attempts <= 2) return .{ .code = 75 };
                }
            }
            return .{ .code = 0 };
        }
        if (op == .finalize) {
            // Finalizing ingestion happens after Vector's endpoint verification.
            const target = if (std.mem.indexOf(u8, command, "ingestion-restart-required") != null) self.state(.ingestion) else current;
            target.pending = false;
            return .{ .code = 0 };
        }
        if (op == .activate) {
            if (std.mem.indexOf(u8, command, "systemctl stop dragontools-vmagent") != null) {
                if (!current.active) return .{ .code = 0, .output = "unchanged" };
                current.active = false;
                self.mutations += 1;
                return .{ .code = 0, .output = "changed" };
            }
            if (current.active and !current.pending) return .{ .code = 0, .output = "unchanged" };
            current.active = true;
            current.restarts += 1;
            self.mutations += 1;
            return .{ .code = 0, .output = "changed" };
        }
        if (op == .binary and self.report.component == .vector and self.fail_vector_binary) return .{ .code = 1 };
        if (op == .config and (std.mem.startsWith(u8, command, "runuser ") or std.mem.indexOf(u8, command, "dragontools-vmalert-dry-run") != null)) return .{ .code = 0 };
        const index = @intFromEnum(op);
        if (current.commands[index]) |existing| if (std.mem.eql(u8, existing, command)) return .{ .code = 0, .output = "unchanged" };
        const initial = current.commands[index] == null;
        current.commands[index] = try self.allocator.dupe(u8, command);
        if (op == .binary) current.downloads += 1;
        if (op == .binary or op == .unit or op == .config or (op == .credentials and initial)) current.pending = true;
        self.mutations += 1;
        return .{ .code = 0, .output = "changed" };
    }
};
const registration: model.Registration = .{ .host = "dt-0123456789abcdef0123456789abcdef", .station = "station.example", .services = &.{"app.service"}, .metrics_targets = &.{.{ .name = "app", .url = "http://127.0.0.1:16000/metrics" }} };

test "agents first install signals finalize and unchanged rerun performs no mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expect(report.state.changes > 0 and report.vmagent_installed);
    try std.testing.expect(!fake.state(.vector).pending and !fake.state(.vmagent).pending and !fake.state(.ingestion).pending);
    const before = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    try std.testing.expectEqual(before, fake.mutations);
    for ([_]model.Component{ .vector, .vmagent, .ingestion }) |kind| {
        try std.testing.expectEqual(@as(usize, 1), fake.state(kind).restarts);
        if (kind != .ingestion) try std.testing.expectEqual(@as(usize, 1), fake.state(kind).secret_writes);
    }
}
test "Vector-only and vmagent-only edits restart only the affected agent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    var changed = registration;
    changed.services = &.{ "app.service", "worker.service" };
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, changed);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vmagent).restarts);
    changed.metrics_targets = &.{.{ .name = "app", .url = "http://127.0.0.1:16001/metrics" }};
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, changed);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vmagent).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.ingestion).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.host_rules).restarts);
}
test "no metrics targets skips vmagent binary account and credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    var selected = registration;
    selected.metrics_targets = &.{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, selected);
    try std.testing.expect(!report.vmagent_installed);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).downloads);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).secret_writes);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).restarts);
}
test "delayed signals retry boundedly and timeout preserves only unfinished agent intent" {
    for ([_]bool{ false, true }) |timeout| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .delayed = .application_metrics_ready, .timeout = timeout };
        if (timeout) {
            try std.testing.expectError(error.ReadinessTimedOut, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
            try std.testing.expect(report.configured and fake.state(.vmagent).pending and !fake.state(.vector).pending);
            try std.testing.expect(fake.now == 45000);
            fake.timeout = false;
            fake.delayed = null;
            report = .{};
            try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
            try std.testing.expect(!fake.state(.vmagent).pending);
            try std.testing.expectEqual(@as(usize, 1), fake.state(.vector).restarts);
        } else {
            try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
            try std.testing.expectEqual(@as(usize, 3), fake.attempts);
            try std.testing.expectEqual(@as(i64, 1500), fake.now);
        }
        report = .{};
        const before = fake.mutations;
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(before, fake.mutations);
    }
}
test "agent deterministic failure never retries and Vector failure cannot alter vmagent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report, .fail = .managed_state };
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(@as(usize, 1), fake.attempts);
    try std.testing.expectEqual(@as(i64, 0), fake.now);
    fake.fail = null;
    fake.fail_vector_binary = true;
    report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).downloads);
}
test "standalone agent verify neither mutates nor exports or resolves credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    const mutations = fake.mutations;
    const exports = fake.secret_reads;
    report = .{};
    try verify.verify(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(mutations, fake.mutations);
    try std.testing.expectEqual(exports, fake.secret_reads);
}

test "removing the last application target stops only managed vmagent and reruns idle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    var changed = registration;
    changed.metrics_targets = &.{};
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, changed);
    try std.testing.expect(!fake.state(.vmagent).active);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.ingestion).restarts);
    const before = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, changed);
    try std.testing.expectEqual(before, fake.mutations);
}

test "unreachable station cannot report success after agent configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report, .station_unreachable = true };
    try std.testing.expectError(error.SshConnectionFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expect(report.configured and fake.state(.vector).pending);
    try std.testing.expectEqual(model.Component.signals, report.component);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).downloads);
    fake.station_unreachable = false;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expect(!fake.state(.vector).pending);
    report = .{};
    const before = fake.mutations;
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(before, fake.mutations);
}

test "application scopes keep shared agents independent of policy edits and isolate endpoint restart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{ .application = "doers" };
    var fake: Fake = .{ .allocator = a, .report = &report };
    const doers = model.ApplicationScope{ .name = "doers", .environment = "production", .services = &.{.{ .name = "web", .systemd = "doers.service", .logs = true, .metrics_url = "http://127.0.0.1:16005/metrics" }} };
    const orderflow = model.ApplicationScope{ .name = "orderflow", .environment = "production", .services = &.{.{ .name = "web", .systemd = "orderflow.service", .logs = true, .metrics_url = "http://127.0.0.1:16006/metrics" }} };
    var merged = registration;
    merged.metrics_targets = &.{};
    merged.services = &.{ "doers.service", "orderflow.service" };
    merged.applications = &.{ doers, orderflow };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, merged);
    try std.testing.expect(report.vmagent_installed);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.host_rules).restarts);
    const before = fake.mutations;
    // Probe and alert data cannot enter the host signal manifest/configuration.
    report = .{ .application = "doers" };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, merged);
    try std.testing.expectEqual(before, fake.mutations);
    var service = doers.services[0];
    service.metrics_url = "http://127.0.0.1:17005/metrics";
    var changed_scope = doers;
    changed_scope.services = &.{service};
    merged.applications = &.{ changed_scope, orderflow };
    report = .{ .application = "doers" };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, merged);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vmagent).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.ingestion).restarts);
    // Removing one application's optional signals preserves the other app.
    merged.applications = &.{ .{ .name = "doers", .environment = "production", .services = &.{} }, orderflow };
    merged.services = &.{"orderflow.service"};
    report = .{ .application = "doers" };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, merged);
    try std.testing.expect(fake.state(.vmagent).active);
    try std.testing.expectEqual(@as(usize, 1), merged.metricsCount());
    const after = fake.mutations;
    report = .{ .application = "doers" };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, merged);
    try std.testing.expectEqual(after, fake.mutations);
}

test "application host metrics without selected logs or metrics targets still installs Vector only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{ .application = "hostonly" };
    var fake: Fake = .{ .allocator = a, .report = &report };
    var selected = registration;
    selected.metrics_targets = &.{};
    selected.services = &.{};
    selected.applications = &.{.{ .name = "hostonly", .environment = "production", .services = &.{} }};
    _ = try model.Registration.parse(a, try selected.json(a));
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, selected);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vector).downloads);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).downloads);
    try std.testing.expect(!report.vmagent_installed);
    const before = fake.mutations;
    report = .{ .application = "hostonly" };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, selected);
    try std.testing.expectEqual(before, fake.mutations);
}
