const std = @import("std");
const remote = @import("../../system/remote.zig");
const ready = @import("../readiness.zig");
const workflow = @import("../install.zig");
pub fn verify(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, report: *workflow.Report, config: @import("../../config/application.zig").Config, host: []const u8) !void {
    var configured = false;
    for (config.services) |service| configured = configured or service.http != null;
    if (!configured) return;
    const payload = try @import("main.zig").data(a, config, host);
    const source = @embedFile("source.py") ++ "\nsys.exit(source_main())\n";
    _ = try ready.deterministic(a, app, report, .http_metrics_ready, try remote.shell(a, &.{ "python3", "-I", "-B", "-c", source, payload }));
    const program = "__name__='dragontools_dashboard_signals'\n" ++ @embedFile("model.py") ++ "\n" ++ @embedFile("signals.py") ++ "\nsys.exit(signal_main())\n";
    try ready.poll(a, station, report, .http_metrics_ready, ready.telemetry_ms, try remote.shell(a, &.{ "python3", "-I", "-B", "-c", program, try @import("main.zig").data(a, config, host) }), ready.ready);
}
