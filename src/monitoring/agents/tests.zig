//! Controller-state fixtures are not Linux/systemd or two-host integration.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const model = @import("model.zig");
const install = @import("install.zig");
const verify = @import("verify.zig");
const readiness = @import("../readiness.zig");
const operations = @typeInfo(remote.Operation).@"enum".fields.len;
const State = struct {
    commands: [operations]?[]const u8 = @splat(null),
    pending: bool = false,
    active: bool = false,
    restarts: usize = 0,
    downloads: usize = 0,
    credential_writes: usize = 0,
};
const Fake = struct {
    allocator: std.mem.Allocator,
    report: *model.Report,
    states: [@typeInfo(model.Component).@"enum".fields.len]State = initialStates(),
    now: i64 = 0,
    delayed: ?readiness.Check = null,
    fail: ?readiness.Check = null,
    attempts: usize = 0,
    mutations: usize = 0,
    enrollments: usize = 0,
    enrolled: bool = false,
    station_hostname: []const u8 = "station.example",
    committed_pending: bool = false,
    pending_registry: bool = false,
    pending_lease_expired: bool = false,
    candidate: bool = false,
    generation: usize = 1,
    renew: bool = false,
    legacy: bool = false,
    fail_signing: bool = false,
    fail_finalize: bool = false,
    rollback_calls: usize = 0,
    finalize_calls: usize = 0,
    endpoint_failure: u8 = 0,
    logs_endpoint_failure: u8 = 0,
    endpoint_attempts: usize = 0,
    registration_command: ?[]const u8 = null,
    timeout: bool = false,
    station_unreachable: bool = false,
    fail_vector_binary: bool = false,
    ingestion_directory: bool = false,
    registry_failure: bool = false,
    ensure_failure: ?remote.Result = null,
    registry_attempts: usize = 0,
    app_helper: bool = false,
    station_helper: bool = true,
    base_missing: bool = false,
    fn initialStates() [@typeInfo(model.Component).@"enum".fields.len]State {
        var states: [@typeInfo(model.Component).@"enum".fields.len]State = @splat(.{});
        states[@intFromEnum(model.Component.caddy)].active = true;
        states[@intFromEnum(model.Component.ingestion)].active = true;
        return states;
    }
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .execute_input = executeInput, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
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
    fn executeInput(ctx: *anyopaque, op: remote.Operation, input: remote.Input, _: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, input.command, "dt-helper-upload") != null) {
            try std.testing.expectEqual(remote.Operation.binary, op);
            try std.testing.expect(input.bytes.len > 1024);
            if (self.report.component == .application_host) self.app_helper = true else self.station_helper = true;
            self.mutations += 1;
            return .{ .code = 0, .output = "changed" };
        }
        const Envelope = struct { action: []const u8, args: []const []const u8 };
        const parsed = try std.json.parseFromSlice(Envelope, self.allocator, input.bytes, .{});
        if (std.mem.eql(u8, parsed.value.action, "ensure")) {
            try std.testing.expectEqual(remote.diagnostics.EnrollmentStage.station_ensure, input.enrollment_stage.?);
            try std.testing.expect(std.mem.indexOf(u8, input.command, "'--diagnostics'") != null);
            if (self.ensure_failure) |failure| return failure;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.allocator, &.{ "fixture-agent", parsed.value.action });
        try argv.appendSlice(self.allocator, parsed.value.args);
        return execute(ctx, op, try remote.shell(self.allocator, argv.items));
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, command, "dt-helper-inspect") != null) return .{ .code = 0, .output = if (if (self.report.component == .application_host) self.app_helper else self.station_helper) "unchanged" else "upload" };
        try std.testing.expect(std.mem.indexOf(u8, command, "PRIVATE-CERTIFICATE-SENTINEL") == null);
        if (std.mem.indexOf(u8, command, " 'station-verify' ") != null) return .{ .code = if (self.base_missing) 86 else 0 };
        if (self.report.state.check == .station_ingress_required and (self.state(.caddy).pending or self.state(.ingestion).pending)) return .{ .code = 1 };
        const registry_ensure = std.mem.indexOf(u8, command, " 'ensure' '") != null;
        if (registry_ensure or std.mem.indexOf(u8, command, " 'verify' '") != null) {
            self.registry_attempts += 1;
            if (self.registry_failure) return .{ .code = 89 };
            if (registry_ensure) return .{ .code = 0, .output = "unchanged" };
        }
        if (std.mem.indexOf(u8, command, " 'inspect' '") != null) return .{ .code = 0, .output = try std.fmt.allocPrint(self.allocator, "{{\"host\":\"dt-0123456789abcdef0123456789abcdef\",\"station\":\"{s}\",\"ca.crt\":\"PUBLIC-CA\",\"legacy\":{s},\"legacy_expired\":false,\"legacy_active\":{s},\"certificate_sha256\":\"{s}\",\"pending_certificate_sha256\":{s}}}", .{ self.station_hostname, if (self.legacy) "true" else "false", if (self.legacy) "true" else "false", if (self.committed_pending) "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" else "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", if (self.pending_registry) "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"" else "null" }) };
        if (std.mem.indexOf(u8, command, " 'client-prepare' '") != null) {
            try std.testing.expect(self.state(.caddy).active and self.state(.ingestion).active);
            if (self.enrolled and !self.renew and !self.legacy and !self.candidate) return .{ .code = 0, .output = "{\"action\":\"unchanged\",\"csr\":null,\"certificate_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" };
            if (!self.candidate) {
                self.enrollments += 1;
                self.candidate = true;
                if (self.enrolled) self.generation += 1;
            }
            return .{ .code = 0, .output = try std.fmt.allocPrint(self.allocator, "{{\"action\":\"{s}\",\"csr\":\"-----BEGIN CERTIFICATE REQUEST-----\\nPUBLIC-CSR\\n-----END CERTIFICATE REQUEST-----\\n\",\"certificate_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}", .{if (self.legacy) "migrate" else if (self.renew) "renew" else "enroll"}) };
        }
        if (std.mem.indexOf(u8, command, " 'stage' '") != null) {
            if (self.fail_signing) return .{ .code = 86 };
            self.pending_registry = true;
            self.pending_lease_expired = false;
            return .{ .code = 0, .output = "{\"host\":\"dt-0123456789abcdef0123456789abcdef\",\"station\":\"station.example\",\"ca.crt\":\"PUBLIC-CA\",\"client.crt\":\"PUBLIC-CERT\",\"certificate_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" };
        }
        if (std.mem.indexOf(u8, command, " 'client-stage' '") != null) return .{ .code = 0, .output = "unchanged" };
        if (std.mem.indexOf(u8, command, " 'stage-registration' '") != null) {
            if (self.registration_command) |old| if (std.mem.eql(u8, old, command)) return .{ .code = 0, .output = "unchanged" };
            self.registration_command = try self.allocator.dupe(u8, command);
            // The first application is already staged with enrollment.
            return .{ .code = 0, .output = "unchanged" };
        }
        if (std.mem.indexOf(u8, command, " 'client-install' '") != null) {
            const current = self.state(self.report.component);
            if (current.credential_writes == self.generation) return .{ .code = 0, .output = "unchanged" };
            current.credential_writes = self.generation;
            current.pending = true;
            self.mutations += 1;
            return .{ .code = 0, .output = "changed" };
        }
        if (std.mem.indexOf(u8, command, " 'client-rollback' '") != null) {
            self.rollback_calls += 1;
            for ([_]model.Component{ .vector, .vmagent }) |kind| {
                const current = self.state(kind);
                if (current.credential_writes == self.generation) {
                    current.credential_writes -= 1;
                    current.pending = true;
                    current.restarts += 1;
                }
            }
            return .{ .code = 0, .output = "changed" };
        }
        if (std.mem.indexOf(u8, command, " 'finalize' '") != null) {
            self.finalize_calls += 1;
            if (self.fail_finalize) return .{ .code = 255 };
            self.enrolled = true;
            self.renew = false;
            self.legacy = false;
            self.pending_registry = false;
            return .{ .code = 0, .output = "unchanged" };
        }
        if (std.mem.indexOf(u8, command, " 'client-commit' '") != null) {
            self.candidate = false;
            return .{ .code = 0, .output = "unchanged" };
        }
        if (op == .detect) return .{ .code = 0, .output = if (std.mem.eql(u8, command, "cat /etc/machine-id")) "0123456789abcdef0123456789abcdef\n" else "ubuntu\n24.04\naarch64\n" };
        if (op == .status and std.mem.indexOf(u8, command, "ExecMainStartTimestampMonotonic") != null) return .{ .code = 0, .output = "1000" };
        if (op == .service_exists) return .{ .code = 0, .output = "loaded\n" };
        const current = self.state(self.report.component);
        if (op == .directories and std.mem.indexOf(u8, command, "path=/opt/dragontools/ingress-auth") != null) {
            if (self.ingestion_directory) return .{ .code = 0, .output = "unchanged" };
            self.ingestion_directory = true;
            self.mutations += 1;
            return .{ .code = 0, .output = "changed" };
        }
        if (op == .health) {
            if (self.report.state.check) |check| {
                if (check == .secure_endpoint or check == .metrics_mtls_authenticated or verify.networkFailure(check) or check == .ingestion_rejected) {
                    self.endpoint_attempts += 1;
                    if (self.pending_lease_expired) return .{ .code = 94 };
                    if (self.endpoint_failure != 0) return .{ .code = self.endpoint_failure };
                    if (self.logs_endpoint_failure != 0 and std.mem.endsWith(u8, command, "'logs'")) return .{ .code = self.logs_endpoint_failure };
                }
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
            const target = if (std.mem.indexOf(u8, command, "ingress-auth-restart-required") != null) self.state(.ingestion) else current;
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
        if (op == .config and (std.mem.startsWith(u8, command, "runuser ") or std.mem.startsWith(u8, command, "CREDENTIALS_DIRECTORY=") or std.mem.indexOf(u8, command, "dragontools-vmalert-dry-run") != null)) return .{ .code = 0 };
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
    try std.testing.expect(!fake.state(.vector).pending and !fake.state(.vmagent).pending and !fake.state(.ingestion).pending and !fake.state(.caddy).pending);
    const before = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    try std.testing.expectEqual(before, fake.mutations);
    for ([_]model.Component{ .vector, .vmagent, .ingestion, .caddy }) |kind| {
        try std.testing.expectEqual(@as(usize, if (kind == .caddy or kind == .ingestion) 0 else 1), fake.state(kind).restarts);
        if (kind == .vector or kind == .vmagent) try std.testing.expectEqual(@as(usize, 1), fake.state(kind).credential_writes);
    }
    try std.testing.expectEqual(@as(usize, 1), fake.enrollments);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.caddy).downloads);
}
test "registry permissions failure reports ingestion check without retry and recovers on apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report, .registry_failure = true };
    try std.testing.expectError(error.RegistryPermissionsConflict, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(model.Component.ingestion, report.component);
    try std.testing.expectEqual(readiness.Check.registry_permissions, report.state.check.?);
    try std.testing.expectEqual(remote.Operation.credentials, report.state.phase);
    try std.testing.expectEqual(@as(usize, 1), fake.registry_attempts);
    try std.testing.expectEqual(@as(usize, 0), fake.enrollments);
    try std.testing.expectEqual(@as(i64, 0), fake.now);
    fake.registry_failure = false;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    const before = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    try std.testing.expectEqual(before, fake.mutations);
}
test "application install refuses missing station ingress without bootstrap or enrollment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report, .base_missing = true };
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(readiness.Check.station_ingress_required, report.state.check.?);
    try std.testing.expectEqual(@as(usize, 0), fake.enrollments);
    for ([_]model.Component{ .caddy, .ingestion }) |kind| {
        try std.testing.expectEqual(@as(usize, 0), fake.state(kind).restarts);
        for (fake.state(kind).commands) |command| try std.testing.expect(command == null);
    }
    // Station install has now independently bootstrapped the transport.
    fake.base_missing = false;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
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
    try std.testing.expectEqual(@as(usize, 0), fake.state(.ingestion).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.host_rules).restarts);
}
test "log schema config upgrade restarts only Vector once and finalizes to no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    fake.state(.vector).commands[@intFromEnum(remote.Operation.config)] = "previous DragonTools log configuration";
    const enrollments = fake.enrollments;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vmagent).restarts);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.caddy).restarts);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.ingestion).restarts);
    try std.testing.expectEqual(enrollments, fake.enrollments);
    try std.testing.expect(!fake.state(.vector).pending);
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vmagent).restarts);
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
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).credential_writes);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmagent).restarts);
}
test "delayed signals retry boundedly and timeout preserves only unfinished agent intent" {
    for ([_]bool{ false, true }) |timeout| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .delayed = .application_metrics_visible, .timeout = timeout };
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
test "metrics diagnostics isolate each safe stage and recovery preserves working Vector and enrollment" {
    for ([_]readiness.Check{ .metrics_agent_active, .metrics_source_ready, .metrics_station_reachable, .metrics_remote_write_accepted, .application_metrics_visible }) |check| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .fail = check };
        try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
        try std.testing.expectEqual(model.Component.signals, report.component);
        try std.testing.expectEqual(check, report.state.check.?);
        try std.testing.expectEqual(@as(usize, 1), fake.attempts);
        try std.testing.expect(fake.state(.vmagent).pending and !fake.state(.vector).pending);
        try std.testing.expectEqual(@as(usize, 0), fake.rollback_calls);
        const enrollment_count = fake.enrollments;
        const vector_restarts = fake.state(.vector).restarts;
        fake.fail = null;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(enrollment_count, fake.enrollments);
        try std.testing.expectEqual(vector_restarts, fake.state(.vector).restarts);
        try std.testing.expectEqual(@as(usize, 0), fake.state(.caddy).restarts);
        try std.testing.expect(!fake.state(.vmagent).pending);
        const changes = fake.mutations;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(changes, fake.mutations);
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
    const enrollments = fake.enrollments;
    report = .{};
    try verify.verify(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(mutations, fake.mutations);
    try std.testing.expectEqual(enrollments, fake.enrollments);
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
    try std.testing.expectEqual(@as(usize, 0), fake.state(.ingestion).restarts);
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
    try std.testing.expectEqual(@as(usize, 0), fake.state(.ingestion).restarts);
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

test "CSR signing failure leaves running consumers and active registration untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    const finalized = fake.finalize_calls;
    fake.renew = true;
    fake.fail_signing = true;
    report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(finalized, fake.finalize_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.rollback_calls);
    for ([_]model.Component{ .vector, .vmagent }) |kind| {
        try std.testing.expect(fake.state(kind).active and !fake.state(kind).pending);
        try std.testing.expectEqual(@as(usize, 1), fake.state(kind).restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.state(kind).credential_writes);
    }
}

