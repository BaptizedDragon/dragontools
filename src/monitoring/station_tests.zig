//! Full controller ordering, composing core fixtures with the four new services.
//! This fake models remote state; it does not execute Linux services or probes.
const std = @import("std");
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
const readiness = @import("readiness.zig");
const probes = @import("probes.zig");
const Secret = @import("../secrets/secret.zig").Secret;
const extra = [_]workflow.Component{ .blackbox_exporter, .alertmanager, .vmalert_logs, .vmalert_metrics, .ingress_auth, .caddy };
const operation_count = @typeInfo(remote.Operation).@"enum".fields.len;
const State = struct {
    present: [operation_count]bool = @splat(false),
    calls: [operation_count]usize = @splat(0),
    active: bool = false,
    pending: bool = false,
    restarts: usize = 0,
    downloads: usize = 0,
    config_writes: usize = 0,
    unit_command: ?[]const u8 = null,
    unit_writes: usize = 0,
    fail: ?readiness.Check = null,
    delayed: ?readiness.Check = null,
    attempts: usize = 0,
    timeout: bool = false,
};
const Fake = struct {
    allocator: std.mem.Allocator,
    report: *workflow.Report,
    core: @import("tests.zig").Fake = .{},
    states: [6]State = @splat(.{}),
    now: i64 = 0,
    shared_binary: bool = false,
    scrape_digest: ?[32]u8 = null,
    scrape_pending: bool = false,
    scrape_writes: usize = 0,
    scrape_reloads: usize = 0,
    scrape_fail: bool = false,
    secret_bytes: ?[]const u8 = null,
    secret_writes: usize = 0,
    template_digest: ?[32]u8 = null,
    notify_calls: usize = 0,
    check_syntax: bool = false,
    helper_present: bool = false,
    dashboards_present: [2]bool = .{ false, false },
    pki_present: bool = false,
    pki_calls: usize = 0,
    fail_after_unit: ?workflow.Component = null,

    fn state(self: *Fake, component: workflow.Component) *State {
        for (extra, 0..) |value, index| if (value == component) return &self.states[index];
        unreachable;
    }
    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .execute_secret = secret, .execute_input = publicInput, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
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
    fn publicInput(ctx: *anyopaque, op: remote.Operation, input: remote.Input, _: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, input.command, "DragonTools public Telegram template transport") != null) {
            try std.testing.expectEqual(workflow.Component.alertmanager, self.report.component.?);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(input.bytes, &digest, .{});
            if (self.template_digest) |old| if (std.mem.eql(u8, &old, &digest)) return .{ .code = 0, .output = if (op == .config) "unchanged" else "" };
            if (op == .health) return .{ .code = 1 };
            self.template_digest = digest;
            self.state(.alertmanager).pending = true;
            return .{ .code = 0, .output = "changed" };
        }
        if (input.enrollment_stage != null) {
            const Request = struct { action: []const u8, args: []const []const u8 };
            const request = (try std.json.parseFromSlice(Request, self.allocator, input.bytes, .{})).value;
            try std.testing.expectEqual(@as(usize, 1), request.args.len);
            try std.testing.expectEqualStrings("station.example", request.args[0]);
            if (std.mem.eql(u8, request.action, "station-ensure")) {
                self.pki_calls += 1;
                if (self.pki_present) return .{ .code = 0, .output = "unchanged" };
                self.pki_present = true;
                self.state(.caddy).pending = true;
                return .{ .code = 0, .output = "changed" };
            }
            try std.testing.expectEqualStrings("station-verify", request.action);
            if (!self.pki_present) return .{ .code = 86 };
            return .{ .code = 0, .output = "unchanged" };
        }
        try std.testing.expectEqual(remote.Operation.binary, op);
        try std.testing.expectEqual(workflow.Component.agent_helper, self.report.component.?);
        try std.testing.expect(input.bytes.len > 100000);
        self.helper_present = true;
        return .{ .code = 0, .output = "changed" };
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
        if (std.mem.indexOf(u8, command, "dragontools_dashboards") != null) {
            if (op == .provisioning) {
                const index: usize = if (self.report.component == .grafana) 1 else 0;
                const changed = !self.dashboards_present[index];
                self.dashboards_present[index] = true;
                return .{ .code = 0, .output = if (changed) "changed" else "unchanged" };
            }
            try std.testing.expectEqual(remote.Operation.health, op);
            try std.testing.expect(self.dashboards_present[0] and self.dashboards_present[1]);
            return .{ .code = 0 };
        }
        if (std.mem.indexOf(u8, command, "base64.b64decode(sys.argv.pop(1)") != null) return self.scrape(op);
        if (op == .detect) return self.core.asRemote().run(op, command);
        const component = self.report.component.?;
        if (component == .agent_helper) return .{ .code = 0, .output = if (self.helper_present) "unchanged" else "upload" };
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
                if (current.fail == check) {
                    current.attempts += 1;
                    return .{ .code = 1 };
                }
                if (check == .legacy_ingress_conflict) return .{ .code = 0 };
                // Ownership of app glob inputs is checked before the evaluator
                // exists or starts; all runtime checks still require active.
                if (check == .application_ownership) {
                    try std.testing.expect(component == .vmalert_logs or component == .vmalert_metrics);
                    try std.testing.expect(std.mem.indexOf(u8, command, "app_all()") != null);
                    return .{ .code = 0 };
                }
                if (current.delayed == check) {
                    current.attempts += 1;
                    if (current.timeout or current.attempts <= 2) return .{ .code = 75 };
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
            .config => if (std.mem.indexOf(u8, command, "dragontools-vmalert-dry-run") != null or std.mem.startsWith(u8, command, "runuser ") or std.mem.startsWith(u8, command, "CREDENTIALS_DIRECTORY=")) return .{ .code = 0, .output = "unchanged" },
            .unit => {
                if (current.unit_command) |existing| if (std.mem.eql(u8, existing, command)) return .{ .code = 0, .output = "unchanged" };
                if (component == .vmalert_logs or component == .vmalert_metrics) {
                    const vmalert = @import("vmalert.zig");
                    const kind: vmalert.Kind = if (component == .vmalert_logs) .logs else .metrics;
                    const other: vmalert.Kind = if (kind == .logs) .metrics else .logs;
                    // Validate the production writer's marker argument, not just
                    // the component selected by this controller-state fixture.
                    try std.testing.expect(std.mem.endsWith(u8, command, try remote.quote(self.allocator, vmalert.marker(kind))));
                    try std.testing.expect(std.mem.indexOf(u8, command, vmalert.marker(other)) == null);
                }
                current.unit_command = try self.allocator.dupe(u8, command);
                current.unit_writes += 1;
                current.pending = true;
                current.present[@intFromEnum(op)] = true;
                if (self.fail_after_unit == component) return .{ .code = 1 };
                return .{ .code = 0, .output = "changed" };
            },
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

test "vmalert zero-delay unit migration dirties only its service and reruns become no-ops" {
    for ([_]workflow.Component{ .vmalert_logs, .vmalert_metrics }) |affected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
        var fake: Fake = .{ .allocator = a, .report = &report };
        try workflow.install(a, fake.asRemote(), &report);
        const current = fake.state(affected);
        // Model a previously installed unit with the unsafe startup flag. All
        // binaries, rules, URLs and the other service's unit are already current.
        current.unit_command = try std.mem.replaceOwned(u8, a, current.unit_command.?, "-group.maxStartDelay=1s", "-group.maxStartDelay=0s");
        const before = fake.states;
        fake.fail_after_unit = affected;
        report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
        try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
        try std.testing.expectEqual(affected, report.component.?);
        try std.testing.expectEqual(remote.Operation.unit, report.phase);
        for (extra, before) |component, previous| {
            const state = fake.state(component);
            try std.testing.expectEqual(component == affected, state.pending);
            try std.testing.expectEqual(previous.restarts, state.restarts);
            try std.testing.expectEqual(previous.unit_writes + @as(usize, @intFromBool(component == affected)), state.unit_writes);
        }
        try std.testing.expect(!fake.core.vm.dirty and !fake.core.vl.dirty and !fake.core.vt.dirty and !fake.core.gf.dirty);

        // The unit write completed before the failure. Recovery must restart
        // from persisted intent, verify, finalize, then leave the next run idle.
        fake.fail_after_unit = null;
        report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 1), report.changes);
        report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 0), report.changes);
        for (extra, before) |component, previous| {
            const state = fake.state(component);
            try std.testing.expect(!state.pending);
            try std.testing.expectEqual(previous.restarts + @as(usize, @intFromBool(component == affected)), state.restarts);
            try std.testing.expectEqual(previous.unit_writes + @as(usize, @intFromBool(component == affected)), state.unit_writes);
            try std.testing.expectEqual(previous.config_writes, state.config_writes);
            try std.testing.expectEqual(previous.downloads, state.downloads);
        }
        try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vl.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vt.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.gf.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.scrape_writes);
        try std.testing.expectEqual(@as(usize, 1), fake.scrape_reloads);
        try std.testing.expectEqual(@as(usize, 0), fake.notify_calls);
    }
}

