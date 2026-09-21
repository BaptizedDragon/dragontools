//! The only place that imports the embedded crypto C API.
const std = @import("std");
pub const c = @cImport({
    @cDefine("MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS", "1");
    @cInclude("psa/crypto.h");
    @cInclude("mbedtls/pk.h");
    // 4.2.0's X.509 profile checks both signature and legacy key-type IDs.
    // ECKEY is defined in this pinned private header; keep that detail here.
    @cInclude("mbedtls/private/pk_private.h");
    @cInclude("mbedtls/x509_crt.h");
    @cInclude("mbedtls/x509_csr.h");
    @cInclude("mbedtls/ssl.h");
    @cInclude("mbedtls/net_sockets.h");
    @cInclude("mbedtls/version.h");
    @cInclude("tf-psa-crypto/version.h");
});
pub const version = "4.2.0";
pub const minimum_approved = "4.2.0";
pub const psa_version = "1.2.0";
pub const archive_sha256 = "2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea";
pub const archive_url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.2.0/mbedtls-4.2.0.tar.bz2";
pub fn check(result: c_int) !void {
    if (result != 0) return error.InvalidPki;
}
pub fn init() !void {
    try check(c.psa_crypto_init());
}
pub fn random(bytes: []u8) !void {
    try init();
    try check(c.psa_generate_random(bytes.ptr, bytes.len));
}
pub fn sha256(bytes: []const u8) ![32]u8 {
    try init();
    var digest: [32]u8 = undefined;
    var len: usize = 0;
    try check(c.psa_hash_compute(c.PSA_ALG_SHA_256, bytes.ptr, bytes.len, &digest, digest.len, &len));
    if (len != digest.len) return error.InvalidPki;
    return digest;
}
test "embedded crypto compiled versions match the reviewed pins and RNG works" {
    try std.testing.expectEqualStrings(version, c.MBEDTLS_VERSION_STRING);
    try std.testing.expectEqualStrings(psa_version, c.TF_PSA_CRYPTO_VERSION_STRING);
    try std.testing.expectEqualStrings(version, minimum_approved);
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    try random(&first);
    try random(&second);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