test "renewal candidate TLS rejection does not publish credentials or finalize identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    const finalized = fake.finalize_calls;
    fake.renew = true;
    fake.endpoint_failure = 93;
    fake.endpoint_attempts = 0;
    report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(readiness.Check.server_tls_invalid, report.state.check.?);
    try std.testing.expectEqual(@as(usize, 1), fake.endpoint_attempts);
    try std.testing.expectEqual(finalized, fake.finalize_calls);
    try std.testing.expectEqual(@as(i64, 0), fake.now);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vector).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.vmagent).restarts);
}

test "migration telemetry failure restores old credentials retains intent and rerun finalizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    const finalized = fake.finalize_calls;
    fake.legacy = true;
    fake.delayed = .application_metrics_visible;
    fake.timeout = true;
    report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(finalized, fake.finalize_calls);
    try std.testing.expect(fake.legacy and fake.candidate);
    try std.testing.expectEqual(@as(usize, 1), fake.rollback_calls);
    for ([_]model.Component{ .vector, .vmagent }) |kind| {
        try std.testing.expectEqual(@as(usize, 1), fake.state(kind).credential_writes);
        try std.testing.expect(fake.state(kind).pending and fake.state(kind).active);
    }
    fake.delayed = null;
    fake.timeout = false;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@import("ingestion.zig").Action.migrate, report.enrollment);
    try std.testing.expect(!fake.legacy and !fake.candidate);
    try std.testing.expectEqual(@as(usize, 2), fake.enrollments);
    for ([_]model.Component{ .vector, .vmagent }) |kind| try std.testing.expect(!fake.state(kind).pending);
    const mutations = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(mutations, fake.mutations);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
}

