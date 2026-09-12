const std = @import("std");
pub const Arch = enum { amd64, arm64 };
pub const Host = struct { release: []const u8, arch: Arch };
pub const detect_command =
    \\set -eu
    \\test "$(id -u)" = 0 || exit 10
    \\test -d /run/systemd/system || exit 11
    \\. /etc/os-release
    \\printf '%s\n%s\n%s\n' "$ID" "$VERSION_ID" "$(uname -m)"
    \\test ! -L /etc/systemd/system/dragontools-victoriametrics.service || exit 43
    \\if test -e /etc/systemd/system/dragontools-victoriametrics.service; then grep -qx '# Managed by DragonTools' /etc/systemd/system/dragontools-victoriametrics.service || exit 40; fi
    \\test -z "$(systemctl show -p DropInPaths --value dragontools-victoriametrics.service)" || exit 42
    \\for tool in curl tar sha256sum stat cmp install useradd getent systemctl flock readlink ss grep cut mktemp ln mv chmod chown tr; do command -v "$tool" >/dev/null || exit 12; done
;
pub fn parse(output: []const u8) !Host {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidHostResponse, "ubuntu")) return error.UnsupportedOS;
    const release = lines.next() orelse return error.InvalidHostResponse;
    if (!std.mem.eql(u8, release, "24.04") and !std.mem.eql(u8, release, "26.04")) return error.UnsupportedOS;
    const arch = lines.next() orelse return error.InvalidHostResponse;
    return .{ .release = release, .arch = if (std.mem.eql(u8, arch, "x86_64")) .amd64 else if (std.mem.eql(u8, arch, "aarch64")) .arm64 else return error.UnsupportedArchitecture };
}
test "narrow supported platforms" {
    try std.testing.expectEqual(Arch.arm64, (try parse("ubuntu\n24.04\naarch64\n")).arch);
    try std.testing.expectError(error.UnsupportedOS, parse("debian\n12\nx86_64\n"));
    try std.testing.expectError(error.UnsupportedOS, parse("ubuntu\n22.04\nx86_64\n"));
}
