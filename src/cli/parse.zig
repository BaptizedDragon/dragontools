const std = @import("std");
const spec = @import("spec.zig");
const config = @import("../config/monitoring.zig");
const application = @import("../config/application.zig");
const references = @import("../secrets/reference.zig");
const probes = @import("../monitoring/probes.zig");
const targets = @import("../monitoring/agents/targets.zig");
pub const Command = spec.Command;
pub const Action = enum { monitoring, host, completion, wizard, local };
pub const Options = struct {
    command: Command = .install,
    action: Action = .monitoring,
    node: spec.Node = .root,
    shell: ?spec.Shell = null,
    help: bool = false,
    json: bool = false,
    plan: bool = false,
    host: []const u8 = "",
    ssh_host: ?[]const u8 = null,
    ingress_hostname: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    grafana_user_op: ?[]const u8 = null,
    grafana_password_op: ?[]const u8 = null,
    probes: []const probes.Probe = &.{},
    telegram_bot_token_op: ?[]const u8 = null,
    telegram_chat_id_op: ?[]const u8 = null,
    // Explicit defaults still conflict with alias mode after config merge.
    explicit_user: bool = false,
    explicit_port: bool = false,
    config_values: ?config.Config = null,
    application_config: ?application.Config = null,
    target_user: ?[]const u8 = null,
    set_default_shell: bool = false,
    update_managed_zshrc: bool = false,
    user: []const u8 = "root",
    port: u16 = 22,
    ssh_sock: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    ssh_op_path: ?[]const u8 = null,
    station: ?[]const u8 = null,
    station_ip: ?[]const u8 = null,
    metrics_targets: std.ArrayList(targets.Target) = .empty,
    domain: ?[]const u8 = null,
    tls: ?[]const u8 = null,
    cloudflare_token_op: ?[]const u8 = null,
    telegram_token_op: ?[]const u8 = null,
    telegram_channel_id: ?[]const u8 = null,
    services: std.ArrayList([]const u8) = .empty,
    admin_ips: std.ArrayList([]const u8) = .empty,
    agent_ips: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Options, a: std.mem.Allocator) void {
        if (self.config_values) |*values| values.deinit();
        if (self.application_config) |*values| values.deinit();
        self.services.deinit(a);
        self.metrics_targets.deinit(a);
        self.admin_ips.deinit(a);
        self.agent_ips.deinit(a);
    }
    pub fn unsupported(self: Options) bool {
        return self.command == .firewall or
            self.ssh_op_path != null or self.station_ip != null or self.admin_ips.items.len > 0 or self.agent_ips.items.len > 0 or self.domain != null or self.tls != null or self.cloudflare_token_op != null or self.telegram_token_op != null or self.telegram_channel_id != null;
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
    } else if (eq(name, "--ssh-host") or eq(name, "--station")) {
        if (!token(value, "_.-:")) return error.InvalidSshHost;
    } else if (eq(name, "--ingress-hostname")) {
        try application.validateStationHostname(value);
    } else if (eq(name, "--user") or eq(name, "--target-user")) {
        if (!token(value, "_-")) return error.InvalidUser;
    } else if (eq(name, "--port")) {
        const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        if (port == 0) return error.InvalidPort;
    } else if (eq(name, "--config")) {
        // Local paths are argv data, never OpenSSH option expansion. Relative
        // paths and spaces are valid; controls and NUL are not.
        if (value.len == 0 or value.len > 4096) return error.InvalidPath;
        for (value) |c| if (c < 32 or c == 127) return error.InvalidPath;
    } else if (eq(name, "--grafana-user-op") or eq(name, "--grafana-password-op")) {
        _ = try references.parseOnePassword(value);
    } else if (item.kind == .path) {
        if (!path(value)) return error.InvalidPath;
    } else if (item.kind == .reference) {
        if (!reference(value)) return error.InvalidReference;
    } else if (eq(name, "--service")) {
        try targets.validateService(value);
    } else if (eq(name, "--metrics-target")) {
        _ = try targets.parseOne(value);
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
    if (eq(name, "--ingress-hostname")) {
        o.ingress_hostname = value;
        return;
    }
    if (eq(name, "--config")) {
        o.config_path = value;
        return;
    }
    if (eq(name, "--grafana-user-op")) {
        o.grafana_user_op = value;
        return;
    }
    if (eq(name, "--grafana-password-op")) {
        o.grafana_password_op = value;
        return;
    }
    if (eq(name, "--station")) {
        o.station = value;
        return;
    }
    if (eq(name, "--metrics-target")) {
        try o.metrics_targets.append(a, try targets.parseOne(value));
        return;
    }
    if (eq(name, "--user")) o.explicit_user = true;
    if (eq(name, "--port")) o.explicit_port = true;
    if (eq(name, "--host")) o.host = value else if (eq(name, "--ssh-host")) o.ssh_host = value else if (eq(name, "--target-user")) o.target_user = value else if (eq(name, "--user")) o.user = value else if (eq(name, "--port")) o.port = try std.fmt.parseInt(u16, value, 10) else if (eq(name, "--ssh-sock")) o.ssh_sock = value else if (eq(name, "--identity")) o.identity = value else if (eq(name, "--ssh-op-path")) o.ssh_op_path = value else if (eq(name, "--station-ip")) o.station_ip = value else if (eq(name, "--domain")) o.domain = value else if (eq(name, "--tls")) o.tls = value else if (eq(name, "--cloudflare-token-op")) o.cloudflare_token_op = value else if (eq(name, "--telegram-bot-token-op")) o.telegram_token_op = value else if (eq(name, "--telegram-channel-id")) o.telegram_channel_id = value else if (eq(name, "--service")) try o.services.append(a, value) else if (eq(name, "--admin-ip")) try o.admin_ips.append(a, value) else if (eq(name, "--agent-ip")) try o.agent_ips.append(a, value) else return error.UnknownFlag;
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
        .version, .maintenance, .maintenance_check => .local,
        .host, .install_oh_my_zsh => .host,
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
            if (eq(key, "--json")) o.json = true else if (eq(key, "--help")) o.help = true else if (eq(key, "--plan")) o.plan = true else if (eq(key, "--set-default-shell")) o.set_default_shell = true else if (eq(key, "--update-managed-zshrc")) o.update_managed_zshrc = true;
            continue;
        }
        if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) return error.MissingValue;
        i += 1;
        try assign(a, &o, key, args[i]);
    }
    try validateMerged(o, o.config_path == null);
    return o;
}

