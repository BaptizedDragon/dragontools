//! Telegram values resolve locally and leave the controller only on SSH stdin.
const std = @import("std");
const Secret = @import("secret.zig").Secret;
const reference = @import("reference.zig");
pub fn payload(a: std.mem.Allocator, resolver: reference.Resolver, token_ref: reference.SecretRef, chat_ref: reference.SecretRef) !*Secret {
    const token = resolver.resolve(a, token_ref) catch return error.TelegramTokenResolutionFailed;
    defer token.deinit();
    const chat = resolver.resolve(a, chat_ref) catch return error.TelegramChatResolutionFailed;
    defer chat.deinit();
    try validate(token.protectedBytes(), chat.protectedBytes());
    const encoded = try a.alloc(u8, 64 + 6 * (token.protectedBytes().len + chat.protectedBytes().len));
    defer {
        std.crypto.secureZero(u8, encoded);
        a.free(encoded);
    }
    var writer = std.Io.Writer.fixed(encoded);
    try std.json.Stringify.value(.{ .token = token.protectedBytes(), .chat_id = chat.protectedBytes() }, .{}, &writer);
    return Secret.init(a, writer.buffered());
}
pub fn validate(token: []const u8, chat: []const u8) !void {
    if (token.len == 0 or token.len > 512) return error.InvalidTelegramTokenSecret;
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse return error.InvalidTelegramTokenSecret;
    if (colon == 0 or colon + 1 == token.len) return error.InvalidTelegramTokenSecret;
    for (token[0..colon]) |c| if (!std.ascii.isDigit(c)) return error.InvalidTelegramTokenSecret;
    for (token[colon + 1 ..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidTelegramTokenSecret;
    if (chat.len == 0 or chat.len > 20) return error.InvalidTelegramChatSecret;
    const digits = if (chat[0] == '-') chat[1..] else chat;
    if (digits.len == 0) return error.InvalidTelegramChatSecret;
    for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidTelegramChatSecret;
    const id = std.fmt.parseInt(i64, chat, 10) catch return error.InvalidTelegramChatSecret;
    if (id == 0) return error.InvalidTelegramChatSecret;
}
test "Telegram validates without exposing resolved values" {
    try validate("123456:opaque_TOKEN-value", "-1001234567890");
    for ([_][]const u8{ "", "token", "1:x y", "1:x\n", "x:y", "1:" }) |v| try std.testing.expectError(error.InvalidTelegramTokenSecret, validate(v, "-123"));
    for ([_][]const u8{ "", "0", "--1", "+12", "1\n", "9223372036854775808" }) |v| try std.testing.expectError(error.InvalidTelegramChatSecret, validate("1:opaque", v));
    const Fake = struct {
        calls: usize = 0,
        fn resolve(ctx: *anyopaque, a: std.mem.Allocator, _: reference.SecretRef) !*Secret {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.calls += 1;
            return Secret.init(a, if (s.calls == 1) "123:private-token" else "-1001234567890");
        }
    };
    var fake: Fake = .{};
    const ref = try reference.parseOnePassword("op://example/item/field");
    const value = try payload(std.testing.allocator, .{ .context = &fake, .read = Fake.resolve }, ref, ref);
    defer value.deinit();
    const out = try std.fmt.allocPrint(std.testing.allocator, "{f} {any}", .{ value, value });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "private-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1001234567890") == null);
}