test "uncertain station finalization retains candidate and resumes without credential rollback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    fake.renew = true;
    fake.fail_finalize = true;
    report = .{};
    try std.testing.expectError(error.SshConnectionFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(@as(usize, 0), fake.rollback_calls);
    try std.testing.expect(fake.candidate);
    fake.fail_finalize = false;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expect(!fake.candidate);
    for ([_]model.Component{ .vector, .vmagent }) |kind| try std.testing.expectEqual(@as(usize, 2), fake.state(kind).restarts);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.ingestion).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.host_rules).restarts);
}

test "endpoint failures expose safe semantic checks with bounded transient retries" {
    const codes = [_]u8{ 91, 92, 93, 94, 95 };
    const checks = [_]readiness.Check{ .dns_unresolved, .tcp_unreachable, .server_tls_invalid, .client_certificate_rejected, .ingestion_rejected };
    for (codes, checks) |code, check| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .endpoint_failure = code };
        const input = try @import("ingestion.zig").endpointCommand(a, "station.example", "canonical", registration.host);
        const result = verify.secureEndpoint(a, fake.asRemote(), &report, input);
        if (code == 93 or code == 94) {
            try std.testing.expectError(error.RemoteOperationFailed, result);
            try std.testing.expectEqual(@as(usize, 1), fake.endpoint_attempts);
            try std.testing.expectEqual(@as(i64, 0), fake.now);
        } else {
            try std.testing.expectError(error.ReadinessTimedOut, result);
            try std.testing.expect(fake.endpoint_attempts > 2);
            try std.testing.expectEqual(@as(i64, 30000), fake.now);
        }
        try std.testing.expectEqual(check, report.state.check.?);
        try std.testing.expectEqual(remote.diagnostics.EnrollmentStage.credential_verify, report.state.enrollment_stage.?);
        try std.testing.expectEqual(remote.diagnostics.detail(code).?, report.state.agent_detail.?);
        try std.testing.expectEqual(@as(usize, 0), fake.mutations);
    }
}

