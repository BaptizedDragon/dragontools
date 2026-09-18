//! Fixed authenticated ingestion health request over an already connected socket.
const std = @import("std");
const m = @import("mbedtls.zig");
const c = m.c;
const certs = @import("certificate.zig");
const Key = @import("key.zig").Key;
extern "c" fn dragontools_tls_send(context: ?*anyopaque, data: [*c]const u8, size: usize) c_int;
extern "c" fn dragontools_network_deadline(code: c_int) void;
fn rejection(ssl: *const c.mbedtls_ssl_context, fallback: anyerror) anyerror {
    return switch (c.mbedtls_ssl_get_fatal_alert(ssl)) {
        c.MBEDTLS_SSL_ALERT_MSG_BAD_CERT, c.MBEDTLS_SSL_ALERT_MSG_UNSUPPORTED_CERT, c.MBEDTLS_SSL_ALERT_MSG_CERT_REVOKED, c.MBEDTLS_SSL_ALERT_MSG_CERT_EXPIRED, c.MBEDTLS_SSL_ALERT_MSG_CERT_UNKNOWN, c.MBEDTLS_SSL_ALERT_MSG_UNKNOWN_CA, c.MBEDTLS_SSL_ALERT_MSG_ACCESS_DENIED => error.ClientCertificateRejected,
        else => fallback,
    };
}
pub fn health(a: std.mem.Allocator, fd: c_int, ca_pem: []const u8, cert_pem: []const u8, key_pem: []const u8, hostname: []const u8, host: []const u8, now: i64) !void {
    var ca = certs.Certificate.parse(a, ca_pem) catch return error.ServerTlsInvalid;
    defer ca.deinit();
    ca.validateCa(now) catch return error.ServerTlsInvalid;
    var client = certs.Certificate.parse(a, cert_pem) catch return error.ClientCertificateRejected;
    defer client.deinit();
    var key = Key.parse(a, key_pem) catch return error.ClientCertificateRejected;
    defer key.deinit();
    client.verify(&ca, .legacy_client, host, now, false) catch return error.ClientCertificateRejected;
    client.matchesKey(&key) catch return error.ClientCertificateRejected;
    var conf: c.mbedtls_ssl_config = undefined;
    c.mbedtls_ssl_config_init(&conf);
    defer c.mbedtls_ssl_config_free(&conf);
    var ssl: c.mbedtls_ssl_context = undefined;
    c.mbedtls_ssl_init(&ssl);
    defer c.mbedtls_ssl_free(&ssl);
    try m.check(c.mbedtls_ssl_config_defaults(&conf, c.MBEDTLS_SSL_IS_CLIENT, c.MBEDTLS_SSL_TRANSPORT_STREAM, c.MBEDTLS_SSL_PRESET_DEFAULT));
    c.mbedtls_ssl_conf_authmode(&conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
    c.mbedtls_ssl_conf_ca_chain(&conf, &ca.context, null);
    try m.check(c.mbedtls_ssl_conf_own_cert(&conf, &client.context, &key.context));
    c.mbedtls_ssl_conf_read_timeout(&conf, 4000);
    try m.check(c.mbedtls_ssl_setup(&ssl, &conf));
    try m.check(c.mbedtls_ssl_set_hostname(&ssl, try a.dupeZ(u8, hostname)));
    var net: c.mbedtls_net_context = .{ .fd = fd };
    c.mbedtls_ssl_set_bio(&ssl, &net, dragontools_tls_send, c.mbedtls_net_recv, c.mbedtls_net_recv_timeout);
    dragontools_network_deadline(93);
    while (true) {
        const result = c.mbedtls_ssl_handshake(&ssl);
        if (result == c.MBEDTLS_ERR_SSL_WANT_READ or result == c.MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (result != 0) return rejection(&ssl, error.ServerTlsInvalid);
        break;
    }
    if (c.mbedtls_ssl_get_verify_result(&ssl) != 0) return error.ServerTlsInvalid;
    const peer = c.mbedtls_ssl_get_peer_cert(&ssl);
    if (peer == null) return error.ServerTlsInvalid;
    var server = certs.Certificate.fromDer(peer.*.raw.p[0..peer.*.raw.len]) catch return error.ServerTlsInvalid;
    defer server.deinit();
    server.verify(&ca, .server, hostname, now, false) catch return error.ServerTlsInvalid;
    dragontools_network_deadline(95);
    const request = try std.fmt.allocPrint(a, "GET /health HTTP/1.1\r\nHost: {s}:9443\r\nConnection: close\r\n\r\n", .{hostname});
    var sent: usize = 0;
    while (sent < request.len) {
        const n = c.mbedtls_ssl_write(&ssl, request[sent..].ptr, request.len - sent);
        if (n == c.MBEDTLS_ERR_SSL_WANT_READ or n == c.MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (n <= 0) return rejection(&ssl, error.IngestionRejected);
        sent += @intCast(n);
    }
    var response: [8192]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        const n = c.mbedtls_ssl_read(&ssl, response[used..].ptr, response.len - used);
        if (n == c.MBEDTLS_ERR_SSL_WANT_READ or n == c.MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (n <= 0) return rejection(&ssl, error.IngestionRejected);
        used += @intCast(n);
        if (std.mem.indexOf(u8, response[0..used], "\r\n\r\n")) |end| return inspectHealth(response[0 .. end + 4], response[end + 4 .. used]);
    }
    return error.IngestionRejected;
}
pub fn inspectHealth(header: []const u8, body: []const u8) !void {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    const status = lines.next() orelse return error.IngestionRejected;
    if (status.len < 12 or (status.len > 12 and status[12] != ' ') or !(std.mem.startsWith(u8, status, "HTTP/1.1 ") or std.mem.startsWith(u8, status, "HTTP/1.0 "))) return error.IngestionRejected;
    const code = status[9..12];
    if (std.mem.eql(u8, code, "401") or std.mem.eql(u8, code, "403")) return error.ClientCertificateRejected;
    if (!std.mem.eql(u8, code, "204") or body.len != 0) return error.IngestionRejected;
    var has_length = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.IngestionRejected;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) return error.IngestionRejected;
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (has_length or !std.mem.eql(u8, value, "0")) return error.IngestionRejected;
            has_length = true;
        }
    }
}
