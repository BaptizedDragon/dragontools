const std = @import("std");
pub const unit_path = "/etc/systemd/system/dragontools-victoriametrics.service";
pub fn render(a: std.mem.Allocator, reserve: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "# Managed by DragonTools\n[Unit]\nDescription=DragonTools VictoriaMetrics\nAfter=network.target\n\n[Service]\n" ++
        "User=dt-victoriametrics\nGroup=dt-victoriametrics\nExecStart=/opt/dragontools/components/victoriametrics/current/victoria-metrics-prod -storageDataPath=/var/lib/dragontools/victoriametrics -retentionPeriod=90d -storage.minFreeDiskSpaceBytes={d} -httpListenAddr=127.0.0.1:8428 -selfScrapeInterval=15s\n" ++
        "Restart=on-failure\nRestartSec=5s\nTimeoutStopSec=120s\n{s}\n\n[Install]\nWantedBy=multi-user.target\n", .{ reserve, @import("../security/hardening.zig").victoria_metrics });
}
test "unit storage and hardening" {
    const s = try render(std.testing.allocator, 2000);
    defer std.testing.allocator.free(s);
    for ([_][]const u8{ "-retentionPeriod=90d", "-storage.minFreeDiskSpaceBytes=2000", "127.0.0.1:8428", "User=dt-victoriametrics", "ProtectSystem=strict" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, s, needle) != null);
}
