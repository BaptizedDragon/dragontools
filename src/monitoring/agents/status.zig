//! One read-only snapshot; no credentials are exported or telemetry generated.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const common = @import("common.zig");
const model = @import("model.zig");
fn state(a: std.mem.Allocator, app: remote.Remote, name: []const u8, verb: []const u8) !bool {
    const result = try app.run(.status, try remote.shell(a, &.{ "systemctl", verb, "--quiet", name }));
    if (result.code == 255) return error.SshConnectionFailed;
    return result.code == 0;
}
fn signal(a: std.mem.Allocator, station: remote.Remote, registration: model.Registration, mode: []const u8) !bool {
    const result = try station.runTimed(.status, try common.python(a, @embedFile("signals.py"), &.{ mode, try registration.json(a) }), 15_000);
    return result.code == 0;
}
pub fn status(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, registration: model.Registration) ![]const u8 {
    return statusSelected(a, app, station, registration, null);
}
pub fn statusForApplication(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, registration: model.Registration, name: []const u8) ![]const u8 {
    return statusSelected(a, app, station, registration, name);
}
fn statusSelected(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, registration: model.Registration, name: ?[]const u8) ![]const u8 {
    const selected = registration.selected(name);
    const active = try state(a, app, "dragontools-vector.service", "is-active");
    const enabled = try state(a, app, "dragontools-vector.service", "is-enabled");
    const logs = try signal(a, station, selected, "logs");
    var log_count: usize = if (selected.applications.len == 0) selected.services.len else 0;
    for (selected.applications) |scope| for (scope.services) |service| {
        if (service.logs) log_count += 1;
    };
    const metrics = try signal(a, station, selected, "host");
    const vector = try std.fmt.allocPrint(a, "Vector\n  {s}\n  {s}\n  log forwarding {s}\n  host metrics {s}\n", .{ if (active) "active" else "inactive", if (enabled) "enabled" else "disabled", if (log_count == 0) "disabled (no selected services)" else if (logs) "healthy (recent stream identity)" else "unverified (no recent stream or station unavailable)", if (metrics) "flowing" else "unverified" });
    if (selected.metricsCount() == 0) return std.fmt.allocPrint(a, "{s}vmagent\n  not required (no application metrics targets)\nOTel traces: unavailable.\n", .{vector});
    const vm_active = try state(a, app, "dragontools-vmagent.service", "is-active");
    const vm_enabled = try state(a, app, "dragontools-vmagent.service", "is-enabled");
    const flowing = try signal(a, station, selected, "app");
    return std.fmt.allocPrint(a, "{s}vmagent\n  {s}\n  {s}\n  configured targets: {d}\n  remote write {s}\nOTel traces: unavailable.\n", .{ vector, if (vm_active) "active" else "inactive", if (vm_enabled) "enabled" else "disabled", selected.metricsCount(), if (flowing) "healthy (fresh scrape telemetry; target may be down)" else "unverified (no recent telemetry or station unavailable)" });
}