test "ten service station installs then remains unchanged while probe add remove only reload scraping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
    var fake: Fake = .{ .allocator = a, .report = &report, .check_syntax = true };
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expect(report.changes > 0);
    try std.testing.expectEqual(@as(usize, 1), fake.scrape_writes);
    try std.testing.expect(!fake.scrape_pending);
    fake.check_syntax = false;
    for ([_][]const probes.Probe{ &one, &two, &one, &one }) |targets| {
        const before = fake.scrape_writes;
        report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = targets };
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
    var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
    var fake: Fake = .{ .allocator = a, .report = &report };
    fake.state(.vmalert_metrics).fail = .rules_ready;
    try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
    try std.testing.expectEqual(workflow.Component.vmalert_metrics, report.component.?);
    try std.testing.expect(fake.state(.vmalert_metrics).pending);
    try std.testing.expect(!fake.state(.vmalert_logs).pending);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.vmalert_metrics).calls[@intFromEnum(remote.Operation.finalize)]);
    try std.testing.expectEqual(@as(i64, 0), fake.now);
    fake.state(.vmalert_metrics).fail = null;
    report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
    try std.testing.expectError(error.RemoteOperationFailed, @import("verify.zig").verify(a, fake.asRemote(), &report));
    try std.testing.expectEqual(readiness.Check.station_ingress_required, report.check.?);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expect(fake.state(.vmalert_metrics).pending);
    report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
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
    var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one, .telegram_credentials = credentials, .telegram_configured = true };
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

