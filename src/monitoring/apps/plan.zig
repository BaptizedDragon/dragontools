//! Local application plan: public validated config only; no SSH or secret access.
const std = @import("std");
const application = @import("../../config/application.zig");

pub fn render(a: std.mem.Allocator, config: application.Config) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("Application monitoring plan (local; SSH not attempted).\n");
    try w.print("Application: {s}\nEnvironment: {s}\nTarget SSH alias: {s}\nStation:\n  SSH alias: {s}\n  ingestion hostname: {s}\n  metrics endpoint: https://{s}:9443\n  logs endpoint: https://{s}:9444\n", .{ config.application.name, config.application.environment, config.target_ssh_host, config.station_ssh_host, config.station_hostname, config.station_hostname, config.station_hostname });
    try w.writeAll("Vector: ensure pinned host metrics with trusted application/environment/host identity.\nHost maintenance: ensure restricted 5m observer timer and persistent transition state; ship host events via Vector :9444.\nSelected journal streams:\n");
    var logs: usize = 0;
    var metrics: usize = 0;
    for (config.services) |service| {
        if (service.logs) {
            try w.print("  {s}: {s}\n", .{ service.name, service.systemd });
            logs += 1;
        }
    }
    if (logs == 0) try w.writeAll("  none requested; host metrics and host events remain enabled\n");
    try w.writeAll("Application Prometheus targets:\n");
    for (config.services) |service| if (service.metrics_url) |url| {
        try w.print("  {s}: {s}\n", .{ service.name, url });
        metrics += 1;
    };
    try w.writeAll(if (metrics == 0) "  none requested; this application does not require vmagent\n" else "vmagent: ensure pinned agent for these explicit targets.\n");
    try w.writeAll("Probes (station blackbox HTTP GET, TLS verified, expected 2xx):\n");
    for (config.probes) |probe| try w.print("  {s}: {s}\n", .{ probe.name, probe.url });
    if (config.probes.len == 0) try w.writeAll("  none\n");
    try w.writeAll("Alerts: shared CPU/memory/disk/inode rules; ServiceProbeFailed per probe (2m, critical) unless overridden below.\n");
    for (config.alerts) |alert| {
        try w.print("  {s}: {s}, {s}", .{ alert.name, @tagName(alert.source), @tagName(alert.severity) });
        if (alert.source == .probe) {
            try w.print(", overrides probe {s}, for {s}\n", .{ alert.probe.?, alert.for_duration orelse "2m" });
        } else {
            try w.print(", service {s}, level {s}, count >= {d} in {s}\n", .{ alert.service orelse "all enabled log services", alert.level.?, alert.threshold.?, alert.window.? });
        }
    }
    try w.print("Owned station namespace: /etc/dragontools/apps/{s}/\n  manifest.json, logs.rules.yml, metrics.rules.yml, scrape.yml\n", .{config.application.name});
    try w.writeAll("Service resources: observe current systemd cgroup v2 CPU/memory/tasks/IO; transport normalized metrics through Vector.\nDashboards: reconcile only this application's VMUI and Grafana documents; preserve manual assets.\n");
    for (config.services) |service| {
        if (service.http) |_| {
            try w.print("HTTP dashboard metrics: explicit family mapping for {s}; verify counter/histogram types and recent samples.\n", .{service.name});
        } else {
            try w.print("HTTP request dashboard metrics unavailable for {s}: no explicit request counter/duration histogram mapping.\n", .{service.name});
        }
    }
    try w.writeAll("Ensure bounded journald and Vector buffers; preserve stricter administrator limits.\nCaddy: require registered mTLS; TCP 9443 metrics, TCP 9444 logs. Raw backends stay loopback-only. TCP 9445 is reserved and closed.\nGenerate client private keys only on the monitored host; exchange public CSRs/certificates. Renew near-expiry leaf certificates with existing keys.\nInspect actual ownership and other application manifests during apply; preserve their signals.\nReconcile shared station loaders once if needed; later changes affect only their consumers.\nVerify recent signals, loaded probes and rules before clearing pending intent.\nNo firewall changes, secret resolution, SSH or mutations performed by this plan.\nTraces: skipped (unsupported); OTel traces, custom metrics alerts: unavailable.\n");
    return out.toOwnedSlice();
}

test "application local plan describes trusted signals and only its owned namespace" {
    var config = try application.parse(std.testing.allocator,
        \\version=1
        \\[application]
        \\name='doers'
        \\environment='production'
        \\[target]
        \\ssh_host='replace-me-app'
        \\[station]
        \\ssh_host='replace-me-station'
        \\hostname='monitoring.baptizeddragon.com'
        \\[[service]]
        \\name='web'
        \\systemd='web.service'
        \\[service.logs]
        \\enabled=true
        \\[service.metrics]
        \\url='http://127.0.0.1:16000/metrics'
        \\[[probe]]
        \\name='website'
        \\url='https://example.com/healthz'
    );
    defer config.deinit();
    const output = try render(std.testing.allocator, config);
    defer std.testing.allocator.free(output);
    for ([_][]const u8{ "local; SSH not attempted", "Target SSH alias: replace-me-app", "SSH alias: replace-me-station", "ingestion hostname: monitoring.baptizeddragon.com", "https://monitoring.baptizeddragon.com:9443", "web: web.service", "http://127.0.0.1:16000/metrics", "https://example.com/healthz", "/etc/dragontools/apps/doers/", "ServiceProbeFailed", "vmagent: ensure", "OTel traces" }) |needle| try std.testing.expect(std.mem.indexOf(u8, output, needle) != null);
    for ([_][]const u8{ "op://", "client.key", "/etc/dragontools/apps/orderflow/" }) |needle| try std.testing.expect(std.mem.indexOf(u8, output, needle) == null);
}
