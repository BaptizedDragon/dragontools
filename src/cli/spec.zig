//! One small catalog shared by the strict parser and local UX frontends.
const std = @import("std");
pub const Command = enum { install, verify, status, agents_install, agents_verify, agents_status, firewall };
pub const Shell = enum { bash, zsh, fish };
pub const Node = enum { root, monitoring, install, verify, status, agents, agents_install, agents_verify, agents_status, firewall, completion, completion_bash, completion_zsh, completion_fish, wizard };
pub const CommandSpec = struct {
    node: Node,
    parent: ?Node,
    name: []const u8,
    description: []const u8,
    command: ?Command = null,
};
pub const commands = [_]CommandSpec{
    .{ .node = .root, .parent = null, .name = "dragontool", .description = "Opinionated monitoring over SSH" },
    .{ .node = .monitoring, .parent = .root, .name = "monitoring", .description = "Install, verify and inspect monitoring" },
    .{ .node = .install, .parent = .monitoring, .name = "install", .description = "Install VictoriaMetrics and VictoriaLogs", .command = .install },
    .{ .node = .verify, .parent = .monitoring, .name = "verify", .description = "Verify installed VictoriaMetrics and VictoriaLogs", .command = .verify },
    .{ .node = .status, .parent = .monitoring, .name = "status", .description = "Show monitoring service state", .command = .status },
    .{ .node = .agents, .parent = .monitoring, .name = "agents", .description = "Manage monitored hosts (not yet available)" },
    .{ .node = .agents_install, .parent = .agents, .name = "install", .description = "Connect a monitored host (not yet available)", .command = .agents_install },
    .{ .node = .agents_verify, .parent = .agents, .name = "verify", .description = "Verify a monitored host (not yet available)", .command = .agents_verify },
    .{ .node = .agents_status, .parent = .agents, .name = "status", .description = "Show agent state (not yet available)", .command = .agents_status },
    .{ .node = .firewall, .parent = .monitoring, .name = "firewall", .description = "Configure monitoring firewall rules (not yet available)", .command = .firewall },
    .{ .node = .completion, .parent = .root, .name = "completion", .description = "Print a local shell completion script" },
    .{ .node = .completion_bash, .parent = .completion, .name = "bash", .description = "Print Bash completion" },
    .{ .node = .completion_zsh, .parent = .completion, .name = "zsh", .description = "Print Zsh completion" },
    .{ .node = .completion_fish, .parent = .completion, .name = "fish", .description = "Print Fish completion" },
    .{ .node = .wizard, .parent = .root, .name = "wizard", .description = "Open the interactive command helper" },
};
pub const ValueKind = enum { boolean, text, path, enumeration, reference };
pub const FlagSpec = struct {
    name: []const u8,
    description: []const u8,
    metavar: []const u8 = "",
    kind: ValueKind = .text,
    values: []const []const u8 = &.{},
    repeatable: bool = false,
    group: []const u8 = "",
    unavailable: bool = false,
    commands: []const Command,
};
const all = &[_]Command{ .install, .verify, .status, .agents_install, .agents_verify, .agents_status, .firewall };
const mutations = &[_]Command{ .install, .agents_install, .firewall };
const station = &[_]Command{.install};
const agents = &[_]Command{ .agents_install, .agents_verify };
const network = &[_]Command{ .install, .firewall };
pub const flags = [_]FlagSpec{
    .{ .name = "--host", .description = "Target host (required)", .metavar = "HOST", .group = "Required", .commands = all },
    .{ .name = "--user", .description = "SSH user (default: root)", .metavar = "USER", .group = "Connection", .commands = all },
    .{ .name = "--port", .description = "SSH port (default: 22)", .metavar = "PORT", .group = "Connection", .commands = all },
    .{ .name = "--ssh-sock", .description = "SSH agent socket, including 1Password agent", .metavar = "PATH", .kind = .path, .group = "Connection", .commands = all },
    .{ .name = "--identity", .description = "SSH identity file (absolute path)", .metavar = "PATH", .kind = .path, .group = "Connection", .commands = all },
    .{ .name = "--ssh-op-path", .description = "1Password private-key reference", .metavar = "REF", .kind = .reference, .group = "Connection", .unavailable = true, .commands = all },
    .{ .name = "--station-ip", .description = "Monitoring station IP address", .metavar = "IP", .group = "Monitoring", .unavailable = true, .commands = agents },
    .{ .name = "--service", .description = "Selected systemd service (repeatable)", .metavar = "NAME.service", .group = "Monitoring", .repeatable = true, .unavailable = true, .commands = agents },
    .{ .name = "--domain", .description = "Monitoring domain", .metavar = "DOMAIN", .group = "Monitoring", .unavailable = true, .commands = station },
    .{ .name = "--admin-ip", .description = "Admin source IP (repeatable)", .metavar = "IP", .group = "Monitoring", .repeatable = true, .unavailable = true, .commands = network },
    .{ .name = "--agent-ip", .description = "Agent source IP (repeatable)", .metavar = "IP", .group = "Monitoring", .repeatable = true, .unavailable = true, .commands = network },
    .{ .name = "--tls", .description = "TLS DNS-01 mode", .metavar = "manual|cloudflare", .kind = .enumeration, .values = &.{ "manual", "cloudflare" }, .group = "TLS", .unavailable = true, .commands = station },
    .{ .name = "--cloudflare-token-op", .description = "Cloudflare DNS token reference", .metavar = "REF", .kind = .reference, .group = "TLS", .unavailable = true, .commands = station },
    .{ .name = "--telegram-bot-token-op", .description = "Telegram bot token reference", .metavar = "REF", .kind = .reference, .group = "Notifications", .unavailable = true, .commands = station },
    .{ .name = "--telegram-channel-id", .description = "Telegram channel/chat ID", .metavar = "ID", .group = "Notifications", .unavailable = true, .commands = station },
    .{ .name = "--plan", .description = "Show the existing plan without connecting", .kind = .boolean, .group = "Safety", .commands = mutations },
    .{ .name = "--help", .description = "Show command help", .kind = .boolean, .group = "Help", .commands = all },
};
pub fn flagAllowed(item: FlagSpec, command: Command) bool {
    return std.mem.indexOfScalar(Command, item.commands, command) != null;
}
pub fn flag(name: []const u8) ?FlagSpec {
    for (flags) |item| if (std.mem.eql(u8, name, item.name)) return item;
    return null;
}
pub fn getNode(node: Node) CommandSpec {
    for (commands) |item| if (item.node == node) return item;
    unreachable;
}
pub fn child(parent: Node, name: []const u8) ?CommandSpec {
    for (commands) |item| if (item.parent == parent and std.mem.eql(u8, name, item.name)) return item;
    return null;
}
pub fn commandNode(command: Command) Node {
    for (commands) |item| if (item.command == command) return item.node;
    unreachable;
}
const command_paths = paths: {
    var paths: [std.meta.tags(Command).len][]const []const u8 = undefined;
    for (std.meta.tags(Command), 0..) |tag, index| {
        var reversed: [4][]const u8 = undefined;
        var count: usize = 0;
        var node = commandNode(tag);
        while (node != .root) {
            const item = getNode(node);
            reversed[count] = item.name;
            count += 1;
            node = item.parent.?;
        }
        var result: [count][]const u8 = undefined;
        for (0..count) |i| result[i] = reversed[count - i - 1];
        const frozen = result;
        paths[index] = &frozen;
    }
    break :paths paths;
};
pub fn commandPath(command: Command) []const []const u8 {
    return command_paths[@intFromEnum(command)];
}

test "metadata has unique nodes/flags and context-aware enum options" {
    for (commands, 0..) |item, i| {
        for (commands[i + 1 ..]) |other| try std.testing.expect(item.node != other.node);
        if (item.parent) |parent| _ = getNode(parent);
        if (item.command) |command| try std.testing.expectEqual(item.node, commandNode(command));
    }
    for (flags, 0..) |item, i| {
        for (flags[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, item.name, other.name));
    }
    try std.testing.expectEqualStrings("agents", commandPath(.agents_install)[1]);
    try std.testing.expect(flagAllowed(flag("--tls").?, .install));
    try std.testing.expect(!flagAllowed(flag("--tls").?, .status));
    try std.testing.expect(flagAllowed(flag("--service").?, .agents_verify));
    try std.testing.expect(!flagAllowed(flag("--service").?, .install));
    try std.testing.expectEqualStrings("cloudflare", flag("--tls").?.values[1]);
}
