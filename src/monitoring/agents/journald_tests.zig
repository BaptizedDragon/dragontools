const std = @import("std");

test "journald temporary filesystem lifecycle preserves administrator limits and restart intent" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/agent_journald_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("", result.stderr);
}
