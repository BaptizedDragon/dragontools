//! Bounded public protocol values. Callers use a per-operation arena.
const std = @import("std");
pub const Value = std.json.Value;
pub const Entry = struct { []const u8, Value };
pub fn require(ok: bool) !void {
    if (!ok) return error.CredentialStateRefused;
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8, limit: usize) !Value {
    try require(bytes.len <= limit);
    return (try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always, .max_value_len = limit })).value;
}
pub fn object(a: std.mem.Allocator, entries: []const Entry) !Value {
    var value: Value = .{ .object = .empty };
    for (entries) |entry| try value.object.put(a, entry[0], entry[1]);
    return value;
}
pub fn copy(a: std.mem.Allocator, value: Value) !Value {
    try require(value == .object);
    var result = try object(a, &.{});
    var it = value.object.iterator();
    while (it.next()) |entry| try result.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
    return result;
}
pub fn string(value: []const u8) Value {
    return .{ .string = value };
}
pub fn integer(value: i64) Value {
    return .{ .integer = value };
}
pub fn boolean(value: bool) Value {
    return .{ .bool = value };
}
pub fn get(value: Value, name: []const u8) !Value {
    try require(value == .object);
    return value.object.get(name) orelse error.CredentialStateRefused;
}
pub fn optional(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
pub fn text(value: Value) ![]const u8 {
    try require(value == .string);
    return value.string;
}
pub fn field(value: Value, name: []const u8) ![]const u8 {
    return text(try get(value, name));
}
pub fn number(value: Value) !i64 {
    try require(value == .integer);
    return value.integer;
}
pub fn flag(value: Value) !bool {
    try require(value == .bool);
    return value.bool;
}
pub fn array(value: Value, limit: usize) ![]Value {
    try require(value == .array and value.array.items.len <= limit);
    return value.array.items;
}
pub fn keys(value: Value, names: []const []const u8) !void {
    try require(value == .object and value.object.count() == names.len);
    for (names) |name| try require(value.object.contains(name));
}
pub fn hasOnly(value: Value, names: []const []const u8) !void {
    try require(value == .object);
    for (value.object.keys()) |name| try require(contains(names, name));
}
pub fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}
pub fn equal(a: std.mem.Allocator, left: Value, right: Value) !bool {
    return std.mem.eql(u8, try encoded(a, left), try encoded(a, right));
}
pub fn encoded(a: std.mem.Allocator, value: Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try emit(a, &out.writer, value);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}
fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
fn emit(a: std.mem.Allocator, out: *std.Io.Writer, value: Value) anyerror!void {
    switch (value) {
        .object => |obj| {
            const names = try a.dupe([]const u8, obj.keys());
            std.mem.sort([]const u8, names, {}, less);
            try out.writeByte('{');
            for (names, 0..) |name, i| {
                if (i != 0) try out.writeByte(',');
                try std.json.Stringify.value(name, .{}, out);
                try out.writeByte(':');
                try emit(a, out, obj.get(name).?);
            }
            try out.writeByte('}');
        },
        .array => |items| {
            try out.writeByte('[');
            for (items.items, 0..) |item, i| {
                if (i != 0) try out.writeByte(',');
                try emit(a, out, item);
            }
            try out.writeByte(']');
        },
        .string => |v| try std.json.Stringify.value(v, .{}, out),
        .integer => |v| try out.print("{d}", .{v}),
        .bool => |v| try out.writeAll(if (v) "true" else "false"),
        .null => try out.writeAll("null"),
        else => return error.CredentialStateRefused,
    }
}