test "application apply preserves station restart intent until station install completes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    fake.state(.caddy).pending = true;
    report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(readiness.Check.station_ingress_required, report.state.check.?);
    try std.testing.expect(fake.state(.caddy).pending);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.caddy).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.enrollments);
    for ([_]model.Component{ .vector, .vmagent }) |kind| try std.testing.expectEqual(@as(usize, 1), fake.state(kind).restarts);
}

test "failure on a station-committed migration rerun never restores revoked credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    // Model station-finalize committed, followed by an interrupted client commit.
    // Inspection reports the candidate active while prepare retains the original
    // transaction fingerprint, so the old generation is no longer a rollback.
    fake.renew = true;
    fake.candidate = true;
    fake.committed_pending = true;
    fake.generation = 2;
    fake.state(.vector).credential_writes = 2;
    fake.state(.vmagent).credential_writes = 2;
    fake.delayed = .application_metrics_visible;
    fake.timeout = true;
    report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(@as(usize, 0), fake.rollback_calls);
    try std.testing.expect(fake.candidate and fake.committed_pending);
    for ([_]model.Component{ .vector, .vmagent }) |kind| try std.testing.expectEqual(@as(usize, 2), fake.state(kind).credential_writes);
}

test "interrupted migration refreshes expired rollout authorization before endpoint proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    // The previous run proved the old identity, staged the new one and switched
    // consumers, but stopped before finalization. Its candidate lease expired.
    fake.legacy = true;
    fake.candidate = true;
    fake.pending_registry = true;
    fake.pending_lease_expired = true;
    fake.generation = 2;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expect(!fake.pending_lease_expired and !fake.candidate and !fake.legacy);
    try std.testing.expectEqual(@as(usize, 0), fake.rollback_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.enrollments);
    const mutations = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(mutations, fake.mutations);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
}

