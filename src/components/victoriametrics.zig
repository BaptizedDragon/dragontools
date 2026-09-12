const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;
pub const version = "v1.151.0";
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
    return remote.shell(a, &.{
        "sh",                 "-eu",               "-c",
        \\root=$1; version=$2; url=$3; archive_hash=$4; binary_hash=$5; pending=$6
        \\exec 9>/run/lock/dragontools-victoriametrics.lock
        \\flock -w 30 9
        \\dest="$root/$version"
        \\changed=0
        \\for dir in "$root" "$dest"; do
        \\  test ! -L "$dir"
        \\  if test ! -d "$dir" || test "$(stat -c '%u:%g:%a' "$dir")" != 0:0:755; then install -d -o root -g root -m 755 "$dir"; changed=1; fi
        \\done
        \\valid=0
        \\if test -f "$dest/victoria-metrics-prod" && test ! -L "$dest/victoria-metrics-prod"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/victoria-metrics-prod" | sha256sum --check --status && test "$(stat -c '%u:%g:%a' "$dest/victoria-metrics-prod")" = 0:0:755; then valid=1; fi
        \\fi
        \\if test "$valid" = 0; then
        \\  tmp=$(mktemp -d "$root/.download.XXXXXX")
        \\  trap 'rm -rf "$tmp"' EXIT
        \\  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 2 --output "$tmp/archive.tar.gz" "$url"
        \\  printf '%s  %s\n' "$archive_hash" "$tmp/archive.tar.gz" | sha256sum --check --status
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions victoria-metrics-prod
        \\  test -f "$tmp/victoria-metrics-prod" && test ! -L "$tmp/victoria-metrics-prod"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/victoria-metrics-prod" | sha256sum --check --status
        \\  install -d -o root -g root -m 755 "$dest"
        \\  install -o root -g root -m 755 "$tmp/victoria-metrics-prod" "$dest/.victoria-metrics-prod.new"
        \\  touch "$pending"
        \\  mv -fT "$dest/.victoria-metrics-prod.new" "$dest/victoria-metrics-prod"
        \\  changed=1
        \\fi
        \\if test "$(readlink "$root/current" || true)" != "$version"; then
        \\  test ! -e "$root/current" || test -L "$root/current"
        \\  touch "$pending"
        \\  ln -sfnT "$version" "$root/.current.new"
        \\  mv -fT "$root/.current.new" "$root/current"
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
