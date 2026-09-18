//! Controller-bundled helper distribution. No target-side release lookup.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const host = @import("../../system/host.zig");
const version = @import("../../version.zig").version;
const payload = @import("agent_payload");
pub const executable = "/opt/dragontools/agent/current/dragontool-agent";
pub const Artifact = struct { bytes: []const u8, sha256: [64]u8 };
pub fn artifact(arch: host.Arch) Artifact {
    const bytes: []const u8 = switch (arch) {
        .amd64 => payload.amd64,
        .arm64 => payload.arm64,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .bytes = bytes, .sha256 = std.fmt.bytesToHex(digest, .lower) };
}
const preflight =
    \\set -eu
    \\export LC_ALL=C
    \\root=/opt/dragontools/agent
    \\version=$1; digest=$2; release="$root/$version-$digest"
    \\directory() { test ! -L "$1" && test -d "$1" && test "$(stat -c '%u:%g:%a' "$1")" = 0:0:755 || exit 40; }
    \\file() { test ! -L "$1" && test -f "$1" && test "$(stat -c '%u:%g:%a:%h' "$1")" = "0:0:$2:1" || exit 40; }
    \\check_release() {
    \\  directory "$1"
    \\  file "$1/.dragontools-managed" 444
    \\  file "$1/dragontool-agent" 755
    \\  name=${1##*/}; old_hash=${name##*-}; old_version=${name%-$old_hash}
    \\  test "${#old_hash}" -eq 64 && test "${#old_version}" -le 64 || exit 40
    \\  case "$old_hash" in *[!0-9a-f]*) exit 40;; esac
    \\  case "$old_version" in ''|*[!0-9A-Za-z.+-]*) exit 40;; esac
    \\  printf 'DragonTools native helper v1\n%s\n%s\n' "$old_version" "$old_hash" | cmp -s - "$1/.dragontools-managed" || exit 40
    \\  printf '%s  %s\n' "$old_hash" "$1/dragontool-agent" | sha256sum --check --status || exit 40
    \\}
    \\directory /opt
    \\if test -e /opt/dragontools || test -L /opt/dragontools; then directory /opt/dragontools; fi
    \\if test -e "$root" || test -L "$root"; then
    \\  directory "$root"
    \\  file "$root/.dragontools-managed" 444
    \\  printf 'DragonTools helper installation v1\n' | cmp -s - "$root/.dragontools-managed" || exit 40
    \\fi
    \\if test -e "$release" || test -L "$release"; then check_release "$release"; fi
    \\if test -e "$root/current" || test -L "$root/current"; then
    \\  test -L "$root/current" && test "$(stat -c '%u:%g' "$root/current")" = 0:0 || exit 40
    \\  target=$(readlink "$root/current")
    \\  case "$target" in "$root/"*) ;; *) exit 40;; esac
    \\  name=${target#"$root/"}; case "$name" in ''|*/*) exit 40;; esac
    \\  check_release "$target"
    \\else target=; fi
;
pub fn inspectCommand(a: std.mem.Allocator, arch: host.Arch, verify_only: bool) ![]const u8 {
    const item = artifact(arch);
    const ending = if (verify_only)
        "\ntest \"$target\" = \"$release\" || exit 40\nprintf unchanged"
    else
        "\nif test \"$target\" = \"$release\"; then printf unchanged; else printf upload; fi";
    return remote.shell(a, &.{ "sh", "-c", try std.mem.concat(a, u8, &.{ preflight, ending }), "dt-helper-inspect", version, &item.sha256 });
}
pub fn uploadCommand(a: std.mem.Allocator, arch: host.Arch) !remote.Input {
    const item = artifact(arch);
    const script = preflight ++
        \\
        \\umask 077
        \\# DragonTools native helper upload: public artifact only.
        \\test -d /opt/dragontools || install -d -o root -g root -m 755 /opt/dragontools
        \\if test ! -d "$root"; then
        \\  stage=$(mktemp -d /opt/dragontools/.helper-XXXXXX)
        \\  trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
        \\  printf 'DragonTools helper installation v1\n' > "$stage/.dragontools-managed"
        \\  chmod 444 "$stage/.dragontools-managed"; chmod 755 "$stage"
        \\  mv -T -- "$stage" "$root"
        \\  trap - EXIT HUP INT TERM
        \\fi
        \\exec 9<"$root"
        \\flock -n 9 || exit 40
        \\stage=$(mktemp -d "$root/.upload-XXXXXX")
        \\trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
        \\cat > "$stage/dragontool-agent"
        \\printf '%s  %s\n' "$digest" "$stage/dragontool-agent" | sha256sum --check --status || exit 40
        \\chmod 755 "$stage/dragontool-agent"
        \\printf 'DragonTools native helper v1\n%s\n%s\n' "$version" "$digest" > "$stage/.dragontools-managed"
        \\chmod 444 "$stage/.dragontools-managed"
        \\# Validate version from the verified artifact before publication.
        \\test "$($stage/dragontool-agent version --json)" = "$3" || exit 40
        \\if test -e "$release" || test -L "$release"; then
        \\  check_release "$release"
        \\else
        \\  chmod 755 "$stage"
        \\  mv -T -- "$stage" "$release"
        \\  stage=$(mktemp -d "$root/.switch-XXXXXX")
        \\fi
        \\ln -s -- "$release" "$stage/current"
        \\mv -Tf -- "$stage/current" "$root/current"
        \\check_release "$release"
        \\test "$(readlink "$root/current")" = "$release"
        \\printf changed
    ;
    return .{ .command = try remote.shell(a, &.{ "sh", "-c", script, "dt-helper-upload", version, &item.sha256, try @import("../../version.zig").render(a, true, true) }), .bytes = item.bytes };
}
pub fn ensure(a: std.mem.Allocator, r: remote.Remote, report: anytype, arch: host.Arch) !void {
    const result = try report.call(r, .binary, try inspectCommand(a, arch, false));
    if (std.mem.eql(u8, result, "unchanged")) return;
    if (!std.mem.eql(u8, result, "upload")) return error.InvalidHelperResponse;
    _ = try report.call(r, .binary, try uploadCommand(a, arch));
    _ = try report.call(r, .health, try inspectCommand(a, arch, true));
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: anytype, arch: host.Arch) !void {
    _ = try report.call(r, .health, try inspectCommand(a, arch, true));
}
