//! Invalid-profile generation for isolated fixtures only. Never imported by
//! either production executable. These deliberately bypass production policy.
const std = @import("std");
const pki = @import("pki.zig");
const m = pki.crypto;
const c = m.c;
const der = @import("der.zig");
const profile = pki.profile;
pub const Kind = enum { client, server, legacy, wrong_san, extra_san, wrong_purpose, expired, ca, non_ca, ca_no_cert_sign, ca_no_crl_sign, ca_no_pathlen, ca_wrong_pathlen };
pub fn certificate(a: std.mem.Allocator, key: *pki.Key, signer: *pki.Key, host: []const u8, kind: Kind, now: i64) ![]const u8 {
    var writer: c.mbedtls_x509write_cert = undefined;
    c.mbedtls_x509write_crt_init(&writer);
    defer c.mbedtls_x509write_crt_free(&writer);
    const is_ca = switch (kind) {
        .ca, .non_ca, .ca_no_cert_sign, .ca_no_crl_sign, .ca_no_pathlen, .ca_wrong_pathlen => true,
        else => false,
    };
    c.mbedtls_x509write_crt_set_version(&writer, c.MBEDTLS_X509_CRT_VERSION_3);
    c.mbedtls_x509write_crt_set_md_alg(&writer, c.MBEDTLS_MD_SHA256);
    c.mbedtls_x509write_crt_set_subject_key(&writer, &key.context);
    c.mbedtls_x509write_crt_set_issuer_key(&writer, &signer.context);
    try @import("certificate.zig").setIdentifiers(a, &writer, &key.context, &(try @import("certificate.zig").keyIdentifier(&signer.context)));
    const name = try std.fmt.allocPrintSentinel(a, "CN={s}", .{if (is_ca) "DragonTools agent CA" else host}, 0);
    try m.check(c.mbedtls_x509write_crt_set_subject_name(&writer, name));
    try m.check(c.mbedtls_x509write_crt_set_issuer_name(&writer, "CN=DragonTools agent CA"));
    var serial: [16]u8 = undefined;
    try m.random(&serial);
    serial[0] = 1;
    try m.check(c.mbedtls_x509write_crt_set_serial_raw(&writer, &serial, serial.len));
    var before: [15:0]u8 = undefined;
    var after: [15:0]u8 = undefined;
    const fmt = @import("certificate.zig").formatTime;
    try m.check(c.mbedtls_x509write_crt_set_validity(&writer, (try fmt(&before, now - 86400)).ptr, (try fmt(&after, if (kind == .expired) now - 1 else now + @as(i64, if (is_ca) 3650 else 365) * 86400)).ptr));
    const basic: []const u8 = switch (kind) {
        .ca_no_pathlen => "\x30\x03\x01\x01\xff",
        .ca_wrong_pathlen => "\x30\x06\x01\x01\xff\x02\x01\x01",
        .non_ca => "\x30\x00",
        else => if (is_ca) "\x30\x06\x01\x01\xff\x02\x01\x00" else "\x30\x00",
    };
    try m.check(c.mbedtls_x509write_crt_set_extension(&writer, profile.basic_oid.ptr, profile.basic_oid.len, 1, basic.ptr, basic.len));
    const usage: c_uint = switch (kind) {
        .ca_no_cert_sign => c.MBEDTLS_X509_KU_CRL_SIGN,
        .ca_no_crl_sign => c.MBEDTLS_X509_KU_KEY_CERT_SIGN,
        else => if (is_ca) c.MBEDTLS_X509_KU_KEY_CERT_SIGN | c.MBEDTLS_X509_KU_CRL_SIGN else c.MBEDTLS_X509_KU_DIGITAL_SIGNATURE,
    };
    try m.check(c.mbedtls_x509write_crt_set_key_usage(&writer, usage));
    if (!is_ca) {
        const eku = try der.wrap(a, 0x30, try der.wrap(a, 0x06, if (kind == .server or kind == .wrong_purpose) profile.server_auth else profile.client_auth));
        try m.check(c.mbedtls_x509write_crt_set_extension(&writer, profile.eku_oid.ptr, profile.eku_oid.len, 0, eku.ptr, eku.len));
        if (kind != .legacy) {
            const uri = try profile.identity(a, if (kind == .wrong_san) "dt-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" else if (kind == .server) "dt-0123456789abcdef0123456789abcdef" else host);
            var entries: std.ArrayList(u8) = .empty;
            try entries.appendSlice(a, try der.wrap(a, if (kind == .server) 0x82 else 0x86, if (kind == .server) host else uri));
            if (kind == .extra_san) try entries.appendSlice(a, try der.wrap(a, 0x82, "extra.example"));
            const san = try der.wrap(a, 0x30, entries.items);
            try m.check(c.mbedtls_x509write_crt_set_extension(&writer, profile.san_oid.ptr, profile.san_oid.len, 0, san.ptr, san.len));
        }
    }
    var output: [16384]u8 = undefined;
    try m.check(c.mbedtls_x509write_crt_pem(&writer, &output, output.len));
    return a.dupe(u8, std.mem.sliceTo(&output, 0));
}
pub fn privilegedCsr(a: std.mem.Allocator, key: *pki.Key, host: []const u8, server_auth: bool) ![]const u8 {
    var writer: c.mbedtls_x509write_csr = undefined;
    c.mbedtls_x509write_csr_init(&writer);
    defer c.mbedtls_x509write_csr_free(&writer);
    c.mbedtls_x509write_csr_set_key(&writer, &key.context);
    c.mbedtls_x509write_csr_set_md_alg(&writer, c.MBEDTLS_MD_SHA256);
    try m.check(c.mbedtls_x509write_csr_set_subject_name(&writer, try std.fmt.allocPrintSentinel(a, "CN={s}", .{host}, 0)));
    const san = try der.wrap(a, 0x30, try der.wrap(a, 0x86, try profile.identity(a, host)));
    try m.check(c.mbedtls_x509write_csr_set_extension(&writer, profile.san_oid.ptr, profile.san_oid.len, 0, san.ptr, san.len));
    const oid = if (server_auth) profile.eku_oid else profile.basic_oid;
    const value = if (server_auth) try der.wrap(a, 0x30, try der.wrap(a, 0x06, profile.server_auth)) else "\x30\x03\x01\x01\xff";
    try m.check(c.mbedtls_x509write_csr_set_extension(&writer, oid.ptr, oid.len, 1, value.ptr, value.len));
    var output: [8192]u8 = undefined;
    try m.check(c.mbedtls_x509write_csr_pem(&writer, &output, output.len));
    return a.dupe(u8, std.mem.sliceTo(&output, 0));
}
