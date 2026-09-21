const std = @import("std");
const pki = @import("pki.zig");
const der = @import("der.zig");
const now: i64 = 1770000000;
const host = "dt-0123456789abcdef0123456789abcdef";

test "OpenSSL-created CA server client keys and CSR remain valid without external tools" {
    const a = std.testing.allocator;
    var ca = try pki.Certificate.parse(a, @embedFile("fixtures/openssl-ca.crt"));
    defer ca.deinit();
    const clock = try ca.validFrom() + 1;
    var ca_key = try pki.Key.parse(a, @embedFile("fixtures/openssl-ca.key"));
    defer ca_key.deinit();
    try ca.validateCa(clock);
    try ca.matchesKey(&ca_key);
    inline for (.{ "server", "client" }) |kind| {
        var cert = try pki.Certificate.parse(a, @embedFile("fixtures/openssl-" ++ kind ++ ".crt"));
        defer cert.deinit();
        var key = try pki.Key.parse(a, @embedFile("fixtures/openssl-" ++ kind ++ ".key"));
        defer key.deinit();
        try cert.matchesKey(&key);
        try cert.verify(&ca, if (std.mem.eql(u8, kind, "server")) .server else .client, if (std.mem.eql(u8, kind, "server")) "station.example" else host, clock, false);
    }
    var csr = try pki.Csr.parse(a, @embedFile("fixtures/openssl-client.csr"), host);
    defer csr.deinit();
    const signed_pem = try pki.signClientCertificate(a, &ca, &ca_key, &csr, host, .{ .not_before = clock, .not_after = clock + 86400 });
    defer a.free(signed_pem);
    var signed = try pki.Certificate.parse(a, signed_pem);
    defer signed.deinit();
    try signed.verify(&ca, .client, host, clock, false);
}
fn rejectedCsr(bytes: []const u8) !void {
    if (pki.Csr.parse(std.testing.allocator, bytes, host)) |value| {
        var csr = value;
        csr.deinit();
        return error.UnexpectedAcceptedCsr;
    } else |_| {}
}
test "valid RSA P384 wrong identity and malformed CSR corpus are rejected" {
    try rejectedCsr(@embedFile("fixtures/openssl-rsa.csr"));
    try rejectedCsr(@embedFile("fixtures/openssl-p384.csr"));
    try rejectedCsr(@embedFile("fixtures/openssl-server.csr"));
    for ([_][]const u8{ "", "\x30\x80\x00\x00", "-----BEGIN CERTIFICATE REQUEST-----\nAAAA\n-----END CERTIFICATE REQUEST-----\n", "-----BEGIN CERTIFICATE REQUEST-----\n////\n-----END CERTIFICATE REQUEST-----\n", "\x00", @embedFile("fixtures/openssl-client.csr") ++ @embedFile("fixtures/openssl-client.csr") }) |value| try rejectedCsr(value);
    const original = @embedFile("fixtures/openssl-client.csr");
    var length: usize = 0;
    while (length < original.len) : (length += 17) try rejectedCsr(original[0..length]);
}

test "signed privilege CSRs and exact invalid CA extension profiles fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const support = @import("test_support.zig");
    var key = try pki.Key.generate();
    defer key.deinit();
    try rejectedCsr(try support.privilegedCsr(a, &key, host, false));
    try rejectedCsr(try support.privilegedCsr(a, &key, host, true));
    for ([_]support.Kind{ .non_ca, .ca_no_cert_sign, .ca_no_crl_sign, .ca_no_pathlen, .ca_wrong_pathlen }) |kind| {
        var cert = try pki.Certificate.parse(a, try support.certificate(a, &key, &key, "DragonTools agent CA", kind, now));
        defer cert.deinit();
        if (cert.validateCa(now)) |_| return error.InvalidCaAccepted else |_| {}
    }
}

test "bounded ingestion HTTP health requires empty 204 and preserves safe semantic rejection" {
    const tls = @import("tls.zig");
    try tls.inspectHealth("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n", "");
    try std.testing.expectError(error.ClientCertificateRejected, tls.inspectHealth("HTTP/1.0 403 Forbidden\r\n\r\n", ""));
    try std.testing.expectError(error.IngestionRejected, tls.inspectHealth("HTTP/1.1 204 No Content\r\n\r\n", "payload"));
    try std.testing.expectError(error.IngestionRejected, tls.inspectHealth("HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n", ""));
    try std.testing.expectError(error.IngestionRejected, tls.inspectHealth("HTTP/1.1 204 No Content\r\nContent-Length: 12\r\n\r\n", ""));
}

