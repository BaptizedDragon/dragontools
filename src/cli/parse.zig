const std = @import("std");
const spec = @import("spec.zig");
pub const Command = spec.Command;
pub const Action = enum { monitoring, completion, wizard };
pub const Options = struct {
    command: Command = .install,
    action: Action = .monitoring,
    node: spec.Node = .root,
    shell: ?spec.Shell = null,
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
/// Authoritative value checks for both argv and wizard prompts. Never echoes input.
pub fn validateValue(name: []const u8, value: []const u8) !void {
    const item = spec.flag(name) orelse return error.UnknownFlag;
    if (item.kind == .boolean) return error.UnexpectedValue;
    if (eq(name, "--host")) {
        if (!token(value, ".-:")) return error.InvalidHost;
    } else if (eq(name, "--user")) {
        if (!token(value, "_-")) return error.InvalidUser;
    } else if (eq(name, "--port")) {
        const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        if (port == 0) return error.InvalidPort;
    } else if (item.kind == .path) {
        if (!path(value)) return error.InvalidPath;
    } else if (item.kind == .reference) {
        if (!reference(value)) return error.InvalidReference;
    } else if (eq(name, "--service")) {
        if (!token(value, "_.@:-") or !std.mem.endsWith(u8, value, ".service")) return error.InvalidService;
    } else if (eq(name, "--station-ip") or eq(name, "--admin-ip") or eq(name, "--agent-ip")) {
        if (!ip(value)) return error.InvalidIP;
    } else if (eq(name, "--domain")) {
        if (!token(value, ".-")) return error.InvalidDomain;
    } else if (item.kind == .enumeration) {
        for (item.values) |choice| if (eq(value, choice)) return;
        return error.InvalidTLS;
    } else if (eq(name, "--telegram-channel-id")) {
        _ = std.fmt.parseInt(i64, value, 10) catch return error.InvalidChatID;
    } else return error.UnknownFlag;
}
fn assign(a: std.mem.Allocator, o: *Options, name: []const u8, value: []const u8) !void {
    try validateValue(name, value);
    if (eq(name, "--host")) o.host = value else if (eq(name, "--user")) o.user = value else if (eq(name, "--port")) o.port = try std.fmt.parseInt(u16, value, 10) else if (eq(name, "--ssh-sock")) o.ssh_sock = value else if (eq(name, "--identity")) o.identity = value else if (eq(name, "--ssh-op-path")) o.ssh_op_path = value else if (eq(name, "--station-ip")) o.station_ip = value else if (eq(name, "--domain")) o.domain = value else if (eq(name, "--tls")) o.tls = value else if (eq(name, "--cloudflare-token-op")) o.cloudflare_token_op = value else if (eq(name, "--telegram-bot-token-op")) o.telegram_token_op = value else if (eq(name, "--telegram-channel-id")) o.telegram_channel_id = value else if (eq(name, "--service")) try o.services.append(a, value) else if (eq(name, "--admin-ip")) try o.admin_ips.append(a, value) else if (eq(name, "--agent-ip")) try o.agent_ips.append(a, value) else return error.UnknownFlag;
}
pub fn parse(a: std.mem.Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    errdefer o.deinit(a);
    var i: usize = 0;
    while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        const child = spec.child(o.node, args[i]) orelse return error.UnknownCommand;
        o.node = child.node;
    }
    const leaf = spec.getNode(o.node);
    if (leaf.command) |command| o.command = command;
    o.action = switch (o.node) {
        .completion, .completion_bash, .completion_zsh, .completion_fish => .completion,
        .wizard => .wizard,
        else => .monitoring,
    };
    o.shell = switch (o.node) {
        .completion_bash => .bash,
        .completion_zsh => .zsh,
        .completion_fish => .fish,
        else => null,
    };
    if (leaf.command == null) {
        if (i < args.len) {
            if (i + 1 != args.len or !eq(args[i], "--help")) return error.UnknownFlag;
            o.help = true;
        } else o.help = o.node != .wizard and o.shell == null;
        return o;
    }
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    while (i < args.len) : (i += 1) {
        const key = args[i];
        const item = spec.flag(key) orelse return error.UnknownFlag;
        if (!spec.flagAllowed(item, o.command)) return error.FlagNotAllowed;
        if (!item.repeatable) {
            if (seen.contains(key)) return error.DuplicateFlag;
            try seen.put(key, {});
        }
        if (item.kind == .boolean) {
            if (eq(key, "--help")) o.help = true else if (eq(key, "--plan")) o.plan = true;
            continue;
        }
        if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) return error.MissingValue;
        i += 1;
        try assign(a, &o, key, args[i]);
    }
    if (!o.help and o.host.len == 0) return error.HostRequired;
    const modes: u8 = @intFromBool(o.ssh_sock != null) + @as(u8, @intFromBool(o.identity != null)) + @as(u8, @intFromBool(o.ssh_op_path != null));
    if (modes > 1) return error.ConflictingAuthentication;
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

test "local entry points and hierarchical help share command metadata" {
    const a = std.testing.allocator;
    for (spec.commands) |item| {
        if (item.command) |command| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(a);
            try argv.appendSlice(a, spec.commandPath(command));
            try argv.append(a, "--help");
            var o = try parse(a, argv.items);
            defer o.deinit(a);
            try std.testing.expect(o.help);
            try std.testing.expectEqual(item.node, o.node);
        }
    }
    var completion = try parse(a, &.{ "completion", "zsh" });
    defer completion.deinit(a);
    try std.testing.expectEqual(Action.completion, completion.action);
    try std.testing.expectEqual(spec.Shell.zsh, completion.shell.?);
    try std.testing.expect(!completion.help);
    var wizard = try parse(a, &.{"wizard"});
    defer wizard.deinit(a);
    try std.testing.expectEqual(Action.wizard, wizard.action);
    try std.testing.expect(!wizard.help);
    try std.testing.expectError(error.UnknownCommand, parse(a, &.{ "completion", "unknown" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "status", "--host", "x", "--tls", "manual" }));
    try std.testing.expectError(error.UnknownFlag, parse(a, &.{ "wizard", "--host", "x" }));
}
test "wizard value validator preserves the same strict checks" {
    try validateValue("--port", "22");
    try validateValue("--tls", "cloudflare");
    try std.testing.expectError(error.InvalidPort, validateValue("--port", "0"));
    try std.testing.expectError(error.InvalidPath, validateValue("--ssh-sock", "/tmp/%h"));
    try std.testing.expectError(error.InvalidService, validateValue("--service", "app;id.service"));
    try std.testing.expectError(error.InvalidReference, validateValue("--ssh-op-path", "plain-secret"));
    try std.testing.expectError(error.InvalidReference, validateValue("--ssh-op-path", "op://secret\x1b"));
}
