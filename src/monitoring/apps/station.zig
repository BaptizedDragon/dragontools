//! Per-application station ownership with native scraper/vmalert integration.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const host = @import("../../system/host.zig");
const workflow = @import("../install.zig");
const readiness = @import("../readiness.zig");
const vmalert = @import("../vmalert.zig");
const vm = @import("../../components/victoriametrics.zig");
const alert_binary = @import("../../components/vmalert.zig");
const Config = @import("../../config/application.zig").Config;
const common = "__name__='dragontools_app'\n" ++ @embedFile("station_model.py") ++ "\n" ++ @embedFile("../scrape.py") ++ "\n" ++ @embedFile("../vmalert_rules.py") ++ "\n" ++ @embedFile("station_read.py");
const read_program = common ++ "\nsys.exit(app_read_main())\n";
const mutate_program = common ++ "\n" ++ @embedFile("station_mutate.py") ++ "\nsys.exit(app_mutate_main())\n";

fn payload(a: std.mem.Allocator, config: Config, identity: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .config = .{ .application = config.application.name, .environment = config.application.environment, .host = identity, .services = config.services, .probes = config.probes, .alerts = config.alerts },
        .pins = .{ .vm_amd64 = vm.artifact(.amd64).binary_sha256, .vm_arm64 = vm.artifact(.arm64).binary_sha256, .alert_amd64 = alert_binary.artifact(.amd64).binary_sha256, .alert_arm64 = alert_binary.artifact(.arm64).binary_sha256 },
        .shared = .{ .logs_unit = try vmalert.unit(a, .logs), .metrics_unit = try vmalert.unit(a, .metrics), .logs_rules = try vmalert.rules(a, .logs), .metrics_rules = try vmalert.rules(a, .metrics) },
    }, .{});
}
fn command(a: std.mem.Allocator, config: Config, identity: []const u8, mode: []const u8, mutation: bool) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", if (mutation) mutate_program else read_program, mode, try payload(a, config, identity) });
}
fn rulesCommand(a: std.mem.Allocator, config: Config, identity: []const u8, kind: vmalert.Kind) ![]const u8 {
    return command(a, config, identity, try std.fmt.allocPrint(a, "rules-{s}", .{@tagName(kind)}), false);
}
pub fn preflight(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, config: Config, identity: []const u8) !void {
    _ = try readiness.deterministic(a, r, report, .application_ownership, try command(a, config, identity, "preflight", false));
}
pub fn apply(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch, config: Config, identity: []const u8) !void {
    _ = try report.call(r, .config, try command(a, config, identity, "publish", true));
    // First integration updates generated units once. Exact fixed rule packs are
    // preserved, and each evaluator keeps its own restart/finalization boundary.
    for ([_]vmalert.Kind{ .logs, .metrics }) |kind| {
        report.component = if (kind == .logs) .vmalert_logs else .vmalert_metrics;
        try vmalert.installWithRuleCheck(a, r, report, arch, kind, try rulesCommand(a, config, identity, kind));
    }
    report.component = .victoriametrics;
    _ = try report.call(r, .activate, try command(a, config, identity, "activate", true));
    try verify(a, r, report, arch, config, identity);
    _ = try report.call(r, .finalize, try command(a, config, identity, "finalize", true));
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch, config: Config, identity: []const u8) !void {
    _ = try readiness.deterministic(a, r, report, .managed_state, try command(a, config, identity, "managed", false));
    for ([_]vmalert.Kind{ .logs, .metrics }) |kind| {
        report.component = if (kind == .logs) .vmalert_logs else .vmalert_metrics;
        try vmalert.health(a, r, report, arch, kind);
        try vmalert.rulesReady(a, r, report, arch, kind, try rulesCommand(a, config, identity, kind));
    }
    report.component = .victoriametrics;
    try readiness.poll(a, r, report, .probe_metrics_ready, readiness.telemetry_ms, try command(a, config, identity, "probes", false), readiness.ready);
}
pub fn status(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, config: Config, identity: []const u8) ![]const u8 {
    const state = try report.call(r, .status, try command(a, config, identity, "status", false));
    if (std.mem.eql(u8, state, "ready")) return "Station:\n  probes registered; recent probe pipeline samples available\n  application alerts loaded\n";
    if (std.mem.eql(u8, state, "pending")) return "Station:\n  application files registered\n  probe pipeline or alert readiness not yet verified\n";
    return error.InvalidApplicationStationStatus;
}

