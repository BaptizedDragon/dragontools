//! Consumer rollout and commit follow controller mTLS/telemetry proof.
const std = @import("std");
const storage = @import("client_store.zig");
const enrollment = @import("client_enrollment.zig");
const s = storage.s;
const j = storage.j;
const f = storage.f;
const pki = storage.pki;
const Context = s.Context;
pub const prepare = enrollment.prepare;
pub const stage = enrollment.stage;
const Backup = struct { values: ?f.Files, active: bool };
fn backupPath(ctx: Context, kind: []const u8) ![]const u8 {
    _ = try ctx.account(kind);
    return ctx.store.path(storage.pending_path ++ "/backups", kind);
}
fn optionalEqual(left: ?f.Files, right: ?f.Files) bool {
    if (left) |l| return if (right) |r| f.equal(l, r) else false;
    return right == null;
}
pub fn backup(ctx: Context, kind: []const u8, current: ?f.Files, active: bool) !Backup {
    const path = try backupPath(ctx, kind);
    if (!try ctx.store.exists(path)) {
        var values = if (current) |v| try f.copy(ctx.store.a, v) else f.Files.empty;
        const state = try j.object(ctx.store.a, &.{ .{ "present", j.boolean(current != null) }, .{ "active", j.boolean(active) }, .{ "missing_key", j.boolean(if (current) |v| !v.contains("client.key") else false) } });
        try values.put(ctx.store.a, "state.json", try j.encoded(ctx.store.a, state));
        try storage.create(ctx, path, values);
    }
    const names = storage.consumer_files ++ [_][]const u8{"state.json"};
    try storage.privateDirectory(ctx, path, &names);
    var values = try storage.readFiles(ctx, path, &names);
    const state = try j.parse(ctx.store.a, try f.item(values, "state.json"), 4096);
    _ = values.remove("state.json");
    try j.keys(state, &.{ "present", "active", "missing_key" });
    const present = try j.flag(try j.get(state, "present"));
    const was_active = try j.flag(try j.get(state, "active"));
    const missing_key = try j.flag(try j.get(state, "missing_key"));
    try j.require(!missing_key or present);
    try f.keys(values, if (!present) &.{} else if (missing_key) &storage.public_consumer_files else &storage.consumer_files);
    const txn = try j.parse(ctx.store.a, try ctx.store.read(storage.pending_path ++ "/transaction.json", ctx.store.root_owner, 0o400, 32768), 32768);
    const history = try j.get(txn, "previous_consumers");
    if (present) {
        const host = try j.field(txn, "host");
        _ = try storage.consumerOrigin(ctx, try f.item(values, ".agent-identity"), host);
        try j.require(std.mem.eql(u8, try ctx.fingerprint(try f.item(values, "client.crt")), try j.field(history, kind)));
        try j.require(std.mem.eql(u8, try ctx.digest(try f.item(values, "ca.crt")), try j.field(txn, "ca_sha256")));
        if (missing_key) try j.require(std.mem.eql(u8, try j.field(txn, "action"), "reenroll"));
        try storage.checkPublicConsumer(ctx, values, host);
    } else try j.require(j.optional(history, kind) == null);
    return .{ .values = if (present) values else null, .active = was_active };
}
fn publish(ctx: Context, kind: []const u8, desired: f.Files, current: ?f.Files) !void {
    const account = try ctx.account(kind);
    const path = try ctx.store.path(f.etc, kind);
    try ctx.store.mark(kind);
    if (try ctx.service("is-active", kind)) _ = try ctx.service("stop", kind);
    if (current == null) _ = try storage.replace(ctx, try ctx.store.path(path, ".dragontools-credentials"), f.marker, ctx.store.root_owner);
    for (storage.consumer_files) |name| {
        if (desired.get(name)) |data| {
            if (current == null or !f.matches(current.?, name, data)) _ = try storage.replace(ctx, try ctx.store.path(path, name), data, if (std.mem.eql(u8, name, ".agent-identity")) ctx.store.root_owner else account);
        } else if (current != null and current.?.contains(name)) {
            // A proven rollback may restore the recorded missing-key state.
            try ctx.store.unlink(try ctx.store.path(path, name));
        }
    }
}
fn allowed(ctx: Context, current: ?f.Files, old: ?f.Files, desired: f.Files, host: []const u8, endpoint: []const u8) !void {
    try j.require(current != null or old == null);
    try storage.allowedState(ctx, current orelse .empty, old orelse .empty, desired, try storage.pending(ctx, host, endpoint));
}
pub fn install(ctx: Context, kind: []const u8, host: []const u8, endpoint: []const u8) !bool {
    _ = try ctx.account(kind);
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    const desired = try storage.desired(ctx, host, endpoint);
    const current = try storage.agentState(ctx, kind);
    if (optionalEqual(current, desired)) {
        try verify(ctx, kind, host, endpoint);
        return false;
    }
    if (try ctx.store.exists(storage.pending_path)) {
        var old: Backup = undefined;
        if (!try ctx.store.exists(try backupPath(ctx, kind))) {
            if (current) |values| {
                const generation = try storage.pending(ctx, host, endpoint);
                const prior = if (std.mem.eql(u8, try j.field(generation.txn, "action"), "reenroll")) blk: {
                    try j.require(f.matches(values, "ca.crt", try f.item(generation.previous, "ca.crt")));
                    try storage.checkPublicConsumer(ctx, values, host);
                    break :blk values;
                } else try storage.consumer(ctx, kind, host, false, true) orelse return error.CredentialStateRefused;
                try j.require(std.mem.eql(u8, try ctx.fingerprint(try f.item(prior, "client.crt")), try j.field(try j.get(generation.txn, "previous_consumers"), kind)));
            }
            old = try backup(ctx, kind, current, try ctx.service("is-active", kind));
        } else old = try backup(ctx, kind, null, false);
        try allowed(ctx, current, old.values, desired, host, endpoint);
    } else if (current) |values| {
        var missing_key = values.count() == storage.public_consumer_files.len and !values.contains("client.key");
        var it = values.iterator();
        while (it.next()) |entry| missing_key = missing_key and f.matches(desired, entry.key_ptr.*, entry.value_ptr.*);
        if (!missing_key) {
            const canonical = try storage.inspectRoot(ctx, host, endpoint, false) orelse return error.CredentialStateRefused;
            const previous = try j.field(try j.get(try storage.metadata(ctx, canonical), "previous_consumers"), kind);
            try j.require(std.mem.eql(u8, try ctx.fingerprint(try f.item(values, "client.crt")), previous));
            try j.require(f.matches(values, "ca.crt", try f.item(canonical, "ca.crt")));
            _ = try storage.consumer(ctx, kind, host, false, true);
        }
    }
    try publish(ctx, kind, desired, current);
    try verify(ctx, kind, host, endpoint);
    return true;
}
pub fn rollback(ctx: Context, host: []const u8, endpoint: []const u8) !bool {
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    if (!try ctx.store.exists(storage.pending_path)) return false;
    const generation = try storage.pending(ctx, host, endpoint);
    if (!generation.values.contains("identity.json")) return false;
    const desired = try storage.desired(ctx, host, endpoint);
    var changed = false;
    for (storage.kinds) |kind| {
        if (!try ctx.store.exists(try backupPath(ctx, kind))) continue;
        const old = try backup(ctx, kind, null, false);
        const current = try storage.agentState(ctx, kind);
        try allowed(ctx, current, old.values, desired, host, endpoint);
        if (!optionalEqual(current, old.values)) {
            if (old.values) |values| {
                try publish(ctx, kind, values, current);
                try storage.checkPublicConsumer(ctx, try storage.agentState(ctx, kind) orelse return error.CredentialStateRefused, host);
            } else {
                try ctx.store.mark(kind);
                if (try ctx.service("is-active", kind)) _ = try ctx.service("stop", kind);
                if (current) |values| {
                    const path = try ctx.store.path(f.etc, kind);
                    var it = values.keyIterator();
                    while (it.next()) |name| try ctx.store.unlink(try ctx.store.path(path, name.*));
                    try ctx.store.unlink(try ctx.store.path(path, ".dragontools-credentials"));
                }
            }
            changed = true;
        }
        if (old.values != null and old.active and !try ctx.service("is-active", kind)) {
            _ = try ctx.service("start", kind);
            changed = true;
        }
    }
    return changed;
}
pub fn commit(ctx: Context, host: []const u8, endpoint: []const u8) !bool {
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    if (!try ctx.store.exists(storage.pending_path)) {
        try j.require(try storage.inspectRoot(ctx, host, endpoint, false) != null);
        if (try ctx.store.exists(f.canonical ++ "/.completed")) {
            try enrollment.discardGeneration(ctx, f.canonical ++ "/.completed");
            return true;
        }
        return false;
    }
    _ = try storage.inspectRoot(ctx, host, endpoint, false);
    const generation = try storage.pending(ctx, host, endpoint);
    for (f.client_files) |name| _ = try f.item(generation.values, name);
    const desired = try storage.desired(ctx, host, endpoint);
    for (try ctx.store.names(storage.pending_path ++ "/backups")) |kind| {
        _ = try backup(ctx, kind, null, false);
        try j.require(optionalEqual(try storage.agentState(ctx, kind), desired));
        try verify(ctx, kind, host, endpoint);
    }
    // Keep complete .pending throughout publication; identity.json is last.
    for (f.client_files) |name| _ = try storage.replace(ctx, try ctx.store.path(f.canonical, name), try f.item(generation.values, name), ctx.store.root_owner);
    try storage.checkIdentity(ctx, try storage.readFiles(ctx, f.canonical, &f.client_files), host, false);
    try ctx.store.rename(storage.pending_path, f.canonical ++ "/.completed", false);
    try enrollment.discardGeneration(ctx, f.canonical ++ "/.completed");
    return true;
}
pub fn verify(ctx: Context, kind: []const u8, host: []const u8, endpoint: []const u8) !void {
    try pki.profile.host(host);
    try s.endpoint(endpoint);
    const values = try storage.consumer(ctx, kind, host, false, false) orelse return error.CredentialStateRefused;
    if (!try ctx.store.exists(f.canonical)) return;
    const current = try storage.inspectRoot(ctx, host, endpoint, false);
    const actual = try f.selected(ctx.store.a, values, &f.secrets);
    var recognized = if (current) |v| f.equal(actual, try f.selected(ctx.store.a, v, &f.secrets)) else false;
    if (try ctx.store.exists(storage.pending_path)) {
        const generation = try storage.pending(ctx, host, endpoint);
        recognized = recognized or f.equal(actual, try f.selected(ctx.store.a, generation.previous, &f.secrets));
        if (generation.values.contains("identity.json")) recognized = recognized or f.equal(actual, try f.selected(ctx.store.a, generation.values, &f.secrets));
        if (std.mem.eql(u8, try j.field(generation.txn, "action"), "migrate") and std.mem.eql(u8, try ctx.fingerprint(try f.item(values, "client.crt")), try j.field(generation.txn, "certificate_sha256"))) return;
    }
    try j.require(recognized);
    try ctx.clientPair(values, host, false, false);
}
