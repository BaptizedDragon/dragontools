//! Progress carries fixed semantic values only, never remote output or secrets.
const std = @import("std");

pub const Component = enum {
    victoriametrics,
    victorialogs,
    victoriatraces,
    grafana,
    blackbox_exporter,
    alertmanager,
    vmalert_logs,
    vmalert_metrics,
    agent_helper,

    pub fn name(self: Component) []const u8 {
        return switch (self) {
            .agent_helper => "DragonTool agent helper",
            .victoriametrics => "VictoriaMetrics",
            .victorialogs => "VictoriaLogs",
            .victoriatraces => "VictoriaTraces",
            .grafana => "Grafana",
            .blackbox_exporter => "Blackbox exporter",
            .alertmanager => "Alertmanager",
            .vmalert_logs => "vmalert logs",
            .vmalert_metrics => "vmalert metrics",
        };
    }
};

pub const Phase = enum {
    component_started,
    inspecting,
    converging,
    verifying,
    waiting,
    plugin_inspecting,
    plugin_installed,
    plugin_current,
    datasources_updated,
    datasources_current,
    logs_query_verified,
    logs_query_unchecked,
    credentials_verified,
    credentials_updated,
    credentials_unmanaged,
    healthy_unchanged,
    healthy_changed,
};

pub const Event = struct {
    component: Component,
    phase: Phase,
    station_enabled: bool = false,

    pub fn text(self: Event) []const u8 {
        return switch (self.phase) {
            .component_started => switch (self.component) {
                .agent_helper => "DragonTool agent helper\n",
                .victoriametrics => if (self.station_enabled) "[1/8] VictoriaMetrics\n" else "[1/4] VictoriaMetrics\n",
                .victorialogs => if (self.station_enabled) "[2/8] VictoriaLogs\n" else "[2/4] VictoriaLogs\n",
                .victoriatraces => if (self.station_enabled) "[3/8] VictoriaTraces\n" else "[3/4] VictoriaTraces\n",
                .grafana => if (self.station_enabled) "[4/8] Grafana\n" else "[4/4] Grafana\n",
                .blackbox_exporter => "[5/8] Blackbox exporter\n",
                .alertmanager => "[6/8] Alertmanager\n",
                .vmalert_logs => "[7/8] vmalert logs\n",
                .vmalert_metrics => "[8/8] vmalert metrics\n",
            },
            .inspecting => "      inspecting...\n",
            .converging => "      applying required changes...\n",
            .verifying => "      verifying...\n",
            .waiting => "      waiting for readiness...\n",
            .plugin_inspecting => "      checking VictoriaLogs datasource plugin...\n",
            .plugin_installed => "      VictoriaLogs datasource plugin installed\n",
            .plugin_current => "      plugin current\n",
            .datasources_updated => "      Metrics, Logs and Traces datasources provisioned\n",
            .datasources_current => "      datasources current\n",
            .logs_query_verified => "      Logs datasource health and query verified\n",
            .logs_query_unchecked => "      Logs plugin query unchecked; configure administrator references to verify\n",
            .credentials_verified => "      administrator credentials verified\n",
            .credentials_updated => "      administrator credentials updated\n",
            .credentials_unmanaged => "      warning: administrator credentials are unmanaged\n",
            .healthy_unchanged => "      healthy; no changes\n",
            .healthy_changed => "      healthy; changes applied\n",
        };
    }
};

/// Optional presentation only: a sink cannot alter verification or error results.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.write(self.context, event);
    }
};

test "progress renderer uses only fixed semantic text" {
    try std.testing.expectEqualStrings("[1/4] VictoriaMetrics\n", (Event{ .component = .victoriametrics, .phase = .component_started }).text());
    try std.testing.expectEqualStrings("[4/4] Grafana\n", (Event{ .component = .grafana, .phase = .component_started }).text());
    try std.testing.expectEqualStrings("      healthy; no changes\n", (Event{ .component = .grafana, .phase = .healthy_unchanged }).text());
    try std.testing.expectEqualStrings("      healthy; changes applied\n", (Event{ .component = .grafana, .phase = .healthy_changed }).text());
    try std.testing.expectEqualStrings("      waiting for readiness...\n", (Event{ .component = .grafana, .phase = .waiting }).text());
    inline for (@typeInfo(Phase).@"enum".fields) |field| {
        const output = (Event{ .component = .grafana, .phase = @enumFromInt(field.value) }).text();
        try std.testing.expect(std.mem.endsWith(u8, output, "\n"));
        try std.testing.expect(std.mem.indexOf(u8, output, "op://") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "password") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "username") == null);
    }
}