test "application station ownership native loader and readiness fixtures" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/app_station_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "station base readiness is independent while application rules gate verification and finalization" {
    const Fake = struct {
        report: *workflow.Report,
        mode: enum { missing, delayed, ready } = .missing,
        pending: bool = true,
        attempts: usize = 0,
        restarts: usize = 0,
        finalizations: usize = 0,
        milliseconds: i64 = 0,
        fn now(ctx: *anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.milliseconds;
        }
        fn sleep(ctx: *anyopaque, delay: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.milliseconds += delay;
        }
        fn call(ctx: *anyopaque, op: remote.Operation, cmd: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (op == .health and self.report.check == .rules_ready) {
                // The mode argument follows the embedded read-only program.
                // Base station probes have no application command at all.
                if (std.mem.indexOf(u8, cmd, "sys.exit(app_read_main())")) |end| {
                    if (std.mem.indexOfPos(u8, cmd, end, "rules-metrics") != null) {
                        self.attempts += 1;
                        if (self.mode == .missing or self.mode == .delayed and self.attempts <= 2) return .{ .code = 75 };
                    }
                }
            }
            if (self.report.component == .vmalert_metrics) {
                if (op == .activate and self.pending) {
                    self.restarts += 1;
                    return .{ .code = 0, .output = "changed" };
                }
                if (op == .finalize) {
                    self.finalizations += 1;
                    self.pending = false;
                }
            }
            return .{ .code = 0, .output = "unchanged" };
        }
        fn asRemote(self: *@This()) remote.Remote {
            return .{ .context = self, .execute = call, .clock = .{ .context = self, .now_ms = now, .sleep_ms = sleep } };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try @import("../../config/application.zig").parse(a, @import("../../config/application.zig").example);
    const identity = "dt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var report: workflow.Report = .{ .component = .vmalert_metrics };
    var fake: Fake = .{ .report = &report };

    // A station install succeeds without consulting any application's API rules.
    try vmalert.install(a, fake.asRemote(), &report, .amd64, .metrics);
    try std.testing.expectEqual(@as(usize, 0), fake.attempts);
    try std.testing.expect(!fake.pending);
    report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, verify(a, fake.asRemote(), &report, .amd64, config, identity));
    try std.testing.expectEqual(readiness.Check.rules_ready, report.check.?);
    try std.testing.expectEqual(workflow.Component.vmalert_metrics, report.component.?);
    try std.testing.expectEqual(@as(i64, readiness.telemetry_ms), fake.milliseconds);
    try std.testing.expectEqual(@as(usize, 1), fake.finalizations);

    // An apply's own missing rule cannot clear this evaluator's restart marker.
    fake.pending = true;
    report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, apply(a, fake.asRemote(), &report, .amd64, config, identity));
    try std.testing.expect(fake.pending);
    try std.testing.expectEqual(@as(usize, 1), fake.finalizations);
    fake.mode = .delayed;
    fake.attempts = 0;
    const before = fake.milliseconds;
    report = .{};
    try apply(a, fake.asRemote(), &report, .amd64, config, identity);
    try std.testing.expectEqual(@as(i64, 1500), fake.milliseconds - before);
    try std.testing.expect(!fake.pending);
    try std.testing.expectEqual(@as(usize, 2), fake.finalizations);
    const restarts = fake.restarts;
    report = .{};
    try apply(a, fake.asRemote(), &report, .amd64, config, identity);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(restarts, fake.restarts);
}
