const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const version = "v1.152.0";
pub const ui_path = "/vmalert/groups";
pub const Kind = enum { logs, metrics };
pub fn port(kind: Kind) u16 {
    return if (kind == .logs) 8880 else 8881;
}
pub const root = "/opt/dragontools/components/vmalert";
pub const pending = "/var/lib/dragontools/vmalert-logs-restart-required";
pub const pending_metrics = "/var/lib/dragontools/vmalert-metrics-restart-required";
pub const Artifact = struct {
    arch: []const u8,
    archive_sha256: []const u8,
    binary_sha256: []const u8,
};

// Reviewed 2026-09-17 against the official v1.152.0 release API asset digests:
// https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/tags/v1.152.0
// Both vmutils archives were downloaded and SHA256-verified without execution.
// Each has seven flat regular members; only vmalert-prod is extracted below.
// Binary SHA256 pins were computed from the verified archive members. This trusts
// the reviewed upstream release account, not an independent publisher signature.
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{
            .arch = "amd64",
            .archive_sha256 = "8eee4a98ff1665c60682475e8a8b292b8d718b63a2f023124384dd2f6a220c79",
            .binary_sha256 = "be382c490ad6eb417a30ad4ef34a66bf531a98b70eded79aa1006ca4455d7bc5",
        },
        .arm64 => .{
            .arch = "arm64",
            .archive_sha256 = "57c567b262962a4cb8e35c0c34efe64629a3e1ea69ac0611d8d67e168df8b1e8",
            .binary_sha256 = "4d63b96d68f62ea1ca51e3544c35257038bf1b41e542434fe8fad02575017f3c",
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
    const url = try std.fmt.allocPrint(a, "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/{s}/vmutils-linux-{s}-{s}.tar.gz", .{ version, item.arch, version });
    defer a.free(url);
    return remote.shell(a, &.{
        "sh",                 "-eu",               "-c",
        \\root=$1; version=$2; url=$3; archive_hash=$4; binary_hash=$5; pending=$6; pending_metrics=$7
        \\umask 077
        \\dest="$root/$version"
        \\for dir in /opt/dragontools /opt/dragontools/components /var/lib/dragontools "$root" "$dest"; do
        \\  test ! -L "$dir"
        \\  test ! -e "$dir" || test -d "$dir"
        \\done
        \\test ! -L "$pending_metrics"
        \\if test -e "$pending_metrics"; then test -f "$pending_metrics" && test "$(stat -c '%u:%g' "$pending_metrics")" = 0:0; fi
        \\test ! -L "$pending"
        \\if test -e "$pending"; then test -f "$pending"; test "$(stat -c '%u:%g' "$pending")" = 0:0; fi
        \\test ! -L "$dest/vmalert-prod"
        \\if test -e "$dest/vmalert-prod"; then test -f "$dest/vmalert-prod" && test "$(stat -c '%h' "$dest/vmalert-prod")" = 1; fi
        \\test ! -e "$root/current" || test -L "$root/current"
        \\current_version=''
        \\if test -L "$root/current"; then
        \\  current_version=$(readlink "$root/current")
        \\  printf '%s\n' "$current_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
        \\  test ! -L "$root/$current_version"
        \\  if test "$current_version" != "$version"; then
        \\    test -d "$root/$current_version"
        \\    test "$(stat -c '%u:%g:%a' "$root/$current_version")" = 0:0:755
        \\    test -f "$root/$current_version/vmalert-prod" && test ! -L "$root/$current_version/vmalert-prod"
        \\  fi
        \\fi
        \\valid=0
        \\if test -f "$dest/vmalert-prod"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/vmalert-prod" | sha256sum --check --status; then valid=1; fi
        \\fi
        \\test ! -L "$root/.install.lock"
        \\if test -e "$root/.install.lock"; then test -f "$root/.install.lock"; test "$(stat -c '%u:%g' "$root/.install.lock")" = 0:0; fi
        \\if test -d "$root" && test -d "$dest"; then test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"; fi
        \\# Matching state returns before creating a lock, temporary file, or marker.
        \\if test "$valid" = 1 && test "$current_version" = "$version" && test "$(stat -c '%u:%g:%a' "$root")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest/vmalert-prod")" = 0:0:755; then printf unchanged; exit 0; fi
        \\mark_dirty() { if test ! -e "$pending"; then : > "$pending"; fi; if test ! -e "$pending_metrics"; then : > "$pending_metrics"; fi; }
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
        \\  if test "$(stat -c '%u:%g' "$dest/vmalert-prod")" != 0:0; then chown root:root "$dest/vmalert-prod"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/vmalert-prod")" != 755; then chmod 755 "$dest/vmalert-prod"; changed=1; fi
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
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions vmalert-prod
        \\  test -f "$tmp/vmalert-prod" && test ! -L "$tmp/vmalert-prod"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/vmalert-prod" | sha256sum --check --status
        \\  install -o root -g root -m 755 "$tmp/vmalert-prod" "$tmp/binary.new"
        \\  test -f "$tmp/binary.new" && test ! -L "$tmp/binary.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/binary.new" "$dest/vmalert-prod"
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
        pending,              pending_metrics,
    });
}

