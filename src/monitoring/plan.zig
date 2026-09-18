//! The concrete install plan; policy values and workflow availability stay distinct.
const std = @import("std");
const policy = @import("policy.zig");
const vm = @import("../components/victoriametrics.zig");
const vl = @import("../components/victorialogs.zig");
const vt = @import("../components/victoriatraces.zig");
const grafana = @import("../components/grafana.zig");
const logs_plugin = @import("../components/grafana_victorialogs_plugin.zig");

pub const unavailable = "Not yet available: dashboards, OTel Collector/traces agents, HostDown and systemd-service state alerts, firewall, public Grafana TLS, automatic OS upgrades.\n";

pub fn renderStation(a: std.mem.Allocator, grafana_configured: bool, telegram_configured: bool, probe_count: usize) ![]const u8 {
    const core = try renderWithCredentials(a, grafana_configured);
    defer a.free(core);
    const without_footer = try std.mem.replaceOwned(u8, a, core, unavailable ++ "No remote operations performed.\n", "");
    defer a.free(without_footer);
    const station_core = try std.mem.replaceOwned(u8, a, without_footer, "Plan: install VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana.\n", "Plan: install the monitoring station (eight services).\n");
    defer a.free(station_core);
    return std.fmt.allocPrint(a, "{s}\nExternal HTTP probes: {d} configured (GET, HTTP 2xx, verified TLS, 30s interval / 5s scrape timeout).\n" ++
        "Blackbox exporter {s}: loopback:9115; dedicated dt-blackbox; HTTP/1.1 only.\n" ++
        "VictoriaMetrics native scraper: fixed configuration path; one initial unit migration, then target changes use reload without restart.\n" ++
        "Probe status observes stored telemetry; probe_success=0 is valid monitoring state, not an installation failure.\n" ++
        "vmalert {s}: independent logs loopback:8880 -> VictoriaLogs and metrics loopback:8881 -> VictoriaMetrics; both notify Alertmanager.\n" ++
        "Deploy ErrorBurst/CriticalLogEvent, ServiceProbeFailed (probe_success == 0 for 2m), and five host-pressure rules selecting verified Vector metrics; no latency rules.\n" ++
        "Alertmanager {s}: loopback:9093; clustering disabled; Telegram {s}.\n" ++
        "Configured Telegram references resolve locally during install only, then transfer through protected stdin to dt-alertmanager 0400 secret files.\n" ++
        "Verification never sends test alerts; notify-test is a separate explicit command.\n" ++
        unavailable ++ "No remote operations performed.\n", .{ station_core, probe_count, @import("../components/blackbox_exporter.zig").version, @import("../components/vmalert.zig").version, @import("../components/alertmanager.zig").version, if (telegram_configured) "configured via secret references" else "disabled (no references)" });
}

pub fn render(a: std.mem.Allocator) ![]const u8 {
    return renderWithCredentials(a, false);
}
pub fn renderWithCredentials(a: std.mem.Allocator, configured: bool) ![]const u8 {
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
        "  local authentication enabled\n" ++
        "  administrator credentials: {s}\n" ++
        "  official VictoriaLogs datasource plugin {s} {s}; signed, SHA256-pinned, persistent versioned storage\n" ++
        "  Metrics datasource -> VictoriaMetrics http://127.0.0.1:8428\n" ++
        "  Logs datasource -> VictoriaLogs http://127.0.0.1:9428\n" ++
        "  Traces datasource -> VictoriaTraces http://127.0.0.1:10428/select/jaeger\n" ++
        "  verify application identity, effective configuration, provisioned records and backend queries\n" ++
        "  {s}\n" ++
        "  {s}\n" ++
        "  Metrics/Traces query-engine and browser UI checks require manual verification through the tunnel\n\n" ++
        "Grafana access: SSH port forwarding only; public Grafana HTTPS/TLS and firewall management are unavailable.\n\n" ++
        "Safe rerun: inspect actual state, resume pending activation, and verify before finalization. Healthy unchanged services are not restarted; unchanged valid binaries are not downloaded. No controller state database.\n" ++
        "Host metric rules use verified Vector contracts; systemd-service state alerts remain deferred.\n" ++
        "Application-host logs/metrics use monitoring agents with authenticated mTLS ingestion on station :9443; station install alone does not install agents.\n" ++
        unavailable ++
        "No remote operations performed.\n", .{
        vm.version,
        policy.metrics.retention,
        policy.metrics.reserve_percent,
        vl.version,
        policy.logs.retention,
        policy.logs.cleanup_usage_percent,
        vt.port,
        vt.version,
        policy.traces.retention,
        policy.traces.cleanup_usage_percent,
        grafana.version,
        if (configured) "configured via secret references" else "unmanaged; change the initial admin password at first login",
        logs_plugin.id,
        logs_plugin.version,
        if (configured) "resolve credentials locally for install/verify; authenticate, reconcile during install only, then verify" else "credential authentication is not checked without explicit references",
        if (configured) "verify Logs plugin health and a bounded read-only LogsQL query through Grafana" else "Logs plugin query requires administrator references; direct backend query and provisioning are checked",
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
