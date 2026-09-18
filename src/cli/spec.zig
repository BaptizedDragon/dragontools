//! One small catalog shared by the strict parser and local UX frontends.
const std = @import("std");
pub const Command = enum { version, maintenance_check, app_apply, app_verify, app_status, install, verify, status, notify_test, agents_install, agents_verify, agents_status, firewall, install_oh_my_zsh };
pub const Shell = enum { bash, zsh, fish };
pub const Node = enum { root, version, maintenance, maintenance_check, monitoring, app_apply, app_verify, app_status, install, verify, status, notify_test, agents, agents_install, agents_verify, agents_status, firewall, host, install_oh_my_zsh, completion, completion_bash, completion_zsh, completion_fish, wizard };
pub const CommandSpec = struct {
    node: Node,
    parent: ?Node,
    name: []const u8,
    description: []const u8,
    command: ?Command = null,
};
pub const commands = [_]CommandSpec{
    .{ .node = .root, .parent = null, .name = "dragontool", .description = "Opinionated monitoring and small host utilities over SSH" },
    .{ .node = .version, .parent = .root, .name = "version", .description = "Report the binary and embedded cryptography versions", .command = .version },
    .{ .node = .maintenance, .parent = .root, .name = "maintenance", .description = "Read-only Ubuntu maintenance observations" },
    .{ .node = .maintenance_check, .parent = .maintenance, .name = "check", .description = "Report local or installed remote agent maintenance state", .command = .maintenance_check },
    .{ .node = .monitoring, .parent = .root, .name = "monitoring", .description = "Install, verify and inspect monitoring" },
    .{ .node = .app_apply, .parent = .monitoring, .name = "apply", .description = "Apply application monitoring from ./monitoring.toml", .command = .app_apply },
    .{ .node = .app_verify, .parent = .monitoring, .name = "app-verify", .description = "Verify application agents, signals, probes and alerts read-only", .command = .app_verify },
    .{ .node = .app_status, .parent = .monitoring, .name = "app-status", .description = "Show application monitoring state", .command = .app_status },
    .{ .node = .install, .parent = .monitoring, .name = "install", .description = "Install the eight-service storage, Grafana, probe and alerting station", .command = .install },
    .{ .node = .verify, .parent = .monitoring, .name = "verify", .description = "Verify station services, stored probe telemetry and alerting readiness", .command = .verify },
    .{ .node = .status, .parent = .monitoring, .name = "status", .description = "Show monitoring service state", .command = .status },
    .{ .node = .notify_test, .parent = .monitoring, .name = "notify-test", .description = "Send an explicit test alert through configured Alertmanager", .command = .notify_test },
    .{ .node = .agents, .parent = .monitoring, .name = "agents", .description = "Manage Vector logs/host metrics and optional vmagent application metrics" },
    .{ .node = .agents_install, .parent = .agents, .name = "install", .description = "Install monitored-host logs and metrics agents", .command = .agents_install },
    .{ .node = .agents_verify, .parent = .agents, .name = "verify", .description = "Verify monitored-host agents and station signal arrival", .command = .agents_verify },
    .{ .node = .agents_status, .parent = .agents, .name = "status", .description = "Show monitored-host forwarding state", .command = .agents_status },
    .{ .node = .firewall, .parent = .monitoring, .name = "firewall", .description = "Configure monitoring firewall rules (not yet available)", .command = .firewall },
    .{ .node = .host, .parent = .root, .name = "host", .description = "Small host utilities, separate from monitoring" },
    .{ .node = .install_oh_my_zsh, .parent = .host, .name = "install-oh-my-zsh", .description = "Install missing zsh and Oh My Zsh; opt in to managed config or login-shell changes", .command = .install_oh_my_zsh },
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
const all = &[_]Command{ .maintenance_check, .install, .verify, .status, .notify_test, .agents_install, .agents_verify, .agents_status, .firewall, .install_oh_my_zsh };
const monitoring = &[_]Command{ .install, .verify, .status, .agents_install, .agents_verify, .agents_status, .firewall };
const mutations = &[_]Command{ .app_apply, .install, .agents_install, .firewall, .install_oh_my_zsh };
const host = &[_]Command{.install_oh_my_zsh};
const native_ssh = &[_]Command{ .maintenance_check, .install, .verify, .status, .notify_test, .agents_install, .agents_verify, .agents_status, .install_oh_my_zsh };
const station = &[_]Command{.install};
const configured = &[_]Command{ .app_apply, .app_verify, .app_status, .install, .verify, .status, .notify_test };
const help_commands = &[_]Command{ .version, .app_apply, .app_verify, .app_status } ++ all.*;
const grafana_credentials = &[_]Command{ .install, .verify };
const agents = &[_]Command{ .agents_install, .agents_verify, .agents_status };
const network = &[_]Command{ .install, .firewall };
pub const flags = [_]FlagSpec{
    .{ .name = "--json", .description = "Machine-readable version metadata", .kind = .boolean, .group = "Output", .commands = &.{.version} },
    .{ .name = "--host", .description = "Direct target host", .metavar = "HOST", .group = "Required", .commands = all },
    .{ .name = "--ssh-host", .description = "OpenSSH host/alias; use normal SSH configuration", .metavar = "ALIAS", .group = "Connection", .commands = native_ssh },
    .{ .name = "--config", .description = "Monitoring TOML path; app commands default to ./monitoring.toml", .metavar = "PATH", .kind = .path, .group = "Configuration", .commands = configured },
    .{ .name = "--user", .description = "SSH user (default: root)", .metavar = "USER", .group = "Connection", .commands = all },
    .{ .name = "--port", .description = "SSH port (default: 22)", .metavar = "PORT", .group = "Connection", .commands = all },
    .{ .name = "--ssh-sock", .description = "SSH agent socket, including 1Password agent", .metavar = "PATH", .kind = .path, .group = "Connection", .commands = all },
    .{ .name = "--identity", .description = "SSH identity file (absolute path)", .metavar = "PATH", .kind = .path, .group = "Connection", .commands = all },
    .{ .name = "--ssh-op-path", .description = "1Password private-key reference", .metavar = "REF", .kind = .reference, .group = "Connection", .unavailable = true, .commands = monitoring },
    .{ .name = "--target-user", .description = "Existing target account (default: actual SSH login user)", .metavar = "USER", .group = "Host utility", .commands = host },
    .{ .name = "--set-default-shell", .description = "Set the login shell to discovered zsh only if different and listed in /etc/shells", .kind = .boolean, .group = "Host utility", .commands = host },
    .{ .name = "--update-managed-zshrc", .description = "Update only an exact DragonTools .zshrc template; preserve other existing files", .kind = .boolean, .group = "Host utility", .commands = host },
    .{ .name = "--grafana-user-op", .description = "Grafana administrator username reference; resolve locally with 1Password", .metavar = "REF", .kind = .reference, .group = "Grafana", .commands = grafana_credentials },
    .{ .name = "--grafana-password-op", .description = "Grafana administrator password reference; pair with a username reference", .metavar = "REF", .kind = .reference, .group = "Grafana", .commands = grafana_credentials },
    .{ .name = "--station-ip", .description = "Monitoring station IP address", .metavar = "IP", .group = "Monitoring", .unavailable = true, .commands = agents },
    .{ .name = "--station", .description = "Required monitoring station OpenSSH alias; never a Victoria URL", .metavar = "ALIAS", .group = "Agents", .commands = agents },
    .{ .name = "--service", .description = "Selected journald systemd service (repeatable; required for install)", .metavar = "NAME.service", .group = "Agents", .repeatable = true, .commands = agents },
    .{ .name = "--metrics-target", .description = "Application metrics endpoint (repeatable; localhost or private literal IP only)", .metavar = "NAME=URL", .group = "Agents", .repeatable = true, .commands = agents },
    .{ .name = "--domain", .description = "Monitoring domain", .metavar = "DOMAIN", .group = "Monitoring", .unavailable = true, .commands = station },
    .{ .name = "--admin-ip", .description = "Admin source IP (repeatable)", .metavar = "IP", .group = "Monitoring", .repeatable = true, .unavailable = true, .commands = network },
    .{ .name = "--agent-ip", .description = "Agent source IP (repeatable)", .metavar = "IP", .group = "Monitoring", .repeatable = true, .unavailable = true, .commands = network },
    .{ .name = "--tls", .description = "TLS DNS-01 mode", .metavar = "manual|cloudflare", .kind = .enumeration, .values = &.{ "manual", "cloudflare" }, .group = "TLS", .unavailable = true, .commands = station },
    .{ .name = "--cloudflare-token-op", .description = "Cloudflare DNS token reference", .metavar = "REF", .kind = .reference, .group = "TLS", .unavailable = true, .commands = station },
    .{ .name = "--telegram-bot-token-op", .description = "Legacy flag; use [telegram] secret references in --config", .metavar = "REF", .kind = .reference, .group = "Notifications", .unavailable = true, .commands = station },
    .{ .name = "--telegram-channel-id", .description = "Legacy flag; use [telegram] chat_id secret reference in --config", .metavar = "ID", .group = "Notifications", .unavailable = true, .commands = station },
    .{ .name = "--plan", .description = "Show the existing plan without connecting", .kind = .boolean, .group = "Safety", .commands = mutations },
    .{ .name = "--help", .description = "Show command help", .kind = .boolean, .group = "Help", .commands = help_commands },
};
pub fn applicationCommand(command: Command) bool {
    return command == .app_apply or command == .app_verify or command == .app_status;
}
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
