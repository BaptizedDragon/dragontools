const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const version = "v0.11.0";
// Pinned upstream HTTP default; the explicit address keeps all APIs private.
pub const port: u16 = 10428;
pub const listen_address = std.fmt.comptimePrint("127.0.0.1:{d}", .{port});
pub const root = "/opt/dragontools/components/victoriatraces";
pub const pending = "/var/lib/dragontools/victoriatraces-restart-required";
pub const Artifact = struct {
    arch: []const u8,
    archive_sha256: []const u8,
    binary_sha256: []const u8,
};

// Reviewed 2026-09-15: the official latest API identified this stable release.
// https://api.github.com/repos/VictoriaMetrics/VictoriaTraces/releases/tags/v0.11.0
// Each downloaded archive was hashed against its release asset digest AND the
// corresponding victoria-traces-linux-<arch>-v0.11.0_checksums.txt release asset.
// Each archive contained exactly one regular victoria-traces-prod; its locally
// calculated hash also matched that checksum file. These are literal pins, not
// runtime trust in latest/checksum downloads. Both sources trust the upstream
// publishing account; this is not an independent publisher signature.
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{
            .arch = "amd64",
            .archive_sha256 = "3089ead89b9a95369e265a5321b1ad8e670c3c94afbc9a9faaa9a356346b5b95",
            .binary_sha256 = "30d9f74a76e8b0e04dbddd7ef782063dfddcb8c01870e8c91bb06ef8ea36e28c",
        },
        .arm64 => .{
            .arch = "arm64",
            .archive_sha256 = "18176f73fac3b9c7ea88ceba637c7f997593635e446e45e789dc68f1de6d0359",
            .binary_sha256 = "dafbdcb97027c905ba05e253def33bf92df5899f6b571dd72b4498c15febbf15",
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
    const url = try std.fmt.allocPrint(a, "https://github.com/VictoriaMetrics/VictoriaTraces/releases/download/{s}/victoria-traces-linux-{s}-{s}.tar.gz", .{ version, item.arch, version });
    defer a.free(url);
    return remote.shell(a, &.{
        "sh",                 "-eu",               "-c",
        \\root=$1; version=$2; url=$3; archive_hash=$4; binary_hash=$5; pending=$6
        \\umask 077
        \\dest="$root/$version"
        \\for dir in /opt/dragontools /opt/dragontools/components /var/lib/dragontools "$root" "$dest"; do
        \\  test ! -L "$dir"
        \\  test ! -e "$dir" || test -d "$dir"
        \\done
        \\test ! -L "$pending"
        \\if test -e "$pending"; then test -f "$pending"; test "$(stat -c '%u:%g' "$pending")" = 0:0; fi
        \\test ! -L "$dest/victoria-traces-prod"
        \\test ! -e "$dest/victoria-traces-prod" || test -f "$dest/victoria-traces-prod"
        \\test ! -e "$root/current" || test -L "$root/current"
        \\current_version=''
        \\if test -L "$root/current"; then
        \\  current_version=$(readlink "$root/current")
        \\  printf '%s\n' "$current_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
        \\  test ! -L "$root/$current_version"
        \\  if test "$current_version" != "$version"; then
        \\    test -d "$root/$current_version"
        \\    test "$(stat -c '%u:%g:%a' "$root/$current_version")" = 0:0:755
        \\    test -f "$root/$current_version/victoria-traces-prod" && test ! -L "$root/$current_version/victoria-traces-prod"
        \\  fi
        \\fi
        \\test ! -L "$root/.install.lock"
        \\if test -e "$root/.install.lock"; then test -f "$root/.install.lock"; test "$(stat -c '%u:%g' "$root/.install.lock")" = 0:0; fi
        \\valid=0
        \\if test -f "$dest/victoria-traces-prod"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/victoria-traces-prod" | sha256sum --check --status; then valid=1; fi
        \\fi
        \\metadata_ok=1
        \\for dir in "$root" "$dest"; do
        \\  if test ! -d "$dir" || test "$(stat -c '%u:%g:%a' "$dir")" != 0:0:755; then metadata_ok=0; fi
        \\done
        \\if test "$valid" = 1 && test "$metadata_ok" = 1 && test "$current_version" = "$version" && test "$(stat -c '%u:%g:%a' "$dest/victoria-traces-prod")" = 0:0:755; then
        \\  printf unchanged
        \\  exit 0
        \\fi
        \\mark_dirty() { if test ! -e "$pending"; then : > "$pending"; fi; }
        \\changed=0
        \\for dir in "$root" "$dest"; do
        \\  if test ! -d "$dir"; then
        \\    install -d -o root -g root -m 755 "$dir"
        \\    changed=1
        \\  else
        \\    if test "$(stat -c '%u:%g' "$dir")" != 0:0; then chown root:root "$dir"; changed=1; fi
        \\    if test "$(stat -c '%a' "$dir")" != 755; then chmod 755 "$dir"; changed=1; fi
        \\  fi
        \\done
        \\# Refuse nested mounts that would turn mv into a cross-filesystem copy.
        \\test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"
        \\exec 9>>"$root/.install.lock"
        \\flock -w 30 9
        \\# Repair metadata without downloading or disturbing a running executable.
        \\if test "$valid" = 1; then
        \\  if test "$(stat -c '%u:%g' "$dest/victoria-traces-prod")" != 0:0; then chown root:root "$dest/victoria-traces-prod"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/victoria-traces-prod")" != 755; then chmod 755 "$dest/victoria-traces-prod"; changed=1; fi
        \\fi
        \\tmp=''
        \\trap 'if test -n "$tmp"; then rm -rf "$tmp"; fi' EXIT
        \\if test "$valid" = 0 || test "$current_version" != "$version"; then
        \\  tmp=$(mktemp -d "$root/.download.XXXXXX")
        \\  test -d "$tmp" && test ! -L "$tmp"
        \\fi
        \\if test "$valid" = 0; then
        \\  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 300 --max-filesize 67108864 --output "$tmp/archive.tar.gz" "$url"
        \\  test -f "$tmp/archive.tar.gz" && test ! -L "$tmp/archive.tar.gz"
        \\  printf '%s  %s\n' "$archive_hash" "$tmp/archive.tar.gz" | sha256sum --check --status
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions victoria-traces-prod
        \\  test -f "$tmp/victoria-traces-prod" && test ! -L "$tmp/victoria-traces-prod"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/victoria-traces-prod" | sha256sum --check --status
        \\  install -o root -g root -m 755 "$tmp/victoria-traces-prod" "$tmp/binary.new"
        \\  test -f "$tmp/binary.new" && test ! -L "$tmp/binary.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/binary.new" "$dest/victoria-traces-prod"
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
        pending,
    });
}