test "vmalert literal artifact pins cover both supported architectures" {
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

test "vmalert verifies archive before extracting only the expected regular binary" {
    const a = std.testing.allocator;
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const command = try binaryCommand(a, arch);
        defer a.free(command);
        const url = try std.fmt.allocPrint(a, "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/{s}/vmutils-linux-{s}-{s}.tar.gz", .{ version, @tagName(arch), version });
        defer a.free(url);
        try expectContains(command, url);
        try expectContains(command, artifact(arch).archive_sha256);
        try expectContains(command, artifact(arch).binary_sha256);
        const archive_check = std.mem.indexOf(u8, command, "\"$archive_hash\" \"$tmp/archive.tar.gz\" | sha256sum --check --status").?;
        const extraction = std.mem.indexOf(u8, command, "tar -xzf").?;
        const binary_check = std.mem.indexOf(u8, command, "\"$binary_hash\" \"$tmp/vmalert-prod\" | sha256sum --check --status").?;
        const activate = std.mem.indexOf(u8, command, "mv -fT \"$tmp/binary.new\"").?;
        try std.testing.expect(archive_check < extraction and extraction < binary_check and binary_check < activate);
        try expectContains(command, "--no-same-owner --no-same-permissions vmalert-prod");
        try expectContains(command, "test -f \"$tmp/vmalert-prod\" && test ! -L \"$tmp/vmalert-prod\"");
        try expectContains(command, "--proto");
        try expectContains(command, "=https");
        try expectContains(command, "--proto-redir");
        try expectContains(command, "--connect-timeout 15 --max-time 300");
        try std.testing.expect(std.mem.indexOf(u8, command, "/latest") == null);
        try std.testing.expect(std.mem.indexOf(u8, command, "checksums.txt") == null);
    }
}

test "vmalert rejects unexpected managed symlinks and preserves restart intent before atomic replacement" {
    const a = std.testing.allocator;
    const command = try binaryCommand(a, .amd64);
    defer a.free(command);
    for ([_][]const u8{
        "test ! -L \"$dir\"",
        "test ! -L \"$pending\"",
        "test ! -L \"$dest/vmalert-prod\"",
        "test \"$(stat -c '\\''%h'\\'' \"$dest/vmalert-prod\")\" = 1",
        "test ! -e \"$root/current\" || test -L \"$root/current\"",
        "test ! -L \"$root/$current_version\"",
        "test ! -L \"$root/.install.lock\"",
        "test -d \"$tmp\" && test ! -L \"$tmp\"",
        "mark_dirty\n  mv -fT \"$tmp/binary.new\" \"$dest/vmalert-prod\"",
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

test "vmalert binary shell parses without executing changes" {
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