fn validateMerged(o: Options, complete: bool) !void {
    if (o.command == .version or spec.applicationCommand(o.command)) return;
    if (o.ingress_hostname) |value| try validateValue("--ingress-hostname", value);
    if (o.ssh_host) |value| try validateValue("--ssh-host", value);
    if (o.grafana_user_op) |value| try validateValue("--grafana-user-op", value);
    if (o.grafana_password_op) |value| try validateValue("--grafana-password-op", value);
    try probes.validate(o.probes);
    try targets.validateServices(o.services.items);
    try targets.validate(o.metrics_targets.items);
    try targets.validateSelectionSize(o.services.items, o.metrics_targets.items);
    if (o.telegram_bot_token_op) |value| _ = try references.parseOnePassword(value);
    if (o.telegram_chat_id_op) |value| _ = try references.parseOnePassword(value);
    if (o.ssh_host != null) {
        if (o.host.len != 0) return error.ConflictingHosts;
        // Alias mode lets OpenSSH resolve every connection/authentication field.
        if (o.explicit_user or o.explicit_port or o.ssh_sock != null or o.identity != null or o.ssh_op_path != null) return error.ConflictingSshMode;
    }
    if (o.command != .maintenance_check and complete and !o.help and o.host.len == 0 and o.ssh_host == null) return error.HostRequired;
    if (complete and !o.help and (o.command == .agents_install or o.command == .agents_verify or o.command == .agents_status)) {
        if (o.station == null) return error.StationRequired;
        if (o.command == .agents_install and o.services.items.len == 0) return error.ServiceRequired;
    }
    const modes: u8 = @intFromBool(o.ssh_sock != null) + @as(u8, @intFromBool(o.identity != null)) + @as(u8, @intFromBool(o.ssh_op_path != null));
    if (modes > 1) return error.ConflictingAuthentication;
    if (complete and !o.help and (o.grafana_user_op != null) != (o.grafana_password_op != null)) return error.GrafanaCredentialReferencesRequired;
    if (complete and !o.help and (o.telegram_bot_token_op != null) != (o.telegram_chat_id_op != null)) return error.TelegramCredentialReferencesRequired;
}