test "station Telegram template update restarts only Alertmanager and identical rerun is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const credentials = try Secret.init(std.testing.allocator, "PRIVATE-TELEGRAM-test-payload");
    defer credentials.deinit();
    var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example", .telegram_credentials = credentials, .telegram_configured = true };
    var fake: Fake = .{ .allocator = a, .report = &report };
    try workflow.install(a, fake.asRemote(), &report);
    const reloads = fake.scrape_reloads;
    fake.template_digest = @splat(0); // An older DragonTools-managed template.
    report.changes = 0;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expect(report.changes > 0);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vl.restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vt.restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.core.gf.restarts);
    for (extra) |component| {
        try std.testing.expectEqual(@as(usize, if (component == .alertmanager) 2 else 1), fake.state(component).restarts);
        try std.testing.expect(!fake.state(component).pending);
    }
    report.changes = 0;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@as(usize, 2), fake.state(.alertmanager).restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.secret_writes);
    try std.testing.expectEqual(reloads, fake.scrape_reloads);
    try std.testing.expectEqual(@as(usize, 0), fake.notify_calls);
}

test "broken blackbox or missing stored metrics fail station without finalizing their intent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
    var fake: Fake = .{ .allocator = a, .report = &report };
    fake.state(.blackbox_exporter).fail = .http_ready;
    try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
    try std.testing.expectEqual(workflow.Component.blackbox_exporter, report.component.?);
    try std.testing.expect(fake.state(.blackbox_exporter).pending and fake.scrape_pending);
    try std.testing.expectEqual(@as(usize, 0), fake.state(.alertmanager).restarts);
    fake.state(.blackbox_exporter).fail = null;
    fake.scrape_fail = true;
    report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
    try std.testing.expectError(error.ReadinessTimedOut, workflow.install(a, fake.asRemote(), &report));
    try std.testing.expectEqual(readiness.Check.probe_metrics_ready, report.check.?);
    try std.testing.expect(fake.scrape_pending);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
    fake.scrape_fail = false;
    report = .{ .station_enabled = true, .ingress_hostname = "station.example", .probes = &one };
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expect(!fake.scrape_pending);
    try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
    report.changes = 0;
    try workflow.install(a, fake.asRemote(), &report);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
}

