//! Resolve and validate the credential pair before any remote mutation.
const std = @import("std");
const Secret = @import("secret.zig").Secret;
const reference = @import("reference.zig");
const Resolver = reference.Resolver;
pub fn payload(a: std.mem.Allocator, resolver: Resolver, username_ref: reference.SecretRef, password_ref: reference.SecretRef) !*Secret {
    const username = resolver.resolve(a, username_ref) catch return error.GrafanaUsernameResolutionFailed;
    defer username.deinit();
    const password = resolver.resolve(a, password_ref) catch return error.GrafanaPasswordResolutionFailed;
    defer password.deinit();
    const user = username.protectedBytes();
    const pass = password.protectedBytes();
    try validate(user, pass);
    // JSON escaping needs at most six bytes per input byte. Fixed storage avoids
    // leaving secret copies behind in an allocator's reallocation history.
    const encoded = try a.alloc(u8, 64 + 6 * (user.len + pass.len));
    defer {
        std.crypto.secureZero(u8, encoded);
        a.free(encoded);
    }
    var writer = std.Io.Writer.fixed(encoded);
    try std.json.Stringify.value(.{ .username = user, .password = pass }, .{}, &writer);
    return Secret.init(a, writer.buffered());
}
fn validate(user: []const u8, pass: []const u8) !void {
    if (user.len == 0 or user.len > 190 or !std.unicode.utf8ValidateSlice(user)) return error.InvalidGrafanaUsernameSecret;
    if (!std.mem.eql(u8, user, std.mem.trim(u8, user, " \t\r\n"))) return error.InvalidGrafanaUsernameSecret;
    for (user) |byte| if (byte < 32 or byte == 127 or byte == ':') return error.InvalidGrafanaUsernameSecret;
    if (pass.len < 4 or pass.len > 16 * 1024 or !std.unicode.utf8ValidateSlice(pass)) return error.InvalidGrafanaPasswordSecret;
    for (pass) |byte| if (byte == 0 or byte == '\n' or byte == '\r') return error.InvalidGrafanaPasswordSecret;
}
test "injected resolver produces opaque stdin payload and safe failures" {
    const Fake = struct {
        fail: bool = false,
        fail_password: bool = false,
        empty: bool = false,
        calls: usize = 0,
        fn read(ctx: *anyopaque, a: std.mem.Allocator, _: reference.SecretRef) !*Secret {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.fail) return error.ProviderFailed;
            if (self.fail_password and self.calls % 2 == 0) return error.ProviderFailed;
            return Secret.init(a, if (self.empty) "" else if (self.calls % 2 == 1) "private-user" else "private-password");
        }
    };
    const a = std.testing.allocator;
    var fake: Fake = .{};
    const ref = try reference.parseOnePassword("op://example/item/field");
    const resolver: Resolver = .{ .context = &fake, .read = Fake.read };
    const secret = try payload(a, resolver, ref, ref);
    defer secret.deinit();
    const output = try std.fmt.allocPrint(a, "{f} {any}", .{ secret, secret });
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "private-user") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "private-password") == null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    fake.fail = true;
    try std.testing.expectError(error.GrafanaUsernameResolutionFailed, payload(a, resolver, ref, ref));
    fake.fail = false;
    fake.calls = 0;
    fake.fail_password = true;
    try std.testing.expectError(error.GrafanaPasswordResolutionFailed, payload(a, resolver, ref, ref));
    fake.fail_password = false;
    fake.empty = true;
    try std.testing.expectError(error.InvalidGrafanaUsernameSecret, payload(a, resolver, ref, ref));
    try std.testing.expectError(error.InvalidGrafanaPasswordSecret, validate("valid", ""));
    try std.testing.expectError(error.InvalidGrafanaPasswordSecret, validate("valid", "123"));
    try std.testing.expectError(error.InvalidGrafanaPasswordSecret, validate("valid", "line\nbreak"));
    try std.testing.expectError(error.InvalidGrafanaUsernameSecret, validate("bad:user", "valid-password"));
}
