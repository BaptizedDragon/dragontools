//! Station-local CA/server keys and public, resumable enrollment registry.
const std = @import("std");
const s = @import("state.zig");
const j = s.j;
const f = s.f;
const pki = s.pki;
const Context = s.Context;
const ca_path = f.base ++ "/pki/ca";
const server_path = f.base ++ "/server";
const modern = [_][]const u8{ "certificate_pem", "certificate_identity" };

fn directories(ctx: Context, create: bool) !bool {
    const store = ctx.store;
    ctx.track(.ingestion_root);
    _ = try store.directory(f.etc, store.root_owner, 0o755, false);
    var changed = try store.directory(f.base, store.root_owner, 0o755, create);
    ctx.track(.pki_directory);
    changed = try store.directory(f.base ++ "/pki", store.root_owner, f.private_directory_mode, create) or changed;
    ctx.track(.clients_directory);
    changed = try store.directory(f.base ++ "/clients", store.root_owner, f.private_directory_mode, create) or changed;
    ctx.track(.registry_directory);
    changed = try store.registry(ctx.ingestion.gid, create) or changed;
    ctx.track(.state_directory);
    changed = try store.directory(f.state, store.root_owner, 0o755, create) or changed;
    changed = try store.directory(f.state ++ "/ingestion", ctx.ingestion, 0o750, create) or changed;
    return changed;
}
fn temporaryName(name: []const u8, prefix: []const u8) bool {
    if (name.len != prefix.len + 32 or !std.mem.startsWith(u8, name, prefix)) return false;
    for (name[prefix.len..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn candidates(ctx: Context, parent: []const u8, active: []const []const u8, owner: f.Owner, mode: u16, files: []const []const u8) !bool {
    var changed = false;
    for (try ctx.store.names(parent)) |name| {
        if (j.contains(active, name)) continue;
        const path = try ctx.store.path(parent, name);
        if (temporaryName(name, ".bundle-")) {
            try ctx.store.discardBundle(path, owner, mode, files);
        } else if (temporaryName(name, ".credential-")) {
            // An interrupted single-file atomic publication is never active.
            _ = try ctx.store.stagedFile(path, owner);
            try ctx.store.unlink(path);
        } else return error.UnexpectedManagedFile;
        changed = true;
    }
    return changed;
}
fn cleanParent(ctx: Context, parent: []const u8, active: []const []const u8) !void {
    for (try ctx.store.names(parent)) |name| if (!j.contains(active, name)) return error.UnexpectedManagedFile;
}

pub fn loadCa(ctx: Context) !f.Files {
    const caller_stage = if (ctx.diagnostic_stage) |current| current.* else .enrollment;
    ctx.track(.ca_state);
    const values = try ctx.store.managed(ca_path, ctx.store.root_owner, 0o700, &.{ "ca.crt", "ca.key" }, f.marker, true);
    ctx.track(.ca_certificate_validation);
    var ca = try ctx.ca(try f.item(values, "ca.crt"));
    defer ca.deinit();
    try ctx.pair(values, "ca");
    ctx.track(caller_stage);
    return values;
}
fn issuance(ctx: Context, ca: f.Files) !void {
    if (try ctx.soon(try f.item(ca, "ca.crt"), s.ca_maintenance)) return error.CaMaintenanceRequired;
}
pub fn verifyServer(ctx: Context, endpoint: []const u8, allow_renewal: bool) ![]const u8 {
    const caller_stage = if (ctx.diagnostic_stage) |current| current.* else .enrollment;
    ctx.track(.server_certificate_validation);
    try s.endpoint(endpoint);
    const store = ctx.store;
    _ = try directories(ctx, false);
    ctx.track(.ingestion_root);
    try cleanParent(ctx, f.base, &.{ "pki", "clients", "registry", "server" });
    ctx.track(.pki_directory);
    try cleanParent(ctx, f.base ++ "/pki", &.{"ca"});
    const root = try loadCa(ctx);
    ctx.track(.server_state);
    const values = try store.managed(server_path, ctx.ingestion, f.server_mode, &.{ "ca.crt", "server.crt", "server.key", "endpoint" }, f.marker, true);
    const ca_pem = try f.item(root, "ca.crt");
    try j.require(f.matches(values, "ca.crt", ca_pem));
    const origin = try f.item(values, "endpoint");
    try s.endpoint(origin);
    ctx.track(.server_certificate_validation);
    var ca = try ctx.ca(ca_pem);
    defer ca.deinit();
    var cert = try ctx.certificate(try f.item(values, "server.crt"));
    defer cert.deinit();
    try ctx.pair(values, "server");
    try cert.verify(&ca, .server, origin, ctx.now, allow_renewal);
    try cert.verify(&ca, .server, endpoint, ctx.now, allow_renewal);
    ctx.track(caller_stage);
    return ca_pem;
}
pub fn registry(ctx: Context, host: []const u8, missing: bool) !?j.Value {
    try pki.profile.host(host);
    _ = try ctx.store.registry(ctx.ingestion.gid, false);
    const path = try std.fmt.allocPrint(ctx.store.a, f.base ++ "/registry/{s}.json", .{host});
    if (missing and !try ctx.store.exists(path)) return null;
    const value = try j.parse(ctx.store.a, try ctx.store.read(path, .{ .uid = ctx.store.root_owner.uid, .gid = ctx.ingestion.gid }, 0o640, f.limit), f.limit);
    const ordinary = try s.ordinary(ctx.store.a, value);
    try s.registration(ctx.store.a, ordinary, host, null);
    const has_modern = j.optional(value, "certificate_pem") != null;
    const has_pending = j.optional(value, "pending_certificate_pem") != null;
    try j.require(value.object.count() == ordinary.object.count() + 1 + @as(usize, if (has_modern) 2 else 0) + @as(usize, if (has_pending) 4 else 0));
    try j.hasOnly(value, &(s.fields ++ [_][]const u8{ "applications", "certificate_sha256" } ++ modern ++ s.pending_fields));
    try s.fingerprint(try j.get(value, "certificate_sha256"), true);
    if (has_modern) {
        try j.require(std.mem.eql(u8, try j.field(value, "certificate_identity"), try pki.profile.identity(ctx.store.a, host)));
        try j.require(std.mem.eql(u8, try ctx.fingerprint(try j.field(value, "certificate_pem")), try j.field(value, "certificate_sha256")));
    }
    if (has_pending) {
        try s.fingerprint(try j.get(value, "pending_certificate_sha256"), false);
        try j.require(std.mem.eql(u8, try ctx.fingerprint(try j.field(value, "pending_certificate_pem")), try j.field(value, "pending_certificate_sha256")));
        try s.registration(ctx.store.a, try j.get(value, "pending_registration"), host, null);
        _ = try j.number(try j.get(value, "pending_expires_at"));
    }
    return value;
}
pub fn saveRegistry(ctx: Context, host: []const u8, value: j.Value) !bool {
    try pki.profile.host(host);
    _ = try ctx.store.registry(ctx.ingestion.gid, false);
    return ctx.store.atomic(try std.fmt.allocPrint(ctx.store.a, f.base ++ "/registry/{s}.json", .{host}), try j.encoded(ctx.store.a, value), .{ .uid = ctx.store.root_owner.uid, .gid = ctx.ingestion.gid }, 0o640, f.base ++ "/registry");
}
fn legacy(ctx: Context, host: []const u8) !bool {
    try pki.profile.host(host);
    const path = try ctx.store.path(f.base ++ "/clients", host);
    if (!try ctx.store.exists(path)) return false;
    const values = try ctx.store.managed(path, ctx.store.root_owner, 0o700, &.{ "client.crt", "client.key" }, f.marker, false);
    _ = try f.item(values, "client.crt");
    return values.contains("client.key");
}
pub fn inspect(ctx: Context, host: []const u8, endpoint: []const u8) !j.Value {
    const ca = try verifyServer(ctx, endpoint, false);
    const value = try registry(ctx, host, true);
    const old_key = try legacy(ctx, host);
    var active = false;
    var expired = false;
    if (value) |current| {
        if (j.optional(current, "certificate_pem") == null and try j.get(current, "certificate_sha256") != .null) {
            active = true;
            try j.require(old_key);
            const values = try ctx.store.managed(try ctx.store.path(f.base ++ "/clients", host), ctx.store.root_owner, 0o700, &.{ "client.crt", "client.key" }, f.marker, true);
            try ctx.pair(values, "client");
            const cert = try f.item(values, "client.crt");
            try ctx.client(cert, ca, host, true, true);
            expired = try ctx.soon(cert, 0);
            try j.require(std.mem.eql(u8, try ctx.fingerprint(cert), try j.field(current, "certificate_sha256")));
        }
    } else try j.require(!old_key);
    return j.object(ctx.store.a, &.{ .{ "host", j.string(host) }, .{ "station", j.string(endpoint) }, .{ "ca.crt", j.string(ca) }, .{ "legacy", j.boolean(old_key) }, .{ "legacy_active", j.boolean(active) }, .{ "legacy_expired", j.boolean(expired) }, .{ "certificate_sha256", if (value) |v| try j.get(v, "certificate_sha256") else .null }, .{ "pending_certificate_sha256", if (value) |v| j.optional(v, "pending_certificate_sha256") orelse .null else .null } });
}
fn newServer(ctx: Context, ca_values: f.Files, existing_key: ?[]const u8, origin: []const u8, names: []const pki.San) !f.Files {
    var ca = try ctx.ca(try f.item(ca_values, "ca.crt"));
    defer ca.deinit();
    var ca_key = try pki.Key.parse(ctx.store.a, try f.item(ca_values, "ca.key"));
    defer ca_key.deinit();
    ctx.track(if (existing_key != null) .server_state else .server_key_generation);
    try ctx.store.checkpoint("generate_server_key", server_path);
    var key = if (existing_key) |pem| try pki.Key.parse(ctx.store.a, pem) else try pki.Key.generate();
    defer key.deinit();
    ctx.track(.server_certificate_generation);
    try ctx.store.checkpoint("generate_server_certificate", server_path);
    const cert_pem = try pki.createServerCertificate(ctx.store.a, &ca, &ca_key, &key, origin, names, ctx.validity(365));
    ctx.track(.server_certificate_validation);
    try ctx.store.checkpoint("validate_server", server_path);
    var cert = try ctx.certificate(cert_pem);
    defer cert.deinit();
    try cert.matchesKey(&key);
    try cert.verify(&ca, .server, origin, ctx.now, false);
    var values: f.Files = .empty;
    try values.put(ctx.store.a, "server.crt", cert_pem);
    ctx.track(.server_key_serialization);
    try values.put(ctx.store.a, "server.key", existing_key orelse try key.privatePem(ctx.store.a));
    try values.put(ctx.store.a, "ca.crt", try f.item(ca_values, "ca.crt"));
    try values.put(ctx.store.a, "endpoint", origin);
    return values;
}
/// Enrollment preparation is read-only: only station install owns CA/server PKI.
pub fn ensure(ctx: Context, value: j.Value) !bool {
    ctx.track(.station_registration_prepare);
    try s.registration(ctx.store.a, value, null, null);
    _ = try verifyServer(ctx, try j.field(value, "station"), false);
    if (try registry(ctx, try j.field(value, "host"), true)) |previous| try s.sameMode(previous, value);
    return false;
}
/// An omitted hostname may reuse only a proven managed server bundle, never SSH.
pub fn stationEndpoint(ctx: Context, requested: ?[]const u8) ![]const u8 {
    if (requested) |name| {
        try s.endpoint(name);
        return name;
    }
    if (!try ctx.store.exists(server_path)) return error.IngressHostnameRequired;
    const values = try ctx.store.managed(server_path, ctx.ingestion, f.server_mode, &.{ "ca.crt", "server.crt", "server.key", "endpoint" }, f.marker, true);
    const name = try f.item(values, "endpoint");
    try s.endpoint(name);
    return name;
}
pub fn ensureStation(ctx: Context, hostname: ?[]const u8) !bool {
    const store = ctx.store;
    ctx.track(.server_state);
    const endpoint = try stationEndpoint(ctx, hostname);
    var changed = try directories(ctx, true);
    ctx.track(.ingestion_root);
    changed = try candidates(ctx, f.base, &.{ "pki", "clients", "registry", "server" }, ctx.ingestion, f.server_mode, &.{ "ca.crt", "server.crt", "server.key", "endpoint" }) or changed;
    ctx.track(.pki_directory);
    changed = try candidates(ctx, f.base ++ "/pki", &.{"ca"}, store.root_owner, 0o700, &.{ "ca.crt", "ca.key" }) or changed;
    ctx.track(.ca_state);
    if (!try store.exists(ca_path)) {
        if (try store.exists(server_path) or (try store.names(f.base ++ "/clients")).len != 0 or (try store.names(f.base ++ "/registry")).len != 0) return error.CaMaintenanceRequired;
        ctx.track(.ca_missing_bootstrap_allowed);
        try store.checkpoint("ca_missing_bootstrap_allowed", ca_path);
        ctx.track(.ca_key_generation);
        try store.checkpoint("generate_ca_key", ca_path);
        var key = try pki.Key.generate();
        defer key.deinit();
        ctx.track(.ca_certificate_generation);
        try store.checkpoint("generate_ca_certificate", ca_path);
        const pem = try pki.createCaCertificate(store.a, &key, ctx.validity(3650));
        ctx.track(.ca_certificate_validation);
        try store.checkpoint("validate_ca", ca_path);
        // Validate before any CA directory can be published.
        var cert = try ctx.ca(pem);
        defer cert.deinit();
        try cert.matchesKey(&key);
        var values: f.Files = .empty;
        try values.put(store.a, "ca.crt", pem);
        ctx.track(.ca_key_serialization);
        try values.put(store.a, "ca.key", try key.privatePem(store.a));
        ctx.track(.ca_publication);
        try store.createBundle(ca_path, store.root_owner, 0o700, values, f.marker);
        changed = true;
    }
    ctx.track(.ca_state);
    const root = try loadCa(ctx);
    try issuance(ctx, root);
    ctx.track(.server_state);
    if (!try store.exists(server_path)) {
        const values = try newServer(ctx, root, null, endpoint, &.{try pki.San.endpoint(store.a, endpoint)});
        ctx.track(.server_publication);
        try store.mark("caddy");
        try store.createBundle(server_path, ctx.ingestion, f.server_mode, values, f.marker);
        changed = true;
    }
    ctx.track(.server_state);
    const current = try store.managed(server_path, ctx.ingestion, f.server_mode, &.{ "ca.crt", "server.crt", "server.key", "endpoint" }, f.marker, true);
    const origin = try f.item(current, "endpoint");
    _ = try verifyServer(ctx, origin, true);
    ctx.track(.server_certificate_validation);
    var cert = try ctx.certificate(try f.item(current, "server.crt"));
    defer cert.deinit();
    var names: [16]pki.San = undefined;
    const prior = try cert.sans(&names);
    const requested = try pki.San.endpoint(store.a, endpoint);
    var found = false;
    for (prior) |name| if (name.tag == requested.tag and std.mem.eql(u8, name.value, requested.value)) {
        found = true;
    };
    if (!found or try ctx.soon(try f.item(current, "server.crt"), s.renew)) {
        var count = prior.len;
        if (!found) {
            try j.require(count < names.len);
            names[count] = requested;
            count += 1;
        }
        const renewed = try newServer(ctx, root, try f.item(current, "server.key"), origin, names[0..count]);
        ctx.track(.server_publication);
        try store.mark("caddy");
        changed = try store.atomic(server_path ++ "/server.crt", try f.item(renewed, "server.crt"), ctx.ingestion, 0o400, f.base) or changed;
    }
    _ = try verifyServer(ctx, endpoint, false);
    return changed;
}
fn candidate(ctx: Context, current: j.Value, registration_value: j.Value, pem: []const u8) !j.Value {
    var desired = try j.copy(ctx.store.a, current);
    try desired.object.put(ctx.store.a, "pending_certificate_pem", j.string(pem));
    try desired.object.put(ctx.store.a, "pending_certificate_sha256", j.string(try ctx.fingerprint(pem)));
    try desired.object.put(ctx.store.a, "pending_registration", registration_value);
    if (try j.number(j.optional(current, "pending_expires_at") orelse j.integer(0)) < ctx.now + 3600) try desired.object.put(ctx.store.a, "pending_expires_at", j.integer(ctx.now + s.pending_seconds));
    return desired;
}
pub fn stage(ctx: Context, value: j.Value, csr_pem: []const u8) !j.Value {
    try s.registration(ctx.store.a, value, null, null);
    const host = try j.field(value, "host");
    const endpoint = try j.field(value, "station");
    const ca_pem = try verifyServer(ctx, endpoint, false);
    const root = try loadCa(ctx);
    try issuance(ctx, root);
    var request = try pki.Csr.parse(ctx.store.a, csr_pem, host);
    defer request.deinit();
    var current = if (try registry(ctx, host, true)) |v| v else blk: {
        try j.require(!try legacy(ctx, host));
        var v = try j.copy(ctx.store.a, value);
        try v.object.put(ctx.store.a, "certificate_sha256", .null);
        break :blk v;
    };
    try s.sameMode(current, value);
    var selected: ?[]const u8 = null;
    for ([_][]const u8{ "pending_certificate_pem", "certificate_pem" }) |name| {
        if (j.optional(current, name)) |existing| {
            const pem = try j.text(existing);
            try ctx.client(pem, ca_pem, host, false, true);
            var cert = try ctx.certificate(pem);
            defer cert.deinit();
            if (try cert.matchesCsr(&request) and !try ctx.soon(pem, s.renew)) {
                selected = pem;
                break;
            }
        }
    }
    const pem = selected orelse blk: {
        var ca = try ctx.ca(ca_pem);
        defer ca.deinit();
        var key = try pki.Key.parse(ctx.store.a, try f.item(root, "ca.key"));
        defer key.deinit();
        break :blk try pki.signClientCertificate(ctx.store.a, &ca, &key, &request, host, ctx.validity(365));
    };
    try ctx.client(pem, ca_pem, host, false, false);
    const same_active = if (j.optional(current, "certificate_pem")) |active| std.mem.eql(u8, try j.text(active), pem) else false;
    if (!(same_active and try j.equal(ctx.store.a, try s.ordinary(ctx.store.a, current), value) and j.optional(current, "pending_certificate_pem") == null)) {
        current = try candidate(ctx, current, value, pem);
        _ = try saveRegistry(ctx, host, current);
    }
    return j.object(ctx.store.a, &.{ .{ "host", j.string(host) }, .{ "station", j.string(endpoint) }, .{ "ca.crt", j.string(ca_pem) }, .{ "client.crt", j.string(pem) }, .{ "certificate_sha256", j.string(try ctx.fingerprint(pem)) } });
}
pub fn stageRegistration(ctx: Context, value: j.Value) !bool {
    try s.registration(ctx.store.a, value, null, null);
    const host = try j.field(value, "host");
    const current = (try registry(ctx, host, false)).?;
    const ca = try verifyServer(ctx, try j.field(value, "station"), false);
    const pem = try j.field(current, "certificate_pem");
    try ctx.client(pem, ca, host, false, false);
    try s.sameMode(current, value);
    if (try j.equal(ctx.store.a, try s.ordinary(ctx.store.a, current), value) and j.optional(current, "pending_certificate_pem") == null) return false;
    return saveRegistry(ctx, host, try candidate(ctx, current, value, pem));
}
pub fn finalize(ctx: Context, host: []const u8, expected: []const u8) !bool {
    try s.fingerprint(j.string(expected), false);
    const current = (try registry(ctx, host, false)).?;
    var changed = false;
    if (j.optional(current, "pending_certificate_pem")) |pending| {
        try j.require(std.mem.eql(u8, try j.field(current, "pending_certificate_sha256"), expected) and try j.number(try j.get(current, "pending_expires_at")) > ctx.now);
        var desired = try j.copy(ctx.store.a, try j.get(current, "pending_registration"));
        const ca = try verifyServer(ctx, try j.field(desired, "station"), false);
        try ctx.client(try j.text(pending), ca, host, false, false);
        try desired.object.put(ctx.store.a, "certificate_sha256", j.string(expected));
        try desired.object.put(ctx.store.a, "certificate_pem", pending);
        try desired.object.put(ctx.store.a, "certificate_identity", j.string(try pki.profile.identity(ctx.store.a, host)));
        changed = try saveRegistry(ctx, host, desired);
    } else {
        try j.require(std.mem.eql(u8, try j.field(current, "certificate_sha256"), expected));
        _ = try j.field(current, "certificate_identity");
        const ca = try verifyServer(ctx, try j.field(current, "station"), false);
        try ctx.client(try j.field(current, "certificate_pem"), ca, host, false, false);
    }
    // Publication follows controller mTLS/telemetry proof; only now unlink the
    // obsolete station copy of a legacy client key. A retry finishes the unlink.
    if (try legacy(ctx, host)) {
        try ctx.store.unlink(try std.fmt.allocPrint(ctx.store.a, f.base ++ "/clients/{s}/client.key", .{host}));
        changed = true;
    }
    return changed;
}
pub fn readRegistration(ctx: Context, host: []const u8) !j.Value {
    const value = (try registry(ctx, host, false)).?;
    try j.require(try j.get(value, "certificate_sha256") != .null);
    return s.ordinary(ctx.store.a, value);
}
pub fn verify(ctx: Context, value: j.Value) !void {
    try s.registration(ctx.store.a, value, null, null);
    const host = try j.field(value, "host");
    const inspection = try inspect(ctx, host, try j.field(value, "station"));
    const current = (try registry(ctx, host, false)).?;
    try j.require(try j.equal(ctx.store.a, try s.ordinary(ctx.store.a, current), value));
    try j.require(j.optional(current, "pending_certificate_pem") == null and !try j.flag(try j.get(inspection, "legacy")));
    try ctx.client(try j.field(current, "certificate_pem"), try j.field(inspection, "ca.crt"), host, false, false);
}
