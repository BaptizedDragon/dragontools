//! No operation exports private files or accepts caller-supplied filesystem paths.
const std = @import("std");
const s = @import("state.zig");
const station = @import("station.zig");
const client = @import("client.zig");
const j = s.j;
fn count(args: []const []const u8, length: usize) !void {
    try j.require(args.len == length);
}
fn changed(value: bool) []const u8 {
    return if (value) "changed" else "unchanged";
}
pub fn stationAction(action: []const u8) bool {
    return j.contains(&.{ "station-ensure", "station-verify", "ensure", "inspect", "stage", "stage-registration", "finalize", "registration", "verify" }, action);
}
pub fn dispatch(ctx: s.Context, action: []const u8, args: []const []const u8) ![]const u8 {
    for (args) |arg| try j.require(arg.len <= s.f.limit and std.mem.indexOfScalar(u8, arg, 0) == null);
    if (j.contains(&.{ "station-ensure", "station-verify" }, action)) {
        try count(args, 1);
        const requested = if (args[0].len == 0) null else args[0];
        if (std.mem.eql(u8, action, "station-ensure")) return changed(try station.ensureStation(ctx, requested));
        _ = try station.verifyServer(ctx, try station.stationEndpoint(ctx, requested), false);
        return "unchanged";
    }
    if (std.mem.eql(u8, action, "endpoint")) {
        try count(args, 4);
        try @import("endpoint.zig").check(ctx, args[0], args[1], args[2], args[3]);
        return "unchanged";
    }
    if (j.contains(&.{ "ensure", "verify", "stage", "stage-registration" }, action)) {
        try count(args, if (std.mem.eql(u8, action, "stage")) 4 else 3);
        const value = try j.parse(ctx.store.a, args[2], 196608);
        try s.registration(ctx.store.a, value, args[0], args[1]);
        if (std.mem.eql(u8, action, "ensure")) return changed(try station.ensure(ctx, value));
        if (std.mem.eql(u8, action, "stage")) return j.encoded(ctx.store.a, try station.stage(ctx, value, args[3]));
        if (std.mem.eql(u8, action, "stage-registration")) return changed(try station.stageRegistration(ctx, value));
        try station.verify(ctx, value);
        return "unchanged";
    }
    if (std.mem.eql(u8, action, "inspect")) {
        try count(args, 2);
        return j.encoded(ctx.store.a, try station.inspect(ctx, args[0], args[1]));
    }
    if (std.mem.eql(u8, action, "finalize")) {
        try count(args, 2);
        return changed(try station.finalize(ctx, args[0], args[1]));
    }
    if (std.mem.eql(u8, action, "registration")) {
        try count(args, 1);
        return j.encoded(ctx.store.a, try station.readRegistration(ctx, args[0]));
    }
    if (std.mem.eql(u8, action, "client-prepare")) {
        try count(args, 3);
        return j.encoded(ctx.store.a, try client.prepare(ctx, args[0], args[1], try j.parse(ctx.store.a, args[2], 32768)));
    }
    if (std.mem.eql(u8, action, "client-stage")) {
        try count(args, 1);
        return changed(try client.stage(ctx, try j.parse(ctx.store.a, args[0], 32768)));
    }
    if (j.contains(&.{ "client-install", "verify-agent" }, action)) {
        try count(args, 3);
        if (std.mem.eql(u8, action, "client-install")) return changed(try client.install(ctx, args[0], args[1], args[2]));
        try client.verify(ctx, args[0], args[1], args[2]);
        return "unchanged";
    }
    if (j.contains(&.{ "client-commit", "client-rollback" }, action)) {
        try count(args, 2);
        return changed(if (std.mem.eql(u8, action, "client-commit")) try client.commit(ctx, args[0], args[1]) else try client.rollback(ctx, args[0], args[1]));
    }
    return error.UnknownAgentOperation;
}
pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.OperationBusy => 96,
        error.DnsUnresolved => 91,
        error.TcpUnreachable => 92,
        error.ServerTlsInvalid => 93,
        error.ClientCertificateRejected => 94,
        error.IngestionRejected => 95,
        error.CaMaintenanceRequired => 87,
        error.ClientIdentityInconsistent => 88,
        error.RegistryPermissions => 89,
        error.IngressHostnameRequired => 90,
        else => 86,
    };
}
