const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const version = "0.28.0";
pub const root = "/opt/dragontools/components/blackbox-exporter";
pub const pending = "/var/lib/dragontools/blackbox-exporter-restart-required";
pub const unit_path = "/etc/systemd/system/dragontools-blackbox-exporter.service";
pub const config_path = "/etc/dragontools/blackbox-exporter/blackbox.yml";
pub const data = "/var/lib/dragontools/blackbox-exporter";

// Only HTTP/HTTPS GET availability is exposed. HTTP/2 is disabled because this
// reviewed upstream release still contains the affected transport in GO-2026-4918:
// https://pkg.go.dev/vuln/GO-2026-4918
// https://github.com/prometheus/blackbox_exporter/blob/v0.28.0/go.mod
// HTTPS certificate/hostname verification and normal redirects remain enabled.
// https://github.com/prometheus/blackbox_exporter/blob/v0.28.0/CONFIGURATION.md
pub const config =
    \\# Managed by DragonTools
    \\modules:
    \\  http_2xx:
    \\    prober: http
    \\    timeout: 5s
    \\    http:
    \\      method: GET
    \\      preferred_ip_protocol: ip4
    \\      ip_protocol_fallback: true
    \\      follow_redirects: true
    \\      enable_http2: false
    \\      tls_config:
    \\        insecure_skip_verify: false
    \\
;

// Stateless HTTP probes require DNS and outbound ordinary TCP sockets, but no
// raw sockets/capabilities or persistent writes. The home exists for the account;
// it stays read-only in the service namespace. ICMP is deliberately unavailable.
pub const unit =
    \\# Managed by DragonTools
    \\[Unit]
    \\Description=DragonTools blackbox exporter
    \\After=network.target
    \\
    \\[Service]
    \\User=dt-blackbox
    \\Group=dt-blackbox
    \\ExecStart=/opt/dragontools/components/blackbox-exporter/current/blackbox_exporter --config.file=/etc/dragontools/blackbox-exporter/blackbox.yml --web.listen-address=127.0.0.1:9115 --history.limit=0 --log.prober=error
    \\Restart=on-failure
    \\RestartSec=5s
    \\TimeoutStopSec=30s
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
    \\ReadWritePaths=
    \\TasksMax=512
    \\UMask=0027
    \\LogRateLimitIntervalSec=30s
    \\LogRateLimitBurst=1000
    \\
    \\[Install]
    \\WantedBy=multi-user.target
    \\
;
pub const Artifact = struct {
    arch: []const u8,
    archive_sha256: []const u8,
    binary_sha256: []const u8,
};

// Reviewed 2026-09-17 against the official release asset digests AND sha256sums.txt:
// https://github.com/prometheus/blackbox_exporter/releases/tag/v0.28.0
// https://github.com/prometheus/blackbox_exporter/releases/download/v0.28.0/sha256sums.txt
// Extracted regular-binary SHA256 values were calculated locally from both
// verified archives without executing their contents. Upstream publishes archive
// hashes; the binary hashes are derived pins, not independent signatures.
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{
            .arch = "amd64",
            .archive_sha256 = "caf5d242fb1cf6d5cb678f3f799f22703d4fafea26b03dcbbd7e1f1825e06329",
            .binary_sha256 = "b79da51dce26afbc787917a3bf884ac84dcf1af8862c4ab215ca23b7c327ca04",
        },
        .arm64 => .{
            .arch = "arm64",
            .archive_sha256 = "63312be0983d85e5109710a7dc93df3051157ae581853fa3655d171cc1b2806e",
            .binary_sha256 = "9132ceb241475206df4ea55a9174e79e563b6fb4fe188873bbb0519110ef8f57",
        },
    };
}

