const std = @import("std");
/// Only one supported source today; consumers depend on this type, not on op.
pub const SecretRef = union(enum) { one_password: []const u8 };
/// Injectable resolution boundary shared by consumers and the local provider.
pub const Resolver = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator, SecretRef) anyerror!*@import("secret.zig").Secret,
    pub fn resolve(self: Resolver, a: std.mem.Allocator, ref: SecretRef) !*@import("secret.zig").Secret {
        return self.read(self.context, a, ref);
    }
};
pub fn parseOnePassword(value: []const u8) !SecretRef {
    if (value.len > 2048 or !std.mem.startsWith(u8, value, "op://")) return error.InvalidSecretReference;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSecretReference;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidSecretReference;
    var segments = std.mem.splitScalar(u8, value[5..], '/');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidSecretReference;
        count += 1;
    }
    if (count != 3 and count != 4) return error.InvalidSecretReference;
    return .{ .one_password = value };
}
test "secret references have an explicit supported source and complete field path" {
    for ([_][]const u8{ "op://vault/item/password", "op://vault/item/section/username", "op://vault with spaces/item/field" }) |value| {
        try std.testing.expectEqualStrings(value, (try parseOnePassword(value)).one_password);
    }
    for ([_][]const u8{ "", "password", "env://PASSWORD", "op://", "op://vault/item", "op://vault//field", "op://vault/item/field/", "op://v/i/f\n", "op://v/i/\xff" }) |value| {
        try std.testing.expectError(error.InvalidSecretReference, parseOnePassword(value));
    }
}
