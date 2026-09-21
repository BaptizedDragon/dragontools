const std = @import("std");
const m = @import("mbedtls.zig");
const c = m.c;
const der = @import("der.zig");
const profile = @import("profile.zig");
const key = @import("key.zig");
pub const Csr = struct {
    context: c.mbedtls_x509_csr,
    pub fn parse(a: std.mem.Allocator, pem: []const u8, host: []const u8) !Csr {
        try profile.host(host);
        const bytes = try der.decodePem(a, pem, "CERTIFICATE REQUEST", 8192);
        defer a.free(bytes);
        var signed = der.Reader{ .rest = (try der.one(bytes, 0x30)).value };
        const info = try signed.take(0x30);
        try profile.signatureAlgorithm((try signed.take(0x30)).encoded);
        const sig = (try signed.take(0x03)).value;
        if (sig.len < 2 or sig[0] != 0) return error.InvalidCsrSignature;
        try signed.end();
        var fields = der.Reader{ .rest = info.value };
        try der.equal((try fields.take(0x02)).value, "\x00");
        try profile.commonName((try fields.take(0x30)).encoded, host);
        try profile.publicKey((try fields.take(0x30)).encoded);
        const attributes = try fields.take(0xa0);
        try fields.end();
        var attr = der.Reader{ .rest = (try der.one(attributes.value, 0x30)).value };
        try der.equal((try attr.take(0x06)).value, profile.extension_request);
        const extensions = (try der.one((try attr.take(0x31)).value, 0x30)).value;
        try attr.end();
        // Exactly one SAN extension. No CA, EKU, challenge or unknown attrs.
        var ext = der.Reader{ .rest = (try der.one(extensions, 0x30)).value };
        try der.equal((try ext.take(0x06)).value, profile.san_oid);
        var value = try ext.next();
        if (value.tag == 0x01) {
            try der.equal(value.value, "\xff");
            value = try ext.next();
        }
        if (value.tag != 0x04) return error.InvalidCsrExtensions;
        try ext.end();
        const san = try der.one((try der.one(value.value, 0x30)).value, 0x86);
        const expected = try profile.identity(a, host);
        defer a.free(expected);
        try der.equal(san.value, expected);
        try m.init();
        var result: Csr = undefined;
        c.mbedtls_x509_csr_init(&result.context);
        errdefer result.deinit();
        try m.check(c.mbedtls_x509_csr_parse_der(&result.context, bytes.ptr, bytes.len));
        // Parse success alone is not proof of possession.
        const digest = try m.sha256(info.encoded);
        try m.check(c.mbedtls_pk_verify(&result.context.pk, c.MBEDTLS_MD_SHA256, &digest, digest.len, sig[1..].ptr, sig.len - 1));
        return result;
    }
    pub fn deinit(self: *Csr) void {
        c.mbedtls_x509_csr_free(&self.context);
    }
    pub fn matchesKey(self: *const Csr, local_key: *const key.Key) !bool {
        return key.samePublic(&self.context.pk, &local_key.context);
    }
};
pub fn create(a: std.mem.Allocator, local_key: *key.Key, host: []const u8) ![]u8 {
    const uri = try profile.identity(a, host);
    defer a.free(uri);
    const name = try std.fmt.allocPrintSentinel(a, "CN={s}", .{host}, 0);
    defer a.free(name);
    const entry = try der.wrap(a, 0x86, uri);
    defer a.free(entry);
    const san = try der.wrap(a, 0x30, entry);
    defer a.free(san);
    var writer: c.mbedtls_x509write_csr = undefined;
    c.mbedtls_x509write_csr_init(&writer);
    defer c.mbedtls_x509write_csr_free(&writer);
    c.mbedtls_x509write_csr_set_key(&writer, &local_key.context);
    c.mbedtls_x509write_csr_set_md_alg(&writer, c.MBEDTLS_MD_SHA256);
    try m.check(c.mbedtls_x509write_csr_set_subject_name(&writer, name));
    try m.check(c.mbedtls_x509write_csr_set_extension(&writer, profile.san_oid.ptr, profile.san_oid.len, 0, san.ptr, san.len));
    var buffer: [8192]u8 = undefined;
    try m.check(c.mbedtls_x509write_csr_pem(&writer, &buffer, buffer.len));
    return a.dupe(u8, std.mem.sliceTo(&buffer, 0));
}
test "CSR has exact machine identity and valid P256 proof of possession" {
    const a = std.testing.allocator;
    const host = "dt-0123456789abcdef0123456789abcdef";
    var local_key = try key.Key.generate();
    defer local_key.deinit();
    const pem = try create(a, &local_key, host);
    defer a.free(pem);
    var parsed = try Csr.parse(a, pem, host);
    defer parsed.deinit();
    try std.testing.expect(try key.samePublic(&local_key.context, &parsed.context.pk));
    try std.testing.expectError(error.InvalidPkiProfile, Csr.parse(a, pem, "dt-ffffffffffffffffffffffffffffffff"));
}
