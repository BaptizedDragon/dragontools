const std = @import("std");
const remote = @import("remote.zig");
/// Non-secret configuration only. Never pass a resolved credential here.
/// Atomic rename is on the destination filesystem; unmanaged files are refused.
pub fn writeCommand(a: std.mem.Allocator, path: []const u8, content: []const u8, restart_marker: []const u8) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                "-eu", "-c",
        \\path=$1
        \\test ! -L "$path"
        \\if test -e "$path"; then grep -qx '# Managed by DragonTools' "$path" || exit 40; fi
        \\tmp=$(mktemp "${path}.XXXXXX")
        \\trap 'rm -f "$tmp"' EXIT
        \\printf '%s' "$2" > "$tmp"
        \\chmod 644 "$tmp"
        \\chown root:root "$tmp"
        \\if test -f "$path" && cmp -s "$tmp" "$path" && test "$(stat -c '%u:%g:%a' "$path")" = 0:0:644; then printf 'unchanged'; else if test -n "$3"; then touch "$3"; fi; mv -fT "$tmp" "$path"; printf 'changed'; fi
        ,
        "dragontools-write", path,  content,
        restart_marker,
    });
}
test "file writer compares and atomically replaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try writeCommand(arena.allocator(), "/tmp/file", "# Managed by DragonTools\n", "");
    try std.testing.expect(std.mem.indexOf(u8, s, "cmp -s") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mv -fT") != null);
}