test "VictoriaTraces literal artifact pins cover both supported architectures" {
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

test "VictoriaTraces verifies archive before extracting only the expected regular binary" {
    const a = std.testing.allocator;
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const command = try binaryCommand(a, arch);
        defer a.free(command);
        const url = try std.fmt.allocPrint(a, "https://github.com/VictoriaMetrics/VictoriaTraces/releases/download/{s}/victoria-traces-linux-{s}-{s}.tar.gz", .{ version, @tagName(arch), version });
        defer a.free(url);
        try expectContains(command, url);
        try expectContains(command, artifact(arch).archive_sha256);
        try expectContains(command, artifact(arch).binary_sha256);
        const archive_check = std.mem.indexOf(u8, command, "\"$archive_hash\" \"$tmp/archive.tar.gz\" | sha256sum --check --status").?;
        const extraction = std.mem.indexOf(u8, command, "tar -xzf").?;
        const binary_check = std.mem.indexOf(u8, command, "\"$binary_hash\" \"$tmp/victoria-traces-prod\" | sha256sum --check --status").?;
        const activate = std.mem.indexOf(u8, command, "mv -fT \"$tmp/binary.new\"").?;
        try std.testing.expect(archive_check < extraction and extraction < binary_check and binary_check < activate);
        try expectContains(command, "--no-same-owner --no-same-permissions victoria-traces-prod");
        try expectContains(command, "test -f \"$tmp/victoria-traces-prod\" && test ! -L \"$tmp/victoria-traces-prod\"");
        try expectContains(command, "--proto");
        try expectContains(command, "=https");
        try expectContains(command, "--proto-redir");
        try expectContains(command, "--connect-timeout 15 --max-time 300");
        try std.testing.expect(std.mem.indexOf(u8, command, "/latest") == null);
        try std.testing.expect(std.mem.indexOf(u8, command, "checksums.txt") == null);
    }
}

test "VictoriaTraces rejects unexpected managed symlinks and preserves restart intent before atomic replacement" {
    const a = std.testing.allocator;
    const command = try binaryCommand(a, .amd64);
    defer a.free(command);
    for ([_][]const u8{
        "test ! -L \"$dir\"",
        "test ! -L \"$pending\"",
        "test ! -L \"$dest/victoria-traces-prod\"",
        "test ! -e \"$root/current\" || test -L \"$root/current\"",
        "test ! -L \"$root/$current_version\"",
        "test ! -L \"$root/.install.lock\"",
        "test -d \"$tmp\" && test ! -L \"$tmp\"",
        "mark_dirty\n  mv -fT \"$tmp/binary.new\" \"$dest/victoria-traces-prod\"",
        "mark_dirty\n  mv -fT \"$tmp/current.new\" \"$root/current\"",
        "flock -w 30 9",
    }) |needle| try expectContains(command, needle);
    const same_filesystem = std.mem.indexOf(u8, command, "\"$root\")\" = \"$(stat -c").?;
    try std.testing.expect(same_filesystem < std.mem.indexOf(u8, command, "mv -fT \"$tmp/binary.new\"").?);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -rf \"$dest\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -f \"$pending\"") == null);
}

test "VictoriaTraces binary shell parses without executing changes" {
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

test "VictoriaTraces unchanged binary returns before mutation and metadata repair reuses the pin" {
    const a = std.testing.allocator;
    const command = try binaryCommand(a, .amd64);
    defer a.free(command);
    const unchanged = std.mem.indexOf(u8, command, "printf unchanged\n  exit 0").?;
    for ([_][]const u8{ "install -d ", "chown root:root", "chmod 755", "exec 9>>", "mktemp -d", "curl --fail" }) |mutation| {
        try std.testing.expect(unchanged < std.mem.indexOf(u8, command, mutation).?);
    }
    try expectContains(command, "if test \"$valid\" = 1; then\n  if test");
    try expectContains(command, "if test \"$valid\" = 0; then\n  curl --fail");
    try std.testing.expect(std.mem.indexOf(u8, command, "exec 9>\"") == null);
    const marker = std.mem.indexOf(u8, command, "mark_dirty\n  mv -fT").?;
    try std.testing.expect(std.mem.indexOf(u8, command, "chmod 755 \"$dest/victoria-traces-prod\"").? < marker);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
