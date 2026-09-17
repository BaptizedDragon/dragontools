const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const version = "v0.34.1";
pub const root = "/opt/dragontools/components/alertmanager";
pub const pending = "/var/lib/dragontools/alertmanager-restart-required";
pub const Artifact = struct {
    arch: []const u8,
    archive_sha256: []const u8,
    binary_sha256: []const u8,
    amtool_sha256: []const u8,
};

// Reviewed 2026-09-17 against official release asset digest and sha256sums.txt.
// https://github.com/prometheus/alertmanager/releases/tag/v0.34.1
// Both Linux archives audited without executing code; two regular binaries pinned.
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{
            .arch = "amd64",
            .archive_sha256 = "265b9d1e55ef0d5306a436018af6d2b686c2ce051f03d968f7464ecb1372a7e8",
            .binary_sha256 = "154890307c382a186d4ddf9354cfa0cab08771f818aac1e647d0cf277ecef854",
            .amtool_sha256 = "1153b0dbf2a672fd54f7da597901b776a3d4e0daaa5c38f3710efc51b8c3b4c8",
        },
        .arm64 => .{
            .arch = "arm64",
            .archive_sha256 = "d98d6cbaf52151c7e76e24355fec88b11cebcb9875d4cdd8b76ddce7a7e5535c",
            .binary_sha256 = "cfd1845106fe1c2e1966a60805cb6c7c7bd6fae1bf77423cc1e049ca5f80c62f",
            .amtool_sha256 = "8391c16f27696ce5394b05fae09bb158cee97e38b03c2f409d3a6a0265ad30c9",
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
    const url = try std.fmt.allocPrint(a, "https://github.com/prometheus/alertmanager/releases/download/{s}/alertmanager-0.34.1.linux-{s}.tar.gz", .{ version, item.arch });
    defer a.free(url);
    return remote.shell(a, &.{
        "sh",                 "-eu",               "-c",
        \\root=$1; version=$2; url=$3; archive_hash=$4; binary_hash=$5; pending=$6; amtool_hash=$7; arch=$8
        \\umask 077
        \\dest="$root/$version"
        \\for dir in /opt/dragontools /opt/dragontools/components /var/lib/dragontools "$root" "$dest"; do
        \\  test ! -L "$dir"
        \\  test ! -e "$dir" || test -d "$dir"
        \\done
        \\test ! -L "$pending"
        \\if test -e "$pending"; then test -f "$pending"; test "$(stat -c '%u:%g' "$pending")" = 0:0; fi
        \\test ! -L "$dest/amtool"
        \\if test -e "$dest/amtool"; then test -f "$dest/amtool" && test "$(stat -c '%h' "$dest/amtool")" = 1; fi
        \\test ! -L "$dest/alertmanager"
        \\if test -e "$dest/alertmanager"; then test -f "$dest/alertmanager" && test "$(stat -c '%h' "$dest/alertmanager")" = 1; fi
        \\test ! -e "$root/current" || test -L "$root/current"
        \\current_version=''
        \\if test -L "$root/current"; then
        \\  current_version=$(readlink "$root/current")
        \\  printf '%s\n' "$current_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
        \\  test ! -L "$root/$current_version"
        \\  if test "$current_version" != "$version"; then
        \\    test -d "$root/$current_version"
        \\    test "$(stat -c '%u:%g:%a' "$root/$current_version")" = 0:0:755
        \\    test -f "$root/$current_version/alertmanager" && test ! -L "$root/$current_version/alertmanager"
        \\  fi
        \\fi
        \\valid=0
        \\if test -f "$dest/alertmanager"; then
        \\  if printf '%s  %s\n' "$binary_hash" "$dest/alertmanager" "$amtool_hash" "$dest/amtool" | sha256sum --check --status; then valid=1; fi
        \\fi
        \\test ! -L "$root/.install.lock"
        \\if test -e "$root/.install.lock"; then test -f "$root/.install.lock"; test "$(stat -c '%u:%g' "$root/.install.lock")" = 0:0; fi
        \\if test -d "$root" && test -d "$dest"; then test "$(stat -c '%d' "$root")" = "$(stat -c '%d' "$dest")"; fi
        \\# Matching state returns before creating a lock, temporary file, or marker.
        \\if test "$valid" = 1 && test "$current_version" = "$version" && test "$(stat -c '%u:%g:%a' "$root")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest/alertmanager")" = 0:0:755 && test "$(stat -c '%u:%g:%a' "$dest/amtool")" = 0:0:755; then printf unchanged; exit 0; fi
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
        \\  if test "$(stat -c '%u:%g' "$dest/amtool")" != 0:0; then chown root:root "$dest/amtool"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/amtool")" != 755; then chmod 755 "$dest/amtool"; changed=1; fi
        \\  if test "$(stat -c '%u:%g' "$dest/alertmanager")" != 0:0; then chown root:root "$dest/alertmanager"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dest/alertmanager")" != 755; then chmod 755 "$dest/alertmanager"; changed=1; fi
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
        \\  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --no-same-owner --no-same-permissions --strip-components=1 "alertmanager-0.34.1.linux-$arch/alertmanager" "alertmanager-0.34.1.linux-$arch/amtool"
        \\  test -f "$tmp/alertmanager" && test ! -L "$tmp/alertmanager"
        \\  printf '%s  %s\n' "$binary_hash" "$tmp/alertmanager" "$amtool_hash" "$tmp/amtool" | sha256sum --check --status
        \\  test -f "$tmp/amtool" && test ! -L "$tmp/amtool"
        \\  install -o root -g root -m 755 "$tmp/alertmanager" "$tmp/binary.new"
        \\  test -f "$tmp/binary.new" && test ! -L "$tmp/binary.new"
        \\  install -o root -g root -m 755 "$tmp/amtool" "$tmp/amtool.new"
        \\  mark_dirty
        \\  mv -fT "$tmp/binary.new" "$dest/alertmanager"
        \\  mv -fT "$tmp/amtool.new" "$dest/amtool"
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
        pending,              item.amtool_sha256,  item.arch,
    });
}
