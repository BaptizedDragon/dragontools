const std = @import("std");
const remote = @import("remote.zig");
const Options = @import("../cli/parse.zig").Options;
pub const Elevation = enum { root, login_user };
pub const Ssh = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    elevation: Elevation = .root,
    pub fn asRemote(self: *Ssh) remote.Remote {
        return .{ .context = self, .execute = execute };
    }
    pub fn argv(self: *Ssh, command: []const u8) ![]const []const u8 {
        const a = self.allocator;
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "ssh");
        // Direct mode keeps the original isolated configuration. Alias mode
        // deliberately delegates resolution to OpenSSH, including jump hosts and
        // agent paths containing spaces. DragonTools never parses that config.
        if (self.options.ssh_host == null) try args.appendSlice(a, &.{ "-F", "/dev/null" });
        try args.appendSlice(a, &.{ "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes" });
        if (self.options.ssh_host == null) {
            try args.appendSlice(a, &.{ "-p", try std.fmt.allocPrint(a, "{d}", .{self.options.port}), "-l", self.options.user });
            if (self.options.ssh_sock) |sock| try args.appendSlice(a, &.{ "-o", try std.fmt.allocPrint(a, "IdentityAgent={s}", .{sock}) });
            if (self.options.identity) |identity| try args.appendSlice(a, &.{ "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-i", identity });
        }
        const cmd = if (self.elevation == .login_user)
            command
        else if (self.options.ssh_host != null)
            // The login UID is unknown locally in alias mode. Determine it on
            // the host before choosing the concrete root execution path.
            try std.fmt.allocPrint(a, "if [ \"$(id -u)\" -eq 0 ]; then {s}; else {s}; fi", .{
                try remote.shell(a, &.{ "sh", "-c", command }),
                try remote.shell(a, &.{ "sudo", "-n", "--", "sh", "-c", command }),
            })
        else if (std.mem.eql(u8, self.options.user, "root"))
            command
        else
            try remote.shell(a, &.{ "sudo", "-n", "--", "sh", "-c", command });
        try args.appendSlice(a, &.{ "--", self.options.ssh_host orelse self.options.host, cmd });
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
    try std.testing.expect(std.mem.indexOf(u8, joined, "-F /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-p 22 -l ops") != null);
}

test "SSH alias uses native config and retains strict trust without connection overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ssh: Ssh = .{ .allocator = arena.allocator(), .io = std.testing.io, .options = .{ .ssh_host = "monitoring" }, .elevation = .login_user };
    const command = "id -un";
    const args = try ssh.argv(command);
    try std.testing.expectEqualStrings("monitoring", args[args.len - 2]);
    try std.testing.expectEqualStrings(command, args[args.len - 1]);
    for (args) |arg| {
        for ([_][]const u8{ "-F", "-l", "-p", "-i", "IdentitiesOnly=yes", "IdentityAgent=none" }) |excluded| {
            try std.testing.expect(!std.mem.eql(u8, arg, excluded));
        }
    }
    const joined = try std.mem.join(arena.allocator(), " ", args);
    try std.testing.expect(std.mem.indexOf(u8, joined, "StrictHostKeyChecking=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "sudo") == null);
}

test "host direct SSH mode preserves the actual login user without automatic sudo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ssh: Ssh = .{ .allocator = arena.allocator(), .io = std.testing.io, .options = .{ .host = "monitoring.example.com", .user = "ops", .ssh_sock = "/tmp/agent.sock", .port = 2222 }, .elevation = .login_user };
    const args = try ssh.argv("id -un");
    const joined = try std.mem.join(arena.allocator(), " ", args);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-F /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-p 2222 -l ops") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "IdentityAgent=/tmp/agent.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "sudo") == null);
    try std.testing.expectEqualStrings("id -un", args[args.len - 1]);
}