test "fixed CA server and client profiles verify signatures chain identities keys and validity" {
    const a = std.testing.allocator;
    var ca_key = try pki.Key.generate();
    defer ca_key.deinit();
    const ca_pem = try pki.createCaCertificate(a, &ca_key, .{ .not_before = now - 60, .not_after = now + pki.profile.ca_seconds });
    defer a.free(ca_pem);
    var ca = try pki.Certificate.parse(a, ca_pem);
    defer ca.deinit();
    try ca.validateCa(now);
    try ca.matchesKey(&ca_key);
    try std.testing.expectEqual(now + pki.profile.ca_seconds, try ca.expiry());
    const fingerprint = try ca.fingerprint();
    try std.testing.expectEqual(@as(usize, 64), fingerprint.len);
    try std.testing.expectError(error.CertificateExpired, ca.validateCa(now + pki.profile.ca_seconds));
    try std.testing.expectError(error.CertificateNotYetValid, ca.validateCa(now - 61));

    var server_key = try pki.Key.generate();
    defer server_key.deinit();
    const names = [_]pki.San{ .{ .tag = 0x82, .value = "station.example" }, .{ .tag = 0x82, .value = "old-station.example" }, .{ .tag = 0x87, .value = "\x7f\x00\x00\x01" } };
    const server_pem = try pki.createServerCertificate(a, &ca, &ca_key, &server_key, "station.example", &names, .{ .not_before = now - 60, .not_after = now + pki.profile.leaf_seconds });
    defer a.free(server_pem);
    var server = try pki.Certificate.parse(a, server_pem);
    defer server.deinit();
    try server.verify(&ca, .server, "station.example", now, false);
    try server.verify(&ca, .server, "old-station.example", now, false);
    try server.verify(&ca, .server, "127.0.0.1", now, false);
    try server.matchesKey(&server_key);
    try std.testing.expectError(error.CertificateHostnameMismatch, server.verify(&ca, .server, "other.example", now, false));
    try std.testing.expectError(error.InvalidPkiProfile, server.validateCa(now));
    try std.testing.expectError(error.InvalidPki, server.matchesKey(&ca_key));
    try std.testing.expectError(error.CertificateExpired, server.verify(&ca, .server, "station.example", now + pki.profile.leaf_seconds, false));
    try server.verify(&ca, .server, "station.example", now + pki.profile.leaf_seconds, true);

    var client_key = try pki.Key.generate();
    defer client_key.deinit();
    const request_pem = try pki.createClientCsr(a, &client_key, host);
    defer a.free(request_pem);
    var request = try pki.Csr.parse(a, request_pem, host);
    defer request.deinit();
    const client_pem = try pki.signClientCertificate(a, &ca, &ca_key, &request, host, .{ .not_before = now - 60, .not_after = now + pki.profile.leaf_seconds });
    defer a.free(client_pem);
    var client = try pki.Certificate.parse(a, client_pem);
    defer client.deinit();
    try client.verify(&ca, .client, host, now, false);
    try client.matchesKey(&client_key);
    try std.testing.expectError(error.InvalidPkiProfile, client.verify(&ca, .server, "station.example", now, false));
    try std.testing.expectError(error.InvalidPkiProfile, client.verify(&ca, .client, "dt-ffffffffffffffffffffffffffffffff", now, false));
    var listed: [16]pki.San = undefined;
    const sans = try client.sans(&listed);
    try std.testing.expectEqual(@as(usize, 1), sans.len);
    try std.testing.expectEqual(@as(u8, 0x86), sans[0].tag);
    try std.testing.expectEqualStrings("dragontools://hosts/" ++ host, sans[0].value);

    const ca_der = try der.decodePem(a, ca_pem, "CERTIFICATE", 16384);
    defer a.free(ca_der);
    ca_der[ca_der.len - 1] ^= 1;
    const corrupt = try pem(a, "CERTIFICATE", ca_der);
    defer a.free(corrupt);
    var corrupted_ca = try pki.Certificate.parse(a, corrupt);
    defer corrupted_ca.deinit();
    try std.testing.expectError(error.InvalidPki, corrupted_ca.validateCa(now));

    const csr_der = try der.decodePem(a, request_pem, "CERTIFICATE REQUEST", 8192);
    defer a.free(csr_der);
    csr_der[csr_der.len - 1] ^= 1;
    const corrupt_csr = try pem(a, "CERTIFICATE REQUEST", csr_der);
    defer a.free(corrupt_csr);
    try std.testing.expectError(error.InvalidPki, pki.Csr.parse(a, corrupt_csr, host));
}
pub fn pem(a: std.mem.Allocator, comptime label: []const u8, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(bytes.len));
    defer a.free(encoded);
    _ = encoder.encode(encoded, bytes);
    return std.fmt.allocPrint(a, "-----BEGIN " ++ label ++ "-----\n{s}\n-----END " ++ label ++ "-----\n", .{encoded});
}

test "malformed certificate and private-key PEM corpus is bounded and never accepted" {
    const original = @embedFile("fixtures/openssl-ca.crt");
    var length: usize = 0;
    while (length < original.len) : (length += 17) {
        if (pki.Certificate.parse(std.testing.allocator, original[0..length])) |value| {
            var certificate = value;
            certificate.deinit();
            return error.TruncatedCertificateAccepted;
        } else |_| {}
    }
    for ([_][]const u8{ "", "\x30\x80\x00\x00", "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n", "PRIVATE KEY sentinel", @embedFile("fixtures/openssl-client.key") ++ @embedFile("fixtures/openssl-client.key") }) |value| {
        if (pki.Key.parse(std.testing.allocator, value)) |parsed| {
            var key = parsed;
            key.deinit();
            return error.MalformedKeyAccepted;
        } else |_| {}
    }
}
