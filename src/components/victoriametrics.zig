const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;
pub const version = "v1.151.0";
pub const ui_path = "/vmui/";
pub const port: u16 = 8428;
pub const listen_address = std.fmt.comptimePrint("127.0.0.1:{d}", .{port});
pub const root = "/opt/dragontools/components/victoriametrics";
pub const pending = "/var/lib/dragontools/victoriametrics-restart-required";
pub const Artifact = struct { arch: []const u8, archive_sha256: []const u8, binary_sha256: []const u8 };
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{ .arch = "amd64", .archive_sha256 = "629bd538bdccaae6cb6c33fd6d387387abf5b6c00f2a99667407ad6085db1c91", .binary_sha256 = "695465592d390d1add29975c883409b19d81d9ac6e62a8b4ee344e9e1f022f45" },
        .arm64 => .{ .arch = "arm64", .archive_sha256 = "4c9236165fdbe8d3175103cf59f0179cfbf49355a39f9959febfde877e6f0a08", .binary_sha256 = "d6fc7e82108e1352bf300cab5c7f2ea7a05c23f09c47e0b566b53c18c07406d1" },
    };
}
pub fn binaryCommand(a: std.mem.Allocator, arch: Arch) ![]const u8 {
    const item = artifact(arch);
    const url = try std.fmt.allocPrint(a, "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/{s}/victoria-metrics-linux-{s}-{s}.tar.gz", .{ version, item.arch, version });
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
        \\test ! -L "$dest/victoria-metrics-prod"
        \\test ! -e "$dest/victoria-metrics-prod" || test -f "$dest/victoria-metrics-prod"
        \\test ! -e "$root/current" || test -L "$root/current"
        \\current_version=''
        \\if test -L "$root/current"; then
        \\  current_version=$(readlink "$root/current")
        \\  printf '%s\n' "$current_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
        \\  test ! -L "$root/$current_version"
        \\  if test "$current_version" != "$version"; then
        \\    test -d "$root/$current_version"
        \\    test "$(stat -c '%u:%g:%a' "$root/$current_version")" = 0:0:755
        \\    test -f "$root/$current_version/victoria-metrics-prod" && test ! -L "$root/$current_version/victoria-metrics-prod"
        \\  fi
        \\fi
        \\valid=0
        \\if test -f "$dest/victoria-metrics-prod"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/victoria-metrics-prod" | sha256sum --check --status; then valid=1; fi
        \\fi
        \\test ! -L "$root/.install.lock"
        \\if test -e "$root/.install.lock"; then test -f "$root/.install.lock"; test "$(stat -c '%u:%g' "$root/.install.lock")" = 0:0; fi
        \\if test -d "$root" && test -d "$dest"; then test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"; fi
        \\# Matching state returns before creating a lock, temporary file, or marker.
        \\if test "$valid" = 1 && test "$current_version" = "$version" && test "$(stat -c '%u:%g:%a' "$root")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest/victoria-metrics-prod")" = 0:0:755; then printf unchanged; exit 0; fi
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
        \\  if test "$(stat -c '%u:%g' "$dest/victoria-metrics-prod")" != 0:0; then chown root:root "$dest/victoria-metrics-prod"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/victoria-metrics-prod")" != 755; then chmod 755 "$dest/victoria-metrics-prod"; changed=1; fi
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
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions victoria-metrics-prod
        \\  test -f "$tmp/victoria-metrics-prod" && test ! -L "$tmp/victoria-metrics-prod"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/victoria-metrics-prod" | sha256sum --check --status
        \\  install -o root -g root -m 755 "$tmp/victoria-metrics-prod" "$tmp/binary.new"
        \\  test -f "$tmp/binary.new" && test ! -L "$tmp/binary.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/binary.new" "$dest/victoria-metrics-prod"
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

test "artifact pins and checksum before extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const command = try binaryCommand(arena.allocator(), .arm64);
    try std.testing.expectEqual(@as(usize, 64), artifact(.amd64).archive_sha256.len);
    try std.testing.expect(std.mem.indexOf(u8, command, "sha256sum --check --status").? < std.mem.indexOf(u8, command, "tar -xzf").?);
    try std.testing.expect(std.mem.indexOf(u8, command, "linux-arm64") != null);
}

test "VictoriaMetrics repair preserves read-only no-op and records intent before replacement" {
    const a = std.testing.allocator;
    const command = try binaryCommand(a, .amd64);
    defer a.free(command);
    const no_op = std.mem.indexOf(u8, command, "then printf unchanged; exit 0; fi").?;
    try std.testing.expect(no_op < std.mem.indexOf(u8, command, "exec 9>>").?);
    try std.testing.expect(no_op < std.mem.indexOf(u8, command, "mktemp").?);
    const binary_check = std.mem.indexOf(u8, command, "\"$binary_hash\" \"$tmp/victoria-metrics-prod\" | sha256sum --check --status").?;
    const replace = std.mem.indexOf(u8, command, "mark_dirty\n  mv -fT \"$tmp/binary.new\"").?;
    try std.testing.expect(binary_check < replace);
    try std.testing.expect(std.mem.indexOf(u8, command, "mark_dirty\n  mv -fT \"$tmp/current.new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "test ! -L \"$dest/victoria-metrics-prod\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "test ! -e \"$root/current\" || test -L \"$root/current\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -rf \"$dest\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -f \"$pending\"") == null);
}
