//! Dedicated bounded process I/O for sensitive stdout/stdin. Never logs stderr.
const std = @import("std");
const diagnostics = @import("../agent/diagnostics.zig");
const Secret = @import("secret.zig").Secret;

fn terminate(child: *std.process.Child, io: std.Io) void {
    // Child.kill uses SIGTERM on POSIX. A stalled provider can ignore it, so
    // force termination before its resource-owning kill/reap operation.
    if (child.id) |pid| switch (@import("builtin").os.tag) {
        .linux, .macos => std.posix.kill(pid, .KILL) catch {},
        else => {},
    };
    child.kill(io);
}

fn waitAndSignal(child: *std.process.Child, io: std.Io, done: *std.Io.Event) std.process.Child.WaitError!std.process.Child.Term {
    defer done.set(io);
    return child.wait(io);
}

fn waitBounded(child: *std.process.Child, io: std.Io, deadline: std.Io.Timeout) !std.process.Child.Term {
    const pid = child.id.?;
    var done: std.Io.Event = .unset;
    var future = try io.concurrent(waitAndSignal, .{ child, io, &done });
    defer {
        _ = future.cancel(io) catch {
            // A canceled Child.wait closes pipes and clears its id without
            // reaping the still-owned process. Restore only after joining the
            // task; the outer cleanup must terminate/reap it before returning.
            child.id = pid;
        };
    }
    while (true) {
        done.waitTimeout(io, deadline) catch |err| switch (err) {
            error.Timeout => {
                // Event waits permit spurious wakeups; keep the original
                // deadline instead of treating one as process completion.
                if (deadline.toDurationFromNow(io).?.raw.toNanoseconds() > 0) continue;
                return error.Timeout;
            },
            else => return err,
        };
        if (deadline.toDurationFromNow(io).?.raw.toNanoseconds() <= 0) return error.Timeout;
        return future.await(io);
    }
}

pub const Result = struct {
    code: u8,
    output: *Secret,
    diagnostic: ?diagnostics.Diagnostic = null,
    pub fn deinit(self: Result) void {
        self.output.deinit();
    }
};
/// Fixed capture storage avoids reallocation copies and is wiped on every exit.
pub fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, input: ?*const Secret, limit: usize, budget_ms: u32) !Result {
    return runInternal(a, io, argv, input, limit, budget_ms, false);
}
/// Only the native helper protocol opts into strictly allowlisted diagnostics.
pub fn runAgent(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, input: ?*const Secret, limit: usize, budget_ms: u32) !Result {
    return runInternal(a, io, argv, input, limit, budget_ms, true);
}
const DiagnosticCapture = struct {
    value: ?diagnostics.Diagnostic = null,
    fn drain(self: *DiagnosticCapture, io: std.Io, file: std.Io.File, deadline: std.Io.Timeout) void {
        var message: [diagnostics.limit]u8 = undefined;
        var chunk: [1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &message);
        defer std.crypto.secureZero(u8, &chunk);
        var used: usize = 0;
        var overflow = false;
        while (true) {
            const result = io.operateTimeout(.{ .file_read_streaming = .{ .file = file, .data = &.{&chunk} } }, deadline) catch return;
            const count = result.file_read_streaming catch |err| switch (err) {
                error.EndOfStream => break,
                else => return,
            };
            if (count == 0) break;
            if (count > message.len - used) overflow = true;
            if (!overflow) {
                @memcpy(message[used..][0..count], chunk[0..count]);
                used += count;
            }
        }
        if (!overflow) self.value = diagnostics.parse(message[0..used]);
    }
};
fn runInternal(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, input: ?*const Secret, limit: usize, budget_ms: u32, agent_diagnostics: bool) !Result {
    const duration: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } };
    const deadline = duration.toDeadline(io);
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = if (input != null) .pipe else .ignore, .stdout = .pipe, .stderr = if (agent_diagnostics) .pipe else .ignore });
    defer terminate(&child, io);
    var capture: DiagnosticCapture = .{};
    // Drain concurrently with stdin/stdout, including oversized rejected stderr.
    var diagnostic_task: ?std.Io.Future(void) = if (agent_diagnostics) try io.concurrent(DiagnosticCapture.drain, .{ &capture, io, child.stderr.?, deadline }) else null;
    defer if (diagnostic_task) |*task| task.cancel(io);
    if (input) |secret| {
        const bytes = secret.protectedBytes();
        var sent: usize = 0;
        while (sent < bytes.len) {
            const result = try io.operateTimeout(.{ .file_write_streaming = .{ .file = child.stdin.?, .data = &.{bytes[sent..]} } }, deadline);
            const count = try result.file_write_streaming;
            if (count == 0) return error.SensitiveInputFailed;
            sent += count;
        }
        child.stdin.?.close(io);
        child.stdin = null;
    }
    const buffer = try a.alloc(u8, limit + 1);
    defer {
        std.crypto.secureZero(u8, buffer);
        a.free(buffer);
    }
    var used: usize = 0;
    while (true) {
        const result = try io.operateTimeout(.{ .file_read_streaming = .{ .file = child.stdout.?, .data = &.{buffer[used..]} } }, deadline);
        const count = result.file_read_streaming catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        used += count;
        if (used > limit) return error.SensitiveOutputTooLarge;
    }
    // Join before Child.wait closes its pipes. The drainer uses the same deadline.
    if (diagnostic_task) |*task| task.await(io);
    const term = try waitBounded(&child, io, deadline);
    return .{ .code = switch (term) {
        .exited => |code| code,
        else => 255,
    }, .output = try Secret.init(a, buffer[0..used]), .diagnostic = capture.value };
}
test "sensitive subprocess uses stdin and suppresses stderr" {
    const a = std.testing.allocator;
    const input = try Secret.init(a, "private-value\n\"'$(not-shell)\"");
    defer input.deinit();
    const result = try run(a, std.testing.io, &.{ "python3", "-I", "-B", "-c", "import sys; data=sys.stdin.buffer.read(); assert data not in repr(sys.argv).encode(); sys.stderr.write('discarded-secret-stderr'); sys.stdout.buffer.write(data)" }, input, 1024, 5000);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings(input.protectedBytes(), result.output.protectedBytes());
    const formatted = try std.fmt.allocPrint(a, "{any}", .{result});
    defer a.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "private-value") == null);
}
test "sensitive process limits and deadlines fail without exposing captured values" {
    try std.testing.expectError(error.SensitiveOutputTooLarge, run(std.testing.allocator, std.testing.io, &.{ "python3", "-I", "-B", "-c", "print('sentinel' * 100)" }, null, 32, 5000));
    try std.testing.expectError(error.Timeout, run(std.testing.allocator, std.testing.io, &.{ "python3", "-I", "-B", "-c", "import time; time.sleep(10)" }, null, 32, 50));
}