test "application hostname change follows station certificate update and restarts only endpoint consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    var changed = registration;
    changed.station = "monitoring.baptizeddragon.com";
    fake.station_hostname = changed.station;
    // Station install already reconciled its certificate and finalized Caddy.
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, changed);
    for ([_]model.Component{ .caddy, .vector, .vmagent }) |kind| try std.testing.expectEqual(@as(usize, if (kind == .caddy) 0 else 2), fake.state(kind).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.state(.host_rules).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.enrollments);
    for ([_]model.Component{ .vector, .vmagent }) |kind| try std.testing.expectEqual(@as(usize, 1), fake.state(kind).credential_writes);
    const mutations = fake.mutations;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, changed);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    try std.testing.expectEqual(mutations, fake.mutations);
    for ([_]model.Component{ .caddy, .vector, .vmagent }) |kind| try std.testing.expectEqual(@as(usize, if (kind == .caddy) 0 else 2), fake.state(kind).restarts);
}

test "station ensure failure reports safe substage and preserves native semantic codes" {
    const Case = struct { code: u8, failure: anyerror, detail: remote.diagnostics.Detail, check: ?readiness.Check = null };
    for ([_]Case{
        .{ .code = 86, .failure = error.RemoteOperationFailed, .detail = .agent_internal_error },
        .{ .code = 87, .failure = error.CaMaintenanceRequired, .detail = .ca_maintenance, .check = .ca_maintenance },
        .{ .code = 88, .failure = error.ClientIdentityInconsistent, .detail = .client_identity_inconsistent, .check = .client_identity_inconsistent },
        .{ .code = 89, .failure = error.RegistryPermissionsConflict, .detail = .registry_permissions, .check = .registry_permissions },
        .{ .code = 91, .failure = error.RemoteOperationFailed, .detail = .dns_unresolved, .check = .dns_unresolved },
        .{ .code = 92, .failure = error.RemoteOperationFailed, .detail = .tcp_unreachable, .check = .tcp_unreachable },
        .{ .code = 93, .failure = error.RemoteOperationFailed, .detail = .server_tls_invalid, .check = .server_tls_invalid },
        .{ .code = 94, .failure = error.RemoteOperationFailed, .detail = .client_certificate_rejected, .check = .client_certificate_rejected },
        .{ .code = 95, .failure = error.RemoteOperationFailed, .detail = .ingestion_rejected, .check = .ingestion_rejected },
        .{ .code = 96, .failure = error.OperationBusy, .detail = .operation_busy, .check = .operation_busy },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .ensure_failure = .{ .code = case.code, .output = "PRIVATE KEY sentinel", .diagnostic = if (case.code == 86) .{ .stage = .ca_key_generation, .reason = .CryptoKeyGenerationFailed } else null } };
        try std.testing.expectError(case.failure, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
        try std.testing.expectEqual(model.Component.ingestion, report.component);
        try std.testing.expectEqual(remote.Operation.credentials, report.state.phase);
        try std.testing.expectEqual(case.check, report.state.check);
        try std.testing.expectEqual(remote.diagnostics.EnrollmentStage.station_ensure, report.state.enrollment_stage.?);
        try std.testing.expectEqual(case.detail, report.state.agent_detail.?);
        const output = try report.state.credentialDiagnostics(a);
        try std.testing.expect(std.mem.startsWith(u8, output, "Stage: station_ensure\nDetail: "));
        try std.testing.expect(std.mem.indexOf(u8, output, "PRIVATE KEY") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "sentinel") == null);
        if (case.code == 86) try std.testing.expectEqualStrings("Stage: station_ensure\nDetail: agent_internal_error\nAgentStage: ca_key_generation\nAgentError: CryptoKeyGenerationFailed\n", output);
        try std.testing.expect(fake.state(.ingestion).commands[@intFromEnum(remote.Operation.unit)] == null);
        try std.testing.expectEqual(@as(usize, 0), fake.enrollments);
        // Removing the fault resumes normal installation; a further rerun is a no-op.
        fake.ensure_failure = null;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        const mutations = fake.mutations;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(@as(usize, 0), report.state.changes);
        try std.testing.expectEqual(mutations, fake.mutations);
        try std.testing.expect(report.state.agent_detail == null and report.state.agent_diagnostic == null);
    }
}
test "silent or rejected native diagnostics still identify station ensure and generic failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report, .ensure_failure = .{ .code = 86 } };
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqualStrings("Stage: station_ensure\nDetail: agent_internal_error\n", try report.state.credentialDiagnostics(a));
}

