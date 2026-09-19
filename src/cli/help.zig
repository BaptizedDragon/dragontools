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
    if (node == .root) try w.print("DragonTools {s}\n\n", .{@import("../version.zig").version});
    try w.print("{s}\n\nUsage:\n  ", .{item.description});
    try writePath(w, node);
    if (item.command) |command| {
        try w.writeAll(if (command == .version) " [--json]\n" else if (command == .maintenance_check) " [--ssh-host ALIAS | --host HOST] [options]\n" else if (spec.applicationCommand(command)) (if (command == .app_apply) " [--config PATH] [--plan]\n" else " [--config PATH]\n") else if (spec.flagAllowed(spec.flag("--config").?, command)) " [--config PATH | --ssh-host ALIAS | --host HOST] [options]\n" else if (spec.flagAllowed(spec.flag("--station").?, command)) " (--ssh-host ALIAS | --host HOST) --station ALIAS [options]\n" else if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) " (--ssh-host ALIAS | --host HOST) [options]\n" else " --host HOST [options]\n");
    } else {
        var has_children = false;
        for (spec.commands) |child| {
            if (child.parent == node) has_children = true;
        }
        try w.writeAll(if (has_children) " <command>\n" else "\n");
    }

    if (node == .maintenance_check) try w.writeAll("\nWith no connection options, inspect this machine locally. Only Ubuntu 24.04/26.04 is supported. Unknown fields are null; no packages, timers or settings are changed. Remote checks require a previously installed matching agent.\n");
    var listed_children = false;
    for (spec.commands) |child| {
        if (child.parent != node) continue;
        if (!listed_children) try w.writeAll("\nCommands:\n");
        listed_children = true;
        try w.print("  {s}\n      {s}\n", .{ child.name, child.description });
    }

    if (item.command) |command| {
        if (command != .version and !spec.applicationCommand(command)) {
            try w.writeAll(if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) "\nConnection (choose one):\n" else "\nRequired:\n");
            if (spec.flagAllowed(spec.flag("--ssh-host").?, command)) try writeFlag(w, spec.flag("--ssh-host").?);
            try writeFlag(w, spec.flag("--host").?);
        }
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
        } else if (!spec.applicationCommand(command)) try w.writeAll("\nSSH defaults: user root, port 22, environment agent/default identities.\nStrict host-key checking is always enabled. Explicit authentication modes are exclusive.\n");
        if (spec.stationCommand(command)) try w.writeAll("\nLoads optional ./station.toml from CWD; --config selects a different file.\nNo parent/home/XDG search. Missing default permits CLI-only usage. Version 1\nsupports connection.ssh_host, station.hostname, Grafana/Telegram secret references\nand named probes. Deprecated [ingress].hostname is accepted unless conflicting.\nRelative config paths are allowed. Literal credentials and unknown keys fail.\nCLI values override config; --host replaces the configured SSH alias and\n--ingress-hostname overrides station.hostname. Credential references are paired.\nHelp, completion, status and --plan never resolve secrets; install and verify\nresolve Grafana references locally; Telegram resolves only during install.\nWithout references, Grafana administrator credentials remain unmanaged.\n");
    }
    try w.writeAll("\n  --help\n      Show help for this command.\n");

    if (item.command) |command| if (spec.applicationCommand(command)) {
        try w.writeAll(
            \\Loads exactly ./monitoring.toml by default, or the explicit --config path.
            \\Missing/invalid config fails before SSH. Version 1 requires application name
            \\and environment, target.ssh_host and station.ssh_host OpenSSH aliases, and
            \\station.hostname: a DNS-only mTLS hostname (no scheme, port, path or IP).
            \\Only --config, --help and apply's --plan are accepted; connection and signal
            \\selections belong in the file. Unknown keys and duplicate names fail.
            \\Host metrics are automatic. Service logs require explicit enabled=true.
            \\Private service metrics endpoints enable vmagent; HTTP(S) probes and bounded
            \\log/probe alerts belong to this application's station namespace.
            \\Traces and custom metrics alerts are explicitly unsupported.
            \\Apply --plan parses locally and contacts no SSH hosts or secret providers.
            \\App verification is read-only and sends no test alerts. Existing station
            \\secrets, unrelated applications and manual assets remain untouched.
            \\Use normal OpenSSH configuration; strict host-key checking remains enabled.
            \\Wizard application mode returns this same CLI with default-No confirmation.
            \\
        );
        return out.toOwnedSlice();
    };
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
    if (node == .agents or node == .agents_install or node == .agents_verify or node == .agents_status) {
        try w.writeAll(
            \\Vector forwards only selected journald services and bounded host metrics.
            \\vmagent is installed only when --metrics-target is supplied.
            \\Install requires at least one unique --service. Target names must be unique;
            \\URLs use HTTP/HTTPS, localhost or literal private/local addresses, without
            \\credentials, queries or fragments. Public/DNS metrics endpoints are rejected.
            \\--station is required for install, verify and status and uses normal OpenSSH
            \\configuration. DragonTools owns the ingestion ports and secure transport.
            \\Verify/status may omit selections to inspect the saved registration.
            \\Verify is read-only; successful install requires station-side signal arrival.
            \\OTel traces agents remain unavailable. --plan performs no remote operations.
            \\
        );
        return out.toOwnedSlice();
    }
    if (node == .root) try w.writeAll("\nHost utility: host install-oh-my-zsh installs only missing shell setup.\n");
    try w.print("\nImplemented: VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana.\nVictoriaMetrics: loopback:8428; retention {s}; reserve {d}%.\nVictoriaLogs: loopback:9428; disk-bound retention; logical limit {s}; native partition budget {d}% of filesystem capacity.\nVictoriaTraces: loopback:{d}; disk-bound retention; logical limit {s}; native partition budget {d}% of filesystem capacity.\nGrafana: loopback:3000; local authentication enabled; Metrics, Logs and Traces provisioned.\nAccess through SSH forwarding only. The official VictoriaLogs plugin is pinned; dashboards remain unavailable.\nLogs/traces preserve the newest two partitions. Cleanup is periodic.\nEach native partition budget excludes other writers; adequate headroom is required.\nReruns inspect actual state and recover pending activation. Healthy unchanged services are not restarted.\n", .{ policy.metrics.retention, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, vt.port, policy.traces.retention, policy.traces.cleanup_usage_percent });
    try w.writeAll(
        \\Blackbox exporter: loopback:9115; HTTP/HTTPS GET probes with verified TLS.
        \\VictoriaMetrics native scraping: 30s interval / 5s timeout; target changes reload without restart.
        \\vmalert-logs: loopback:8880; vmalert-metrics: loopback:8881; Alertmanager: loopback:9093.
        \\Configure [[probe]] name/url and optional [telegram] bot_token/chat_id op references with --config.
        \\ServiceProbeFailed alerts after probe_success == 0 for 2m. A down target does not fail station installation.
        \\Telegram resolves locally during install only; protected files never enter argv or configuration.
        \\Status reads stored probe metrics. Verify is read-only and sends no test alerts.
        \\Send a test explicitly with monitoring notify-test (reads ./station.toml).
        \\Vector logs/host metrics and optional vmagent app metrics use monitoring agents.
        \\OTel traces agents, dashboards, firewall, TLS and legacy Telegram flags are unavailable.
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
    try std.testing.expect(std.mem.indexOf(u8, install, "dragontool monitoring install [--config PATH | --ssh-host ALIAS | --host HOST]") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "./station.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "--grafana-user-op") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "--grafana-password-op") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "status and --plan never resolve secrets") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "--tls") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "[unavailable: rejected before SSH]") != null);
    const verify = try render(a, .verify);
    defer a.free(verify);
    try std.testing.expect(std.mem.indexOf(u8, verify, "--host HOST") != null);
    try std.testing.expect(std.mem.indexOf(u8, verify, "  --plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, verify, "  --tls") == null);
    const agents = try render(a, .agents_install);
    defer a.free(agents);
    try std.testing.expect(std.mem.indexOf(u8, agents, "dragontool monitoring agents install (--ssh-host ALIAS | --host HOST) --station ALIAS") != null);
    try std.testing.expect(std.mem.indexOf(u8, agents, "--service") != null);
    try std.testing.expect(std.mem.indexOf(u8, agents, "--metrics-target") != null);
    try std.testing.expect(std.mem.indexOf(u8, agents, "Verify/status may omit selections") != null);
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

test "application help gives one default config and no station override options" {
    for ([_]spec.Node{ .app_apply, .app_verify, .app_status }) |node| {
        const output = try render(std.testing.allocator, node);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "./monitoring.toml") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "--config PATH") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "  --ssh-host") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "  --host") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "  --grafana-user-op") == null);
        try std.testing.expectEqual(node == .app_apply, std.mem.indexOf(u8, output, "  --plan") != null);
    }
}