test "sensitive process deadline includes wait after stdout EOF and kills an unresponsive child" {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io).toMilliseconds();
    try std.testing.expectError(error.Timeout, run(std.testing.allocator, io, &.{
        "python3",                                                                                                                           "-I", "-B", "-c",
        "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(1,b'sensitive-result'); os.close(1); time.sleep(10)",
    }, null, 128, 500));
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - start;
    try std.testing.expect(elapsed < 5000);
}

test "native diagnostic transport accepts only fixed names and drains rejected stderr" {
    const a = std.testing.allocator;
    const prefix = "import sys; sys.stderr.buffer.write(";
    const suffix = "); sys.stderr.flush(); sys.stdout.write('public-result'); sys.exit(86)";
    const Case = struct { script: []const u8, accepted: bool };
    for ([_]Case{
        .{ .script = prefix ++ "b'AgentStage: ca_key_generation\\nAgentError: CryptoKeyGenerationFailed\\n'" ++ suffix, .accepted = true },
        .{ .script = prefix ++ "b'AgentStage: ca_key_generation\\nAgentError: CryptoKeyGenerationFailed\\nPRIVATE KEY sentinel'" ++ suffix, .accepted = false },
        .{ .script = prefix ++ "b'PRIVATE KEY sentinel' * 10000" ++ suffix, .accepted = false },
        .{ .script = prefix ++ "b'AgentStage: ca_key_generation\\nAgentError: PrivateKeyBytes\\n'" ++ suffix, .accepted = false },
    }) |case| {
        const result = try runAgent(a, std.testing.io, &.{ "python3", "-I", "-B", "-c", case.script }, null, 64, 5000);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 86), result.code);
        try std.testing.expectEqualStrings("public-result", result.output.protectedBytes());
        try std.testing.expectEqual(case.accepted, result.diagnostic != null);
        if (result.diagnostic) |diagnostic| try std.testing.expectEqual(diagnostics.AgentError.CryptoKeyGenerationFailed, diagnostic.reason);
        const formatted = try std.fmt.allocPrint(a, "{any}", .{result});
        defer a.free(formatted);
        try std.testing.expect(std.mem.indexOf(u8, formatted, "PRIVATE KEY") == null);
        try std.testing.expect(std.mem.indexOf(u8, formatted, "sentinel") == null);
    }
}
test "native diagnostic transport retains deadline and concurrent stdin stdout draining" {
    try std.testing.expectError(error.Timeout, runAgent(std.testing.allocator, std.testing.io, &.{ "python3", "-I", "-B", "-c", "import os,time; os.close(1); time.sleep(10)" }, null, 32, 100));
    const input = try Secret.init(std.testing.allocator, "public-input" ** 20000);
    defer input.deinit();
    const result = try runAgent(std.testing.allocator, std.testing.io, &.{ "python3", "-I", "-B", "-c", "import sys; sys.stderr.buffer.write(b'private-sentinel' * 20000); sys.stderr.flush(); sys.stdin.buffer.read(); sys.stdout.write('unchanged')" }, input, 32, 5000);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("unchanged", result.output.protectedBytes());
    try std.testing.expect(result.diagnostic == null);
}