/// Transfer ownership only after validating the complete merge. On failure the
/// caller still owns values and options are unchanged. Explicit argv wins.
fn merge(o: *Options, values: config.Config) !void {
    if (o.config_values != null) return error.MonitoringConfigAlreadyLoaded;
    var merged = o.*;
    if (merged.ssh_host == null and merged.host.len == 0) merged.ssh_host = values.ssh_host;
    if (merged.ingress_hostname == null) merged.ingress_hostname = values.ingress_hostname;
    if (merged.grafana_user_op == null) merged.grafana_user_op = values.grafana_user_op;
    if (merged.grafana_password_op == null) merged.grafana_password_op = values.grafana_password_op;
    merged.probes = values.probes;
    if (merged.telegram_bot_token_op == null) merged.telegram_bot_token_op = values.telegram_bot_token_op;
    if (merged.telegram_chat_id_op == null) merged.telegram_chat_id_op = values.telegram_chat_id_op;
    try validateMerged(merged, true);
    merged.config_values = values;
    o.* = merged;
}

/// Help/completion return before this function. Plans load only references; no
/// parser/config path imports a resolver or spawns a process.
pub fn loadAndMerge(a: std.mem.Allocator, io: std.Io, o: *Options) !void {
    if (o.help or o.action != .monitoring) return;
    if (spec.applicationCommand(o.command)) {
        if (o.application_config != null) return error.ApplicationConfigAlreadyLoaded;
        o.application_config = try application.load(a, io, o.config_path orelse application.default_path);
        return;
    }
    if (o.config_path) |path_value| {
        var values = try config.load(a, io, path_value);
        errdefer values.deinit();
        try merge(o, values);
    } else try validateMerged(o.*, true);
}

fn mergeText(a: std.mem.Allocator, o: *Options, contents: []const u8) !void {
    var values = try config.parse(a, contents);
    errdefer values.deinit();
    try merge(o, values);
}

