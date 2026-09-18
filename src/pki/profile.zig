//! Fixed issuance and verification policy; no arbitrary extensions in the API.
const std = @import("std");
const der = @import("der.zig");
pub const Profile = enum { ca, server, client, legacy_client };
pub const sha256_ecdsa = "\x2a\x86\x48\xce\x3d\x04\x03\x02";
pub const ec_public = "\x2a\x86\x48\xce\x3d\x02\x01";
pub const p256 = "\x2a\x86\x48\xce\x3d\x03\x01\x07";
pub const cn_oid = "\x55\x04\x03";
pub const san_oid = "\x55\x1d\x11";
pub const basic_oid = "\x55\x1d\x13";
pub const usage_oid = "\x55\x1d\x0f";
pub const eku_oid = "\x55\x1d\x25";
pub const client_auth = "\x2b\x06\x01\x05\x05\x07\x03\x02";
pub const server_auth = "\x2b\x06\x01\x05\x05\x07\x03\x01";
pub const extension_request = "\x2a\x86\x48\x86\xf7\x0d\x01\x09\x0e";
pub const leaf_seconds = 365 * 86400;
pub const renew_seconds = 30 * 86400;
pub const ca_seconds = 3650 * 86400;
pub const ca_maintenance_seconds = 366 * 86400;
pub fn host(value: []const u8) !void {
    if (value.len != 35 or !std.mem.startsWith(u8, value, "dt-")) return error.InvalidHostIdentity;
    for (value[3..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidHostIdentity;
}
pub fn identity(a: std.mem.Allocator, value: []const u8) ![]u8 {
    try host(value);
    return std.fmt.allocPrint(a, "dragontools://hosts/{s}", .{value});
}
pub fn dns(value: []const u8) !void {
    if (value.len == 0 or value.len > 253) return error.InvalidStationEndpoint;
    var labels = std.mem.splitScalar(u8, value, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidStationEndpoint;
        for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidStationEndpoint;
    }
}
pub fn signatureAlgorithm(encoded: []const u8) !void {
    var r = der.Reader{ .rest = (try der.one(encoded, 0x30)).value };
    try der.equal((try r.take(0x06)).value, sha256_ecdsa);
    try r.end();
}
pub fn publicKey(encoded: []const u8) !void {
    var r = der.Reader{ .rest = (try der.one(encoded, 0x30)).value };
    var alg = der.Reader{ .rest = (try r.take(0x30)).value };
    try der.equal((try alg.take(0x06)).value, ec_public);
    try der.equal((try alg.take(0x06)).value, p256);
    try alg.end();
    const point = (try r.take(0x03)).value;
    if (point.len != 66 or point[0] != 0 or point[1] != 4) return error.InvalidPkiProfile;
    try r.end();
}
pub fn commonName(encoded: []const u8, expected: []const u8) !void {
    const sequence = try der.one(encoded, 0x30);
    const set = try der.one(sequence.value, 0x31);
    var r = der.Reader{ .rest = (try der.one(set.value, 0x30)).value };
    try der.equal((try r.take(0x06)).value, cn_oid);
    const value = try r.next();
    if (value.tag != 0x0c and value.tag != 0x13) return error.InvalidPkiProfile;
    try der.equal(value.value, expected);
    try r.end();
}
