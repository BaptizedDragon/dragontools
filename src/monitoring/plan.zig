//! The concrete install plan. policy.renderPlan retains its original policy-only
//! snapshot for internal callers; CLI availability belongs to this workflow.
const std = @import("std");
const policy = @import("policy.zig");
const vm = @import("../components/victoriametrics.zig");
const vl = @import("../components/victorialogs.zig");

pub const unavailable = "Not yet available: VictoriaTraces, Grafana, vmalert, Alertmanager, Telegram, Vector, vmagent, OTel Collector, node_exporter, monitoring agents, firewall, TLS, update monitoring and maintenance.\n";

pub fn render(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "Plan: install VictoriaMetrics and VictoriaLogs.\n" ++
        "Detect Ubuntu 24.04/26.04 + systemd once. For each component, ensure its dedicated user and data directory, verify pinned archive and binary SHA-256, install a versioned executable and hardened unit, restart only when required, verify, then clear its restart marker.\n\n" ++
        "VictoriaMetrics: loopback:8428\n" ++
        "  install pinned release {s}\n" ++
        "  retention: {s}; filesystem reserve: {d}% (bytes calculated on host)\n" ++
        "  verify health and stored self-scraped metrics\n\n" ++
        "VictoriaLogs: loopback:9428\n" ++
        "  install pinned release {s}\n" ++
        "  retention: disk-bound; logical limit: {s}\n" ++
        "  native cleanup threshold: {d}% filesystem usage\n" ++
        "  verify health, application identity and writable storage\n" ++
        "  cleanup checks are periodic and preserve the newest two days; usage can exceed the threshold\n\n" ++
        "Alert rules are rendered locally only; no rule deployment or alert evaluation/delivery.\n" ++
        unavailable ++
        "No remote operations performed.\n", .{
        vm.version, policy.metrics.retention, policy.metrics.reserve_percent,
        vl.version, policy.logs.retention,    policy.logs.cleanup_usage_percent,
    });
}

test "installation plan describes both pinned components and the remaining boundary" {
    const output = try render(std.testing.allocator);
    defer std.testing.allocator.free(output);
    for ([_][]const u8{ "VictoriaMetrics: loopback:8428", "VictoriaLogs: loopback:9428", vm.version, vl.version, "retention: 90d; filesystem reserve: 20%", "logical limit: 100y", "cleanup threshold: 75%", "newest two days", "No remote operations performed." }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "VictoriaLogs") == null);
}