test "CLI hierarchy, repeated services, and rejected injection" {
    const a = std.testing.allocator;
    var o = try parse(a, &.{ "monitoring", "agents", "install", "--host", "app01.example.com", "--station", "monitoring", "--service", "one.service", "--service", "two.service" });
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

test "agent CLI accepts SSH aliases and validates all selections before dispatch" {
    const a = std.testing.allocator;
    var options = try parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--metrics-target", "app=http://127.0.0.1:16000/metrics", "--metrics-target", "worker=https://10.1.2.3/metrics", "--plan" });
    defer options.deinit(a);
    try std.testing.expect(!options.unsupported());
    try std.testing.expectEqualStrings("application", options.ssh_host.?);
    try std.testing.expectEqualStrings("monitoring", options.station.?);
    try std.testing.expectEqual(@as(usize, 2), options.metrics_targets.items.len);
    try std.testing.expectEqualStrings("app", options.metrics_targets.items[0].name);
    try std.testing.expectEqualStrings("http://127.0.0.1:16000/metrics", options.metrics_targets.items[0].url);
    for ([_][]const u8{ "verify", "status" }) |command| {
        var read_only = try parse(a, &.{ "monitoring", "agents", command, "--ssh-host", "application", "--station", "monitoring" });
        defer read_only.deinit(a);
        try std.testing.expect(!read_only.unsupported());
        try std.testing.expectEqual(@as(usize, 0), read_only.services.items.len);
        try std.testing.expectEqual(@as(usize, 0), read_only.metrics_targets.items.len);
        try std.testing.expectError(error.StationRequired, parse(a, &.{ "monitoring", "agents", command, "--ssh-host", "application" }));
    }
    try std.testing.expectError(error.StationRequired, parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--service", "app.service" }));
    try std.testing.expectError(error.ServiceRequired, parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring" }));
    try std.testing.expectError(error.DuplicateService, parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--service", "app.service" }));
    try std.testing.expectError(error.DuplicateMetricsTargetName, parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--metrics-target", "app=http://127.0.0.1/a", "--metrics-target", "app=http://127.0.0.1/b" }));
    try std.testing.expectError(error.InvalidMetricsTargetUrl, parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--metrics-target", "app=http://public.example/metrics" }));
    try std.testing.expectError(error.InvalidSshHost, parse(a, &.{ "monitoring", "agents", "install", "--ssh-host", "application", "--station", "https://monitoring.example/", "--service", "app.service" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "install", "--ssh-host", "monitoring", "--metrics-target", "app=http://127.0.0.1/metrics" }));
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

test "host utility accepts an SSH alias without overriding the target account" {
    const a = std.testing.allocator;
    var alias = try parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--plan" });
    defer alias.deinit(a);
    try std.testing.expectEqual(Action.host, alias.action);
    try std.testing.expectEqual(Command.install_oh_my_zsh, alias.command);
    try std.testing.expectEqualStrings("monitoring", alias.ssh_host.?);
    try std.testing.expect(alias.host.len == 0);
    try std.testing.expect(alias.target_user == null);
    try std.testing.expect(!alias.set_default_shell);
    try std.testing.expect(!alias.update_managed_zshrc);
    try std.testing.expect(alias.ssh_sock == null);
    try std.testing.expect(alias.plan);
    try std.testing.expect(!alias.unsupported());

    var direct = try parse(a, &.{ "host", "install-oh-my-zsh", "--host", "monitoring.example.com", "--user", "ops", "--ssh-sock", "/tmp/agent.sock", "--target-user", "vasyl" });
    defer direct.deinit(a);
    try std.testing.expect(direct.ssh_host == null);
    try std.testing.expectEqualStrings("ops", direct.user);
    try std.testing.expectEqualStrings("vasyl", direct.target_user.?);
    try std.testing.expectEqualStrings("/tmp/agent.sock", direct.ssh_sock.?);
}

test "host personalization changes are explicit host-only boolean options" {
    const a = std.testing.allocator;
    var options = try parse(a, &.{ "host", "install-oh-my-zsh", "--set-default-shell", "--ssh-host", "monitoring", "--update-managed-zshrc", "--target-user", "ops", "--plan" });
    defer options.deinit(a);
    try std.testing.expect(options.set_default_shell);
    try std.testing.expect(options.update_managed_zshrc);
    try std.testing.expect(options.plan);
    try std.testing.expectEqualStrings("ops", options.target_user.?);
    for ([_][]const u8{ "--set-default-shell", "--update-managed-zshrc" }) |flag| {
        try std.testing.expectError(error.DuplicateFlag, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", flag, flag }));
        try std.testing.expectError(error.UnknownFlag, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", flag, "true" }));
        try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "install", "--host", "monitoring", flag }));
        try std.testing.expectError(error.UnexpectedValue, validateValue(flag, "true"));
    }
}

test "host utility rejects conflicting connection forms and unsafe arguments" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.HostRequired, parse(a, &.{ "host", "install-oh-my-zsh" }));
    try std.testing.expectError(error.ConflictingHosts, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--host", "example.com" }));
    for ([_][]const u8{ "--user", "--port", "--ssh-sock", "--identity" }, [_][]const u8{ "root", "22", "/tmp/sock", "/tmp/key" }) |flag, value| {
        try std.testing.expectError(error.ConflictingSshMode, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", flag, value }));
    }
    for ([_][]const u8{ "", "-oProxyCommand=x", "root@host", "host;id", "host name", "host\nother", "host%h" }) |value| {
        try std.testing.expectError(error.InvalidSshHost, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", value }));
    }
    try std.testing.expectError(error.InvalidUser, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--target-user", "root;id" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--tls", "manual" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "install", "--host", "monitoring", "--target-user", "vasyl" }));
}

test "implemented monitoring accepts native SSH aliases without direct overrides" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "install", "verify", "status" }) |command| {
        var options = try parse(a, &.{ "monitoring", command, "--ssh-host", "monitoring" });
        defer options.deinit(a);
        try std.testing.expectEqualStrings("monitoring", options.ssh_host.?);
        try std.testing.expect(options.host.len == 0);
        try std.testing.expect(!options.unsupported());
        try std.testing.expectError(error.ConflictingHosts, parse(a, &.{ "monitoring", command, "--ssh-host", "monitoring", "--host", "example.com" }));
        for ([_][]const u8{ "--user", "--port", "--ssh-sock", "--identity", "--ssh-op-path" }, [_][]const u8{ "root", "22", "/tmp/sock", "/tmp/key", "op://vault/key/private" }) |flag, value| {
            try std.testing.expectError(error.ConflictingSshMode, parse(a, &.{ "monitoring", command, "--ssh-host", "monitoring", flag, value }));
        }
        try std.testing.expectError(error.InvalidSshHost, parse(a, &.{ "monitoring", command, "--ssh-host", "host;id" }));
    }
    var plan = try parse(a, &.{ "monitoring", "install", "--ssh-host", "monitoring", "--plan" });
    defer plan.deinit(a);
    try std.testing.expect(plan.plan);
}

const example_config =
    \\version = 1
    \\[connection]
    \\ssh_host = "monitoring"
    \\[grafana]
    \\username = { op = "op://Example/Grafana/username" }
    \\password = { op = "op://Example/Grafana/password" }
;

test "monitoring config merge supplies alias and paired reference values without resolution" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "install", "verify", "status" }) |command| {
        var options = try parse(a, &.{ "monitoring", command, "--config", "examples/monitoring.toml" });
        defer options.deinit(a);
        try std.testing.expect(options.ssh_host == null);
        try mergeText(a, &options, example_config);
        try std.testing.expectEqualStrings("monitoring", options.ssh_host.?);
        try std.testing.expectEqualStrings("op://Example/Grafana/username", options.grafana_user_op.?);
        try std.testing.expectEqualStrings("op://Example/Grafana/password", options.grafana_password_op.?);
        try std.testing.expect(!options.unsupported());
    }
    var plan = try parse(a, &.{ "monitoring", "install", "--config", "./monitoring.toml", "--plan" });
    defer plan.deinit(a);
    try mergeText(a, &plan, example_config);
    try std.testing.expect(plan.plan);
}