test "station ingress with zero clients retries readiness and finalizes independent intent" {
    for ([_]bool{ false, true }) |timeout| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example" };
        var fake: Fake = .{ .allocator = a, .report = &report };
        fake.state(.caddy).delayed = .caddy_tls;
        fake.state(.caddy).timeout = timeout;
        if (timeout) {
            try std.testing.expectError(error.ReadinessTimedOut, workflow.install(a, fake.asRemote(), &report));
            try std.testing.expectEqual(readiness.Check.caddy_tls, report.check.?);
            try std.testing.expect(fake.pki_present and fake.state(.caddy).pending);
            try std.testing.expect(!fake.state(.ingress_auth).pending);
            try std.testing.expectEqual(@as(i64, 30000), fake.now);
            fake.state(.caddy).timeout = false;
            report.changes = 0;
            try workflow.install(a, fake.asRemote(), &report);
        } else try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expect(fake.pki_present and fake.pki_calls > 0);
        try std.testing.expect(fake.state(.caddy).attempts >= 3);
        try std.testing.expect(!fake.state(.caddy).pending);
        const restarts = fake.state(.caddy).restarts;
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try @import("verify.zig").verify(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 0), report.changes);
        try std.testing.expectEqual(restarts, fake.state(.caddy).restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.state(.caddy).downloads);
        try std.testing.expectEqual(@as(usize, 1), fake.state(.ingress_auth).restarts);
    }
}

test "station Caddy binary unit config and server certificate changes restart only Caddy and rerun is unchanged" {
    const Change = enum { binary, unit, config, certificate };
    for (std.enums.values(Change)) |change| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example" };
        var fake: Fake = .{ .allocator = a, .report = &report };
        try workflow.install(a, fake.asRemote(), &report);
        switch (change) {
            // Native PKI tests prove publication marks only Caddy before write.
            .certificate => fake.state(.caddy).pending = true,
            .binary => fake.state(.caddy).present[@intFromEnum(remote.Operation.binary)] = false,
            .config => fake.state(.caddy).present[@intFromEnum(remote.Operation.config)] = false,
            .unit => fake.state(.caddy).unit_command = null,
        }
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 2), fake.state(.caddy).restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vm.restarts);
        try std.testing.expectEqual(@as(usize, 1), fake.core.vl.restarts);
        for (extra) |component| if (component != .caddy) try std.testing.expectEqual(@as(usize, 1), fake.state(component).restarts);
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 0), report.changes);
        try std.testing.expectEqual(@as(usize, 2), fake.state(.caddy).restarts);
    }
}

