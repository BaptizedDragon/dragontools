const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const version = "v2.11.4";
pub const root = "/opt/dragontools/components/caddy";
pub const pending = "/var/lib/dragontools/caddy-restart-required";
pub const unit_path = "/etc/systemd/system/dragontools-caddy.service";
pub const config_path = "/etc/dragontools/caddy/Caddyfile";
pub const data = "/var/lib/dragontools/caddy";

pub const Artifact = struct {
    arch: []const u8,
    archive_sha256: []const u8,
    binary_sha256: []const u8,
};

// Reviewed 2026-09-18: official release API SHA256 digests.
// https://api.github.com/repos/caddyserver/caddy/releases/tags/v2.11.4
// Binary digests derived from both verified archives. These trust the reviewed
// release account; they are not independent publisher signatures.
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{
            .arch = "amd64",
            .archive_sha256 = "527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9",
            .binary_sha256 = "b7105518e3ed1c0761f232e44fc09345535533c9cb0abf0e12809416c7ac64d9",
        },
        .arm64 => .{
            .arch = "arm64",
            .archive_sha256 = "52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904",
            .binary_sha256 = "e1f904038fc11ca897ac5a12fdacfb2a7add02a8720c426d562a37f6fdad2afe",
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
    const url = try std.fmt.allocPrint(a, "https://github.com/caddyserver/caddy/releases/download/{s}/caddy_{s}_linux_{s}.tar.gz", .{ version, version[1..], item.arch });
    defer a.free(url);
    const member = "caddy";
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
        \\test ! -L "$dest/caddy"
        \\if test -e "$dest/caddy"; then test -f "$dest/caddy" && test "$(stat -c '%h' "$dest/caddy")" = 1; fi
        \\test ! -e "$root/current" || test -L "$root/current"
        \\current_version=''
        \\if test -L "$root/current"; then
        \\  current_version=$(readlink "$root/current")
        \\  printf '%s\n' "$current_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
        \\  test ! -L "$root/$current_version"
        \\  if test "$current_version" != "$version"; then
        \\    test -d "$root/$current_version"
        \\    test "$(stat -c '%u:%g:%a' "$root/$current_version")" = 0:0:755
        \\    test -f "$root/$current_version/caddy" && test ! -L "$root/$current_version/caddy"
        \\  fi
        \\fi
        \\valid=0
        \\if test -f "$dest/caddy"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/caddy" | sha256sum --check --status; then valid=1; fi
        \\fi
        \\test ! -L "$root/.install.lock"
        \\if test -e "$root/.install.lock"; then test -f "$root/.install.lock"; test "$(stat -c '%u:%g' "$root/.install.lock")" = 0:0; fi
        \\if test -d "$root" && test -d "$dest"; then test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"; fi
        \\# Matching state returns before creating a lock, temporary file, or marker.
        \\if test "$valid" = 1 && test "$current_version" = "$version" && test "$(stat -c '%u:%g:%a' "$root")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest/caddy")" = 0:0:755; then printf unchanged; exit 0; fi
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
        \\  if test "$(stat -c '%u:%g' "$dest/caddy")" != 0:0; then chown root:root "$dest/caddy"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/caddy")" != 755; then chmod 755 "$dest/caddy"; changed=1; fi
        \\fi
        \\tmp=''
        \\trap 'if test -n "$tmp"; then rm -rf "$tmp"; fi' EXIT
        \\if test "$valid" = 0 || test "$current_version" != "$version"; then
        \\  tmp=$(mktemp -d "$root/.download.XXXXXX")
        \\  test -d "$tmp" && test ! -L "$tmp"
        \\fi
        \\if test "$valid" = 0; then
        \\  curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 300 --max-filesize 200000000 --output "$tmp/archive.tar.gz" "$url"
        \\  test -f "$tmp/archive.tar.gz" && test ! -L "$tmp/archive.tar.gz"
        \\  printf '%s  %s\n' "$archive_hash" "$tmp/archive.tar.gz" | sha256sum --check --status
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions "$member"
        \\  test -f "$tmp/caddy" && test ! -L "$tmp/caddy"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/caddy" | sha256sum --check --status
        \\  install -o root -g root -m 755 "$tmp/caddy" "$tmp/binary.new"
        \\  test -f "$tmp/binary.new" && test ! -L "$tmp/binary.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/binary.new" "$dest/caddy"
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

test "caddy literal artifact pins cover both supported architectures" {
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

test "caddy verifies archive before extracting only the expected regular binary" {
    const a = std.testing.allocator;
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const command = try binaryCommand(a, arch);
        defer a.free(command);
        const url = try std.fmt.allocPrint(a, "https://github.com/caddyserver/caddy/releases/download/{s}/caddy_{s}_linux_{s}.tar.gz", .{ version, version[1..], @tagName(arch) });
        defer a.free(url);
        try expectContains(command, url);
        try expectContains(command, artifact(arch).archive_sha256);
        try expectContains(command, artifact(arch).binary_sha256);
        const archive_check = std.mem.indexOf(u8, command, "\"$archive_hash\" \"$tmp/archive.tar.gz\" | sha256sum --check --status").?;
        const extraction = std.mem.indexOf(u8, command, "tar -xzf").?;
        const binary_check = std.mem.indexOf(u8, command, "\"$binary_hash\" \"$tmp/caddy\" | sha256sum --check --status").?;
        const activate = std.mem.indexOf(u8, command, "mv -fT \"$tmp/binary.new\"").?;
        try std.testing.expect(archive_check < extraction and extraction < binary_check and binary_check < activate);
        try expectContains(command, "--no-same-owner --no-same-permissions");
        try expectContains(command, "test -f \"$tmp/caddy\" && test ! -L \"$tmp/caddy\"");
        try expectContains(command, "--proto");
        try expectContains(command, "=https");
        try expectContains(command, "--proto-redir");
        try expectContains(command, "--connect-timeout 15 --max-time 300");
        try std.testing.expect(std.mem.indexOf(u8, command, "/latest") == null);
        try std.testing.expect(std.mem.indexOf(u8, command, "checksums.txt") == null);
    }
}

test "caddy rejects unexpected managed symlinks and preserves restart intent before atomic replacement" {
    const a = std.testing.allocator;
    const command = try binaryCommand(a, .amd64);
    defer a.free(command);
    for ([_][]const u8{
        "test ! -L \"$dir\"",
        "test ! -L \"$pending\"",
        "test ! -L \"$dest/caddy\"",
        "test ! -e \"$root/current\" || test -L \"$root/current\"",
        "test ! -L \"$root/$current_version\"",
        "test ! -L \"$root/.install.lock\"",
        "test -d \"$tmp\" && test ! -L \"$tmp\"",
        "mark_dirty\n  mv -fT \"$tmp/binary.new\" \"$dest/caddy\"",
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

test "caddy binary shell parses without executing changes" {
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
