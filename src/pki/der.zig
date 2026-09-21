//! Bounded canonical DER inspection for the fixed DragonTools profiles.
//! Cryptographic parsing and signature checks always use Mbed TLS as well.
const std = @import("std");
pub const Element = struct { tag: u8, value: []const u8, encoded: []const u8 };
pub const Reader = struct {
    rest: []const u8,
    pub fn next(self: *Reader) !Element {
        const data = self.rest;
        if (data.len < 2 or data[0] & 31 == 31) return error.InvalidDer;
        var offset: usize = 2;
        var len: usize = data[1];
        if (len & 128 != 0) {
            const count = len & 127;
            if (count == 0 or count > 3 or offset + count > data.len or data[offset] == 0) return error.InvalidDer;
            len = 0;
            for (data[offset..][0..count]) |byte| len = (len << 8) | byte;
            offset += count;
            if (len < 128) return error.InvalidDer;
        }
        if (len > data.len - offset) return error.InvalidDer;
        self.rest = data[offset + len ..];
        return .{ .tag = data[0], .value = data[offset..][0..len], .encoded = data[0 .. offset + len] };
    }
    pub fn take(self: *Reader, tag: u8) !Element {
        const item = try self.next();
        if (item.tag != tag) return error.InvalidDer;
        return item;
    }
    pub fn end(self: Reader) !void {
        if (self.rest.len != 0) return error.InvalidDer;
    }
};
pub fn one(bytes: []const u8, tag: u8) !Element {
    var r = Reader{ .rest = bytes };
    const item = try r.take(tag);
    try r.end();
    return item;
}
pub fn equal(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPkiProfile;
}
pub fn wrap(a: std.mem.Allocator, tag: u8, data: []const u8) ![]u8 {
    if (data.len > 65535) return error.PkiInputTooLarge;
    const header: usize = if (data.len < 128) 2 else if (data.len < 256) 3 else 4;
    const result = try a.alloc(u8, header + data.len);
    result[0] = tag;
    switch (header) {
        2 => result[1] = @intCast(data.len),
        3 => {
            result[1] = 0x81;
            result[2] = @intCast(data.len);
        },
        4 => {
            result[1] = 0x82;
            std.mem.writeInt(u16, result[2..4], @intCast(data.len), .big);
        },
        else => unreachable,
    }
    @memcpy(result[header..], data);
    return result;
}
pub fn decodePem(a: std.mem.Allocator, input: []const u8, comptime label: []const u8, limit: usize) ![]u8 {
    if (input.len > limit or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPem;
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const data = std.mem.trim(u8, input, " \r\n\t");
    if (!std.mem.startsWith(u8, data, begin) or !std.mem.endsWith(u8, data, end) or data.len <= begin.len + end.len) return error.InvalidPem;
    var compact: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, compact.items);
        compact.deinit(a);
    }
    for (data[begin.len .. data.len - end.len]) |byte| {
        if (byte == '\r' or byte == '\n') continue;
        try compact.append(a, byte);
    }
    const decoder = std.base64.standard.Decoder;
    const result = try a.alloc(u8, try decoder.calcSizeForSlice(compact.items));
    errdefer {
        std.crypto.secureZero(u8, result);
        a.free(result);
    }
    try decoder.decode(result, compact.items);
    _ = try one(result, 0x30);
    return result;
}
test "malformed DER corpus is rejected without allocation or recursion" {
    for ([_][]const u8{ "", "\x30", "\x30\x80", "\x30\x81\x01\x00", "\x30\x82\x00\x80", "\x30\xff", "\x30\x02\x00", "\x3f\x00", "\x30\x00\x00" }) |bad| {
        if (one(bad, 0x30)) |_| return error.AcceptedMalformedDer else |_| {}
    }
}