test "explicit CLI alias direct host and Grafana references override config individually" {
    const a = std.testing.allocator;
    var alias = try parse(a, &.{ "monitoring", "install", "--config", "monitoring.toml", "--ssh-host", "other", "--grafana-user-op", "op://Other/Grafana/username" });
    defer alias.deinit(a);
    try mergeText(a, &alias, example_config);
    try std.testing.expectEqualStrings("other", alias.ssh_host.?);
    try std.testing.expectEqualStrings("op://Other/Grafana/username", alias.grafana_user_op.?);
    try std.testing.expectEqualStrings("op://Example/Grafana/password", alias.grafana_password_op.?);

    var direct = try parse(a, &.{ "monitoring", "verify", "--config", "monitoring.toml", "--host", "direct.example.com", "--user", "ops", "--port", "2222", "--identity", "/tmp/key", "--grafana-password-op", "op://Other/Grafana/password" });
    defer direct.deinit(a);
    try mergeText(a, &direct, example_config);
    try std.testing.expectEqualStrings("direct.example.com", direct.host);
    try std.testing.expect(direct.ssh_host == null);
    try std.testing.expectEqualStrings("ops", direct.user);
    try std.testing.expectEqual(@as(u16, 2222), direct.port);
    try std.testing.expectEqualStrings("op://Example/Grafana/username", direct.grafana_user_op.?);
    try std.testing.expectEqualStrings("op://Other/Grafana/password", direct.grafana_password_op.?);

    var overridden = try parse(a, &.{ "monitoring", "install", "--config", "monitoring.toml", "--host", "direct.example.com" });
    defer overridden.deinit(a);
    try mergeText(a, &overridden, "version = 1\n[connection]\nssh_host = 'ignored invalid alias'\n");
    try std.testing.expect(overridden.ssh_host == null);
}

