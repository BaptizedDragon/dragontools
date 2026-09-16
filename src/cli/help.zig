const std = @import("std");
const spec = @import("spec.zig");
const policy = @import("../monitoring/policy.zig");
const vt = @import("../components/victoriatraces.zig");

fn writePath(w: *std.Io.Writer, node: spec.Node) !void {
    if (node == .root) return w.writeAll("dragontool");
    const item = spec.getNode(node);
    if (item.parent) |parent| {
        try writePath(w, parent);
        try w.writeByte(' ');
    }
    try w.writeAll(item.name);
}

fn writeFlag(w: *std.Io.Writer, flag: spec.FlagSpec) !void {
    try w.print("  {s}", .{flag.name});
    if (flag.metavar.len > 0) try w.print(" {s}", .{flag.metavar});
    try w.print("\n      {s}", .{flag.description});
    if (flag.repeatable and std.mem.indexOf(u8, flag.description, "repeatable") == null) try w.writeAll(" (repeatable)");
    if (flag.unavailable) try w.writeAll(" [unavailable: rejected before SSH]");
    try w.writeByte('\n');
}

fn isRequiredConnection(flag: spec.FlagSpec, command: spec.Command) bool {
    return std.mem.eql(u8, flag.name, "--host") or
        (spec.flagAllowed(spec.flag("--ssh-host").?, command) and std.mem.eql(u8, flag.name, "--ssh-host"));
}

/// Help and completions consume the same metadata as the strict parser.
pub fn render(a: std.mem.Allocator, node: spec.Node) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    const item = spec.getNode(node);
    if (node == .root) try w.writeAll("DragonTools 0.1.0-dev\n\n");
    try w.print("{s}\n\nUsage:\n  ", .{item.description});
    try writePath(w, node);
    if (item.command) |command| {
        try w.writeAll(if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) " (--ssh-host ALIAS | --host HOST) [options]\n" else " --host HOST [options]\n");
    } else {
        var has_children = false;
        for (spec.commands) |child| {
            if (child.parent == node) has_children = true;
        }
        try w.writeAll(if (has_children) " <command>\n" else "\n");
    }

    var listed_children = false;
    for (spec.commands) |child| {
        if (child.parent != node) continue;
        if (!listed_children) try w.writeAll("\nCommands:\n");
        listed_children = true;
        try w.print("  {s}\n      {s}\n", .{ child.name, child.description });
    }

    if (item.command) |command| {
        try w.writeAll(if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) "\nConnection (choose one):\n" else "\nRequired:\n");
        if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) try writeFlag(w, spec.flag("--ssh-host").?);
        try writeFlag(w, spec.flag("--host").?);
        // Group names and option availability are defined once in spec.zig.
        for (spec.flags, 0..) |flag, i| {
            if (!spec.flagAllowed(flag, command) or isRequiredConnection(flag, command) or std.mem.eql(u8, flag.name, "--help")) continue;
            var prior_group = false;
            for (spec.flags[0..i]) |previous| {
                if (spec.flagAllowed(previous, command) and !isRequiredConnection(previous, command) and !std.mem.eql(u8, previous.name, "--help") and std.mem.eql(u8, previous.group, flag.group)) prior_group = true;
            }
            if (prior_group) continue;
            try w.print("\n{s}:\n", .{if (flag.group.len == 0) "Options" else flag.group});
            for (spec.flags) |grouped| {
                if (spec.flagAllowed(grouped, command) and !isRequiredConnection(grouped, command) and !std.mem.eql(u8, grouped.name, "--help") and std.mem.eql(u8, grouped.group, flag.group)) try writeFlag(w, grouped);
            }
        }
        if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) {
            try w.writeAll("\nAlias mode: OpenSSH resolves HostName, User, Port, IdentityAgent, IdentityFile\nand ProxyJump through normal SSH configuration. Do not combine --ssh-host\nwith direct connection options. Direct mode defaults: user root, port 22,\nenvironment agent/default identities. Strict host-key checking is always enabled.\n");
        } else try w.writeAll("\nSSH defaults: user root, port 22, environment agent/default identities.\nStrict host-key checking is always enabled. Explicit authentication modes are exclusive.\n");
    }
    try w.writeAll("\n  --help\n      Show help for this command.\n");

    if (node == .completion) try w.writeAll(
        \\
        \\Print a local completion script to stdout. No SSH, network or secret access.
        \\Install for your shell (create the directory first):
        \\
        \\Bash:
        \\  mkdir -p ~/.local/share/bash-completion/completions
        \\  dragontool completion bash > ~/.local/share/bash-completion/completions/dragontool
        \\  source ~/.local/share/bash-completion/completions/dragontool
        \\Zsh:
        \\  mkdir -p ~/.zsh/completions
        \\  dragontool completion zsh > ~/.zsh/completions/_dragontool
        \\  Add fpath=(~/.zsh/completions $fpath) before compinit in ~/.zshrc.
        \\  Initialize with: autoload -Uz compinit && compinit
        \\Fish:
        \\  mkdir -p ~/.config/fish/completions
        \\  dragontool completion fish > ~/.config/fish/completions/dragontool.fish
        \\
        \\Completion never edits shell startup files.
        \\
    );
    if (node == .wizard) try w.writeAll(
        \\
        \\Start the interactive helper with terminal stdin and stdout.
        \\Answers use regular CLI validation and the existing workflows.
        \\Review the equivalent command, choose plan or apply, and confirm mutations.
        \\Enter accepts a default; ? explains a prompt; back returns; quit cancels.
        \\The information-only path performs no remote operations.
        \\
    );
    if (node == .host or node == .install_oh_my_zsh) {
        try w.writeAll(
            \\
            \\Installs zsh and pinned Oh My Zsh only when missing on Ubuntu/Debian.
            \\The default target is the actual SSH login user; --target-user selects an
            \\existing account. Its home comes from host account information.
            \\Existing Oh My Zsh and .zshrc are preserved by default. An absent .zshrc
            \\gets a DragonTools marker, user@hostname directory prompt, Oh My Zsh and git.
            \\The prompt uses the remote machine's actual short hostname.
            \\--update-managed-zshrc migrates exact prior DragonTools templates only;
            \\arbitrary or locally edited files remain untouched, even with a marker.
            \\--set-default-shell changes the login shell only if it differs from the
            \\discovered zsh path listed in /etc/shells. Otherwise no chsh is invoked.
            \\Reconnect after a login-shell change to start the new shell.
            \\Reruns inspect actual state; an unchanged installation requires no changes.
            \\--plan is local and performs no SSH. This utility does not modify monitoring.
            \\
        );
        return out.toOwnedSlice();
    }
    if (node == .root) try w.writeAll("\nHost utility: host install-oh-my-zsh installs only missing shell setup.\n");
    try w.print("\nImplemented: VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana.\nVictoriaMetrics: loopback:8428; retention {s}; reserve {d}%.\nVictoriaLogs: loopback:9428; disk-bound retention; logical limit {s}; native partition budget {d}% of filesystem capacity.\nVictoriaTraces: loopback:{d}; disk-bound retention; logical limit {s}; native partition budget {d}% of filesystem capacity.\nGrafana: loopback:3000; local authentication enabled; Metrics and Traces provisioned.\nAccess through SSH forwarding only; Logs UI and dashboards remain unavailable.\nLogs/traces preserve the newest two partitions. Cleanup is periodic.\nEach native partition budget excludes other writers; adequate headroom is required.\nReruns inspect actual state and recover pending activation. Healthy unchanged services are not restarted.\n", .{ policy.metrics.retention, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, vt.port, policy.traces.retention, policy.traces.cleanup_usage_percent });
    try w.writeAll(
        \\Agents, firewall, TLS, Telegram and the other station components are unavailable.
        \\Unavailable options are validated, then rejected before SSH, including with --plan.
        \\
    );
    return out.toOwnedSlice();
}