test "station ensure diagnostics identify fixed managed invariants without exposing remote output" {
    const Case = struct { stage: remote.diagnostics.Stage, reason: remote.diagnostics.AgentError = .InvalidManagedState, check: readiness.Check, code: u8 = 86 };
    for ([_]Case{
        .{ .stage = .ingestion_root, .check = .ingestion_root_invalid },
        .{ .stage = .pki_directory, .check = .pki_directory_invalid },
        .{ .stage = .clients_directory, .check = .clients_directory_invalid },
        .{ .stage = .registry_directory, .reason = .RegistryPermissions, .check = .registry_directory_invalid, .code = 89 },
        .{ .stage = .state_directory, .check = .state_directory_invalid },
        .{ .stage = .ca_state, .check = .ca_bundle_invalid },
        .{ .stage = .ca_certificate_validation, .reason = .CertificateValidationFailed, .check = .ca_bundle_invalid },
        .{ .stage = .server_state, .check = .server_identity_invalid },
        .{ .stage = .server_certificate_validation, .reason = .CertificateValidationFailed, .check = .server_identity_invalid },
        .{ .stage = .pki_directory, .reason = .UnexpectedManagedFile, .check = .unexpected_managed_file },
        .{ .stage = .clients_directory, .reason = .UnexpectedSymlink, .check = .unexpected_symlink },
        .{ .stage = .operation_lock, .reason = .OperationBusy, .check = .operation_busy, .code = 96 },
        .{ .stage = .operation_lock, .reason = .OperationLockFailed, .check = .operation_lock_failed },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .ensure_failure = .{
            .code = case.code,
            .output = "PRIVATE KEY sentinel",
            .diagnostic = .{ .stage = case.stage, .reason = case.reason },
        } };
        try std.testing.expectError(if (case.code == 89) error.RegistryPermissionsConflict else if (case.code == 96) error.OperationBusy else error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
        try std.testing.expectEqual(case.check, report.state.check.?);
        try std.testing.expectEqual(remote.diagnostics.EnrollmentStage.station_ensure, report.state.enrollment_stage.?);
        const output = try report.state.credentialDiagnostics(a);
        try std.testing.expect(std.mem.indexOf(u8, output, "PRIVATE KEY") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "sentinel") == null);
        try std.testing.expectEqual(@as(usize, 0), fake.enrollments);
    }
}

