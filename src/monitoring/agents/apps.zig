//! Application-specific manifests merge only agent signal configuration.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const common = @import("common.zig");
const model = @import("model.zig");

pub fn prepare(a: std.mem.Allocator, app: remote.Remote, report: *model.Report, scope: model.ApplicationScope, host: []const u8, station: []const u8, mutate: bool) !model.Registration {
    try scope.validate();
    if (!model.validHostId(host)) return error.InvalidMachineIdentity;
    try model.validateEndpoint(station);
    report.application = scope.name;
    report.component = .application_host;
    const host_state = @import("../../system/host.zig");
    _ = try host_state.parse(try report.call(app, .detect, host_state.detect_command));
    for (scope.services) |service| _ = try report.call(app, .service_exists, try common.selectedService(a, service.systemd));
    if (mutate) _ = try report.call(app, .directories, try @import("install.zig").parentDirectories(a));
    report.component = .application_host;
    const command = try common.python(a, @embedFile("apps.py"), &.{ if (mutate) "apply" else "verify", try std.json.Stringify.valueAlloc(a, scope, .{}), host, station });
    const result = try app.run(if (mutate) .config else .status, command);
    if (result.code != 0) return error.ApplicationAgentOwnershipConflict;
    const split = std.mem.indexOfScalar(u8, result.output, '\n') orelse return error.InvalidAgentRegistration;
    if (std.mem.eql(u8, result.output[0..split], "changed")) {
        if (!mutate) return error.AgentRegistrationMismatch;
        report.state.changes += 1;
    } else if (!std.mem.eql(u8, result.output[0..split], "unchanged")) return error.InvalidAgentRegistration;
    return model.Registration.parse(a, result.output[split + 1 ..]);
}

test "application manifests preserve independent repositories and reject ownership conflicts" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/agent_apps_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
