const std = @import("std");
const remote = @import("remote.zig");
const Options = @import("../cli/parse.zig").Options;
pub const Ssh = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    pub fn asRemote(self: *Ssh) remote.Remote {
        return .{ .context = self, .execute = execute };
    }
    pub fn argv(self: *Ssh, command: []const u8) ![]const []const u8 {
        const a = self.allocator;
        var args: std.ArrayList([]const u8) = .empty;
        // Ignore local SSH config: it can contain ProxyCommand, forwards or weaker trust settings.
        try args.appendSlice(a, &.{ "ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-p", try std.fmt.allocPrint(a, "{d}", .{self.options.port}), "-l", self.options.user });
        if (self.options.ssh_sock) |sock| try args.appendSlice(a, &.{ "-o", try std.fmt.allocPrint(a, "IdentityAgent={s}", .{sock}) });
        if (self.options.identity) |identity| try args.appendSlice(a, &.{ "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-i", identity });
        const cmd = if (std.mem.eql(u8, self.options.user, "root")) command else try remote.shell(a, &.{ "sudo", "-n", "--", "sh", "-c", command });
        try args.appendSlice(a, &.{ "--", self.options.host, cmd });
        return args.toOwnedSlice(a);
    }
    fn execute(ctx: *anyopaque, _: remote.Operation, command: []const u8) !remote.Result {
        const self: *Ssh = @ptrCast(@alignCast(ctx));
        const result = try std.process.run(self.allocator, self.io, .{ .argv = try self.argv(command), .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(64 * 1024) });
        defer {
            std.crypto.secureZero(u8, result.stderr);
            self.allocator.free(result.stderr);
        }
        return .{ .code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        }, .output = result.stdout };
    }
};
test "SSH strict trust and identity options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ssh: Ssh = .{ .allocator = arena.allocator(), .io = std.testing.io, .options = .{ .host = "host", .identity = "/tmp/key", .user = "ops" } };
    const args = try ssh.argv("id -u");
    const joined = try std.mem.join(arena.allocator(), " ", args);
    try std.testing.expect(std.mem.indexOf(u8, joined, "StrictHostKeyChecking=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "IdentityAgent=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "'sudo' '-n'") != null);
}