test "merged config preserves SSH conflicts and validates incomplete credential pairs" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "--user", "--port", "--identity", "--ssh-sock" }, [_][]const u8{ "root", "22", "/tmp/key", "/tmp/sock" }) |flag, value| {
        var options = try parse(a, &.{ "monitoring", "install", "--config", "monitoring.toml", flag, value });
        defer options.deinit(a);
        try std.testing.expectError(error.ConflictingSshMode, mergeText(a, &options, example_config));
        try std.testing.expect(options.config_values == null);
        try std.testing.expect(options.ssh_host == null);
    }
    var missing = try parse(a, &.{ "monitoring", "install", "--config", "monitoring.toml" });
    defer missing.deinit(a);
    try std.testing.expectError(error.HostRequired, mergeText(a, &missing, "version = 1"));
    try std.testing.expectError(error.GrafanaCredentialReferencesRequired, mergeText(a, &missing, "version = 1\n[connection]\nssh_host = 'monitoring'\n[grafana]\nusername = { op = 'op://Example/Grafana/username' }"));
    try std.testing.expectError(error.InvalidSshHost, mergeText(a, &missing, "version = 1\n[connection]\nssh_host = 'host;id'"));
    try std.testing.expectError(error.GrafanaCredentialReferencesRequired, parse(a, &.{ "monitoring", "install", "--ssh-host", "monitoring", "--grafana-user-op", "op://Example/Grafana/username" }));
    var pair = try parse(a, &.{ "monitoring", "verify", "--ssh-host", "monitoring", "--grafana-user-op", "op://Example/Grafana/username", "--grafana-password-op", "op://Example/Grafana/password" });
    defer pair.deinit(a);
    try std.testing.expect(!pair.unsupported());
}

test "config and Grafana flags are available only in intended command contexts" {
    const a = std.testing.allocator;
    try validateValue("--config", "./config folder/monitoring.toml");
    try validateValue("--config", "monitoring.toml");
    try std.testing.expectError(error.InvalidPath, validateValue("--config", "config\n.toml"));
    try std.testing.expectError(error.InvalidPath, validateValue("--config", ""));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "host", "install-oh-my-zsh", "--config", "monitoring.toml" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "status", "--ssh-host", "monitoring", "--grafana-user-op", "op://Example/Grafana/username" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "agents", "install", "--config", "monitoring.toml" }));
    try std.testing.expectError(error.DuplicateFlag, parse(a, &.{ "monitoring", "install", "--config", "a.toml", "--config", "b.toml" }));
    var help_options = try parse(a, &.{ "monitoring", "install", "--config", "/does/not/exist.toml", "--help" });
    defer help_options.deinit(a);
    try loadAndMerge(a, std.testing.io, &help_options);
    try std.testing.expect(help_options.config_values == null);
}

test "monitoring merge owns normalized probes and opaque Telegram references" {
    const a = std.testing.allocator;
    const contents =
        \\version = 1
        \\[connection]
        \\ssh_host = 'monitoring'
        \\[telegram]
        \\bot_token = { op = 'op://Example/DragonTools/token' }
        \\chat_id = { op = 'op://Example/DragonTools/chat' }
        \\[[probe]]
        \\name = 'example'
        \\url = 'HTTPS://EXAMPLE.COM:443'
    ;
    for ([_][]const u8{ "install", "verify", "status" }) |command| {
        var options = try parse(a, &.{ "monitoring", command, "--config", "monitoring.toml" });
        defer options.deinit(a);
        try mergeText(a, &options, contents);
        try std.testing.expectEqual(@as(usize, 1), options.probes.len);
        try std.testing.expectEqualStrings("https://example.com/", options.probes[0].url);
        try std.testing.expectEqualStrings("op://Example/DragonTools/token", options.telegram_bot_token_op.?);
        try std.testing.expectEqualStrings("op://Example/DragonTools/chat", options.telegram_chat_id_op.?);
        try std.testing.expect(options.telegram_token_op == null);
        try std.testing.expect(options.telegram_channel_id == null);
        try std.testing.expect(!options.unsupported());
    }
}

test "legacy Telegram arguments do not silently become the supported reference pair" {
    const a = std.testing.allocator;
    var options = try parse(a, &.{ "monitoring", "install", "--ssh-host", "monitoring", "--telegram-bot-token-op", "op://Example/DragonTools/token", "--telegram-channel-id", "-10012345" });
    defer options.deinit(a);
    try std.testing.expect(options.unsupported());
    try std.testing.expect(options.telegram_bot_token_op == null);
    try std.testing.expect(options.telegram_chat_id_op == null);
}