test "Caddy listener retries precede enrollment and preserve restart intent on timeout" {
    for ([_]bool{ false, true }) |timeout| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .delayed = .caddy_listener, .timeout = timeout };
        if (timeout) {
            try std.testing.expectError(error.ReadinessTimedOut, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
            try std.testing.expectEqual(readiness.Check.caddy_listener, report.state.check.?);
            try std.testing.expectEqual(@as(usize, 0), fake.enrollments);
            try std.testing.expect(!fake.state(.caddy).pending and !fake.state(.ingestion).pending);
            fake.timeout = false;
            report = .{};
            try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        } else try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expect(fake.attempts >= 3 and !fake.state(.caddy).pending);
        const mutations = fake.mutations;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(mutations, fake.mutations);
        try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    }
}

test "Caddy invariants and legacy public gateway conflicts fail once before client enrollment" {
    for ([_]readiness.Check{ .caddy_credentials, .legacy_ingress_conflict }) |check| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .fail = check };
        try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
        try std.testing.expectEqual(check, report.state.check.?);
        try std.testing.expectEqual(@as(usize, 1), fake.attempts);
        try std.testing.expectEqual(@as(usize, 0), fake.enrollments);
        try std.testing.expectEqual(@as(usize, 0), fake.state(.vector).restarts);
    }
}

test "application apply refuses Caddy drift and never writes base configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: model.Report = .{};
    var fake: Fake = .{ .allocator = a, .report = &report };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    const mutations = fake.mutations;
    fake.fail = .caddy_credentials;
    report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
    try std.testing.expectEqual(mutations, fake.mutations);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.caddy).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.enrollments);
    // Only station install repairs it. The next apply remains unchanged.
    fake.fail = null;
    report = .{};
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    for ([_]model.Component{ .caddy, .ingestion }) |kind| for (fake.state(kind).commands) |command| try std.testing.expect(command == null);
}