/// Parent directories and the marker parent are managed root-owned directories.
/// Dynamic arguments cross the shared remote quoting boundary. Temporary files
/// stay in a private staging directory on the installation filesystem; no fixed
/// .new pathname is overwritten. The lock covers binary staging/activation only,
/// so operators must still serialize whole installations per target.
pub fn binaryCommand(a: std.mem.Allocator, arch: Arch) ![]const u8 {
    const item = artifact(arch);
    const url = try std.fmt.allocPrint(a, "https://github.com/prometheus/blackbox_exporter/releases/download/v{s}/blackbox_exporter-{s}.linux-{s}.tar.gz", .{ version, version, item.arch });
    defer a.free(url);
    const member = try std.fmt.allocPrint(a, "blackbox_exporter-{s}.linux-{s}/blackbox_exporter", .{ version, item.arch });
    defer a.free(member);
    return remote.shell(a, &.{
        "sh",                 "-eu",               "-c",
        \\root=$1; version=$2; url=$3; archive_hash=$4; binary_hash=$5; pending=$6; member=$7
        \\umask 077
        \\dest="$root/$version"
        \\for dir in /opt/dragontools /opt/dragontools/components /var/lib/dragontools "$root" "$dest"; do
        \\  test ! -L "$dir"
        \\  test ! -e "$dir" || test -d "$dir"
        \\done
        \\test ! -L "$pending"
        \\if test -e "$pending"; then test -f "$pending"; test "$(stat -c '%u:%g' "$pending")" = 0:0; fi
        \\test ! -L "$dest/blackbox_exporter"
        \\test ! -e "$dest/blackbox_exporter" || test -f "$dest/blackbox_exporter"
        \\test ! -e "$root/current" || test -L "$root/current"
        \\current_version=''
        \\if test -L "$root/current"; then
        \\  current_version=$(readlink "$root/current")
        \\  printf '%s\n' "$current_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
        \\  test ! -L "$root/$current_version"
        \\  if test "$current_version" != "$version"; then
        \\    test -d "$root/$current_version"
        \\    test "$(stat -c '%u:%g:%a' "$root/$current_version")" = 0:0:755
        \\    test -f "$root/$current_version/blackbox_exporter" && test ! -L "$root/$current_version/blackbox_exporter"
        \\  fi
        \\fi
        \\valid=0
        \\if test -f "$dest/blackbox_exporter"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/blackbox_exporter" | sha256sum --check --status; then valid=1; fi
        \\fi
        \\test ! -L "$root/.install.lock"
        \\if test -e "$root/.install.lock"; then test -f "$root/.install.lock"; test "$(stat -c '%u:%g' "$root/.install.lock")" = 0:0; fi
        \\if test -d "$root" && test -d "$dest"; then test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"; fi
        \\# Matching state returns before creating a lock, temporary file, or marker.
        \\if test "$valid" = 1 && test "$current_version" = "$version" && test "$(stat -c '%u:%g:%a' "$root")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest/blackbox_exporter")" = 0:0:755; then printf unchanged; exit 0; fi
        \\mark_dirty() { if test ! -e "$pending"; then : > "$pending"; fi; }
        \\changed=0
        \\for dir in "$root" "$dest"; do
        \\  if test -d "$dir"; then
        \\    if test "$(stat -c '%u:%g' "$dir")" != 0:0; then chown root:root "$dir"; changed=1; fi
        \\    if test "$(stat -c '%a' "$dir")" != 755; then chmod 755 "$dir"; changed=1; fi
        \\  else
        \\    install -d -o root -g root -m 755 "$dir"
        \\    changed=1
        \\  fi
        \\done
        \\# Refuse nested mounts that would turn mv into a cross-filesystem copy.
        \\test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"
        \\exec 9>>"$root/.install.lock"
        \\flock -w 30 9
        \\# Correct bytes need metadata repair only, never another download/restart.
        \\if test "$valid" = 1; then
        \\  if test "$(stat -c '%u:%g' "$dest/blackbox_exporter")" != 0:0; then chown root:root "$dest/blackbox_exporter"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/blackbox_exporter")" != 755; then chmod 755 "$dest/blackbox_exporter"; changed=1; fi
        \\fi
        \\tmp=''
        \\trap 'if test -n "$tmp"; then rm -rf "$tmp"; fi' EXIT
        \\if test "$valid" = 0 || test "$current_version" != "$version"; then
        \\  tmp=$(mktemp -d "$root/.download.XXXXXX")
        \\  test -d "$tmp" && test ! -L "$tmp"
        \\fi
        \\if test "$valid" = 0; then
        \\  curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 300 --max-filesize 67108864 --output "$tmp/archive.tar.gz" "$url"
        \\  test -f "$tmp/archive.tar.gz" && test ! -L "$tmp/archive.tar.gz"
        \\  printf '%s  %s\n' "$archive_hash" "$tmp/archive.tar.gz" | sha256sum --check --status
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions --strip-components=1 "$member"
        \\  test -f "$tmp/blackbox_exporter" && test ! -L "$tmp/blackbox_exporter"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/blackbox_exporter" | sha256sum --check --status
        \\  install -o root -g root -m 755 "$tmp/blackbox_exporter" "$tmp/binary.new"
        \\  test -f "$tmp/binary.new" && test ! -L "$tmp/binary.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/binary.new" "$dest/blackbox_exporter"
        \\  changed=1
        \\fi
        \\if test "$current_version" != "$version"; then
        \\  ln -s "$version" "$tmp/current.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/current.new" "$root/current"
        \\  changed=1
        \\fi
        \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
        ,
        "dragontools-binary", root,                version,
        url,                  item.archive_sha256, item.binary_sha256,
        pending,              member,
    });
}

test "Blackbox exporter literal artifact pins cover both supported architectures" {
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const item = artifact(arch);
        try std.testing.expectEqualStrings(@tagName(arch), item.arch);
        for ([_][]const u8{ item.archive_sha256, item.binary_sha256 }) |hash| {
            try std.testing.expectEqual(@as(usize, 64), hash.len);
            for (hash) |c| try std.testing.expect(std.ascii.isHex(c));
        }
    }
    try std.testing.expect(!std.mem.eql(u8, artifact(.amd64).archive_sha256, artifact(.arm64).archive_sha256));
    try std.testing.expect(!std.mem.eql(u8, artifact(.amd64).binary_sha256, artifact(.arm64).binary_sha256));
}

