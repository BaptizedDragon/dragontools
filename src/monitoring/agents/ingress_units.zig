//! Fixed station ingress services. No caller-supplied proxy configuration.
pub const caddy_command = "/opt/dragontools/components/caddy/current/caddy run --config /etc/dragontools/caddy/Caddyfile --adapter caddyfile";
pub const auth_command = "/usr/bin/python3 -I -B /opt/dragontools/ingress-auth/authorize.py";
const hardening =
    \\Restart=on-failure
    \\RestartSec=5s
    \\TimeoutStopSec=60s
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
    \\UMask=0077
    \\StandardOutput=null
    \\StandardError=null
    \\LimitCORE=0
    \\
;
const enabled = "\n[Install]\nWantedBy=multi-user.target\n";
pub const caddy =
    \\# Managed by DragonTools
    \\[Unit]
    \\Description=DragonTools Caddy mTLS ingress
    \\After=network-online.target dragontools-ingress-auth.service
    \\Wants=network-online.target dragontools-ingress-auth.service
    \\
    \\[Service]
    \\User=dt-caddy
    \\Group=dt-caddy
    \\SupplementaryGroups=dt-ingest
    \\Environment=HOME=/var/lib/dragontools/caddy XDG_DATA_HOME=/var/lib/dragontools/caddy XDG_CONFIG_HOME=/var/lib/dragontools/caddy
    \\LoadCredential=ca.crt:/etc/dragontools/ingestion/server/ca.crt
    \\LoadCredential=server.crt:/etc/dragontools/ingestion/server/server.crt
    \\LoadCredential=server.key:/etc/dragontools/ingestion/server/server.key
    \\InaccessiblePaths=/etc/dragontools/ingestion/pki /etc/dragontools/ingestion/clients /etc/dragontools/ingestion/server
    \\ReadWritePaths=/var/lib/dragontools/caddy
    \\TasksMax=512
    \\MemoryMax=256M
    \\
++ "ExecStart=" ++ caddy_command ++ "\n" ++ hardening ++ enabled;
pub const auth =
    \\# Managed by DragonTools
    \\[Unit]
    \\Description=DragonTools private ingress authorization and identity normalization
    \\After=network.target
    \\
    \\[Service]
    \\User=dt-ingest
    \\Group=dt-ingest
    \\RuntimeDirectory=dragontools-ingress
    \\RuntimeDirectoryMode=0750
    \\InaccessiblePaths=/etc/dragontools/ingestion/pki /etc/dragontools/ingestion/clients /etc/dragontools/ingestion/server
    \\ReadWritePaths=/run/dragontools-ingress
    \\TasksMax=64
    \\MemoryMax=256M
    \\
++ "ExecStart=" ++ auth_command ++ "\n" ++ hardening ++ enabled;

test "Caddy is the only public ingress and private authorization cannot read key storage" {
    const std = @import("std");
    const config = @embedFile("Caddyfile");
    for ([_][]const u8{ "admin off", "auto_https off", "persist_config off", "request_header -X-DragonTools-*", "protocols tls1.2 tls1.3", "{$CREDENTIALS_DIRECTORY}/ca.crt" }) |value| try std.testing.expect(std.mem.indexOf(u8, config, value) != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, config, "mode require_and_verify"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, config, "bind tcp4/0.0.0.0"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, config, "https://:9443 {"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, config, "https://:9444 {"));
    const split = std.mem.indexOf(u8, config, "https://:9444").?;
    try std.testing.expect(std.mem.indexOf(u8, config[0..split], "reverse_proxy unix//run/dragontools-ingress/metrics.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, config[split..], "reverse_proxy unix//run/dragontools-ingress/logs.sock") != null);
    for ([_][]const u8{ "9445", "handle_path", "acme", "127.0.0.1:3000", "127.0.0.1:10428" }) |value| try std.testing.expect(std.mem.indexOf(u8, config, value) == null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, caddy, "LoadCredential="));
    try std.testing.expect(std.mem.indexOf(u8, caddy, "LoadCredential=ca.key") == null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "LoadCredential=") == null);
    for ([_][]const u8{ caddy, auth }) |unit| {
        try std.testing.expect(std.mem.indexOf(u8, unit, "InaccessiblePaths=/etc/dragontools/ingestion/pki /etc/dragontools/ingestion/clients /etc/dragontools/ingestion/server") != null);
        try std.testing.expect(std.mem.indexOf(u8, unit, "StandardError=null") != null);
        try std.testing.expect(std.mem.indexOf(u8, unit, "LimitCORE=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, unit, "dragontools-ingestion.service") == null);
    }
}
