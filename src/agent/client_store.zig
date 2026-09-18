//! Exact local identity generations and consumer ownership proofs.
const std = @import("std");
pub const s = @import("state.zig");
pub const j = s.j;
pub const f = s.f;
pub const pki = s.pki;
pub const Context = s.Context;
pub const pending_path = f.canonical ++ "/.pending";
pub const reissue_file = ".reissues.json";
pub const consumer_files = f.secrets ++ [_][]const u8{".agent-identity"};
pub const public_files = [_][]const u8{ "ca.crt", "client.crt", "identity.json" };
pub const public_consumer_files = [_][]const u8{ "ca.crt", "client.crt", ".agent-identity" };
pub const pending_files = f.client_files ++ [_][]const u8{ "request.csr", "transaction.json", reissue_file };
pub const kinds = [_][]const u8{ "vector", "vmagent" };
pub fn privateDirectory(ctx: Context, path: []const u8, allowed: []const []const u8) !void {
    const store = ctx.store;
    _ = try store.directory(path, store.root_owner, 0o700, false);
    for (try store.names(path)) |name| try j.require(j.contains(allowed, name) or std.mem.eql(u8, name, ".dragontools-managed"));
    try j.require(std.mem.eql(u8, try store.read(try store.path(path, ".dragontools-managed"), store.root_owner, 0o400, 128), f.client_marker));
}
pub fn readFiles(ctx: Context, path: []const u8, names: []const []const u8) !f.Files {
    return ctx.store.readFiles(path, names, ctx.store.root_owner);
}
pub fn create(ctx: Context, path: []const u8, values: f.Files) !void {
    try ctx.store.createBundle(path, ctx.store.root_owner, 0o700, values, f.client_marker);
}
pub fn replace(ctx: Context, path: []const u8, data: []const u8, owner: f.Owner) !bool {
    return ctx.store.atomic(path, data, owner, 0o400, f.etc);
}
pub fn identity(ctx: Context, host: []const u8, endpoint: []const u8, cert: []const u8, history: j.Value) ![]const u8 {
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    try s.history(history);
    return j.encoded(ctx.store.a, try j.object(ctx.store.a, &.{ .{ "version", j.integer(1) }, .{ "host", j.string(host) }, .{ "station", j.string(endpoint) }, .{ "certificate_identity", j.string(try pki.profile.identity(ctx.store.a, host)) }, .{ "certificate_sha256", j.string(try ctx.fingerprint(cert)) }, .{ "key_source", j.string("host-generated") }, .{ "previous_consumers", history } }));
}
pub fn metadata(ctx: Context, values: f.Files) !j.Value {
    return j.parse(ctx.store.a, try f.item(values, "identity.json"), 32768);
}
pub fn checkPublicIdentity(ctx: Context, values: f.Files, host: []const u8, expired: bool) !void {
    try f.keys(values, if (values.contains("client.key")) &f.client_files else &public_files);
    const meta = try metadata(ctx, values);
    const origin = try j.field(meta, "station");
    const cert = try f.item(values, "client.crt");
    try j.require(f.matches(values, "identity.json", try identity(ctx, host, origin, cert, try j.get(meta, "previous_consumers"))));
    try ctx.client(cert, try f.item(values, "ca.crt"), host, false, expired);
}
pub fn checkIdentity(ctx: Context, values: f.Files, host: []const u8, expired: bool) !void {
    try f.keys(values, &f.client_files);
    try checkPublicIdentity(ctx, values, host, expired);
    try ctx.pair(values, "client");
}
pub const Pending = struct { values: f.Files, previous: f.Files, txn: j.Value };
pub fn pending(ctx: Context, host: []const u8, endpoint: []const u8) anyerror!Pending {
    try privateDirectory(ctx, pending_path, &(pending_files ++ [_][]const u8{ "previous", "backups" }));
    var values = try readFiles(ctx, pending_path, &pending_files);
    const txn = try j.parse(ctx.store.a, try f.item(values, "transaction.json"), 32768);
    try j.keys(txn, &.{ "version", "host", "station", "action", "certificate_sha256", "previous_consumers", "ca_sha256" });
    try j.require(try j.number(try j.get(txn, "version")) == 1);
    try j.require(std.mem.eql(u8, try j.field(txn, "host"), host) and std.mem.eql(u8, try j.field(txn, "station"), endpoint));
    const action = try j.field(txn, "action");
    try j.require(j.contains(&.{ "enroll", "renew", "migrate", "reenroll" }, action));
    try s.fingerprint(try j.get(txn, "certificate_sha256"), true);
    try s.fingerprint(try j.get(txn, "ca_sha256"), false);
    const history = try j.get(txn, "previous_consumers");
    try s.history(history);
    var key = try pki.Key.parse(ctx.store.a, try f.item(values, "client.key"));
    defer key.deinit();
    var csr = try pki.Csr.parse(ctx.store.a, try f.item(values, "request.csr"), host);
    defer csr.deinit();
    try j.require(try csr.matchesKey(&key));
    try privateDirectory(ctx, pending_path ++ "/previous", &f.client_files);
    const previous = try readFiles(ctx, pending_path ++ "/previous", &f.client_files);
    if (previous.count() != 0) {
        if (std.mem.eql(u8, action, "reenroll")) {
            try j.require(!previous.contains("client.key"));
            try checkPublicIdentity(ctx, previous, host, true);
        } else {
            try j.require(std.mem.eql(u8, action, "renew"));
            try checkIdentity(ctx, previous, host, true);
            try j.require(f.matches(previous, "client.key", try f.item(values, "client.key")));
        }
        try j.require(std.mem.eql(u8, try ctx.fingerprint(try f.item(previous, "client.crt")), try j.field(txn, "certificate_sha256")));
    } else try j.require(j.contains(&.{ "enroll", "migrate" }, action));
    _ = try ctx.store.directory(pending_path ++ "/backups", ctx.store.root_owner, 0o700, false);
    for (try ctx.store.names(pending_path ++ "/backups")) |kind| try j.require(j.contains(&kinds, kind));
    if (values.get(reissue_file)) |raw| {
        for (f.client_files) |name| _ = try f.item(values, name);
        const journal = try j.parse(ctx.store.a, raw, f.limit);
        try j.keys(journal, &.{ "version", "certificates" });
        try j.require(try j.number(try j.get(journal, "version")) == 1);
        const certs = try j.array(try j.get(journal, "certificates"), 16);
        try j.require(certs.len >= 2);
        var found_cert = false;
        var found_identity = false;
        for (certs, 0..) |cert_value, index| {
            const pem = try j.text(cert_value);
            try ctx.client(pem, try f.item(values, "ca.crt"), host, false, true);
            var cert = try ctx.certificate(pem);
            defer cert.deinit();
            try cert.matchesKey(&key);
            for (certs[0..index]) |prior| try j.require(!std.mem.eql(u8, try j.text(prior), pem));
            found_cert = found_cert or f.matches(values, "client.crt", pem);
            found_identity = found_identity or f.matches(values, "identity.json", try identity(ctx, host, endpoint, pem, history));
        }
        try j.require(found_cert and found_identity);
        const latest = try j.text(certs[certs.len - 1]);
        try values.put(ctx.store.a, "client.crt", latest);
        try values.put(ctx.store.a, "identity.json", try identity(ctx, host, endpoint, latest, history));
    }
    if (values.contains("identity.json")) try checkIdentity(ctx, try f.selected(ctx.store.a, values, &f.client_files), host, true);
    return .{ .values = values, .previous = previous, .txn = txn };
}
pub fn generations(ctx: Context, generation: Pending) ![]const f.Files {
    const raw = generation.values.get(reissue_file) orelse return &.{};
    const journal = try j.parse(ctx.store.a, raw, f.limit);
    const certs = try j.array(try j.get(journal, "certificates"), 16);
    const result = try ctx.store.a.alloc(f.Files, certs.len);
    for (certs, result) |cert, *values| {
        values.* = try f.selected(ctx.store.a, generation.values, &f.secrets);
        try values.put(ctx.store.a, "client.crt", try j.text(cert));
        try values.put(ctx.store.a, "identity.json", try identity(ctx, try j.field(generation.txn, "host"), try j.field(generation.txn, "station"), try j.text(cert), try j.get(generation.txn, "previous_consumers")));
        try values.put(ctx.store.a, ".agent-identity", try consumerIdentity(ctx, try j.field(generation.txn, "host"), try j.field(generation.txn, "station")));
    }
    return result;
}
pub fn allowedState(ctx: Context, current: f.Files, old: f.Files, target: f.Files, generation: Pending) !void {
    const previous = try generations(ctx, generation);
    var it = current.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const data = entry.value_ptr.*;
        var recognized = f.matches(old, name, data) or f.matches(target, name, data);
        for (previous) |prior| recognized = recognized or f.matches(prior, name, data);
        try j.require(recognized);
    }
}
pub fn inspectRoot(ctx: Context, host: []const u8, endpoint: []const u8, missing_key: bool) !?f.Files {
    if (!try ctx.store.exists(f.canonical)) return null;
    try privateDirectory(ctx, f.canonical, &(f.client_files ++ [_][]const u8{ ".pending", ".completed" }));
    const values = try readFiles(ctx, f.canonical, &f.client_files);
    if (try ctx.store.exists(pending_path)) {
        const generation = try pending(ctx, host, endpoint);
        const candidate = try f.selected(ctx.store.a, generation.values, &f.client_files);
        try allowedState(ctx, values, generation.previous, candidate, generation);
        if (f.equal(values, generation.previous)) return if (values.count() == 0) null else values;
        try f.keys(candidate, &f.client_files);
        return candidate;
    }
    if (values.count() == 0) return null;
    if (missing_key) try checkPublicIdentity(ctx, values, host, true) else try checkIdentity(ctx, values, host, true);
    return values;
}
pub fn consumerIdentity(ctx: Context, host: []const u8, endpoint: []const u8) ![]const u8 {
    return j.encoded(ctx.store.a, try j.object(ctx.store.a, &.{ .{ "host", j.string(host) }, .{ "station", j.string(endpoint) } }));
}
pub fn consumerOrigin(ctx: Context, raw: []const u8, host: []const u8) ![]const u8 {
    const value = try j.parse(ctx.store.a, raw, 4096);
    const origin = try j.field(value, "station");
    try s.endpoint(origin);
    try j.require(std.mem.eql(u8, raw, try consumerIdentity(ctx, host, origin)));
    return origin;
}
pub fn agentState(ctx: Context, kind: []const u8) !?f.Files {
    const account = try ctx.account(kind);
    const store = ctx.store;
    const path = try store.path(f.etc, kind);
    _ = try store.directory(path, store.root_owner, 0o755, false);
    const marker_path = try store.path(path, ".dragontools-credentials");
    if (!try store.exists(marker_path)) {
        for (consumer_files) |name| try j.require(!try store.exists(try store.path(path, name)));
        return null;
    }
    try j.require(std.mem.eql(u8, try store.read(marker_path, store.root_owner, 0o400, 128), f.marker));
    var values = try store.readFiles(path, &f.secrets, account);
    const id_path = try store.path(path, ".agent-identity");
    if (try store.exists(id_path)) try values.put(store.a, ".agent-identity", try store.read(id_path, store.root_owner, 0o400, 4096));
    return values;
}
pub fn consumer(ctx: Context, kind: []const u8, host: []const u8, modern: bool, expired: bool) !?f.Files {
    const values = try agentState(ctx, kind) orelse return null;
    try f.keys(values, &consumer_files);
    _ = try consumerOrigin(ctx, try f.item(values, ".agent-identity"), host);
    try ctx.clientPair(values, host, !modern, expired);
    return values;
}
pub fn checkPublicConsumer(ctx: Context, values: f.Files, host: []const u8) !void {
    try f.keys(values, if (values.contains("client.key")) &consumer_files else &public_consumer_files);
    _ = try consumerOrigin(ctx, try f.item(values, ".agent-identity"), host);
    try ctx.client(try f.item(values, "client.crt"), try f.item(values, "ca.crt"), host, true, true);
    if (values.contains("client.key")) try ctx.pair(values, "client");
}
pub fn desired(ctx: Context, host: []const u8, endpoint: []const u8) !f.Files {
    var current = try inspectRoot(ctx, host, endpoint, false);
    if (try ctx.store.exists(pending_path)) {
        const generation = try pending(ctx, host, endpoint);
        current = try f.selected(ctx.store.a, generation.values, &f.client_files);
        try f.keys(current.?, &f.client_files);
    }
    const values = current orelse return error.CredentialStateRefused;
    const origin = try j.field(try metadata(ctx, values), "station");
    var result = try f.selected(ctx.store.a, values, &f.secrets);
    try result.put(ctx.store.a, ".agent-identity", try consumerIdentity(ctx, host, origin));
    return result;
}
