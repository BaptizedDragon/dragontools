const std = @import("std");
pub const Command = enum { install, verify, status, agents_install, agents_verify, agents_status, firewall };
pub const Options = struct {
    command: Command = .install,
    help: bool = false,
    plan: bool = false,
    host: []const u8 = "",
    user: []const u8 = "root",
    port: u16 = 22,
    ssh_sock: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    ssh_op_path: ?[]const u8 = null,
    station_ip: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    tls: ?[]const u8 = null,
    cloudflare_token_op: ?[]const u8 = null,
    telegram_token_op: ?[]const u8 = null,
    telegram_channel_id: ?[]const u8 = null,
    services: std.ArrayList([]const u8) = .empty,
    admin_ips: std.ArrayList([]const u8) = .empty,
    agent_ips: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Options, a: std.mem.Allocator) void {
        self.services.deinit(a);
        self.admin_ips.deinit(a);
        self.agent_ips.deinit(a);
    }
    pub fn unsupported(self: Options) bool {
        return self.command == .agents_install or self.command == .agents_verify or self.command == .agents_status or self.command == .firewall or
            self.ssh_op_path != null or self.station_ip != null or self.services.items.len > 0 or self.admin_ips.items.len > 0 or self.agent_ips.items.len > 0 or self.domain != null or self.tls != null or self.cloudflare_token_op != null or self.telegram_token_op != null or self.telegram_channel_id != null;
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn token(s: []const u8, extras: []const u8) bool {
    if (s.len == 0 or s.len > 253 or !std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, extras, c) == null) return false;
    return true;
}
fn path(s: []const u8) bool {
    if (s.len == 0 or s[0] != '/') return false;
    // OpenSSH expands '%' tokens and quotes in option values; reject those too.
    for (s) |c| if (c < 33 or c > 126 or c == '%' or c == '"' or c == '\'' or c == '\\') return false;
    return true;
}
fn ip(s: []const u8) bool {
    _ = std.Io.net.IpAddress.parse(s, 0) catch return false;
    return true;
}
fn reference(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "op://") or s.len <= 5) return false;
    for (s) |c| if (c < 32 or c == 127) return false;
    return true;
}
pub fn parse(a: std.mem.Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    errdefer o.deinit(a);
    if (args.len == 0 or (args.len == 1 and eq(args[0], "--help"))) {
        o.help = true;
        return o;
    }
    if (!eq(args[0], "monitoring")) return error.UnknownCommand;
    if (args.len == 1 or eq(args[1], "--help")) {
        o.help = true;
        return o;
    }
    var i: usize = 2;
    if (eq(args[1], "agents")) {
        if (args.len == 2 or eq(args[2], "--help")) {
            o.help = true;
            return o;
        }
        o.command = if (eq(args[2], "install")) .agents_install else if (eq(args[2], "verify")) .agents_verify else if (eq(args[2], "status")) .agents_status else return error.UnknownCommand;
        i = 3;
    } else {
        o.command = if (eq(args[1], "install")) .install else if (eq(args[1], "verify")) .verify else if (eq(args[1], "status")) .status else if (eq(args[1], "firewall")) .firewall else return error.UnknownCommand;
    }
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    while (i < args.len) : (i += 1) {
        const key = args[i];
        if (eq(key, "--help")) {
            o.help = true;
            continue;
        }
        if (eq(key, "--plan")) {
            o.plan = true;
            continue;
        }
        if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) return error.MissingValue;
        const value = args[i + 1];
        i += 1;
        if (!eq(key, "--service") and !eq(key, "--admin-ip") and !eq(key, "--agent-ip")) {
            if (seen.contains(key)) return error.DuplicateFlag;
            try seen.put(key, {});
        }
        if (eq(key, "--host")) {
            if (!token(value, ".-:")) return error.InvalidHost;
            o.host = value;
        } else if (eq(key, "--user")) {
            if (!token(value, "_-")) return error.InvalidUser;
            o.user = value;
        } else if (eq(key, "--port")) {
            o.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
            if (o.port == 0) return error.InvalidPort;
        } else if (eq(key, "--ssh-sock")) {
            if (!path(value)) return error.InvalidPath;
            o.ssh_sock = value;
        } else if (eq(key, "--identity")) {
            if (!path(value)) return error.InvalidPath;
            o.identity = value;
        } else if (eq(key, "--ssh-op-path")) {
            if (!reference(value)) return error.InvalidReference;
            o.ssh_op_path = value;
        } else if (eq(key, "--service")) {
            if (!token(value, "_.@:-") or !std.mem.endsWith(u8, value, ".service")) return error.InvalidService;
            try o.services.append(a, value);
        } else if (eq(key, "--admin-ip")) {
            if (!ip(value)) return error.InvalidIP;
            try o.admin_ips.append(a, value);
        } else if (eq(key, "--agent-ip")) {
            if (!ip(value)) return error.InvalidIP;
            try o.agent_ips.append(a, value);
        } else if (eq(key, "--station-ip")) {
            if (!ip(value)) return error.InvalidIP;
            o.station_ip = value;
        } else if (eq(key, "--domain")) {
            if (!token(value, ".-")) return error.InvalidDomain;
            o.domain = value;
        } else if (eq(key, "--tls")) {
            if (!eq(value, "manual") and !eq(value, "cloudflare")) return error.InvalidTLS;
            o.tls = value;
        } else if (eq(key, "--cloudflare-token-op")) {
            if (!reference(value)) return error.InvalidReference;
            o.cloudflare_token_op = value;
        } else if (eq(key, "--telegram-bot-token-op")) {
            if (!reference(value)) return error.InvalidReference;
            o.telegram_token_op = value;
        } else if (eq(key, "--telegram-channel-id")) {
            _ = std.fmt.parseInt(i64, value, 10) catch return error.InvalidChatID;
            o.telegram_channel_id = value;
        } else return error.UnknownFlag;
    }
    if (!o.help and o.host.len == 0) return error.HostRequired;
    const modes: u8 = @intFromBool(o.ssh_sock != null) + @as(u8, @intFromBool(o.identity != null)) + @as(u8, @intFromBool(o.ssh_op_path != null));
    if (modes > 1) return error.ConflictingAuthentication;
    if (o.plan and o.command != .install and o.command != .agents_install and o.command != .firewall) return error.InvalidPlanCommand;
    return o;
}

test "CLI hierarchy, repeated services, and rejected injection" {
    const a = std.testing.allocator;
    var o = try parse(a, &.{ "monitoring", "agents", "install", "--host", "app01.example.com", "--service", "one.service", "--service", "two.service" });
    defer o.deinit(a);
    try std.testing.expectEqual(Command.agents_install, o.command);
    try std.testing.expectEqual(@as(usize, 2), o.services.items.len);
    try std.testing.expectError(error.InvalidHost, parse(a, &.{ "monitoring", "install", "--host", "x;id" }));
    try std.testing.expectError(error.InvalidHost, parse(a, &.{ "monitoring", "install", "--host", "-oProxyCommand=x" }));
    try std.testing.expectError(error.UnknownCommand, parse(a, &.{ "user", "create" }));
    try std.testing.expectError(error.ConflictingAuthentication, parse(a, &.{ "monitoring", "install", "--host", "x", "--ssh-sock", "/tmp/sock", "--identity", "/tmp/key" }));
    try std.testing.expectError(error.InvalidIP, parse(a, &.{ "monitoring", "firewall", "--host", "x", "--admin-ip", "999.1.1.1" }));
    try std.testing.expectError(error.DuplicateFlag, parse(a, &.{ "monitoring", "install", "--host", "x", "--host", "y" }));
}
