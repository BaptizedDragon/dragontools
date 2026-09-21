//! Bounded native enrollment envelope. Normal pipe EOF terminates a request.
const std = @import("std");
const j = @import("json.zig");
pub const limit = 512 * 1024;
pub const Envelope = struct { action: []const u8, args: []const []const u8 };
pub fn read(a: std.mem.Allocator, io: std.Io, file: std.Io.File) !Envelope {
    const buffer = try a.alloc(u8, limit + 1);
    defer a.free(buffer);
    var used: usize = 0;
    while (used < buffer.len) {
        const n = file.readStreaming(io, &.{buffer[used..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        used += n;
    }
    return decode(a, buffer[0..used]);
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Envelope {
    try j.require(bytes.len <= limit);
    const value = try j.parse(a, bytes, limit);
    try j.keys(value, &.{ "action", "args" });
    const action = try j.field(value, "action");
    try j.require(action.len > 0 and action.len <= 32);
    const values = try j.array(try j.get(value, "args"), 4);
    const args = try a.alloc([]const u8, values.len);
    for (values, args) |item, *arg| {
        arg.* = try j.text(item);
        try j.require(arg.len <= 393216 and std.mem.indexOfScalar(u8, arg.*, 0) == null);
    }
    return .{ .action = action, .args = args };
}
test "normal native request EOF accepts a complete JSON envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(std.testing.io, "request", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "{\"action\":\"endpoint\",\"args\":[\"station.example\",\"vector\",\"dt-0123456789abcdef0123456789abcdef\",\"logs\"]}", 0);
    const value = try read(arena.allocator(), std.testing.io, file);
    try std.testing.expectEqualStrings("endpoint", value.action);
    try std.testing.expectEqualStrings("logs", value.args[3]);
}
test "native request remains strict bounded and rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "{", "{\"action\":\"ensure\",\"args\":[],\"unknown\":true}", "{\"action\":\"ensure\",\"args\":[\"\\u0000\"]}" }) |input| {
        if (decode(a, input)) |_| return error.TestUnexpectedResult else |_| {}
    }
    const oversized = try a.alloc(u8, limit + 1);
    @memset(oversized, 'x');
    try std.testing.expectError(error.CredentialStateRefused, decode(a, oversized));
}
