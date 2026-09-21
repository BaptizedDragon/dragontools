//! Attached UI access only. No station mutation, credentials or background daemon.
const std = @import("std");
const builtin = @import("builtin");
const spec = @import("../cli/spec.zig");
const Options = @import("../cli/parse.zig").Options;
const Ssh = @import("../system/ssh.zig").Ssh;
const vm = @import("../components/victoriametrics.zig");
const vl = @import("../components/victorialogs.zig");
const vt = @import("../components/victoriatraces.zig");
const gf = @import("../components/grafana.zig");
const vmalert = @import("../components/vmalert.zig");
const alertmanager = @import("../components/alertmanager.zig");
pub const Endpoint = struct { title: []const u8, port: u16, path: []const u8 };
pub fn endpoint(command: spec.Command) Endpoint {
    return switch (command) {
        .ui_metrics => .{ .title = "VictoriaMetrics VMUI", .port = vm.port, .path = vm.ui_path },
        .ui_logs => .{ .title = "VictoriaLogs VMUI", .port = vl.port, .path = vl.ui_path },
        .ui_traces => .{ .title = "VictoriaTraces VMUI", .port = vt.port, .path = vt.ui_path },
        .ui_grafana => .{ .title = "Grafana", .port = gf.port, .path = gf.ui_path },
        .ui_alerts => .{ .title = "Metrics/probe/host alert evaluation", .port = vmalert.port(.metrics), .path = vmalert.ui_path },
        .ui_log_alerts => .{ .title = "Log alert evaluation", .port = vmalert.port(.logs), .path = vmalert.ui_path },
        .ui_alertmanager => .{ .title = "Alertmanager", .port = alertmanager.port, .path = alertmanager.ui_path },
        else => unreachable,
    };
}
pub fn url(a: std.mem.Allocator, target: Endpoint, port: u16) ![]const u8 {
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, target.path });
}
pub fn opener(os: std.Target.Os.Tag) ?[]const u8 {
    return switch (os) {
        .macos => "open",
        .linux => "xdg-open",
        else => null,
    };
}

/// Probe with exclusive bind; an occupied listener is never contacted or killed.
/// OpenSSH's subsequent forward acknowledgement closes the release/bind race.
pub fn choosePort(io: std.Io, preferred: u16) !u16 {
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(preferred) };
    var listener = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => fallback: {
            address = .{ .ip4 = .loopback(0) };
            break :fallback try address.listen(io, .{});
        },
        else => return err,
    };
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

/// Only local mux requests use isolated config. They cannot fall back to a new
/// SSH connection: -O requires the private socket of our attached child.
pub fn controlArgv(a: std.mem.Allocator, control: []const u8, host: []const u8, forward: ?struct { local: u16, remote: u16 }) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "ssh", "-F", "/dev/null", "-S", control, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ControlMaster=no", "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes", "-O", if (forward == null) "check" else "forward" });
    if (forward) |ports| try args.appendSlice(a, &.{ "-L", try std.fmt.allocPrint(a, "127.0.0.1:{d}:127.0.0.1:{d}", .{ ports.local, ports.remote }) });
    try args.appendSlice(a, &.{ "--", host });
    return args.toOwnedSlice(a);
}

var interrupted: std.atomic.Value(bool) = .init(false);
fn interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}
fn checkInterrupt() !void {
    if (interrupted.load(.acquire)) return error.UiInterrupted;
}
fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}
fn pause(io: std.Io, ms: u32) !void {
    try std.Io.sleep(io, .fromMilliseconds(ms), .awake);
}

