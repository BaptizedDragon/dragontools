//! Host-only key generation, recovery, and public response staging.
const std = @import("std");
pub const storage = @import("client_store.zig");
const s = storage.s;
const j = storage.j;
const f = storage.f;
const pki = storage.pki;
const Context = s.Context;
fn same(value: j.Value, bytes: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, bytes);
}
pub fn recognizedFingerprint(ctx: Context, current: f.Files, inspection: j.Value, kind: []const u8, fp: []const u8) !bool {
    return same(try j.get(inspection, "certificate_sha256"), fp) or same(j.optional(try j.get(try storage.metadata(ctx, current), "previous_consumers"), kind) orelse .null, fp);
}
fn recover(ctx: Context, host: []const u8, endpoint: []const u8, inspection: j.Value) !?bool {
    _ = endpoint;
    if (!try ctx.store.exists(f.canonical) or try ctx.store.exists(storage.pending_path) or try ctx.store.exists(f.canonical ++ "/client.key") or !try ctx.store.exists(f.canonical ++ "/client.crt")) return false;
    try storage.privateDirectory(ctx, f.canonical, &(f.client_files ++ [_][]const u8{".completed"}));
    const values = try storage.readFiles(ctx, f.canonical, &f.client_files);
    try f.keys(values, &storage.public_files);
    try j.require(f.matches(values, "ca.crt", try j.field(inspection, "ca.crt")));
    try j.require(same(try j.get(inspection, "certificate_sha256"), try ctx.fingerprint(try f.item(values, "client.crt"))));
    try storage.checkPublicIdentity(ctx, values, host, true);
    for (storage.kinds) |kind| {
        const marker_path = try std.fmt.allocPrint(ctx.store.a, f.etc ++ "/{s}/.dragontools-credentials", .{kind});
        if (!try ctx.store.exists(marker_path)) continue;
        const consumer = try storage.agentState(ctx, kind) orelse continue;
        if (!consumer.contains("client.key") or !consumer.contains("client.crt") or !consumer.contains("ca.crt")) continue;
        if (!f.matches(consumer, "ca.crt", try f.item(values, "ca.crt")) or !try recognizedFingerprint(ctx, values, inspection, kind, try ctx.fingerprint(try f.item(consumer, "client.crt")))) continue;
        try storage.checkPublicConsumer(ctx, consumer, host);
        var cert = try ctx.certificate(try f.item(values, "client.crt"));
        defer cert.deinit();
        var key = try pki.Key.parse(ctx.store.a, try f.item(consumer, "client.key"));
        defer key.deinit();
        cert.matchesKey(&key) catch continue;
        var restored = try f.copy(ctx.store.a, values);
        try restored.put(ctx.store.a, "client.key", try f.item(consumer, "client.key"));
        try storage.checkIdentity(ctx, restored, host, true);
        _ = try storage.replace(ctx, f.canonical ++ "/client.key", try f.item(consumer, "client.key"), ctx.store.root_owner);
        return true;
    }
    // Known public identity, but no proven matching key anywhere on this host.
    // Keep it as a rollback generation; a fresh key requires reenrollment proof.
    return null;
}
fn preparation(ctx: Context, action: []const u8, csr: ?[]const u8, fp: j.Value, recovered: bool) !j.Value {
    var result = try j.object(ctx.store.a, &.{ .{ "action", j.string(action) }, .{ "csr", if (csr) |v| j.string(v) else .null }, .{ "certificate_sha256", fp } });
    if (recovered) try result.object.put(ctx.store.a, "recovered_key", j.boolean(true));
    return result;
}
pub fn prepare(ctx: Context, host: []const u8, endpoint: []const u8, inspection: j.Value) !j.Value {
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    try j.keys(inspection, &.{ "host", "station", "ca.crt", "legacy", "legacy_active", "legacy_expired", "certificate_sha256", "pending_certificate_sha256" });
    try j.require(std.mem.eql(u8, try j.field(inspection, "host"), host) and std.mem.eql(u8, try j.field(inspection, "station"), endpoint));
    const legacy = try j.flag(try j.get(inspection, "legacy"));
    const legacy_active = try j.flag(try j.get(inspection, "legacy_active"));
    const legacy_expired = try j.flag(try j.get(inspection, "legacy_expired"));
    try j.require((!legacy_expired or legacy_active) and (!legacy_active or legacy));
    const ca_pem = try j.field(inspection, "ca.crt");
    var ca = try ctx.ca(ca_pem);
    defer ca.deinit();
    const fp = try j.get(inspection, "certificate_sha256");
    try s.fingerprint(fp, true);
    try s.fingerprint(try j.get(inspection, "pending_certificate_sha256"), true);
    _ = try ctx.store.directory(f.etc, ctx.store.root_owner, 0o755, false);
    const recovered = try recover(ctx, host, endpoint, inspection);
    const current = try storage.inspectRoot(ctx, host, endpoint, recovered == null);
    if (try ctx.store.exists(f.canonical ++ "/.completed")) {
        const values = current orelse return error.CredentialStateRefused;
        try j.require(same(fp, try ctx.fingerprint(try f.item(values, "client.crt"))));
    }
    if (try ctx.store.exists(storage.pending_path)) {
        const generation = try storage.pending(ctx, host, endpoint);
        var recognized = try j.equal(ctx.store.a, fp, try j.get(generation.txn, "certificate_sha256"));
        if (generation.values.contains("identity.json")) {
            recognized = recognized or same(fp, try ctx.fingerprint(try f.item(generation.values, "client.crt")));
            for (try storage.generations(ctx, generation)) |prior| recognized = recognized or same(fp, try ctx.fingerprint(try f.item(prior, "client.crt")));
        }
        try j.require(recognized);
        try j.require(std.mem.eql(u8, try ctx.digest(ca_pem), try j.field(generation.txn, "ca_sha256")));
        if (generation.previous.count() != 0) try j.require(f.matches(generation.previous, "ca.crt", ca_pem));
        if (generation.values.contains("ca.crt")) try j.require(f.matches(generation.values, "ca.crt", ca_pem));
        return preparation(ctx, try j.field(generation.txn, "action"), try f.item(generation.values, "request.csr"), try j.get(generation.txn, "certificate_sha256"), false);
    }
    var action: []const u8 = undefined;
    var existing_key: ?[]const u8 = null;
    if (current) |values| {
        try j.require(f.matches(values, "ca.crt", ca_pem));
        try j.require(same(fp, try ctx.fingerprint(try f.item(values, "client.crt"))));
        if (!try ctx.soon(try f.item(values, "client.crt"), s.renew) and recovered != null) return preparation(ctx, "unchanged", null, fp, recovered.?);
        if (recovered == null) action = "reenroll" else {
            action = "renew";
            existing_key = try f.item(values, "client.key");
        }
    } else {
        try j.require(fp == .null or legacy);
        if (legacy) {
            const previous = try storage.consumer(ctx, "vector", host, false, legacy_expired) orelse return error.CredentialStateRefused;
            try j.require(f.matches(previous, "ca.crt", ca_pem));
            try j.require(same(fp, try ctx.fingerprint(try f.item(previous, "client.crt"))));
            if (try ctx.store.exists(f.etc ++ "/vmagent/.dragontools-credentials")) try j.require(f.equal(previous, try storage.consumer(ctx, "vmagent", host, false, legacy_expired) orelse return error.CredentialStateRefused));
            action = "migrate";
        } else {
            for (storage.kinds) |kind| if (try ctx.store.exists(try ctx.store.path(f.etc, kind))) try j.require(try storage.agentState(ctx, kind) == null);
            action = "enroll";
        }
    }
    var history = try j.object(ctx.store.a, &.{});
    for (storage.kinds) |kind| {
        if (!try ctx.store.exists(try std.fmt.allocPrint(ctx.store.a, f.etc ++ "/{s}/.dragontools-credentials", .{kind}))) continue;
        const prior = if (std.mem.eql(u8, action, "reenroll")) blk: {
            const values = try storage.agentState(ctx, kind) orelse return error.CredentialStateRefused;
            try storage.checkPublicConsumer(ctx, values, host);
            break :blk values;
        } else try storage.consumer(ctx, kind, host, false, std.mem.eql(u8, action, "renew") or legacy_expired) orelse return error.CredentialStateRefused;
        try j.require(f.matches(prior, "ca.crt", ca_pem));
        const prior_fp = try ctx.fingerprint(try f.item(prior, "client.crt"));
        if (current) |values| try j.require(try recognizedFingerprint(ctx, values, inspection, kind, prior_fp)) else try j.require(same(fp, prior_fp));
        try history.object.put(ctx.store.a, kind, j.string(prior_fp));
    }
    var key = if (existing_key) |pem| try pki.Key.parse(ctx.store.a, pem) else try pki.Key.generate();
    defer key.deinit();
    const pem = existing_key orelse try key.privatePem(ctx.store.a);
    const csr = try pki.createClientCsr(ctx.store.a, &key, host);
    const txn = try j.object(ctx.store.a, &.{ .{ "version", j.integer(1) }, .{ "host", j.string(host) }, .{ "station", j.string(endpoint) }, .{ "action", j.string(action) }, .{ "certificate_sha256", fp }, .{ "previous_consumers", history }, .{ "ca_sha256", j.string(try ctx.digest(ca_pem)) } });
    // A finalized rollout may have been interrupted during cleanup months ago.
    // Its proven current identity can now need renewal; retire that bounded
    // completed generation before publishing the next pending generation.
    if (try ctx.store.exists(f.canonical ++ "/.completed")) try discardGeneration(ctx, f.canonical ++ "/.completed");
    if (!try ctx.store.exists(f.canonical)) try storage.create(ctx, f.canonical, .empty);
    const stage_path = try ctx.store.temporary(f.etc, "enrollment", true);
    var published = false;
    defer if (!published) discardGeneration(ctx, stage_path) catch {};
    try ctx.store.write(try ctx.store.path(stage_path, ".dragontools-managed"), f.client_marker, ctx.store.root_owner, 0o400);
    try ctx.store.write(try ctx.store.path(stage_path, "client.key"), pem, ctx.store.root_owner, 0o400);
    try ctx.store.write(try ctx.store.path(stage_path, "request.csr"), csr, ctx.store.root_owner, 0o400);
    try ctx.store.write(try ctx.store.path(stage_path, "transaction.json"), try j.encoded(ctx.store.a, txn), ctx.store.root_owner, 0o400);
    try storage.create(ctx, try ctx.store.path(stage_path, "previous"), current orelse .empty);
    _ = try ctx.store.directory(try ctx.store.path(stage_path, "backups"), ctx.store.root_owner, 0o700, true);
    try ctx.store.sync(stage_path);
    try ctx.store.rename(stage_path, storage.pending_path, false);
    published = true;
    return preparation(ctx, action, csr, fp, recovered orelse false);
}
pub fn stage(ctx: Context, payload: j.Value) !bool {
    try j.keys(payload, &.{ "host", "station", "ca.crt", "client.crt", "certificate_sha256" });
    const host = try j.field(payload, "host");
    const endpoint = try j.field(payload, "station");
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    const generation = try storage.pending(ctx, host, endpoint);
    var desired: f.Files = .empty;
    const ca = try j.field(payload, "ca.crt");
    const cert = try j.field(payload, "client.crt");
    try j.require(std.mem.eql(u8, try j.field(payload, "certificate_sha256"), try ctx.fingerprint(cert)));
    try j.require(std.mem.eql(u8, try ctx.digest(ca), try j.field(generation.txn, "ca_sha256")));
    if (generation.previous.count() != 0) try j.require(f.matches(generation.previous, "ca.crt", ca));
    try desired.put(ctx.store.a, "ca.crt", ca);
    try desired.put(ctx.store.a, "client.crt", cert);
    try desired.put(ctx.store.a, "client.key", try f.item(generation.values, "client.key"));
    try desired.put(ctx.store.a, "identity.json", try storage.identity(ctx, host, endpoint, cert, try j.get(generation.txn, "previous_consumers")));
    // Nothing is written until the complete response matches the existing local key.
    try storage.checkIdentity(ctx, desired, host, false);
    var changed = false;
    if (generation.values.contains("identity.json") and !f.matches(generation.values, "client.crt", cert)) {
        var certificates: std.ArrayList(j.Value) = .empty;
        if (generation.values.get(storage.reissue_file)) |raw| {
            const journal = try j.parse(ctx.store.a, raw, f.limit);
            try certificates.appendSlice(ctx.store.a, try j.array(try j.get(journal, "certificates"), 16));
        } else try certificates.append(ctx.store.a, j.string(try f.item(generation.values, "client.crt")));
        try j.require(certificates.items.len < 16);
        for (certificates.items) |previous| try j.require(!same(previous, cert));
        try certificates.append(ctx.store.a, j.string(cert));
        const journal = try j.object(ctx.store.a, &.{ .{ "version", j.integer(1) }, .{ "certificates", .{ .array = certificates.toManaged(ctx.store.a) } } });
        changed = try storage.replace(ctx, storage.pending_path ++ "/" ++ storage.reissue_file, try j.encoded(ctx.store.a, journal), ctx.store.root_owner);
    }
    const physical = try storage.readFiles(ctx, storage.pending_path, &f.client_files);
    for ([_][]const u8{ "ca.crt", "client.crt", "identity.json" }) |name| {
        const data = try f.item(desired, name);
        if (!f.matches(physical, name, data)) {
            if (std.mem.eql(u8, name, "ca.crt") and physical.contains(name)) return error.CredentialStateRefused;
            changed = try storage.replace(ctx, try ctx.store.path(storage.pending_path, name), data, ctx.store.root_owner) or changed;
        }
    }
    return changed;
}
pub fn discardGeneration(ctx: Context, path: []const u8) !void {
    // Validate the whole bounded tree before any cleanup. Missing files are
    // allowed after interrupted cleanup; links, extra files and owners are not.
    const root_allowed = storage.pending_files ++ [_][]const u8{".dragontools-managed"};
    const previous_allowed = f.client_files ++ [_][]const u8{".dragontools-managed"};
    const backup_allowed = storage.consumer_files ++ [_][]const u8{ ".dragontools-managed", "state.json" };
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.append(ctx.store.a, path);
    var index: usize = 0;
    while (index < dirs.items.len) : (index += 1) {
        const current = dirs.items[index];
        _ = try ctx.store.directory(current, ctx.store.root_owner, 0o700, false);
        const relative = if (current.len == path.len) "" else current[path.len + 1 ..];
        const allowed: []const []const u8 = if (relative.len == 0) &root_allowed else if (std.mem.eql(u8, relative, "previous")) &previous_allowed else if (std.mem.eql(u8, relative, "backups")) &.{} else if (j.contains(&.{ "backups/vector", "backups/vmagent" }, relative)) &backup_allowed else return error.CredentialStateRefused;
        for (try ctx.store.names(current)) |name| {
            const child = try ctx.store.path(current, name);
            if (relative.len == 0 and j.contains(&.{ "previous", "backups" }, name) or std.mem.eql(u8, relative, "backups") and j.contains(&storage.kinds, name)) {
                try dirs.append(ctx.store.a, child);
            } else {
                try j.require(j.contains(allowed, name));
                _ = try ctx.store.read(child, ctx.store.root_owner, 0o400, f.limit);
                try files.append(ctx.store.a, child);
            }
        }
    }
    for (files.items) |file| try ctx.store.unlink(file);
    var remaining = dirs.items.len;
    while (remaining != 0) {
        remaining -= 1;
        try ctx.store.removeEmpty(dirs.items[remaining]);
    }
}
