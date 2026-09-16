//! Concrete Grafana service policy, independent from storage component units.
const std = @import("std");

pub const unit_path = "/etc/systemd/system/dragontools-grafana.service";
pub const executable = "/opt/dragontools/components/grafana/current/bin/grafana";
pub const homepath = "/opt/dragontools/components/grafana/current";

// Grafana needs SQLite/state/plugin storage and ordinary loopback sockets. Its
// signed bundled assets stay root-owned, outside its single persistent write
// path. Private temporary files are available. No requested hardening directive
// is relaxed. Compatibility under real Ubuntu systemd remains an integration gate.
pub fn render(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8,
        \\# Managed by DragonTools
        \\[Unit]
        \\Description=DragonTools Grafana
        \\After=network.target
        \\
        \\[Service]
        \\User=dt-grafana
        \\Group=dt-grafana
        \\WorkingDirectory=/opt/dragontools/components/grafana/current
        \\ExecStart=/opt/dragontools/components/grafana/current/bin/grafana server --homepath=/opt/dragontools/components/grafana/current --config=/etc/dragontools/grafana/grafana.ini
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
        \\ReadWritePaths=/var/lib/dragontools/grafana
        \\TasksMax=512
        \\UMask=0027
        \\StandardOutput=journal
        \\StandardError=journal
        \\LogRateLimitIntervalSec=30s
        \\LogRateLimitBurst=1000
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    );
}

test "Grafana unit has a dedicated account pinned home and one persistent write path" {
    const a = std.testing.allocator;
    const first = try render(a);
    defer a.free(first);
    const second = try render(a);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    for ([_][]const u8{
        "User=dt-grafana\n",           "Group=dt-grafana\n",                                 "ExecStart=" ++ executable ++ " server ",
        "--homepath=" ++ homepath,     "--config=/etc/dragontools/grafana/grafana.ini\n",    "Restart=on-failure\n",
        "RestartSec=5s\n",             "NoNewPrivileges=yes\n",                              "PrivateTmp=yes\n",
        "PrivateDevices=yes\n",        "ProtectHome=yes\n",                                  "ProtectSystem=strict\n",
        "ProtectKernelTunables=yes\n", "ProtectKernelModules=yes\n",                         "ProtectControlGroups=yes\n",
        "RestrictSUIDSGID=yes\n",      "LockPersonality=yes\n",                              "CapabilityBoundingSet=\n",
        "AmbientCapabilities=\n",      "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n", "ReadWritePaths=/var/lib/dragontools/grafana\n",
        "UMask=0027\n",                "StandardOutput=journal\n",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, first, needle) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "ReadWritePaths="));
    try std.testing.expect(std.mem.indexOf(u8, first, "CAP_") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "ExecStartPre") == null);
}