test "Caddy semantic failures preserve pending intent and recover to an unchanged install" {
    for ([_]readiness.Check{ .caddy_account, .caddy_binary, .caddy_unit, .caddy_config, .caddy_directories, .caddy_systemd_properties, .caddy_credentials, .caddy_listener, .caddy_tls }) |check| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example" };
        var fake: Fake = .{ .allocator = a, .report = &report };
        try workflow.install(a, fake.asRemote(), &report);
        const current = fake.state(.caddy);
        current.pending = true;
        current.fail = check;
        const finalized = current.calls[@intFromEnum(remote.Operation.finalize)];
        report.changes = 0;
        try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
        try std.testing.expectEqual(workflow.Component.caddy, report.component.?);
        try std.testing.expectEqual(check, report.check.?);
        try std.testing.expectEqual(@as(usize, 1), current.attempts);
        try std.testing.expectEqual(@as(i64, 0), fake.now);
        try std.testing.expect(current.pending);
        try std.testing.expectEqual(finalized, current.calls[@intFromEnum(remote.Operation.finalize)]);
        current.fail = null;
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 1), report.changes);
        try std.testing.expect(!current.pending);
        try @import("verify.zig").verify(a, fake.asRemote(), &report);
        const restarts = current.restarts;
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 0), report.changes);
        try std.testing.expectEqual(restarts, current.restarts);
        try std.testing.expectEqual(@as(usize, 1), current.config_writes);
        try std.testing.expectEqual(@as(usize, 1), current.unit_writes);
        try std.testing.expectEqual(@as(usize, 1), current.downloads);
        for (extra) |component| if (component != .caddy) try std.testing.expectEqual(@as(usize, 1), fake.state(component).restarts);
    }
}

test "ingress managed checks identify drift and retained production restart intent converges to no-op" {
    for ([_]readiness.Check{ .managed_account, .managed_unit, .managed_helper, .managed_directories, .managed_registry, .managed_server_state, .managed_systemd_properties }) |check| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: workflow.Report = .{ .station_enabled = true, .ingress_hostname = "station.example" };
        var fake: Fake = .{ .allocator = a, .report = &report };
        try workflow.install(a, fake.asRemote(), &report);
        const auth = fake.state(.ingress_auth);
        // Observed production state: desired resources already installed,
        // healthy running service, but failed verification retained its marker.
        auth.pending = true;
        auth.fail = check;
        const finalized = auth.calls[@intFromEnum(remote.Operation.finalize)];
        report.changes = 0;
        try std.testing.expectError(error.RemoteOperationFailed, workflow.install(a, fake.asRemote(), &report));
        try std.testing.expectEqual(workflow.Component.ingress_auth, report.component.?);
        try std.testing.expectEqual(check, report.check.?);
        try std.testing.expectEqual(@as(usize, 1), auth.attempts);
        try std.testing.expectEqual(@as(i64, 0), fake.now);
        try std.testing.expect(auth.pending);
        try std.testing.expectEqual(finalized, auth.calls[@intFromEnum(remote.Operation.finalize)]);
        try std.testing.expectEqual(@as(usize, 1), auth.config_writes);
        try std.testing.expectEqual(@as(usize, 1), auth.unit_writes);

        auth.fail = null;
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 1), report.changes);
        try std.testing.expect(!auth.pending);
        const restarts = auth.restarts;
        try @import("verify.zig").verify(a, fake.asRemote(), &report);
        report.changes = 0;
        try workflow.install(a, fake.asRemote(), &report);
        try std.testing.expectEqual(@as(usize, 0), report.changes);
        try std.testing.expectEqual(restarts, auth.restarts);
        try std.testing.expectEqual(@as(usize, 1), auth.config_writes);
        try std.testing.expectEqual(@as(usize, 1), auth.unit_writes);
        for (extra) |component| if (component != .ingress_auth) try std.testing.expectEqual(@as(usize, 1), fake.state(component).restarts);
    }
}