test "hierarchical help lists only the current command children" {
    const a = std.testing.allocator;
    const root = try render(a, .root);
    defer a.free(root);
    try std.testing.expect(std.mem.indexOf(u8, root, "  monitoring\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "  completion\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana") != null);
    const agents = try render(a, .agents);
    defer a.free(agents);
    try std.testing.expect(std.mem.indexOf(u8, agents, "dragontool monitoring agents <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, agents, "  install\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, agents, "  firewall\n") == null);
}

test "workflow help has contextual options and explicit availability" {
    const a = std.testing.allocator;
    const install = try render(a, .install);
    defer a.free(install);
    try std.testing.expect(std.mem.indexOf(u8, install, "dragontool monitoring install (--ssh-host ALIAS | --host HOST)") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "--tls") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "[unavailable: rejected before SSH]") != null);
    const verify = try render(a, .verify);
    defer a.free(verify);
    try std.testing.expect(std.mem.indexOf(u8, verify, "--host HOST") != null);
    try std.testing.expect(std.mem.indexOf(u8, verify, "  --plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, verify, "  --tls") == null);
    const agents = try render(a, .agents_install);
    defer a.free(agents);
    try std.testing.expect(std.mem.indexOf(u8, agents, "dragontool monitoring agents install --host HOST") != null);
    try std.testing.expect(std.mem.indexOf(u8, agents, "--service") != null);
}

test "completion and wizard help explain local behavior" {
    const a = std.testing.allocator;
    const completion = try render(a, .completion);
    defer a.free(completion);
    try std.testing.expect(std.mem.indexOf(u8, completion, "fpath=") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "dragontool completion fish >") != null);
    const wizard = try render(a, .wizard);
    defer a.free(wizard);
    try std.testing.expect(std.mem.indexOf(u8, wizard, "regular CLI validation") != null);
}

test "host help describes alias resolution and preservation without monitoring options" {
    const a = std.testing.allocator;
    const container = try render(a, .host);
    defer a.free(container);
    try std.testing.expect(std.mem.indexOf(u8, container, "dragontool host <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, container, "  install-oh-my-zsh\n") != null);
    const command = try render(a, .install_oh_my_zsh);
    defer a.free(command);
    for ([_][]const u8{ "dragontool host install-oh-my-zsh (--ssh-host ALIAS | --host HOST)", "--target-user", "actual SSH login user", "IdentityAgent", "ProxyJump", "Existing Oh My Zsh and .zshrc are preserved by default", "--set-default-shell", "--update-managed-zshrc", "user@hostname directory prompt", "/etc/shells", "even with a marker", "--plan is local" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, command, expected) != null);
    }
    for ([_][]const u8{ "  --tls", "  --service", "  --ssh-op-path", "VictoriaMetrics" }) |excluded| {
        try std.testing.expect(std.mem.indexOf(u8, command, excluded) == null);
    }
}
