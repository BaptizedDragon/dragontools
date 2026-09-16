//! The concrete install plan; policy values and workflow availability stay distinct.
const std = @import("std");
const policy = @import("policy.zig");
const vm = @import("../components/victoriametrics.zig");
const vl = @import("../components/victorialogs.zig");
const vt = @import("../components/victoriatraces.zig");
const grafana = @import("../components/grafana.zig");

pub const unavailable = "Not yet available: Grafana Logs datasource, dashboards, vmalert, Alertmanager, Telegram, Vector, vmagent, OTel Collector, monitoring agents, firewall, TLS, update monitoring and maintenance.\n";

pub fn render(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "Plan: install VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana.\n" ++
        "Detect Ubuntu 24.04/26.04 + systemd once. For each component, ensure its dedicated user and data directory, verify committed artifact integrity, install versioned files and a hardened unit, restart only when required, verify, then clear its restart marker.\n\n" ++
        "VictoriaMetrics: loopback:8428\n" ++
        "  install pinned release {s}\n" ++
        "  retention: {s}; filesystem reserve: {d}% (bytes calculated on host)\n" ++
        "  verify health and stored self-scraped metrics\n\n" ++
        "VictoriaLogs: loopback:9428\n" ++
        "  install pinned release {s}\n" ++
        "  retention: disk-bound; logical limit: {s}\n" ++
        "  native partition budget: {d}% of filesystem capacity\n" ++
        "  verify health, application identity and writable storage\n" ++
        "  periodic cleanup preserves the newest two partitions; other writers can fill the filesystem earlier\n\n" ++
        "VictoriaTraces: loopback:{d}\n" ++
        "  install pinned release {s}\n" ++
        "  retention: disk-bound; logical limit: {s}\n" ++
        "  native partition budget: {d}% of filesystem capacity\n" ++
        "  periodic cleanup preserves the newest two partitions; other writers can fill the filesystem earlier\n" ++
        "  verify health, application identity and writable storage; extra OTLP gRPC listener disabled\n\n" ++
        "Grafana: loopback:3000\n" ++
        "  install pinned OSS release {s} with a dedicated account and SQLite data\n" ++
        "  local authentication enabled; change the initial admin password at first login\n" ++
        "  Metrics datasource -> VictoriaMetrics http://127.0.0.1:8428\n" ++
        "  Traces datasource -> VictoriaTraces http://127.0.0.1:10428/select/jaeger\n" ++
        "  verify application identity, effective configuration, provisioned records and backend queries\n" ++
        "  authenticated Grafana query/UI checks require manual verification through the tunnel\n\n" ++
        "Access: SSH port forwarding only; public HTTPS, TLS and firewall management are unavailable.\n\n" ++
        "Safe rerun: inspect actual state, resume pending activation, and verify before finalization. Healthy unchanged services are not restarted; unchanged valid binaries are not downloaded. No controller state database.\n" ++
        "Alert policy is defined; rendering is partial/provisional. Host/service expressions await verified metric contracts. No rule deployment or alert evaluation/delivery.\n" ++
        unavailable ++
        "No remote operations performed.\n", .{
        vm.version,                          policy.metrics.retention, policy.metrics.reserve_percent,
        vl.version,                          policy.logs.retention,    policy.logs.cleanup_usage_percent,
        vt.port,                             vt.version,               policy.traces.retention,
        policy.traces.cleanup_usage_percent, grafana.version,
    });
}

test "installation plan describes four pinned components and the remaining boundary" {
    const output = try render(std.testing.allocator);
    defer std.testing.allocator.free(output);
    for ([_][]const u8{ "VictoriaMetrics: loopback:8428", "VictoriaLogs: loopback:9428", "VictoriaTraces: loopback:10428", "Grafana: loopback:3000", grafana.version, "local authentication enabled", "http://127.0.0.1:10428/select/jaeger", vm.version, vl.version, vt.version, "retention: 90d; filesystem reserve: 20%", "logical limit: 100y", "partition budget: 75%", "newest two partitions", "No remote operations performed." }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }
    for ([_][]const u8{ "VictoriaMetrics", "VictoriaLogs", "VictoriaTraces" }) |implemented| {
        try std.testing.expect(std.mem.indexOf(u8, unavailable, implemented) == null);
    }
}