test "per-signal endpoint diagnostics require host event logs even without application logs" {
    for ([_]u8{ 92, 95 }) |code| {
        for ([_]bool{ false, true }) |logs| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var report: model.Report = .{};
            var fake: Fake = .{ .allocator = a, .report = &report };
            if (logs) fake.logs_endpoint_failure = code else fake.endpoint_failure = code;
            try std.testing.expectError(error.ReadinessTimedOut, verify.enrollmentEndpoints(a, fake.asRemote(), &report, registration, "pending"));
            try std.testing.expectEqual(if (code == 92) (if (logs) readiness.Check.tcp_logs_unreachable else .tcp_metrics_unreachable) else (if (logs) readiness.Check.logs_ingestion_rejected else .metrics_ingestion_rejected), report.state.check.?);
            try std.testing.expect(fake.endpoint_attempts > 2 and fake.now <= readiness.http_ms);
            if (logs) {
                var host_only = registration;
                host_only.services = &.{};
                report = .{};
                try std.testing.expectError(error.ReadinessTimedOut, verify.enrollmentEndpoints(a, fake.asRemote(), &report, host_only, "pending"));
                try std.testing.expectEqual(if (code == 92) readiness.Check.tcp_logs_unreachable else .logs_ingestion_rejected, report.state.check.?);
            }
        }
    }
}

test "Doers reference enrollment rerun preserves agents certificates and station ingress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value = try @import("../../config/application.zig").load(a, std.testing.io, "examples/doers-monitoring.toml");
    defer value.deinit();
    try std.testing.expectEqualStrings("softwarelanding", value.target_ssh_host);
    try std.testing.expectEqualStrings("monitoring", value.station_ssh_host);
    try std.testing.expectEqualStrings("monitoring.baptizeddragon.com", value.station_hostname);
    try std.testing.expectEqualStrings("doers", value.application.name);
    try std.testing.expectEqualStrings("production", value.application.environment);
    try std.testing.expectEqualStrings("doers.service", value.services[0].systemd);
    try std.testing.expect(value.services[0].logs);
    try std.testing.expectEqualStrings("http://127.0.0.1:16005/metrics", value.services[0].metrics_url.?);
    try std.testing.expectEqualStrings("https://doers.business/healthz", value.probes[0].url);
    const scopes = [_]model.ApplicationScope{try @import("../apps/dispatch.zig").scope(a, value)};
    const reference: model.Registration = .{ .host = registration.host, .station = value.station_hostname, .services = &.{"doers.service"}, .metrics_targets = &.{}, .applications = &scopes };
    var report: model.Report = .{ .application = value.application.name };
    var fake: Fake = .{ .allocator = a, .report = &report, .station_hostname = value.station_hostname };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, reference);
    const before = fake.mutations;
    report = .{ .application = value.application.name };
    try install.install(a, fake.asRemote(), fake.asRemote(), &report, reference);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
    try std.testing.expectEqual(before, fake.mutations);
    try std.testing.expectEqual(@as(usize, 1), fake.enrollments);
    for ([_]model.Component{ .vector, .vmagent }) |kind| {
        try std.testing.expectEqual(@as(usize, 1), fake.state(kind).restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.state(kind).credential_writes);
        try std.testing.expect(!fake.state(kind).pending);
    }
    for ([_]model.Component{ .caddy, .ingestion, .host_rules }) |kind| {
        try std.testing.expectEqual(@as(usize, 0), fake.state(kind).restarts);
        for (fake.state(kind).commands) |command| try std.testing.expect(command == null);
    }
}

test "host events readiness preserves independent intent and recovers to an unchanged rerun" {
    for ([_]readiness.Check{ .host_events_state_directory, .host_events_timer_active, .host_events_last_run, .host_events_state_safe, .host_events_stream_ready, .log_stream_ready }) |check| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: model.Report = .{};
        var fake: Fake = .{ .allocator = a, .report = &report, .fail = check };
        try std.testing.expectError(error.RemoteOperationFailed, install.install(a, fake.asRemote(), fake.asRemote(), &report, registration));
        try std.testing.expectEqual(check, report.state.check.?);
        try std.testing.expect(fake.state(.host_events).pending and fake.state(.vector).pending);
        try std.testing.expect(!fake.state(.caddy).pending and !fake.state(.ingestion).pending);
        try std.testing.expectEqual(@as(usize, 1), fake.attempts);
        fake.fail = null;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expect(!fake.state(.host_events).pending);
        const before = fake.mutations;
        const runs = fake.state(.host_events).restarts;
        report = .{};
        try install.install(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(before, fake.mutations);
        try std.testing.expectEqual(runs, fake.state(.host_events).restarts);
        report = .{};
        try verify.verify(a, fake.asRemote(), fake.asRemote(), &report, registration);
        try std.testing.expectEqual(before, fake.mutations);
    }
}