test "Blackbox exporter verifies archive before extracting only the expected regular binary" {
    const a = std.testing.allocator;
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const command = try binaryCommand(a, arch);
        defer a.free(command);
        const url = try std.fmt.allocPrint(a, "https://github.com/prometheus/blackbox_exporter/releases/download/v{s}/blackbox_exporter-{s}.linux-{s}.tar.gz", .{ version, version, @tagName(arch) });
        defer a.free(url);
        try expectContains(command, url);
        try expectContains(command, artifact(arch).archive_sha256);
        try expectContains(command, artifact(arch).binary_sha256);
        const archive_check = std.mem.indexOf(u8, command, "\"$archive_hash\" \"$tmp/archive.tar.gz\" | sha256sum --check --status").?;
        const extraction = std.mem.indexOf(u8, command, "tar -xzf").?;
        const binary_check = std.mem.indexOf(u8, command, "\"$binary_hash\" \"$tmp/blackbox_exporter\" | sha256sum --check --status").?;
        const activate = std.mem.indexOf(u8, command, "mv -fT \"$tmp/binary.new\"").?;
        try std.testing.expect(archive_check < extraction and extraction < binary_check and binary_check < activate);
        try expectContains(command, "--no-same-owner --no-same-permissions --strip-components=1");
        try expectContains(command, "test -f \"$tmp/blackbox_exporter\" && test ! -L \"$tmp/blackbox_exporter\"");
        try expectContains(command, "--proto");
        try expectContains(command, "=https");
        try expectContains(command, "--proto-redir");
        try expectContains(command, "--connect-timeout 15 --max-time 300");
        try std.testing.expect(std.mem.indexOf(u8, command, "/latest") == null);
        try std.testing.expect(std.mem.indexOf(u8, command, "checksums.txt") == null);
    }
}

test "Blackbox exporter rejects unexpected managed symlinks and preserves restart intent before atomic replacement" {
    const a = std.testing.allocator;
    const command = try binaryCommand(a, .amd64);
    defer a.free(command);
    for ([_][]const u8{
        "test ! -L \"$dir\"",
        "test ! -L \"$pending\"",
        "test ! -L \"$dest/blackbox_exporter\"",
        "test ! -e \"$root/current\" || test -L \"$root/current\"",
        "test ! -L \"$root/$current_version\"",
        "test ! -L \"$root/.install.lock\"",
        "test -d \"$tmp\" && test ! -L \"$tmp\"",
        "mark_dirty\n  mv -fT \"$tmp/binary.new\" \"$dest/blackbox_exporter\"",
        "mark_dirty\n  mv -fT \"$tmp/current.new\" \"$root/current\"",
        "flock -w 30 9",
    }) |needle| try expectContains(command, needle);
    const same_filesystem = std.mem.indexOf(u8, command, "\"$root\")\" = \"$(stat -c").?;
    try std.testing.expect(same_filesystem < std.mem.indexOf(u8, command, "mv -fT \"$tmp/binary.new\"").?);
    const no_op = std.mem.indexOf(u8, command, "then printf unchanged; exit 0; fi").?;
    try std.testing.expect(no_op < std.mem.indexOf(u8, command, "exec 9>>").?);
    try std.testing.expect(no_op < std.mem.indexOf(u8, command, "mktemp").?);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -rf \"$dest\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -f \"$pending\"") == null);
}

test "Blackbox exporter binary shell parses without executing changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const command = try binaryCommand(a, arch);
        // Intercept the quoted sh wrapper so /bin/sh -n parses its inner body.
        const script = try std.fmt.allocPrint(a, "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command});
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "Blackbox module keeps GET 2xx verified HTTPS redirects and bounded IPv4 preferred probes" {
    for ([_][]const u8{ "http_2xx:", "prober: http\n", "timeout: 5s\n", "method: GET\n", "preferred_ip_protocol: ip4\n", "ip_protocol_fallback: true\n", "follow_redirects: true\n", "enable_http2: false\n", "insecure_skip_verify: false\n" }) |needle| try expectContains(config, needle);
    for ([_][]const u8{ "insecure_skip_verify: true", "valid_status_codes:", "headers:", "authorization:", "basic_auth:", "prober: icmp", "enable_http3: true" }) |unexpected| try std.testing.expect(std.mem.indexOf(u8, config, unexpected) == null);
}

test "Blackbox service uses loopback dedicated account no capabilities and no persistent writes" {
    for ([_][]const u8{ "User=dt-blackbox\n", "Group=dt-blackbox\n", "--web.listen-address=127.0.0.1:9115", "--config.file=/etc/dragontools/blackbox-exporter/blackbox.yml", "--history.limit=0", "NoNewPrivileges=yes\n", "PrivateTmp=yes\n", "PrivateDevices=yes\n", "ProtectSystem=strict\n", "ProtectHome=yes\n", "CapabilityBoundingSet=\n", "AmbientCapabilities=\n", "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n", "ReadWritePaths=\n" }) |needle| try expectContains(unit, needle);
    for ([_][]const u8{ "CAP_", "0.0.0.0", "[::]", "PrivateNetwork=yes", "IPAddressDeny=any" }) |unexpected| try std.testing.expect(std.mem.indexOf(u8, unit, unexpected) == null);
}