test "application CLI commands accept only config plan and help before local load" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "apply", "app-verify", "app-status" }) |command| {
        var options = try parse(a, &.{ "monitoring", command });
        defer options.deinit(a);
        try std.testing.expect(spec.applicationCommand(options.command));
        try std.testing.expect(options.config_path == null);
        try std.testing.expect(options.application_config == null);
        for ([_][]const u8{ "--ssh-host", "--host", "--station", "--service", "--grafana-user-op" }, [_][]const u8{ "app", "app", "station", "app.service", "op://Example/item/key" }) |flag, value| try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", command, flag, value }));
        var help_options = try parse(a, &.{ "monitoring", command, "--config", "/does/not/exist.toml", "--help" });
        defer help_options.deinit(a);
        try loadAndMerge(a, std.testing.io, &help_options);
        try std.testing.expect(help_options.application_config == null);
    }
    for ([_][]const u8{ "app-verify", "app-status" }) |command| try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", command, "--plan" }));
    var plan = try parse(a, &.{ "monitoring", "apply", "--plan" });
    defer plan.deinit(a);
    try std.testing.expect(plan.plan);
}

test "application CLI loads only its schema and missing config fails locally" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_value = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/monitoring.toml", .{tmp.sub_path});
    defer a.free(path_value);
    var options = try parse(a, &.{ "monitoring", "apply", "--config", path_value, "--plan" });
    defer options.deinit(a);
    try std.testing.expectError(error.UnableToReadApplicationConfig, loadAndMerge(a, std.testing.io, &options));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "monitoring.toml", .data = application.example });
    try loadAndMerge(a, std.testing.io, &options);
    try std.testing.expectEqualStrings("doers", options.application_config.?.application.name);
    try std.testing.expect(options.config_values == null);
    try std.testing.expectError(error.ApplicationConfigAlreadyLoaded, loadAndMerge(a, std.testing.io, &options));
}

test "version and maintenance share strict CLI metadata without implicit SSH" {
    const a = std.testing.allocator;
    var version = try parse(a, &.{ "version", "--json" });
    defer version.deinit(a);
    try std.testing.expect(version.json and version.command == .version);
    var local = try parse(a, &.{ "maintenance", "check" });
    defer local.deinit(a);
    try std.testing.expect(local.host.len == 0 and local.ssh_host == null);
    var remote_check = try parse(a, &.{ "maintenance", "check", "--ssh-host", "application" });
    defer remote_check.deinit(a);
    try std.testing.expectEqualStrings("application", remote_check.ssh_host.?);
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "maintenance", "check", "--plan" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "version", "--ssh-host", "application" }));
}

test "station ingress hostname is explicit DNS configuration with CLI precedence" {
    const a = std.testing.allocator;
    var options = try parse(a, &.{ "monitoring", "install", "--ssh-host", "ssh-alias", "--ingress-hostname", "tls.example", "--config", "station.toml" });
    defer options.deinit(a);
    try mergeText(a, &options, "version=1\n[ingress]\nhostname='config.example'\n");
    try std.testing.expectEqualStrings("tls.example", options.ingress_hostname.?);
    var configured = try parse(a, &.{ "monitoring", "verify", "--config", "station.toml" });
    defer configured.deinit(a);
    try mergeText(a, &configured, "version=1\n[connection]\nssh_host='admin-alias'\n[ingress]\nhostname='config.example'\n");
    try std.testing.expectEqualStrings("config.example", configured.ingress_hostname.?);
    var reused = try parse(a, &.{ "monitoring", "install", "--ssh-host", "admin-alias" });
    defer reused.deinit(a);
    try std.testing.expect(reused.ingress_hostname == null);
    try std.testing.expectError(error.InvalidStationHostname, parse(a, &.{ "monitoring", "install", "--ssh-host", "alias", "--ingress-hostname", "https://station.example:9443" }));
    try std.testing.expectError(error.FlagNotAllowed, parse(a, &.{ "monitoring", "apply", "--ingress-hostname", "station.example" }));
}
