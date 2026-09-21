const std = @import("std");
/// Opaque storage prevents accidental structural formatting from printing bytes.
/// Resolvers own this value; transport must use a protected input stream.
pub const Secret = opaque {
    const Storage = struct { bytes: []u8, allocator: std.mem.Allocator };
    pub fn init(a: std.mem.Allocator, bytes: []const u8) !*Secret {
        const s = try a.create(Storage);
        errdefer a.destroy(s);
        s.* = .{ .bytes = try a.dupe(u8, bytes), .allocator = a };
        return @ptrCast(s);
    }
    pub fn deinit(self: *Secret) void {
        const s: *Storage = @ptrCast(@alignCast(self));
        std.crypto.secureZero(u8, s.bytes);
        s.allocator.free(s.bytes);
        s.allocator.destroy(s);
    }
    pub fn format(_: *const Secret, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("[REDACTED]");
    }
    /// Only validation, serialization and protected stdin may access these bytes.
    /// Never pass them to logging, argv, or ordinary file writers.
    pub fn protectedBytes(self: *const Secret) []const u8 {
        const s: *const Storage = @ptrCast(@alignCast(self));
        return s.bytes;
    }
};
test "secret custom and structural formatting never expose bytes" {
    const s = try Secret.init(std.testing.allocator, "do-not-print-me");
    defer s.deinit();
    const output = try std.fmt.allocPrint(std.testing.allocator, "{f} {any}", .{ s, s });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "do-not-print-me") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[REDACTED]") != null);
}
