const std = @import("std");
const m = @import("mbedtls.zig");
const c = m.c;
const der = @import("der.zig");
const policy = @import("profile.zig");
const key = @import("key.zig");
const csr = @import("csr.zig");
pub const San = struct {
    tag: u8,
    value: []const u8,
    pub fn endpoint(a: std.mem.Allocator, name: []const u8) !San {
        if (std.Io.net.IpAddress.parse(name, 0)) |ip| {
            return .{ .tag = 0x87, .value = switch (ip) {
                .ip4 => |v| try a.dupe(u8, &v.bytes),
                .ip6 => |v| try a.dupe(u8, &v.bytes),
            } };
        } else |_| {
            try policy.dns(name);
            return .{ .tag = 0x82, .value = try a.dupe(u8, name) };
        }
    }
};
pub const Validity = struct { not_before: i64, not_after: i64 };
const Extension = struct { oid: []const u8, value: []const u8, critical: bool };
pub const Info = struct {
    tbs: []const u8,
    signature: []const u8,
    issuer: []const u8,
    subject: []const u8,
    extensions: [8]Extension = undefined,
    extension_count: usize = 0,
    pub fn extension(self: *const Info, oid: []const u8) ?Extension {
        for (self.extensions[0..self.extension_count]) |ext| if (std.mem.eql(u8, ext.oid, oid)) return ext;
        return null;
    }
    fn requireExtension(self: *const Info, oid: []const u8, value: []const u8, critical: bool) !void {
        const ext = self.extension(oid) orelse return error.MissingCertificateExtension;
        try der.equal(ext.value, value);
        if (ext.critical != critical) return error.InvalidCertificateExtension;
    }
};
pub const Certificate = struct {
    context: c.mbedtls_x509_crt,
    info: Info,
    pub fn parse(a: std.mem.Allocator, pem: []const u8) !Certificate {
        const bytes = try der.decodePem(a, pem, "CERTIFICATE", 16384);
        defer a.free(bytes);
        return fromDer(bytes);
    }
    pub fn fromDer(bytes: []const u8) !Certificate {
        if (bytes.len > 16384) return error.InvalidCertificate;
        try m.init();
        var result: Certificate = undefined;
        c.mbedtls_x509_crt_init(&result.context);
        errdefer result.deinit();
        try m.check(c.mbedtls_x509_crt_parse_der(&result.context, bytes.ptr, bytes.len));
        if (result.context.next != null) return error.InvalidCertificateChain;
        // All borrowed slices refer to Mbed TLS's owned DER copy.
        result.info = try inspect(result.raw());
        return result;
    }
    pub fn deinit(self: *Certificate) void {
        c.mbedtls_x509_crt_free(&self.context);
    }
    pub fn raw(self: *const Certificate) []const u8 {
        return self.context.raw.p[0..self.context.raw.len];
    }
    pub fn fingerprint(self: *const Certificate) ![64]u8 {
        return std.fmt.bytesToHex(try m.sha256(self.raw()), .lower);
    }
    pub fn expiry(self: *const Certificate) !i64 {
        return timestamp(self.context.valid_to);
    }
    pub fn validFrom(self: *const Certificate) !i64 {
        return timestamp(self.context.valid_from);
    }
    pub fn validity(self: *const Certificate, now: i64, allow_expired: bool) !void {
        if (try timestamp(self.context.valid_from) > now) return error.CertificateNotYetValid;
        if (!allow_expired and try self.expiry() <= now) return error.CertificateExpired;
    }
    pub fn matchesKey(self: *const Certificate, local_key: *const key.Key) !void {
        try m.check(c.mbedtls_pk_check_pair(&self.context.pk, &local_key.context));
    }
    pub fn matchesCsr(self: *const Certificate, request: *const csr.Csr) !bool {
        return key.samePublic(&self.context.pk, &request.context.pk);
    }
    pub fn sans(self: *const Certificate, out: *[16]San) ![]const San {
        const ext = self.info.extension(policy.san_oid) orelse return out[0..0];
        var r = der.Reader{ .rest = (try der.one(ext.value, 0x30)).value };
        var count: usize = 0;
        while (r.rest.len != 0) {
            if (count == out.len) return error.TooManyCertificateNames;
            const item = try r.next();
            if (item.tag != 0x82 and item.tag != 0x86 and item.tag != 0x87) return error.InvalidCertificateName;
            if (item.value.len == 0 or item.value.len > 253 or std.mem.indexOfScalar(u8, item.value, 0) != null and item.tag != 0x87) return error.InvalidCertificateName;
            if (item.tag == 0x82) try policy.dns(item.value);
            if (item.tag == 0x87 and item.value.len != 4 and item.value.len != 16) return error.InvalidCertificateName;
            for (out[0..count]) |previous| if (previous.tag == item.tag and std.mem.eql(u8, previous.value, item.value)) return error.DuplicateCertificateName;
            out[count] = .{ .tag = item.tag, .value = item.value };
            count += 1;
        }
        if (count == 0) return error.InvalidCertificateName;
        return out[0..count];
    }
    pub fn validateCa(self: *Certificate, now: i64) !void {
        try self.validity(now, false);
        try self.info.requireExtension(policy.basic_oid, "\x30\x06\x01\x01\xff\x02\x01\x00", true);
        try self.info.requireExtension(policy.usage_oid, "\x03\x02\x01\x06", true);
        if (self.info.extension(policy.eku_oid) != null or self.info.extension(policy.san_oid) != null) return error.InvalidCaProfile;
        try der.equal(self.info.issuer, self.info.subject);
        try self.signature(&self.context.pk);
    }
    fn signature(self: *Certificate, public_key: *c.mbedtls_pk_context) !void {
        const digest = try m.sha256(self.info.tbs);
        try m.check(c.mbedtls_pk_verify(public_key, c.MBEDTLS_MD_SHA256, &digest, digest.len, self.info.signature.ptr, self.info.signature.len));
    }
    pub fn verify(self: *Certificate, ca: *Certificate, kind: policy.Profile, expected: []const u8, now: i64, allow_expired: bool) !void {
        if (kind == .ca) return error.InvalidPkiProfile;
        try ca.validateCa(now);
        try self.validity(now, allow_expired);
        try self.info.requireExtension(policy.basic_oid, "\x30\x00", true);
        try self.info.requireExtension(policy.usage_oid, "\x03\x02\x07\x80", true);
        const eku = self.info.extension(policy.eku_oid) orelse return error.MissingCertificateExtension;
        if (eku.critical) return error.InvalidCertificateExtension;
        try der.equal((try der.one((try der.one(eku.value, 0x30)).value, 0x06)).value, if (kind == .server) policy.server_auth else policy.client_auth);
        try der.equal(self.info.issuer, ca.info.subject);
        try self.signature(&ca.context.pk);
        var names: [16]San = undefined;
        const values = try self.sans(&names);
        if (kind == .server) {
            if (values.len == 0) return error.MissingCertificateExtension;
            const ip = std.Io.net.IpAddress.parse(expected, 0) catch null;
            var matched = false;
            for (values) |value| {
                if (value.tag != 0x82 and value.tag != 0x87) return error.InvalidCertificateName;
                if (ip) |address| {
                    const bytes: []const u8 = switch (address) {
                        .ip4 => |*v| &v.bytes,
                        .ip6 => |*v| &v.bytes,
                    };
                    if (value.tag == 0x87 and std.mem.eql(u8, value.value, bytes)) matched = true;
                } else if (value.tag == 0x82 and std.ascii.eqlIgnoreCase(value.value, expected)) matched = true;
            }
            if (!matched) return error.CertificateHostnameMismatch;
        } else {
            try policy.host(expected);
            try policy.commonName(self.info.subject, expected);
            if (kind != .legacy_client or values.len != 0) {
                if (values.len != 1 or values[0].tag != 0x86) return error.InvalidCertificateName;
                var uri: [55]u8 = undefined;
                const wanted = try std.fmt.bufPrint(&uri, "dragontools://hosts/{s}", .{expected});
                try der.equal(values[0].value, wanted);
            }
        }
        // Fixed two-level chain: cryptography, issuer and every extension were
        // checked above; Mbed TLS also applies its constrained chain profile.
        const chain_profile = c.mbedtls_x509_crt_profile{
            .allowed_mds = c.MBEDTLS_X509_ID_FLAG(c.MBEDTLS_MD_SHA256),
            .allowed_pks = c.MBEDTLS_X509_ID_FLAG(c.MBEDTLS_PK_SIGALG_ECDSA) | c.MBEDTLS_X509_ID_FLAG(c.MBEDTLS_PK_ECKEY),
            .allowed_curves = c.MBEDTLS_X509_ID_FLAG(c.MBEDTLS_ECP_DP_SECP256R1),
            .rsa_min_bitlen = 0,
        };
        var flags: u32 = 0;
        try m.check(c.mbedtls_x509_crt_verify_with_profile(&self.context, &ca.context, null, &chain_profile, null, &flags, checkedTime, null));
        if (flags != 0) return error.InvalidCertificateChain;
    }
};
fn checkedTime(_: ?*anyopaque, _: [*c]c.mbedtls_x509_crt, _: c_int, flags: [*c]u32) callconv(.c) c_int {
    // Time was checked above using the supplied clock, including the CA. Only
    // explicit legacy/renewal callers may allow an expired leaf. Never suppress
    // signature, purpose, constraints or other chain failures.
    flags.* &= ~@as(u32, c.MBEDTLS_X509_BADCERT_EXPIRED | c.MBEDTLS_X509_BADCERT_FUTURE);
    return 0;
}
fn inspect(bytes: []const u8) !Info {
    var outer = der.Reader{ .rest = (try der.one(bytes, 0x30)).value };
    const tbs = try outer.take(0x30);
    try policy.signatureAlgorithm((try outer.take(0x30)).encoded);
    const sig = (try outer.take(0x03)).value;
    if (sig.len < 2 or sig[0] != 0) return error.InvalidCertificateSignature;
    try outer.end();
    var r = der.Reader{ .rest = tbs.value };
    try der.equal((try r.take(0xa0)).value, "\x02\x01\x02");
    const serial = (try r.take(0x02)).value;
    if (serial.len == 0 or serial.len > 20 or serial[0] & 0x80 != 0) return error.InvalidCertificateSerial;
    try policy.signatureAlgorithm((try r.take(0x30)).encoded);
    const issuer = (try r.take(0x30)).encoded;
    _ = try r.take(0x30); // Validity is independently parsed by Mbed TLS.
    const subject = (try r.take(0x30)).encoded;
    try policy.publicKey((try r.take(0x30)).encoded);
    const extension_field = try r.take(0xa3);
    try r.end();
    var result: Info = .{ .tbs = tbs.encoded, .signature = sig[1..], .issuer = issuer, .subject = subject };
    var extensions = der.Reader{ .rest = (try der.one(extension_field.value, 0x30)).value };
    while (extensions.rest.len != 0) {
        if (result.extension_count == result.extensions.len) return error.TooManyCertificateExtensions;
        var ext = der.Reader{ .rest = (try extensions.take(0x30)).value };
        const oid = (try ext.take(0x06)).value;
        if (result.extension(oid) != null) return error.DuplicateCertificateExtension;
        var value = try ext.next();
        var critical = false;
        if (value.tag == 0x01) {
            try der.equal(value.value, "\xff");
            critical = true;
            value = try ext.next();
        }
        if (value.tag != 0x04) return error.InvalidCertificateExtension;
        try ext.end();
        // OpenSSL adds SKI/AKI to existing profiles. Preserve those certificates.
        const known = [_][]const u8{ policy.basic_oid, policy.usage_oid, policy.eku_oid, policy.san_oid, "\x55\x1d\x0e", "\x55\x1d\x23" };
        var allowed = false;
        for (known) |item| if (std.mem.eql(u8, oid, item)) {
            allowed = true;
        };
        if (!allowed) return error.UnsupportedCertificateExtension;
        result.extensions[result.extension_count] = .{ .oid = oid, .critical = critical, .value = value.value };
        result.extension_count += 1;
    }
    return result;
}
pub fn timestamp(value: c.mbedtls_x509_time) !i64 {
    if (value.year < 1970 or value.year > 9999 or value.mon < 1 or value.mon > 12 or value.day < 1 or value.day > 31 or value.hour < 0 or value.hour > 23 or value.min < 0 or value.min > 59 or value.sec < 0 or value.sec > 59) return error.InvalidCertificateDate;
    const epoch = std.time.epoch;
    var days: i64 = 0;
    var year: u16 = 1970;
    while (year < value.year) : (year += 1) days += epoch.getDaysInYear(year);
    var month: u4 = 1;
    while (month < value.mon) : (month += 1) days += epoch.getDaysInMonth(year, @enumFromInt(month));
    if (value.day > epoch.getDaysInMonth(year, @enumFromInt(month))) return error.InvalidCertificateDate;
    days += value.day - 1;
    return days * 86400 + @as(i64, value.hour) * 3600 + @as(i64, value.min) * 60 + value.sec;
}
pub fn formatTime(buffer: *[15:0]u8, stamp: i64) ![:0]const u8 {
    if (stamp < 0 or stamp > 253402300799) return error.InvalidCertificateDate;
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(stamp) };
    const yd = seconds.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = seconds.getDaySeconds();
    _ = try std.fmt.bufPrint(buffer[0..14], "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ yd.year, @intFromEnum(md.month), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    buffer[14] = 0;
    return buffer[0..14 :0];
}
pub fn keyIdentifier(public_key: *const c.mbedtls_pk_context) ![20]u8 {
    var buffer: [256]u8 = undefined;
    var fields = der.Reader{ .rest = (try der.one(try key.publicDer(public_key, &buffer), 0x30)).value };
    _ = try fields.take(0x30);
    const bits = (try fields.take(0x03)).value;
    if (bits.len != 66 or bits[0] != 0) return error.InvalidPublicKey;
    // RFC 7093 method 1: leftmost 160 bits of SHA-256 of subjectPublicKey.
    // No SHA-1 algorithm needs to be enabled just for certificate identifiers.
    const digest = try m.sha256(bits[1..]);
    return digest[0..20].*;
}
pub fn setIdentifiers(a: std.mem.Allocator, writer: *c.mbedtls_x509write_cert, subject_key: *const c.mbedtls_pk_context, issuer_id: []const u8) !void {
    const subject_id = try keyIdentifier(subject_key);
    const ski = try der.wrap(a, 0x04, &subject_id);
    defer a.free(ski);
    try m.check(c.mbedtls_x509write_crt_set_extension(writer, "\x55\x1d\x0e", 3, 0, ski.ptr, ski.len));
    const field = try der.wrap(a, 0x80, issuer_id);
    defer a.free(field);
    const aki = try der.wrap(a, 0x30, field);
    defer a.free(aki);
    try m.check(c.mbedtls_x509write_crt_set_extension(writer, "\x55\x1d\x23", 3, 0, aki.ptr, aki.len));
}
fn issuerIdentifier(fallback: *[20]u8, ca: *const Certificate) ![]const u8 {
    if (ca.info.extension("\x55\x1d\x0e")) |ext| {
        const value = (try der.one(ext.value, 0x04)).value;
        if (value.len == 0 or value.len > 64 or ext.critical) return error.InvalidCertificateExtension;
        return value;
    }
    fallback.* = try keyIdentifier(&ca.context.pk);
    return fallback;
}
fn write(a: std.mem.Allocator, kind: policy.Profile, subject_key: *c.mbedtls_pk_context, issuer_key: *key.Key, issuer_id: []const u8, issuer_name: [:0]const u8, subject_name: [:0]const u8, names: []const San, valid: Validity) ![]u8 {
    if (valid.not_after <= valid.not_before or names.len > 16) return error.InvalidPkiProfile;
    var writer: c.mbedtls_x509write_cert = undefined;
    c.mbedtls_x509write_crt_init(&writer);
    defer c.mbedtls_x509write_crt_free(&writer);
    c.mbedtls_x509write_crt_set_version(&writer, c.MBEDTLS_X509_CRT_VERSION_3);
    c.mbedtls_x509write_crt_set_md_alg(&writer, c.MBEDTLS_MD_SHA256);
    c.mbedtls_x509write_crt_set_subject_key(&writer, subject_key);
    c.mbedtls_x509write_crt_set_issuer_key(&writer, &issuer_key.context);
    try setIdentifiers(a, &writer, subject_key, issuer_id);
    try m.check(c.mbedtls_x509write_crt_set_subject_name(&writer, subject_name));
    try m.check(c.mbedtls_x509write_crt_set_issuer_name(&writer, issuer_name));
    var serial: [16]u8 = undefined;
    try m.random(&serial);
    serial[0] = (serial[0] & 0x7f) | 1;
    try m.check(c.mbedtls_x509write_crt_set_serial_raw(&writer, &serial, serial.len));
    var start: [15:0]u8 = undefined;
    var end: [15:0]u8 = undefined;
    try m.check(c.mbedtls_x509write_crt_set_validity(&writer, (try formatTime(&start, valid.not_before)).ptr, (try formatTime(&end, valid.not_after)).ptr));
    const basic: []const u8 = if (kind == .ca) "\x30\x06\x01\x01\xff\x02\x01\x00" else "\x30\x00";
    try m.check(c.mbedtls_x509write_crt_set_extension(&writer, policy.basic_oid.ptr, policy.basic_oid.len, 1, basic.ptr, basic.len));
    try m.check(c.mbedtls_x509write_crt_set_key_usage(&writer, if (kind == .ca) c.MBEDTLS_X509_KU_KEY_CERT_SIGN | c.MBEDTLS_X509_KU_CRL_SIGN else c.MBEDTLS_X509_KU_DIGITAL_SIGNATURE));
    if (kind != .ca) {
        const oid = try der.wrap(a, 0x06, if (kind == .server) policy.server_auth else policy.client_auth);
        defer a.free(oid);
        const eku = try der.wrap(a, 0x30, oid);
        defer a.free(eku);
        try m.check(c.mbedtls_x509write_crt_set_extension(&writer, policy.eku_oid.ptr, policy.eku_oid.len, 0, eku.ptr, eku.len));
        var entries: std.ArrayList(u8) = .empty;
        defer entries.deinit(a);
        for (names, 0..) |name, i| {
            if (name.tag == 0x82) try policy.dns(name.value) else if (name.tag == 0x87) {
                if (name.value.len != 4 and name.value.len != 16) return error.InvalidCertificateName;
            } else if (name.tag != 0x86) return error.InvalidCertificateName;
            for (names[0..i]) |previous| if (previous.tag == name.tag and std.mem.eql(u8, previous.value, name.value)) return error.DuplicateCertificateName;
            const entry = try der.wrap(a, name.tag, name.value);
            defer a.free(entry);
            try entries.appendSlice(a, entry);
        }
        if (entries.items.len > 0) {
            const san = try der.wrap(a, 0x30, entries.items);
            defer a.free(san);
            try m.check(c.mbedtls_x509write_crt_set_extension(&writer, policy.san_oid.ptr, policy.san_oid.len, 0, san.ptr, san.len));
        }
    }
    var buffer: [16384]u8 = undefined;
    try m.check(c.mbedtls_x509write_crt_pem(&writer, &buffer, buffer.len));
    return a.dupe(u8, std.mem.sliceTo(&buffer, 0));
}
pub fn createCa(a: std.mem.Allocator, local_key: *key.Key, valid: Validity) ![]u8 {
    return write(a, .ca, &local_key.context, local_key, &(try keyIdentifier(&local_key.context)), "CN=DragonTools agent CA", "CN=DragonTools agent CA", &.{}, valid);
}
fn issuerName(a: std.mem.Allocator, ca: *const Certificate) ![:0]u8 {
    var buffer: [1024]u8 = undefined;
    const count = c.mbedtls_x509_dn_gets(&buffer, buffer.len, &ca.context.subject);
    if (count <= 0 or count >= buffer.len) return error.InvalidCaProfile;
    return a.dupeZ(u8, buffer[0..@intCast(count)]);
}
pub fn createServer(a: std.mem.Allocator, ca: *Certificate, ca_key: *key.Key, server_key: *key.Key, origin: []const u8, names: []const San, valid: Validity) ![]u8 {
    if (names.len == 0) return error.InvalidCertificateName;
    for (names) |name| if (name.tag != 0x82 and name.tag != 0x87) return error.InvalidCertificateName;
    // The application schema permits DNS; legacy registration also permits IP.
    if (std.Io.net.IpAddress.parse(origin, 0)) |_| {} else |_| try policy.dns(origin);
    try ca.matchesKey(ca_key);
    const issuer = try issuerName(a, ca);
    defer a.free(issuer);
    const subject = try std.fmt.allocPrintSentinel(a, "CN={s}", .{origin}, 0);
    defer a.free(subject);
    var issuer_id: [20]u8 = undefined;
    return write(a, .server, &server_key.context, ca_key, try issuerIdentifier(&issuer_id, ca), issuer, subject, names, valid);
}
pub fn signClient(a: std.mem.Allocator, ca: *Certificate, ca_key: *key.Key, request: *csr.Csr, host: []const u8, valid: Validity) ![]u8 {
    try policy.host(host);
    try policy.commonName(request.context.subject_raw.p[0..request.context.subject_raw.len], host);
    try ca.matchesKey(ca_key);
    const issuer = try issuerName(a, ca);
    defer a.free(issuer);
    const subject = try std.fmt.allocPrintSentinel(a, "CN={s}", .{host}, 0);
    defer a.free(subject);
    const uri = try policy.identity(a, host);
    defer a.free(uri);
    var issuer_id: [20]u8 = undefined;
    return write(a, .client, &request.context.pk, ca_key, try issuerIdentifier(&issuer_id, ca), issuer, subject, &.{.{ .tag = 0x86, .value = uri }}, valid);
}
