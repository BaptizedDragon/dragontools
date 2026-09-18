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
        return .{ .context = self, .execute = execute, .execute_timed = executeTimed, .execute_secret = executeSecret, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
    }
    fn nowMs(ctx: *anyopaque) i64 {
        const self: *Ssh = @ptrCast(@alignCast(ctx));
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
    fn sleepMs(ctx: *anyopaque, milliseconds: u32) !void {
        const self: *Ssh = @ptrCast(@alignCast(ctx));
        try std.Io.sleep(self.io, .fromMilliseconds(milliseconds), .awake);
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
        const agent_command = self.options.command == .agents_install or self.options.command == .agents_verify or self.options.command == .agents_status;
        const transport_command = if (agent_command and command.len > 8192) try compactAgentCommand(a, command) else command;
        const cmd = if (self.elevation == .login_user)
            transport_command
        else if (self.options.ssh_host != null)
            // The login UID is unknown locally in alias mode. Determine it on
            // the host before choosing the concrete root execution path. Keep
            // one command copy so bounded configuration payloads fit argv limits.
            try std.fmt.allocPrint(a, "if [ \"$(id -u)\" -eq 0 ]; then set --; else set -- sudo -n --; fi; \"$@\" {s}", .{
                try remote.shell(a, &.{ "sh", "-c", transport_command }),
            })
        else if (std.mem.eql(u8, self.options.user, "root"))
            transport_command
        else
            try remote.shell(a, &.{ "sudo", "-n", "--", "sh", "-c", transport_command });
        try args.appendSlice(a, &.{ "--", self.options.ssh_host orelse self.options.host, cmd });
        return args.toOwnedSlice(a);
    }
    fn execute(ctx: *anyopaque, _: remote.Operation, command: []const u8) !remote.Result {
        return executeWithTimeout(ctx, command, .none);
    }
    fn executeSecret(ctx: *anyopaque, _: remote.Operation, command: []const u8, payload: *const @import("../secrets/secret.zig").Secret, budget_ms: u32) !remote.Result {
        const self: *Ssh = @ptrCast(@alignCast(ctx));
        const result = try @import("../secrets/process.zig").run(std.heap.page_allocator, self.io, try self.argv(command), payload, 128, budget_ms);
        defer result.deinit();
        // Only fixed protocol tokens leave the sensitive capture boundary.
        if (result.code != 0) return .{ .code = result.code };
        for ([_][]const u8{ "changed", "unchanged" }) |token| {
            if (std.mem.eql(u8, result.output.protectedBytes(), token)) return .{ .code = 0, .output = token };
        }
        return error.InvalidCredentialResponse;
    }
    fn executeTimed(ctx: *anyopaque, _: remote.Operation, command: []const u8, budget_ms: u32) !remote.Result {
        const self: *Ssh = @ptrCast(@alignCast(ctx));
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } };
        return executeWithTimeout(ctx, command, timeout.toDeadline(self.io));
    }
    fn executeWithTimeout(ctx: *anyopaque, command: []const u8, timeout: std.Io.Timeout) !remote.Result {
        const self: *Ssh = @ptrCast(@alignCast(ctx));
        const result = try std.process.run(self.allocator, self.io, .{ .argv = try self.argv(command), .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = timeout });
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

/// Agent configuration can contain 64 service selectors/targets. Compress the
/// already quoted non-secret command to stay below SSH/kernel argument limits.
/// The protected stdin stream is inherited unchanged by exec (never encoded).
fn compactAgentCommand(a: std.mem.Allocator, command: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    defer out.deinit();
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &buffer, .zlib, .default);
    try compress.writer.writeAll(command);
    try compress.finish();
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(out.written().len));
    defer a.free(encoded);
    _ = encoder.encode(encoded, out.written());
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", "import base64,os,sys,zlib; os.execl('/bin/sh','sh','-c',zlib.decompress(base64.b64decode(sys.argv[1],validate=True)).decode())", encoded });
}
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

test "monitoring SSH alias elevates by actual remote UID and preserves strict authentication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The default local user field must not imply that a native alias logs in as root.
    var ssh: Ssh = .{ .allocator = a, .io = std.testing.io, .options = .{ .ssh_host = "monitoring", .user = "root" } };
    const payload = "literal apostrophe ' and $(not-a-command)";
    const args = try ssh.argv(try remote.shell(a, &.{ "printf", "%s", payload }));
    try std.testing.expectEqualStrings("monitoring", args[args.len - 2]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, args[args.len - 1], "$(not-a-command)"));
    for ([_][]const u8{ "StrictHostKeyChecking=yes", "BatchMode=yes", "ForwardAgent=no", "ClearAllForwardings=yes" }) |required| {
        var present = false;
        for (args) |arg| if (std.mem.eql(u8, required, arg)) {
            present = true;
        };
        try std.testing.expect(present);
    }
    for (args) |arg| {
        for ([_][]const u8{ "-F", "-l", "-p", "-i", "IdentityAgent=none", "IdentitiesOnly=yes" }) |excluded| {
            try std.testing.expect(!std.mem.eql(u8, arg, excluded));
        }
    }
    // Execute only the rendered remote wrapper locally. UID/sudo are fixtures;
    // no SSH connection, privilege change, filesystem write or real sudo occurs.
    const sudo_fixture =
        \\sudo() {
        \\  test "$1" = -n && test "$2" = -- || return 91
        \\  shift 2
        \\  printf 'sudo\n'
        \\  "$@"
        \\}
        \\
    ;
    for ([_]u32{ 0, 1001 }) |uid| {
        const script = try std.fmt.allocPrint(
            a,
            "id() {{ test \"$#\" = 1 && test \"$1\" = -u || return 91; printf '%s' '{d}'; }}\n{s}\n{s}",
            .{ uid, sudo_fixture, args[args.len - 1] },
        );
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", "inherited-argument" } });
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(if (uid == 0) payload else "sudo\n" ++ payload, result.stdout);
    }
    const denied = try std.fmt.allocPrint(a, "id() {{ printf 1001; }}\nsudo() {{ return 77; }}\n{s}", .{args[args.len - 1]});
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", denied } });
    try std.testing.expectEqual(@as(u8, 77), result.term.exited);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "compressed agent commands retain literal arguments and protected stdin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Quotes expand fourfold before transport. Keep the decoded sh -c argument
    // below Linux's 128 KiB limit while still exceeding the compression threshold.
    const value = try a.alloc(u8, 16384);
    @memset(value, '\'');
    const command = try remote.shell(a, &.{ "printf", "%s", value });
    const encoded = try compactAgentCommand(a, command);
    try std.testing.expect(encoded.len < 8192);
    const output = try std.process.run(a, std.testing.io, .{ .argv = &.{ "sh", "-c", encoded } });
    try std.testing.expectEqual(@as(u8, 0), output.term.exited);
    try std.testing.expectEqualStrings("", output.stderr);
    try std.testing.expectEqualStrings(value, output.stdout);
    const payload = try @import("../secrets/secret.zig").Secret.init(std.testing.allocator, "PRIVATE-STDIN-FIXTURE");
    defer payload.deinit();
    const copy = try compactAgentCommand(a, "python3 -I -B -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())'");
    const captured = try @import("../secrets/process.zig").run(std.testing.allocator, std.testing.io, &.{ "sh", "-c", copy }, payload, 128, 5000);
    defer captured.deinit();
    try std.testing.expectEqual(@as(u8, 0), captured.code);
    try std.testing.expectEqualStrings(payload.protectedBytes(), captured.output.protectedBytes());
}
