//! Test-only certificate factory / native TLS probe. Not a release artifact.
const std = @import("std");
const pki = @import("pki/pki.zig");
const support = @import("pki/test_support.zig");
const protocol = @import("agent/protocol.zig");
extern "c" fn dragontools_connect(host: [*:0]const u8, port: [*:0]const u8, result: *c_int) c_int;
extern "c" fn dragontools_network_cancel() void;
fn read(a: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ directory, name }), a, .limited(16384));
}
fn write(a: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ directory, name }), .{ .exclusive = true, .permissions = .fromMode(0o400) });
    defer file.close(io);
    try file.writePositionalAll(io, data, 0);
}
pub fn main(init: std.process.Init) void {
    run(init) catch |err| std.process.exit(protocol.exitCode(err));
}
fn run(init: std.process.Init) !void {
    try @import("agent/runtime.zig").protect();
    var secure: @import("agent/secure_allocator.zig").SecureAllocator = .{ .child = std.heap.page_allocator };
    var arena = std.heap.ArenaAllocator.init(secure.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const now = std.Io.Clock.real.now(init.io).toSeconds();
    if (args.len == 2 and std.mem.eql(u8, args[1], "helper-scripts")) {
        const helper = @import("monitoring/agents/helper.zig");
        const arch: @import("system/host.zig").Arch = if (@import("builtin").cpu.arch == .aarch64) .arm64 else .amd64;
        const artifact = helper.artifact(arch);
        const upload = try helper.uploadCommand(a, arch);
        const output = try std.json.Stringify.valueAlloc(a, .{ .inspect = try helper.inspectCommand(a, arch, false), .verify = try helper.inspectCommand(a, arch, true), .upload = upload.command, .sha256 = @as([]const u8, &artifact.sha256), .version = @import("version.zig").version }, .{});
        try std.Io.File.stdout().writeStreamingAll(init.io, output);
    } else if (args.len == 2 and std.mem.eql(u8, args[1], "maintenance")) {
        const maintenance = @import("maintenance/main.zig");
        try std.Io.File.stdout().writeStreamingAll(init.io, try maintenance.metrics(a, .{ .supported = true, .package_metadata_fresh = true, .updates_pending = 12, .security_updates_pending = 3, .reboot_required = true, .automatic_security_updates_enabled = true, .automatic_security_updates_healthy = true }, "0.1.0-fixture"));
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "ca")) {
        var key = try pki.Key.generate();
        defer key.deinit();
        const cert = try pki.createCaCertificate(a, &key, .{ .not_before = now - 60, .not_after = now + 3650 * 86400 });
        try write(a, init.io, args[2], "ca.key", try key.privatePem(a));
        try write(a, init.io, args[2], "ca.crt", cert);
    } else if (args.len == 6 and std.mem.eql(u8, args[1], "issue")) {
        const kind = std.meta.stringToEnum(support.Kind, args[4]) orelse return error.InvalidFixture;
        var signer = try pki.Key.parse(a, try read(a, init.io, args[2], "ca.key"));
        defer signer.deinit();
        var key = try pki.Key.generate();
        defer key.deinit();
        const cert = try support.certificate(a, &key, &signer, args[5], kind, now);
        try write(a, init.io, args[3], "client.key", try key.privatePem(a));
        try write(a, init.io, args[3], "client.crt", cert);
        try write(a, init.io, args[3], "ca.crt", try read(a, init.io, args[2], "ca.crt"));
    } else if (args.len == 6 and std.mem.eql(u8, args[1], "endpoint")) {
        const port = try std.fmt.parseInt(u16, args[4], 10);
        if (port == 0) return error.InvalidFixture;
        var fd: c_int = -1;
        const result = dragontools_connect(try a.dupeZ(u8, args[2]), try a.dupeZ(u8, args[4]), &fd);
        if (result == 91) return error.DnsUnresolved;
        if (result != 0) return error.TcpUnreachable;
        defer _ = std.c.close(fd);
        defer dragontools_network_cancel();
        try @import("pki/tls.zig").health(a, fd, try read(a, init.io, args[3], "ca.crt"), try read(a, init.io, args[3], "client.crt"), try read(a, init.io, args[3], "client.key"), args[2], args[5], now);
    } else return error.InvalidFixture;
}
