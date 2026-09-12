//! Thin terminal adapter; the wizard itself is tested with scripted input/output.
const std = @import("std");
const builtin = @import("builtin");
const wizard = @import("wizard.zig");

pub fn isInteractive(io: std.Io) !bool {
    return try std.Io.File.stdin().isTty(io) and try std.Io.File.stdout().isTty(io);
}
pub fn shouldWelcome(argument_count: usize, io: std.Io) !bool {
    if (argument_count != 0) return false;
    return useWelcome(argument_count, try std.Io.File.stdin().isTty(io), try std.Io.File.stdout().isTty(io));
}
pub fn useWelcome(argument_count: usize, stdin_tty: bool, stdout_tty: bool) bool {
    return argument_count == 0 and stdin_tty and stdout_tty;
}
const Terminal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: std.Io.File.Reader,

    fn readLine(context: *anyopaque) !?[]const u8 {
        const self: *Terminal = @ptrCast(@alignCast(context));
        while (true) {
            const line = self.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // Drain one oversized answer; never reinterpret its tail as a confirmation.
                    while (true) {
                        const byte = self.reader.interface.takeByte() catch |read_error| switch (read_error) {
                            error.EndOfStream => return null,
                            else => return read_error,
                        };
                        if (byte == '\n') break;
                    }
                    try write(context, "Input too long (maximum 4095 bytes). Enter the answer again: ");
                    continue;
                },
                else => return err,
            } orelse return null;
            return try self.allocator.dupe(u8, std.mem.trimEnd(u8, line, "\r"));
        }
    }
    fn write(context: *anyopaque, message: []const u8) !void {
        const self: *Terminal = @ptrCast(@alignCast(context));
        try std.Io.File.stdout().writeStreamingAll(self.io, message);
    }
};
fn interrupt(_: std.posix.SIG) callconv(.c) void {
    // Only async-signal-safe calls here. Canonical input/echo were never modified,
    // no deployment has begun, and no credential is held by this frontend.
    const message = "\nCancelled. No changes made.\n";
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, message.ptr, message.len);
    if (builtin.os.tag == .linux) std.os.linux.exit_group(130) else std.c._exit(130);
}
pub fn run(a: std.mem.Allocator, io: std.Io) !?[]const []const u8 {
    if (!try isInteractive(io)) return error.InteractiveTerminalRequired;
    var previous: std.posix.Sigaction = undefined;
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = interrupt },
        .mask = undefined,
        .flags = 0,
    };
    action.mask = std.posix.sigemptyset();
    std.posix.sigaction(.INT, &action, &previous);
    defer std.posix.sigaction(.INT, &previous, null);
    var buffer: [4096]u8 = undefined;
    var terminal: Terminal = .{ .allocator = a, .io = io, .reader = std.Io.File.stdin().readerStreaming(io, &buffer) };
    return wizard.run(a, .{ .context = &terminal, .readLine = Terminal.readLine, .write = Terminal.write });
}
test "no arguments starts welcome only when both streams are terminals" {
    try std.testing.expect(useWelcome(0, true, true));
    try std.testing.expect(!useWelcome(0, false, true));
    try std.testing.expect(!useWelcome(0, true, false));
    try std.testing.expect(!useWelcome(0, false, false));
    try std.testing.expect(!useWelcome(1, true, true));
}
