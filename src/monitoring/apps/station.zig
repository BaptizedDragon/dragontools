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
pub fn preflight(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, config: Config, identity: []const u8) !void {
    _ = try readiness.deterministic(a, r, report, .application_ownership, try command(a, config, identity, "preflight", false));
}
pub fn apply(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch, config: Config, identity: []const u8) !void {
    _ = try report.call(r, .config, try command(a, config, identity, "publish", true));
    // First integration updates generated units once. Exact fixed rule packs are
    // preserved, and each evaluator keeps its own restart/finalization boundary.
    for ([_]vmalert.Kind{ .logs, .metrics }) |kind| {
        report.component = if (kind == .logs) .vmalert_logs else .vmalert_metrics;
        try vmalert.install(a, r, report, arch, kind);
    }
    report.component = .victoriametrics;
    _ = try report.call(r, .activate, try command(a, config, identity, "activate", true));
    try verify(a, r, report, arch, config, identity);
    _ = try report.call(r, .finalize, try command(a, config, identity, "finalize", true));
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch, config: Config, identity: []const u8) !void {
    _ = try readiness.deterministic(a, r, report, .managed_state, try command(a, config, identity, "managed", false));
    for ([_]vmalert.Kind{ .logs, .metrics }) |kind| try vmalert.health(a, r, report, arch, kind);
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
