const std = @import("std");
const vt = @import("victoriatraces.zig");
const policy = @import("../monitoring/policy.zig");

pub const unit_path = "/etc/systemd/system/dragontools-victoriatraces.service";

// Dedicated single-node VictoriaTraces profile. It needs ordinary files, sockets,
// and standard pseudo-devices, not raw devices, capabilities, or personality
// changes. PrivateTmp provides private temporary storage; ReadWritePaths permits
// only the data directory as persistent write access. No requested directive is
// intentionally omitted. Real systemd/Ubuntu compatibility remains a VM gate.
// Pinned flags: https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.11.0/app/vtstorage/main.go
// Do not combine percentage retention with retention.maxDiskSpaceUsageBytes.
// This release budgets its own partition bytes against total filesystem capacity,
// checks periodically, and preserves the newest two partitions. Other writers are
// not included in that budget; this is not a global filesystem usage ceiling.
// Pinned dependency: https://github.com/VictoriaMetrics/VictoriaLogs/blob/6ae2da3c11f3/lib/logstorage/storage.go#L826-L871
// Disable the separate gRPC server explicitly; HTTP ingestion stays loopback-only.
// https://github.com/VictoriaMetrics/VictoriaTraces/blob/v0.11.0/app/vtinsert/main.go#L30-L44
pub fn render(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\# Managed by DragonTools
        \\[Unit]
        \\Description=DragonTools VictoriaTraces
        \\After=network.target
        \\
        \\[Service]
        \\User=dt-victoriatraces
        \\Group=dt-victoriatraces
        \\ExecStart=/opt/dragontools/components/victoriatraces/current/victoria-traces-prod -storageDataPath=/var/lib/dragontools/victoriatraces -httpListenAddr={s} -otlpGRPCListenAddr= -retentionPeriod={s} -retention.maxDiskUsagePercent={d}
        \\Restart=on-failure
        \\RestartSec=5s
        \\TimeoutStopSec=120s
        \\NoNewPrivileges=yes
        \\PrivateTmp=yes
        \\PrivateDevices=yes
        \\ProtectHome=yes
        \\ProtectSystem=strict
        \\ProtectKernelTunables=yes
        \\ProtectKernelModules=yes
        \\ProtectControlGroups=yes
        \\RestrictSUIDSGID=yes
        \\LockPersonality=yes
        \\CapabilityBoundingSet=
        \\AmbientCapabilities=
        \\RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
        \\ReadWritePaths=/var/lib/dragontools/victoriatraces
        \\TasksMax=512
        \\UMask=0027
        \\LogRateLimitIntervalSec=30s
        \\LogRateLimitBurst=1000
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{
        vt.listen_address,
        policy.traces.retention,
        policy.traces.cleanup_usage_percent,
    });
}

test "VictoriaTraces unit has fixed storage policy dedicated account and loopback listener" {
    const a = std.testing.allocator;
    const unit = try render(a);
    defer a.free(unit);
    const again = try render(a);
    defer a.free(again);
    try std.testing.expectEqualStrings(unit, again);
    for ([_][]const u8{
        "User=dt-victoriatraces\n",
        "Group=dt-victoriatraces\n",
        "/current/victoria-traces-prod ",
        "-storageDataPath=/var/lib/dragontools/victoriatraces ",
        "-httpListenAddr=127.0.0.1:10428 ",
        "-otlpGRPCListenAddr= ",
        "-retentionPeriod=100y ",
        "-retention.maxDiskUsagePercent=75\n",
        "Restart=on-failure\n",
        "RestartSec=5s\n",
    }) |needle| try expectContains(unit, needle);
    for ([_][]const u8{ "0.0.0.0", "[::]", "-httpListenAddr=:10428", "-retention.maxDiskSpaceUsageBytes", "victoriametrics" }) |unexpected| {
        try std.testing.expect(std.mem.indexOf(u8, unit, unexpected) == null);
    }
}

test "VictoriaTraces dedicated hardening has only one persistent writable path" {
    const a = std.testing.allocator;
    const unit = try render(a);
    defer a.free(unit);
    for ([_][]const u8{
        "NoNewPrivileges=yes\n",
        "PrivateTmp=yes\n",
        "PrivateDevices=yes\n",
        "ProtectHome=yes\n",
        "ProtectSystem=strict\n",
        "ProtectKernelTunables=yes\n",
        "ProtectKernelModules=yes\n",
        "ProtectControlGroups=yes\n",
        "RestrictSUIDSGID=yes\n",
        "LockPersonality=yes\n",
        "CapabilityBoundingSet=\n",
        "AmbientCapabilities=\n",
        "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n",
        "ReadWritePaths=/var/lib/dragontools/victoriatraces\n",
        "UMask=0027\n",
    }) |needle| try expectContains(unit, needle);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, unit, "ReadWritePaths="));
    try std.testing.expect(std.mem.indexOf(u8, unit, "CAP_") == null);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
