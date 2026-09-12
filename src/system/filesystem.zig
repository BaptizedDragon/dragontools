const std = @import("std");
pub fn reserve(total: u64) !u64 {
    if (total == 0) return error.InvalidCapacity;
    return total / 5 + @intFromBool(total % 5 != 0);
}
pub fn capacity(output: []const u8) !u64 {
    var tokens = std.mem.tokenizeAny(u8, output, " \n\t");
    const blocks = try std.fmt.parseInt(u64, tokens.next() orelse return error.InvalidCapacity, 10);
    const size = try std.fmt.parseInt(u64, tokens.next() orelse return error.InvalidCapacity, 10);
    if (tokens.next() != null) return error.InvalidCapacity;
    return std.math.mul(u64, blocks, size);
}
test "reserve rounds up without overflow" {
    try std.testing.expectEqual(@as(u64, 21), try reserve(101));
    try std.testing.expectEqual(@as(u64, 409600), try capacity("100 4096\n"));
    _ = try reserve(std.math.maxInt(u64));
    try std.testing.expectError(error.InvalidCapacity, reserve(0));
}
