//! Progress carries fixed semantic values only, never remote output or secrets.
const std = @import("std");

pub const Component = enum {
    victoriametrics,
    victorialogs,
    victoriatraces,
    grafana,

    pub fn name(self: Component) []const u8 {
        return switch (self) {
            .victoriametrics => "VictoriaMetrics",
            .victorialogs => "VictoriaLogs",
            .victoriatraces => "VictoriaTraces",
            .grafana => "Grafana",
        };
    }
};

pub const Phase = enum {
    component_started,
    inspecting,
    converging,
    verifying,
    waiting,
    credentials_verified,
    credentials_updated,
    credentials_unmanaged,
    healthy_unchanged,
    healthy_changed,
};

pub const Event = struct {
    component: Component,
    phase: Phase,

    pub fn text(self: Event) []const u8 {
        return switch (self.phase) {
            .component_started => switch (self.component) {
                .victoriametrics => "[1/4] VictoriaMetrics\n",
                .victorialogs => "[2/4] VictoriaLogs\n",
                .victoriatraces => "[3/4] VictoriaTraces\n",
                .grafana => "[4/4] Grafana\n",
            },
            .inspecting => "      inspecting...\n",
            .converging => "      applying required changes...\n",
            .verifying => "      verifying...\n",
            .waiting => "      waiting for readiness...\n",
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
