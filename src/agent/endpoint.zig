const std = @import("std");
const s = @import("state.zig");
extern "c" fn dragontools_connect(host: [*:0]const u8, port: [*:0]const u8, result: *c_int) c_int;
extern "c" fn dragontools_network_cancel() void;
pub fn check(ctx: s.Context, endpoint: []const u8, kind: []const u8, host: []const u8, signal: []const u8) !void {
    try s.j.require(s.j.contains(&.{ "metrics", "logs" }, signal));
    try s.endpoint(endpoint);
    try s.pki.profile.host(host);
    const is_pending = std.mem.eql(u8, kind, "pending");
    const owner = if (is_pending) ctx.store.root_owner else try ctx.account(kind);
    const path = if (is_pending) s.f.canonical ++ "/.pending" else try ctx.store.path(s.f.etc, kind);
    var fd: c_int = -1;
    const result = dragontools_connect(try ctx.store.a.dupeZ(u8, endpoint), if (std.mem.eql(u8, signal, "metrics")) "9443" else "9444", &fd);
    if (result == 91) return error.DnsUnresolved;
    if (result != 0) return error.TcpUnreachable;
    defer _ = std.c.close(fd);
    defer dragontools_network_cancel();
    const ca = ctx.store.read(try ctx.store.path(path, "ca.crt"), owner, 0o400, 16384) catch return error.ServerTlsInvalid;
    const cert = ctx.store.read(try ctx.store.path(path, "client.crt"), owner, 0o400, 16384) catch return error.ClientCertificateRejected;
    const key = ctx.store.read(try ctx.store.path(path, "client.key"), owner, 0o400, 4096) catch return error.ClientCertificateRejected;
    try @import("../pki/tls.zig").health(ctx.store.a, fd, ca, cert, key, endpoint, if (std.mem.eql(u8, signal, "metrics")) 9443 else 9444, host, ctx.now);
}
