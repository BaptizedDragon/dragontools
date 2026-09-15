const std = @import("std");
const policy = @import("../monitoring/policy.zig");

pub const unit_path = "/etc/systemd/system/dragontools-victorialogs.service";

// Dedicated single-node VictoriaLogs profile. It needs ordinary files, sockets,
// and standard pseudo-devices, not raw devices, capabilities, or personality
// changes. PrivateTmp provides private temporary storage; ReadWritePaths permits
// only the data directory as persistent write access. No requested directive is
// intentionally omitted. Real systemd/Ubuntu compatibility remains a VM gate.
// Pinned flags: https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.52.0/app/vlstorage/main.go
// Do not combine percentage retention with retention.maxDiskSpaceUsageBytes.
pub fn render(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\# Managed by DragonTools
        \\[Unit]
        \\Description=DragonTools VictoriaLogs
        \\After=network.target
        \\
        \\[Service]
        \\User=dt-victorialogs
        \\Group=dt-victorialogs
        \\ExecStart=/opt/dragontools/components/victorialogs/current/victoria-logs-prod -storageDataPath=/var/lib/dragontools/victorialogs -httpListenAddr=127.0.0.1:9428 -retentionPeriod={s} -retention.maxDiskUsagePercent={d}
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
        \\ReadWritePaths=/var/lib/dragontools/victorialogs
        \\TasksMax=512
        \\UMask=0027
        \\LogRateLimitIntervalSec=30s
        \\LogRateLimitBurst=1000
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{
        policy.logs.retention,
        policy.logs.cleanup_usage_percent,
    });
}

test "VictoriaLogs unit has fixed storage policy dedicated account and loopback listener" {
    const a = std.testing.allocator;
    const unit = try render(a);
    defer a.free(unit);
    const again = try render(a);
    defer a.free(again);
    try std.testing.expectEqualStrings(unit, again);
    for ([_][]const u8{
        "User=dt-victorialogs\n",
        "Group=dt-victorialogs\n",
        "/current/victoria-logs-prod ",
        "-storageDataPath=/var/lib/dragontools/victorialogs ",
        "-httpListenAddr=127.0.0.1:9428 ",
        "-retentionPeriod=100y ",
        "-retention.maxDiskUsagePercent=75\n",
        "Restart=on-failure\n",
        "RestartSec=5s\n",
    }) |needle| try expectContains(unit, needle);
    for ([_][]const u8{ "0.0.0.0", "[::]", "-httpListenAddr=:9428", "-retention.maxDiskSpaceUsageBytes", "victoriametrics" }) |unexpected| {
        try std.testing.expect(std.mem.indexOf(u8, unit, unexpected) == null);
    }
}

test "VictoriaLogs dedicated hardening has only one persistent writable path" {
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
        "ReadWritePaths=/var/lib/dragontools/victorialogs\n",
        "UMask=0027\n",
    }) |needle| try expectContains(unit, needle);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, unit, "ReadWritePaths="));
    try std.testing.expect(std.mem.indexOf(u8, unit, "CAP_") == null);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