// A small POSIX child owner: std.process spawning, nonblocking waitpid for prompt
// Ctrl-C even during authentication, and bounded TERM/KILL/reap cleanup. No pipes,
// PID files, detached children or globally shared SSH masters are owned here.
const Process = struct {
    child: std.process.Child,
    fn start(io: std.Io, argv: []const []const u8) !Process {
        return .{ .child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 }) };
    }
    fn poll(self: *Process) !?u8 {
        const pid = self.child.id orelse return error.UiProcessAlreadyReaped;
        var status: c_int = 0;
        const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (result == 0) return null;
        if (result == -1) {
            if (std.posix.errno(result) == .INTR) return null;
            return error.UiProcessWaitFailed;
        }
        self.child.id = null;
        const value: u32 = @bitCast(status);
        return if (std.c.W.IFEXITED(value)) std.c.W.EXITSTATUS(value) else 255;
    }
    fn close(self: *Process, io: std.Io) void {
        const pid = self.child.id orelse return;
        // The unreaped child pins this process group ID. Include ProxyJump
        // children during cleanup, but never signal a shared user SSH process.
        std.posix.kill(-pid, .TERM) catch {};
        const deadline = now(io) + 1000;
        while (now(io) < deadline) {
            if (self.poll() catch break) |_| return;
            pause(io, 25) catch break;
        }
        std.posix.kill(-pid, .KILL) catch {};
        self.child.kill(io);
    }
};
fn quietRun(io: std.Io, argv: []const []const u8, budget: u32) !bool {
    try checkInterrupt();
    var child = try Process.start(io, argv);
    defer child.close(io);
    const deadline = now(io) + budget;
    while (true) {
        try checkInterrupt();
        if (try child.poll()) |code| return code == 0;
        if (now(io) >= deadline) return error.UiProcessTimedOut;
        try pause(io, 25);
    }
}

/// A missing platform opener is the same nonfatal manual-URL fallback as a
/// failed launcher. The explicit program also permits tests without a GUI.
pub fn openBrowser(a: std.mem.Allocator, io: std.Io, program: ?[]const u8, local_url: []const u8) ![]const u8 {
    const opened = if (program) |name| quietRun(io, &.{ name, local_url }, 5000) catch |err| switch (err) {
        error.UiInterrupted => return err,
        else => false,
    } else false;
    return if (opened)
        try a.dupe(u8, "Browser opened.\n")
    else
        try std.fmt.allocPrint(a, "Browser could not be opened automatically.\n\nOpen manually:\n  {s}\n\nTunnel remains active.\n", .{local_url});
}

fn httpReady(io: std.Io, port: u16, path: []const u8, done: *std.Io.Event) !void {
    defer done.set(io);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    // Zig 0.16's POSIX connect timeout option is unimplemented. The enclosing
    // cancellable task bounds connect, write and read together on every attempt.
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ path, port });
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    var response_buffer: [2048]u8 = undefined;
    var reader = stream.reader(io, &response_buffer);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    if (line.len < 13 or !(std.mem.startsWith(u8, line, "HTTP/1.1 ") or std.mem.startsWith(u8, line, "HTTP/1.0 "))) return error.UiUnavailable;
    const status = std.fmt.parseInt(u16, line[9..12], 10) catch return error.UiUnavailable;
    // Grafana redirects to its login page; never authenticate or follow a redirect.
    if (status < 200 or status >= 400 or line[12] != ' ') return error.UiUnavailable;
}
fn httpAttempt(io: std.Io, port: u16, path: []const u8, master: *Process, deadline: i64) !void {
    var done: std.Io.Event = .unset;
    var task = try io.concurrent(httpReady, .{ io, port, path, &done });
    defer _ = task.cancel(io) catch {};
    while (!done.isSet()) {
        try checkInterrupt();
        if (try master.poll()) |_| return error.UiTunnelClosed;
        if (now(io) >= deadline) return error.UiUnavailable;
        try pause(io, 25);
    }
    task.await(io) catch return error.UiUnavailable;
}

fn verifyHttp(io: std.Io, port: u16, path: []const u8, master: *Process) !void {
    const deadline = now(io) + 10000;
    var retry_ms: u32 = 150;
    while (true) {
        try checkInterrupt();
        if (try master.poll()) |_| return error.UiTunnelClosed;
        if (now(io) >= deadline) return error.UiUnavailable;
        httpAttempt(io, port, path, master, @min(deadline, now(io) + 2000)) catch |err| switch (err) {
            error.UiUnavailable => {
                const remaining = deadline - now(io);
                if (remaining <= 0) return error.UiUnavailable;
                // Delay only after a failed check; the whole sequence is bounded.
                try pause(io, @intCast(@min(remaining, retry_ms)));
                retry_ms = 500;
                continue;
            },
            else => return err,
        };
        try checkInterrupt();
        if (try master.poll()) |_| return error.UiTunnelClosed;
        return;
    }
}

