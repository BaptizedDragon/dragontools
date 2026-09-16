const std = @import("std");
const remote = @import("remote.zig");
/// Non-secret configuration only. Never pass a resolved credential here.
/// Atomic rename is on the destination filesystem; unmanaged files are refused.
pub fn writeCommand(a: std.mem.Allocator, path: []const u8, content: []const u8, restart_marker: []const u8) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                "-eu", "-c",
        \\path=$1
        \\test ! -L "$path" || exit 43
        \\if test -n "$3"; then
        \\  test ! -L "$3" || exit 43
        \\  if test -e "$3"; then test -f "$3" && test "$(stat -c '%u:%g' "$3")" = 0:0 || exit 40; fi
        \\fi
        \\if test -e "$path"; then
        \\  test -f "$path" || exit 40
        \\  grep -qx '# Managed by DragonTools' "$path" || exit 40
        \\  if printf '%s' "$2" | cmp -s - "$path"; then
        \\    changed=0
        \\    if test "$(stat -c '%u:%g' "$path")" != 0:0; then chown root:root "$path"; changed=1; fi
        \\    if test "$(stat -c '%a' "$path")" != 644; then chmod 644 "$path"; changed=1; fi
        \\    if test "$changed" = 1; then printf changed; else printf unchanged; fi
        \\    exit 0
        \\  fi
        \\fi
        \\tmp=$(mktemp "${path}.XXXXXX")
        \\trap 'rm -f "$tmp"' EXIT
        \\printf '%s' "$2" > "$tmp"
        \\chmod 644 "$tmp"
        \\chown root:root "$tmp"
        \\if test -n "$3" && test ! -e "$3"; then (umask 077; : > "$3"); fi
        \\mv -fT "$tmp" "$path"
        \\printf changed
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
    try std.testing.expect(std.mem.indexOf(u8, s, "cmp -s -").? < std.mem.indexOf(u8, s, "mktemp").?);
    try std.testing.expect(std.mem.indexOf(u8, s, ": > \"$3\"").? < std.mem.indexOf(u8, s, "mv -fT").?);
    try std.testing.expect(std.mem.indexOf(u8, s, "test -f \"$path\" || exit 40") != null);
}
