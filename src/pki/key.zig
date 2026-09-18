const std = @import("std");
const m = @import("mbedtls.zig");
const c = m.c;
const profile = @import("profile.zig");
pub const Key = struct {
    context: c.mbedtls_pk_context,
    pub fn generate() !Key {
        try m.init();
        var result: Key = undefined;
        c.mbedtls_pk_init(&result.context);
        errdefer result.deinit();
        var attributes = c.psa_key_attributes_init();
        c.psa_set_key_type(&attributes, c.PSA_KEY_TYPE_ECC_KEY_PAIR(c.PSA_ECC_FAMILY_SECP_R1));
        c.psa_set_key_bits(&attributes, 256);
        c.psa_set_key_usage_flags(&attributes, c.PSA_KEY_USAGE_EXPORT | c.PSA_KEY_USAGE_SIGN_HASH | c.PSA_KEY_USAGE_VERIFY_HASH);
        c.psa_set_key_algorithm(&attributes, c.PSA_ALG_ECDSA(c.PSA_ALG_SHA_256));
        var id: c.mbedtls_svc_key_id_t = 0;
        try m.check(c.psa_generate_key(&attributes, &id));
        defer _ = c.psa_destroy_key(id);
        try m.check(c.mbedtls_pk_copy_from_psa(id, &result.context));
        return result;
    }
    pub fn parse(a: std.mem.Allocator, pem: []const u8) !Key {
        if (pem.len > 4096 or std.mem.indexOfScalar(u8, pem, 0) != null) return error.InvalidPrivateKey;
        try m.init();
        const trimmed = std.mem.trim(u8, pem, " \r\n\t");
        const der = @import("der.zig");
        const decoded = if (std.mem.startsWith(u8, trimmed, "-----BEGIN EC PRIVATE KEY-----"))
            try der.decodePem(a, pem, "EC PRIVATE KEY", 4096)
        else
            try der.decodePem(a, pem, "PRIVATE KEY", 4096);
        defer {
            std.crypto.secureZero(u8, decoded);
            a.free(decoded);
        }
        var result: Key = undefined;
        c.mbedtls_pk_init(&result.context);
        errdefer result.deinit();
        try m.check(c.mbedtls_pk_parse_key(&result.context, decoded.ptr, decoded.len, null, 0));
        var storage: [256]u8 = undefined;
        try profile.publicKey(try publicDer(&result.context, &storage));
        return result;
    }
    pub fn deinit(self: *Key) void {
        c.mbedtls_pk_free(&self.context);
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
    /// Private output is for local protected file writers only, never transport.
    /// The owner must zero this allocation before freeing it.
    pub fn privatePem(self: *const Key, a: std.mem.Allocator) ![]u8 {
        var buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        try m.check(c.mbedtls_pk_write_key_pem(&self.context, &buffer, buffer.len));
        return a.dupe(u8, std.mem.sliceTo(&buffer, 0));
    }
};
pub fn publicDer(context: *const c.mbedtls_pk_context, buffer: []u8) ![]const u8 {
    const count = c.mbedtls_pk_write_pubkey_der(context, buffer.ptr, buffer.len);
    if (count <= 0 or count > buffer.len) return error.InvalidPublicKey;
    return buffer[buffer.len - @as(usize, @intCast(count)) ..];
}
pub fn samePublic(left: *const c.mbedtls_pk_context, right: *const c.mbedtls_pk_context) !bool {
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    return std.mem.eql(u8, try publicDer(left, &first), try publicDer(right, &second));
}
test "P256 private key roundtrip and normalized public key comparison" {
    const a = std.testing.allocator;
    var key = try Key.generate();
    defer key.deinit();
    const pem = try key.privatePem(a);
    defer {
        std.crypto.secureZero(u8, pem);
        a.free(pem);
    }
    var parsed = try Key.parse(a, pem);
    defer parsed.deinit();
    try std.testing.expect(try samePublic(&key.context, &parsed.context));
    var other = try Key.generate();
    defer other.deinit();
    try std.testing.expect(!try samePublic(&key.context, &other.context));
    try std.testing.expectError(error.InvalidPki, m.check(c.mbedtls_pk_check_pair(&key.context, &other.context)));
}
