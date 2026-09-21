//! Managed dashboards have no data-agent activation side effects.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const workflow = @import("../install.zig");
const ready = @import("../readiness.zig");
const Config = @import("../../config/application.zig").Config;
pub const program = "__name__='dragontools_dashboards'\n" ++ @embedFile("model.py") ++ "\n" ++ @embedFile("state.py") ++ "\nsys.exit(main())\n";
pub fn data(a: std.mem.Allocator, config: Config, host: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .application = config.application.name, .environment = config.application.environment, .host = host, .services = config.services, .probes = config.probes }, .{});
}
fn command(a: std.mem.Allocator, mode: []const u8, payload: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", program, mode, payload });
}
pub fn station(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, grafana: bool) !void {
    report.check = .dashboard_ownership;
    _ = try report.call(r, .provisioning, try command(a, if (grafana) "setup-grafana" else "setup-vm", "{\"station\":true}"));
}
pub fn preflight(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, config: Config, host: []const u8) !void {
    _ = try ready.deterministic(a, r, report, .dashboard_ownership, try command(a, "preflight", try data(a, config, host)));
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, payload: []const u8) !void {
    try ready.poll(a, r, report, .dashboards_ready, ready.telemetry_ms, try command(a, "loaded", payload), ready.ready);
}
pub fn apply(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, config: Config, host: []const u8) !void {
    const payload = try data(a, config, host);
    report.check = .dashboard_ownership;
    _ = try report.call(r, .provisioning, try command(a, "publish", payload));
    try verify(a, r, report, payload);
    _ = try report.call(r, .finalize, try command(a, "finish", payload));
}
test "dashboard ownership queries rendering and publication fixtures" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/dashboards_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
