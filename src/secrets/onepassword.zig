//! Controller-local optional resolver; never invoked by plan/status/completion.
const std = @import("std");
const Secret = @import("secret.zig").Secret;
const reference = @import("reference.zig");
const process = @import("process.zig");
const Resolver = reference.Resolver;
pub const Local = struct {
    io: std.Io,
    pub fn resolver(self: *Local) Resolver {
        return .{ .context = self, .read = read };
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, ref: reference.SecretRef) !*Secret {
        const self: *Local = @ptrCast(@alignCast(ctx));
        const args = argv(ref);
        const result = process.run(a, self.io, &args, null, 16 * 1024, 30_000) catch |err| switch (err) {
            error.FileNotFound => return error.OnePasswordUnavailable,
            else => return error.SecretResolutionFailed,
        };
        errdefer result.deinit();
        if (result.code != 0) return error.SecretResolutionFailed;
        if (result.output.protectedBytes().len == 0) return error.EmptySecret;
        return result.output;
    }
};
pub fn argv(ref: reference.SecretRef) [4][]const u8 {
    return .{ "op", "read", "--no-newline", switch (ref) {
        .one_password => |value| value,
    } };
}
test "op resolution uses fixed argv and literal reference without a shell" {
    const ref = try reference.parseOnePassword("op://vault/item/'$(not-a-command)' field");
    const args = argv(ref);
    try std.testing.expectEqualStrings("op", args[0]);
    try std.testing.expectEqualStrings("read", args[1]);
    try std.testing.expectEqualStrings("--no-newline", args[2]);
    try std.testing.expectEqualStrings(ref.one_password, args[3]);
}
