//! Grafana's non-secret, deterministic station configuration.
const std = @import("std");

pub const ini_path = "/etc/dragontools/grafana/grafana.ini";
pub const datasources_path = "/etc/dragontools/grafana/provisioning/datasources/dragontools.yaml";

// The initial admin uses Grafana's first-login flow. Do not put credentials here
// or attempt admin/admin authentication during verification after first startup.
// Pinned settings: https://github.com/grafana/grafana/blob/v13.2.2/conf/defaults.ini
pub const ini =
    \\# Managed by DragonTools
    \\[server]
    \\protocol = http
    \\http_addr = 127.0.0.1
    \\http_port = 3000
    \\domain = 127.0.0.1
    \\root_url = http://127.0.0.1:3000/
    \\serve_on_socket = false
    \\
    \\[grpc_server]
    \\enabled = false
    \\
    \\[nats]
    \\enabled = false
    \\
    \\[paths]
    \\data = /var/lib/dragontools/grafana
    \\logs = /var/lib/dragontools/grafana/log
    \\plugins = /var/lib/dragontools/grafana/plugins
    \\bundled_plugins = /opt/dragontools/components/grafana/current/data/plugins-bundled
    \\provisioning = /etc/dragontools/grafana/provisioning
    \\
    \\[database]
    \\type = sqlite3
    \\path = grafana.db
    \\wal = false
    \\
    \\[log]
    \\mode = console
    \\level = info
    \\
    \\[security]
    \\disable_initial_admin_creation = false
    \\disable_gravatar = true
    \\
    \\[auth]
    \\disable_login_form = false
    \\
    \\[auth.basic]
    \\enabled = true
    \\
    \\[auth.anonymous]
    \\enabled = false
    \\
    \\[auth.proxy]
    \\enabled = false
    \\
    \\[users]
    \\allow_sign_up = false
    \\
    \\[analytics]
    \\reporting_enabled = false
    \\check_for_updates = false
    \\check_for_plugin_updates = false
    \\
    \\[plugins]
    \\plugin_admin_enabled = false
    \\preinstall_disabled = true
    \\preinstall_auto_update = false
    \\public_key_retrieval_disabled = true
    \\
    \\[snapshots]
    \\external_enabled = false
    \\
    \\[unified_alerting]
    \\enabled = false
    \\
;

// VictoriaMetrics recommends the built-in Prometheus datasource. The pinned
// VictoriaTraces v0.11.0 Jaeger handler lives beneath /select/jaeger, not root:
// https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.11.0/app/vtselect/main.go
// VictoriaLogs needs the separate victoriametrics-logs-datasource plugin, deferred
// until its artifact, update, and runtime contracts receive their own review.
pub const datasources =
    \\# Managed by DragonTools
    \\apiVersion: 1
    \\datasources:
    \\  - name: Metrics
    \\    uid: dragontools-metrics
    \\    orgId: 1
    \\    type: prometheus
    \\    access: proxy
    \\    url: http://127.0.0.1:8428
    \\    isDefault: true
    \\    editable: false
    \\    version: 1
    \\    jsonData:
    \\      httpMethod: POST
    \\      prometheusType: Prometheus
    \\      prometheusVersion: 2.24.0
    \\  - name: Traces
    \\    uid: dragontools-traces
    \\    orgId: 1
    \\    type: jaeger
    \\    access: proxy
    \\    url: http://127.0.0.1:10428/select/jaeger
    \\    isDefault: false
    \\    editable: false
    \\    version: 1
    \\
;

pub fn render(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8, ini);
}

pub fn renderDatasources(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8, datasources);
}

test "Grafana config keeps authentication and loopback-only persistent SQLite explicit" {
    const a = std.testing.allocator;
    const first = try render(a);
    defer a.free(first);
    const second = try render(a);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    for ([_][]const u8{
        "http_addr = 127.0.0.1\n",                                "http_port = 3000\n",                               "data = /var/lib/dragontools/grafana\n",
        "provisioning = /etc/dragontools/grafana/provisioning\n", "plugins = /var/lib/dragontools/grafana/plugins\n", "[database]\ntype = sqlite3\npath = grafana.db\nwal = false\n",
        "[log]\nmode = console\n",                                "disable_initial_admin_creation = false\n",         "disable_login_form = false\n",
        "[auth.basic]\nenabled = true\n",                         "[auth.anonymous]\nenabled = false\n",              "[auth.proxy]\nenabled = false\n",
        "allow_sign_up = false\n",                                "preinstall_disabled = true\n",                     "preinstall_auto_update = false\n",
        "plugin_admin_enabled = false\n",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, first, needle) != null);
    for ([_][]const u8{ "0.0.0.0", "password", "secret_key", "org_role = Admin", "mode = file", "allow_loading_unsigned_plugins" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, first, needle) == null);
    }
}

test "Grafana provisions deterministic builtin Metrics and documented Jaeger datasource" {
    const a = std.testing.allocator;
    const first = try renderDatasources(a);
    defer a.free(first);
    const second = try renderDatasources(a);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    for ([_][]const u8{ "name: Metrics\n", "type: prometheus\n", "url: http://127.0.0.1:8428\n", "isDefault: true\n", "name: Traces\n", "type: jaeger\n", "url: http://127.0.0.1:10428/select/jaeger\n" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, first, needle) != null);
    }
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first, "editable: false\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first, "access: proxy\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first, "url: http://127.0.0.1:"));
    for ([_][]const u8{ "loki", "name: Logs", "https://", "deleteDatasources", "prune: true" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, first, needle) == null);
    }
}
