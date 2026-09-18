//! Shared, fixed PKI policy and enrollment protocol validation.
const std = @import("std");
pub const j = @import("json.zig");
pub const f = @import("files.zig");
pub const pki = @import("../pki/pki.zig");
pub const renew: i64 = 30 * 86400;
pub const ca_maintenance: i64 = 366 * 86400;
pub const pending_seconds: i64 = 86400;
pub const fields = [_][]const u8{ "version", "host", "station", "services", "metrics_targets" };
pub const pending_fields = [_][]const u8{ "pending_certificate_pem", "pending_certificate_sha256", "pending_registration", "pending_expires_at" };
pub const Context = struct {
    store: f.Store,
    now: i64,
    ingestion: f.Owner,
    vector: f.Owner,
    vmagent: f.Owner,
    diagnostic_stage: ?*@import("diagnostics.zig").Stage = null,
    service_context: ?*anyopaque = null,
    service_fn: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!bool = null,
    pub fn track(self: Context, stage: @import("diagnostics.zig").Stage) void {
        if (self.diagnostic_stage) |current| current.* = stage;
    }
    pub fn account(self: Context, kind: []const u8) !f.Owner {
        const owner = if (std.mem.eql(u8, kind, "vector")) self.vector else if (std.mem.eql(u8, kind, "vmagent")) self.vmagent else return error.CredentialStateRefused;
        try j.require(owner.uid != std.math.maxInt(std.posix.uid_t) and owner.gid != std.math.maxInt(std.posix.gid_t));
        return owner;
    }
    pub fn service(self: Context, verb: []const u8, kind: []const u8) !bool {
        _ = try self.account(kind);
        return (self.service_fn orelse return error.ServiceUnavailable)(self.service_context, verb, kind);
    }
    pub fn validity(self: Context, days: i64) pki.Validity {
        return .{ .not_before = self.now, .not_after = self.now + days * 86400 };
    }
    pub fn certificate(self: Context, pem: []const u8) !pki.Certificate {
        return pki.Certificate.parse(self.store.a, pem);
    }
    pub fn ca(self: Context, pem: []const u8) !pki.Certificate {
        var cert = try self.certificate(pem);
        errdefer cert.deinit();
        try cert.validateCa(self.now);
        return cert;
    }
    pub fn client(self: Context, cert_pem: []const u8, ca_pem: []const u8, host: []const u8, legacy: bool, expired: bool) !void {
        var root = try self.ca(ca_pem);
        defer root.deinit();
        var cert = try self.certificate(cert_pem);
        defer cert.deinit();
        try cert.verify(&root, if (legacy) .legacy_client else .client, host, self.now, expired);
    }
    pub fn pair(self: Context, values: f.Files, name: []const u8) !void {
        var cert = try self.certificate(try f.item(values, try std.fmt.allocPrint(self.store.a, "{s}.crt", .{name})));
        defer cert.deinit();
        var key = try pki.Key.parse(self.store.a, try f.item(values, try std.fmt.allocPrint(self.store.a, "{s}.key", .{name})));
        defer key.deinit();
        try cert.matchesKey(&key);
    }
    pub fn clientPair(self: Context, values: f.Files, host: []const u8, legacy: bool, expired: bool) !void {
        try self.pair(values, "client");
        try self.client(try f.item(values, "client.crt"), try f.item(values, "ca.crt"), host, legacy, expired);
    }
    pub fn fingerprint(self: Context, pem: []const u8) ![]const u8 {
        var cert = try self.certificate(pem);
        defer cert.deinit();
        return self.store.a.dupe(u8, &(try cert.fingerprint()));
    }
    pub fn soon(self: Context, pem: []const u8, seconds: i64) !bool {
        var cert = try self.certificate(pem);
        defer cert.deinit();
        return try cert.expiry() <= self.now + seconds;
    }
    pub fn digest(self: Context, bytes: []const u8) ![]const u8 {
        return self.store.a.dupe(u8, &std.fmt.bytesToHex(try pki.crypto.sha256(bytes), .lower));
    }
};
pub fn endpoint(value: []const u8) !void {
    if (std.Io.net.IpAddress.parse(value, 0)) |_| {} else |_| try pki.profile.dns(value);
}
pub fn fingerprint(value: j.Value, nullable: bool) !void {
    if (nullable and value == .null) return;
    const bytes = try j.text(value);
    try j.require(bytes.len == 64);
    for (bytes) |byte| try j.require(std.ascii.isDigit(byte) or byte >= 'a' and byte <= 'f');
}
fn named(value: []const u8) !void {
    try j.require(value.len > 0 and value.len <= 63 and std.ascii.isAlphanumeric(value[0]));
    for (value) |byte| try j.require(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-');
}
fn unit(value: []const u8) !void {
    try j.require(value.len > 8 and value.len <= 253 and std.ascii.isAlphanumeric(value[0]) and std.mem.endsWith(u8, value, ".service"));
    for (value) |byte| try j.require(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "_.@:-", byte) != null);
}
fn ordered(previous: ?[]const u8, next: []const u8) !void {
    if (previous) |before| try j.require(std.mem.lessThan(u8, before, next));
}
pub fn registration(a: std.mem.Allocator, value: j.Value, host: ?[]const u8, station: ?[]const u8) !void {
    const applications = j.optional(value, "applications");
    try j.keys(value, if (applications != null) &(fields ++ [_][]const u8{"applications"}) else &fields);
    try j.require(try j.number(try j.get(value, "version")) == 1);
    const identity = try j.field(value, "host");
    const destination = try j.field(value, "station");
    try pki.profile.host(identity);
    try endpoint(destination);
    if (host) |expected| try j.require(std.mem.eql(u8, expected, identity));
    if (station) |expected| try j.require(std.mem.eql(u8, expected, destination));
    const services = try j.array(try j.get(value, "services"), 64);
    var before: ?[]const u8 = null;
    for (services) |service| {
        const name = try j.text(service);
        try unit(name);
        try ordered(before, name);
        before = name;
    }
    const targets = try j.array(try j.get(value, "metrics_targets"), 64);
    before = null;
    for (targets) |target| {
        try j.keys(target, &.{ "name", "url" });
        const name = try j.field(target, "name");
        const url = try j.field(target, "url");
        try named(name);
        try ordered(before, name);
        before = name;
        try j.require(url.len <= 2048 and std.mem.indexOfScalar(u8, url, '\n') == null);
    }
    const apps = if (applications) |items| try j.array(items, 32) else &.{};
    try j.require(services.len > 0 or apps.len > 0);
    try j.require(apps.len == 0 or targets.len == 0);
    var all_units: std.StringHashMapUnmanaged(void) = .empty;
    var selected: std.StringHashMapUnmanaged(void) = .empty;
    before = null;
    for (apps) |app| {
        try j.keys(app, &.{ "name", "environment", "services" });
        const name = try j.field(app, "name");
        try named(name);
        try named(try j.field(app, "environment"));
        try ordered(before, name);
        before = name;
        var previous_service: ?[]const u8 = null;
        for (try j.array(try j.get(app, "services"), 64)) |service| {
            try j.keys(service, &.{ "name", "systemd", "logs", "metrics_url" });
            const svc = try j.field(service, "name");
            const systemd = try j.field(service, "systemd");
            try named(svc);
            try ordered(previous_service, svc);
            previous_service = svc;
            try unit(systemd);
            try j.require(!all_units.contains(systemd) and all_units.count() < 64);
            try all_units.put(a, systemd, {});
            if (try j.flag(try j.get(service, "logs"))) try selected.put(a, systemd, {});
            const url = try j.get(service, "metrics_url");
            if (url != .null) try j.require((try j.text(url)).len <= 2048);
        }
    }
    if (apps.len != 0) {
        try j.require(services.len == selected.count());
        for (services) |service| try j.require(selected.contains(try j.text(service)));
    }
}
pub fn ordinary(a: std.mem.Allocator, value: j.Value) !j.Value {
    var result = try j.object(a, &.{});
    for (fields ++ [_][]const u8{"applications"}) |name| if (j.optional(value, name)) |v| try result.object.put(a, name, v);
    return result;
}
pub fn sameMode(left: j.Value, right: j.Value) !void {
    const l = if (j.optional(left, "applications")) |apps| (try j.array(apps, 32)).len else 0;
    const r = if (j.optional(right, "applications")) |apps| (try j.array(apps, 32)).len else 0;
    try j.require((l != 0) == (r != 0));
}
pub fn history(value: j.Value) !void {
    try j.hasOnly(value, &.{ "vector", "vmagent" });
    for (value.object.values()) |v| try fingerprint(v, false);
}
