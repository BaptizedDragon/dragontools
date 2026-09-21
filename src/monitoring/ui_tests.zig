const std = @import("std");
const ui = @import("ui.zig");
test "UI endpoints use their owned ports and pinned native paths" {
    const Case = struct { command: @import("../cli/spec.zig").Command, port: u16, path: []const u8 };
    for ([_]Case{
        .{ .command = .ui_metrics, .port = 8428, .path = "/vmui/" },
        .{ .command = .ui_logs, .port = 9428, .path = "/select/vmui/" },
        .{ .command = .ui_traces, .port = 10428, .path = "/select/vmui/" },
        .{ .command = .ui_grafana, .port = 3000, .path = "/" },
        .{ .command = .ui_alerts, .port = 8881, .path = "/vmalert/groups" },
        .{ .command = .ui_log_alerts, .port = 8880, .path = "/vmalert/groups" },
        .{ .command = .ui_alertmanager, .port = 9093, .path = "/" },
    }) |case| {
        const value = ui.endpoint(case.command);
        try std.testing.expectEqual(case.port, value.port);
        try std.testing.expectEqualStrings(case.path, value.path);
        const url = try ui.url(std.testing.allocator, value, 49173);
        defer std.testing.allocator.free(url);
        try std.testing.expect(std.mem.startsWith(u8, url, "http://127.0.0.1:49173/"));
        try std.testing.expect(std.mem.endsWith(u8, url, case.path));
    }
}
test "UI browser opener selection requires no GUI" {
    try std.testing.expectEqualStrings("open", ui.opener(.macos).?);
    try std.testing.expectEqualStrings("xdg-open", ui.opener(.linux).?);
    try std.testing.expect(ui.opener(.windows) == null);
}

test "UI unsupported browser platform keeps a manual URL without launching a process" {
    const notice = try ui.openBrowser(std.testing.allocator, std.testing.io, ui.opener(.windows), "http://127.0.0.1:49173/vmui/");
    defer std.testing.allocator.free(notice);
    try std.testing.expect(std.mem.indexOf(u8, notice, "Open manually:\n  http://127.0.0.1:49173/vmui/") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "Tunnel remains active.") != null);
}

test "UI prefers a free loopback port and falls back while preserving an occupied listener" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    const preferred = server.socket.address.getPort();
    const fallback = try ui.choosePort(io, preferred);
    try std.testing.expect(fallback != 0 and fallback != preferred);
    // The original listener remains alive.
    const client = try server.socket.address.connect(io, .{ .mode = .stream });
    client.close(io);
    server.deinit(io);
    try std.testing.expectEqual(preferred, try ui.choosePort(io, preferred));
}

test "UI SSH argv preserves connection policy and acknowledges one localhost forward without a shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ssh: @import("../system/ssh.zig").Ssh = .{ .allocator = a, .io = std.testing.io, .options = .{ .command = .ui_logs, .ssh_host = "station-alias" } };
    const args = try ssh.tunnelArgv("/tmp/private-ui/ssh");
    try std.testing.expectEqualStrings("station-alias", args[args.len - 1]);
    const joined = try std.mem.join(a, " ", args);
    for ([_][]const u8{ "BatchMode=yes", "StrictHostKeyChecking=yes", "ClearAllForwardings=yes", "ControlPersist=no", "ControlMaster=yes", "ForkAfterAuthentication=no", "GatewayPorts=no", "-N", "-S /tmp/private-ui/ssh" }) |required| try std.testing.expect(std.mem.indexOf(u8, joined, required) != null);
    for (args) |arg| for ([_][]const u8{ "sh", "-c", "sudo", "-F", "-l", "-p", "-i", "IdentityAgent=none", "StrictHostKeyChecking=no", "-f" }) |forbidden| try std.testing.expect(!std.mem.eql(u8, arg, forbidden));
    const forward = try ui.controlArgv(a, "/tmp/private-ui/ssh", "station-alias", .{ .local = 49173, .remote = ui.endpoint(.ui_logs).port });
    try std.testing.expectEqualStrings("127.0.0.1:49173:127.0.0.1:9428", forward[forward.len - 3]);
    try std.testing.expectEqualStrings("station-alias", forward[forward.len - 1]);
    try std.testing.expectEqualStrings("--", forward[forward.len - 2]);
    ssh.options = .{ .command = .ui_metrics, .host = "127.0.0.1", .user = "operator", .port = 2222, .identity = "/tmp/key" };
    const direct = try std.mem.join(a, " ", try ssh.tunnelArgv("/tmp/private-ui/ssh"));
    for ([_][]const u8{ "-F /dev/null", "-l operator", "-p 2222", "-i /tmp/key", "StrictHostKeyChecking=yes" }) |required| try std.testing.expect(std.mem.indexOf(u8, direct, required) != null);
}
