//! Publish only a natively validated, non-secret Vector configuration.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const component = @import("../../components/vector.zig");

pub fn writeCommand(a: std.mem.Allocator, content: []const u8) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                        "-eu",                 "-c",
        \\path=$1; pending=$3
        \\test ! -L "$path" && test ! -L "$pending" || exit 43
        \\if test -e "$pending"; then test -f "$pending" && test "$(stat -c '%u:%g' "$pending")" = 0:0 || exit 40; fi
        \\if test -e "$path"; then
        \\  test -f "$path" && grep -qx '# Managed by DragonTools' "$path" || exit 40
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
        \\chown root:root "$tmp"
        \\chmod 644 "$tmp"
        \\runuser -u dt-vector -- /opt/dragontools/components/vector/current/vector validate --no-environment --skip-healthchecks --config-yaml "$tmp" >/dev/null 2>&1
        \\if test ! -e "$pending"; then (umask 077; : > "$pending"); fi
        \\mv -fT "$tmp" "$path"
        \\printf changed
        ,
        "dragontools-vector-config", component.config_path, content,
        component.pending,
    });
}

test "Vector candidate validation preserves good configuration and restart intent on failure" {
    const a = std.testing.allocator;
    const command = try writeCommand(a, "# Managed by DragonTools\nfixture candidate\n");
    defer a.free(command);
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/vector_config_test.py", command } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