fn session(a: std.mem.Allocator, io: std.Io, options: Options) !void {
    const target = endpoint(options.command);
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const directory = try std.fmt.allocPrint(a, "/tmp/dragontools-ui-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.createDirAbsolute(io, directory, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const control = try std.fmt.allocPrint(a, "{s}/ssh", .{directory});
    var ssh: Ssh = .{ .allocator = a, .io = io, .options = options, .elevation = .login_user };
    var master = Process.start(io, try ssh.tunnelArgv(control)) catch return error.UiSshUnavailable;
    defer master.close(io);
    const host = options.ssh_host orelse options.host;
    const check = try controlArgv(a, control, host, null);
    const deadline = now(io) + 30000;
    while (true) {
        try checkInterrupt();
        if (try master.poll()) |_| return error.UiSshUnavailable;
        if (try quietRun(io, check, 2000)) break;
        if (now(io) >= deadline) return error.UiSshUnavailable;
        try pause(io, 100);
    }
    var port = try choosePort(io, target.port);
    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        if (attempts == 4) return error.UiForwardFailed;
        if (try quietRun(io, try controlArgv(a, control, host, .{ .local = port, .remote = target.port }), 2000)) break;
        // Retry only a demonstrated bind race, not a denied forwarding policy.
        const next = try choosePort(io, port);
        if (next == port) return error.UiForwardFailed;
        port = next;
    }
    try verifyHttp(io, port, target.path, &master);
    const local_url = try url(a, target, port);
    const message = try std.fmt.allocPrint(a, "{s}\n\nSSH host:\n  {s}\n\nTunnel:\n  127.0.0.1:{d} -> station 127.0.0.1:{d}\n\nOpen:\n  {s}\n\n", .{ target.title, host, port, target.port, local_url });
    try std.Io.File.stdout().writeStreamingAll(io, message);
    if (options.open_browser) {
        const notice = try openBrowser(a, io, opener(builtin.os.tag), local_url);
        defer a.free(notice);
        try std.Io.File.stdout().writeStreamingAll(io, notice);
    }
    try std.Io.File.stdout().writeStreamingAll(io, "Press Ctrl-C to close.\n");
    while (true) {
        try checkInterrupt();
        if (try master.poll()) |_| return error.UiTunnelClosed;
        try pause(io, 100);
    }
}

pub fn run(a: std.mem.Allocator, io: std.Io, options: Options) !void {
    interrupted.store(false, .release);
    var previous_int: std.posix.Sigaction = undefined;
    var previous_term: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, &previous_int);
    defer std.posix.sigaction(.INT, &previous_int, null);
    std.posix.sigaction(.TERM, &action, &previous_term);
    defer std.posix.sigaction(.TERM, &previous_term, null);
    session(a, io, options) catch |err| {
        if (err == error.UiInterrupted) {
            try std.Io.File.stdout().writeStreamingAll(io, "\nTunnel closed.\n");
            return;
        }
        const message = if (err == error.UiUnavailable)
            try std.fmt.allocPrint(a, "{s} is not available on the monitoring station.\nRun: dragontool monitoring verify (with the same station configuration).\n", .{endpoint(options.command).title})
        else if (err == error.UiSshUnavailable)
            "Unable to establish the station SSH session. Check the configured SSH connection, authentication and known host key.\n"
        else if (err == error.UiForwardFailed)
            "Unable to open the localhost forward. Check station SSH forwarding policy.\n"
        else if (err == error.UiTunnelClosed)
            "The station SSH tunnel closed. Rerun the same UI command to reconnect.\n"
        else
            "Unable to open the station UI tunnel.\n";
        std.Io.File.stderr().writeStreamingAll(io, message) catch {};
        return err;
    };
}

test {
    _ = @import("ui_tests.zig");
}
