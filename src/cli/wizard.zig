const std = @import("std");
const parse = @import("parse.zig");
const spec = @import("spec.zig");
const remote = @import("../system/remote.zig");
const policy = @import("../monitoring/policy.zig");
const vt = @import("../components/victoriatraces.zig");
const targets = @import("../monitoring/agents/targets.zig");

/// The caller owns input storage and the operation arena. The wizard only reads,
/// writes, and returns ordinary CLI arguments; it never executes an operation.
pub const IO = struct {
    context: *anyopaque,
    readLine: *const fn (*anyopaque) anyerror!?[]const u8,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};

const Input = struct {
    a: std.mem.Allocator,
    io: IO,

    fn write(self: Input, value: []const u8) !void {
        try self.io.write(self.io.context, value);
    }

    fn prompt(self: Input, label: []const u8, default: ?[]const u8, optional: bool, flag: ?[]const u8, help: []const u8) ![]const u8 {
        while (true) {
            try self.write(label);
            if (default) |value| {
                try self.write(" [");
                try self.write(value);
                try self.write("]");
            }
            try self.write(": ");
            const line = self.io.readLine(self.io.context) catch |err| switch (err) {
                error.InputTooLong => {
                    try self.write("Input is too long. Please try again.\n");
                    continue;
                },
                else => return err,
            };
            const value = std.mem.trim(u8, line orelse return error.Cancelled, " \t\r\n");
            if (eq(value, "quit")) return error.Cancelled;
            if (eq(value, "back")) return error.Back;
            if (eq(value, "?")) {
                if (flag) |name| {
                    if (spec.flag(name)) |metadata| {
                        try self.write(metadata.description);
                        try self.write("\n");
                    }
                }
                try self.write(help);
                try self.write("\nEnter accepts a default; back returns to the previous step; quit cancels.\n");
                continue;
            }
            const answer = if (value.len == 0) default orelse value else value;
            if (answer.len == 0) {
                if (optional) return "";
                try self.write("A value is required.\n");
                continue;
            }
            if (flag) |name| {
                parse.validateValue(name, answer) catch |err| {
                    try self.write(validationMessage(err));
                    continue;
                };
            }
            // Terminal adapters may reuse their line buffer on the next read.
            return try self.a.dupe(u8, answer);
        }
    }

    fn choice(self: Input, label: []const u8, default: ?[]const u8, values: []const []const u8, help: []const u8) ![]const u8 {
        while (true) {
            const value = try self.prompt(label, default, false, null, help);
            for (values) |allowed| if (eq(value, allowed)) return value;
            try self.write("Choose one of the listed options.\n");
        }
    }

    fn yesNo(self: Input, label: []const u8, help: []const u8) !bool {
        const displayed = try std.fmt.allocPrint(self.a, "{s} [y/N]", .{label});
        while (true) {
            const value = try self.prompt(displayed, null, true, null, help);
            if (value.len == 0) return false;
            if (std.ascii.eqlIgnoreCase(value, "y") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
            if (std.ascii.eqlIgnoreCase(value, "n") or std.ascii.eqlIgnoreCase(value, "no")) return false;
            try self.write("Please enter yes or no.\n");
        }
    }

    fn list(self: Input, label: []const u8, flag: []const u8, required: bool, help: []const u8) ![]const []const u8 {
        var values: std.ArrayList([]const u8) = .empty;
        errdefer values.deinit(self.a);
        while (true) {
            const value = self.prompt(label, null, values.items.len > 0 or !required, flag, help) catch |err| switch (err) {
                error.Back => {
                    if (values.pop() != null) {
                        try self.write("Removed the previous entry.\n");
                        continue;
                    }
                    return error.Back;
                },
                else => return err,
            };
            if (value.len == 0) return values.toOwnedSlice(self.a);
            var duplicate = false;
            if (eq(flag, "--service") or eq(flag, "--metrics-target")) {
                for (values.items) |previous| {
                    const same = if (eq(flag, "--service")) eq(previous, value) else eq((try targets.parseOne(previous)).name, (try targets.parseOne(value)).name);
                    if (same) duplicate = true;
                }
                if (duplicate) {
                    try self.write("Duplicate selection. Use a unique service or target name.\n");
                    continue;
                }
                if (values.items.len >= 64) {
                    try self.write("At most 64 selections are supported.\n");
                    return values.toOwnedSlice(self.a);
                }
            }
            try values.append(self.a, value);
            if (!try self.yesNo("Add another?", "Enter yes to add another validated value.")) return values.toOwnedSlice(self.a);
        }
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn validationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSshHost => "Invalid SSH alias. Use a configured OpenSSH host name.\n",
        error.InvalidMetricsTarget, error.InvalidMetricsTargetName, error.InvalidMetricsTargetUrl => "Invalid metrics target. Use unique-name=http://127.0.0.1:PORT/metrics or another private literal address.\n",
        error.InvalidHost => "Invalid host. Use a hostname or IP address.\n",
        error.InvalidUser => "Invalid SSH user.\n",
        error.InvalidPort => "Invalid port. Use a number from 1 to 65535.\n",
        error.InvalidPath => "Invalid path. Config paths may be relative; SSH socket/identity paths must be absolute without whitespace, quotes, backslash, or percent expansions.\n",
        error.InvalidReference => "Invalid 1Password reference. Use an op:// reference, never a token or private key.\n",
        error.InvalidService => "Invalid service. Use a unit name ending in .service.\n",
        error.InvalidIP => "Invalid IP address.\n",
        error.InvalidDomain => "Invalid domain.\n",
        error.InvalidTLS => "Invalid TLS mode. Use manual or cloudflare.\n",
        error.InvalidChatID => "Invalid Telegram channel ID. Use a signed integer.\n",
        else => "Invalid value. Please try again.\n",
    };
}

const welcome =
    \\DragonTools
    \\Opinionated infrastructure tools for minimalistic architectures.
    \\
    \\  1. Install a monitoring station
    \\  2. Connect a server to a monitoring station
    \\  3. Verify a monitoring station
    \\  4. Check monitoring status
    \\  5. Configure monitoring firewall (unavailable)
    \\  6. Learn what DragonTools will install
    \\  7. Show command-line help
    \\  8. Apply application monitoring.toml
    \\  0. Exit
    \\
    \\Enter accepts defaults; ? explains a prompt; back goes back; quit exits.
    \\
;

const overview = std.fmt.comptimePrint(
    \\Implemented today
    \\  VictoriaMetrics: metrics on the station, bound to 127.0.0.1:8428.
    \\  Metrics retention: {d} days. Reserve: {d}% of data filesystem capacity.
    \\  Below the reserve, ingestion stops; this is not a hard disk quota.
    \\  VictoriaLogs: logs on the station, bound to 127.0.0.1:9428.
    \\  Logs retention: disk-bound, logical limit {s}; partition budget {d}% of capacity.
    \\  VictoriaTraces: traces on the station, bound to {s}.
    \\  Traces retention: disk-bound, logical limit {s}; partition budget {d}% of capacity.
    \\  Logs/traces cleanup is periodic and preserves the newest two partitions.
    \\  Each budget excludes other writers, so adequate headroom is required.
    \\  Grafana: local authentication and Metrics/Logs/Traces datasources, bound to 127.0.0.1:3000.
    \\  Blackbox exporter: HTTP/HTTPS GET with verified TLS, bound to 127.0.0.1:9115.
    \\  Native VictoriaMetrics scraper: 30s interval / 5s timeout; probe changes reload without restart.
    \\  vmalert-logs: 127.0.0.1:8880; vmalert-metrics: 127.0.0.1:8881; Alertmanager: 127.0.0.1:9093.
    \\  Probes and optional Telegram use the CLI --config TOML path; this wizard creates a station without them.
    \\  ServiceProbeFailed evaluates probe_success == 0 for 2m; down targets do not fail installation.
    \\  Access with an explicit SSH tunnel. The official VictoriaLogs plugin is pinned; dashboards remain unavailable.
    \\  Vector logs/host metrics and optional vmagent app metrics use the agents command.
    \\  SSH installation with strict host-key checks, dedicated service users,
    \\  pinned and checksum-verified binaries, and systemd hardening.
    \\
    \\Roadmap only - not installed or configured in this release
    \\  Monitoring station: dashboards and systemd-service state alerts.
    \\  Monitored server:
    \\    OpenTelemetry Collector  traces
    \\    automatic OS upgrades   deferred; read-only maintenance checks are available
    \\  Security: firewall automation and public Grafana TLS.
    \\  Host alerts use verified Vector metrics; service-state alerts remain deferred.
    \\  Intended defaults: disk warning {d}%, critical {d}%;
    \\    automatic OS security updates; no automatic reboot;
    \\    component updates notification only; Telegram optional.
    \\
    \\Agent installation must inspect and bound journald and verify actual
    \\signal arrival before it can report success. Firewall commands and
    \\roadmap configuration flags currently fail before SSH, including --plan.
    \\This overview contacts no hosts or secret providers.
    \\
,
    .{ policy.metrics.retention_days, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, vt.listen_address, policy.traces.retention, policy.traces.cleanup_usage_percent, policy.disk.warning_percent, policy.disk.critical_percent },
);

/// Returns validated argv without the executable name, or null on cancellation
/// or an information-only path. CLI help returns --help for normal dispatch.
/// Returned strings belong to the operation arena.
pub fn run(a: std.mem.Allocator, io: IO) !?[]const []const u8 {
    const input: Input = .{ .a = a, .io = io };
    return menu(input) catch |err| switch (err) {
        error.Cancelled => {
            try input.write("Cancelled. No operation was started.\n");
            return null;
        },
        else => return err,
    };
}

fn menu(input: Input) !?[]const []const u8 {
    while (true) {
        try input.write(welcome);
        const choice = input.choice("Choice", null, &.{ "0", "1", "2", "3", "4", "5", "6", "7", "8" }, "Choose a workflow, learn about the current release, or show CLI help.") catch |err| switch (err) {
            error.Back => continue,
            else => return err,
        };
        if (eq(choice, "0")) return null;
        if (eq(choice, "6")) {
            try input.write(overview);
            return null;
        }
        if (eq(choice, "7")) return &.{"--help"};
        const command: spec.Command = if (eq(choice, "8")) .app_apply else if (eq(choice, "1")) .install else if (eq(choice, "2")) .agents_install else if (eq(choice, "3")) .verify else if (eq(choice, "4")) .status else .firewall;
        return workflow(input, command) catch |err| switch (err) {
            error.Back => continue,
            else => return err,
        };
    }
}

const Step = enum { config, host, user, port, authentication, credential, extras, domain, tls, cloudflare, admin, agents, telegram, telegram_token, telegram_channel, station, services, metrics_targets, firewall_admin, firewall_agents, review };
const Answers = struct {
    command: spec.Command,
    config_path: []const u8 = "./monitoring.toml",
    host: []const u8 = "",
    user: []const u8 = "root",
    port: []const u8 = "22",
    authentication: []const u8 = "1",
    credential: []const u8 = "",
    extras: bool = false,
    domain: []const u8 = "",
    tls: []const u8 = "none",
    cloudflare: []const u8 = "",
    admins: []const []const u8 = &.{},
    agents: []const []const u8 = &.{},
    telegram: bool = false,
    telegram_token: []const u8 = "",
    telegram_channel: []const u8 = "",
    station: []const u8 = "",
    services: []const []const u8 = &.{},
    metrics_targets: []const []const u8 = &.{},

    fn argv(self: Answers, a: std.mem.Allocator) ![]const []const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        errdefer args.deinit(a);
        try args.appendSlice(a, spec.commandPath(self.command));
        if (spec.applicationCommand(self.command)) {
            try args.appendSlice(a, &.{ "--config", self.config_path });
            return args.toOwnedSlice(a);
        }
        if (self.command == .agents_install) {
            try args.appendSlice(a, &.{ "--ssh-host", self.host });
        } else {
            try args.appendSlice(a, &.{ "--host", self.host, "--user", self.user, "--port", self.port });
            if (self.authFlag()) |flag| try args.appendSlice(a, &.{ flag, self.credential });
        }
        if (self.command == .install and self.extras) {
            if (self.domain.len > 0) try args.appendSlice(a, &.{ "--domain", self.domain });
            if (!eq(self.tls, "none")) try args.appendSlice(a, &.{ "--tls", self.tls });
            if (eq(self.tls, "cloudflare")) try args.appendSlice(a, &.{ "--cloudflare-token-op", self.cloudflare });
            if (self.telegram) try args.appendSlice(a, &.{ "--telegram-bot-token-op", self.telegram_token, "--telegram-channel-id", self.telegram_channel });
        }
        if ((self.command == .install and self.extras) or self.command == .firewall) {
            for (self.admins) |value| try args.appendSlice(a, &.{ "--admin-ip", value });
            for (self.agents) |value| try args.appendSlice(a, &.{ "--agent-ip", value });
        }
        if (self.command == .agents_install) {
            try args.appendSlice(a, &.{ "--station", self.station });
            for (self.services) |value| try args.appendSlice(a, &.{ "--service", value });
            for (self.metrics_targets) |value| try args.appendSlice(a, &.{ "--metrics-target", value });
        }
        return args.toOwnedSlice(a);
    }

    fn authFlag(self: Answers) ?[]const u8 {
        if (eq(self.authentication, "2") or eq(self.authentication, "4")) return "--ssh-sock";
        if (eq(self.authentication, "3")) return "--identity";
        if (eq(self.authentication, "5")) return "--ssh-op-path";
        return null;
    }

    fn afterConnection(self: Answers) Step {
        return switch (self.command) {
            .install => .extras,
            .agents_install => .station,
            .firewall => .firewall_admin,
            else => .review,
        };
    }
};

fn workflow(input: Input, command: spec.Command) !?[]const []const u8 {
    var answers: Answers = .{ .command = command };
    var step: Step = if (spec.applicationCommand(command)) .config else .host;
    var history: std.ArrayList(Step) = .empty;
    defer history.deinit(input.a);
    if (command == .install) try input.write(std.fmt.comptimePrint("\nThis release installs eight loopback services: VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana, blackbox exporter, Alertmanager and two vmalert instances.\nMetrics retention is {d} days, with a {d}% data filesystem reserve.\nLogs retain as much history as fits, with a {s} logical limit and a {d}%\nfilesystem-capacity partition budget.\nTraces use a {s} logical limit and a {d}% filesystem-capacity partition budget.\nBoth budgets exclude other writers and preserve the newest two partitions.\nCleanup is periodic; adequate capacity/headroom is required. These defaults are fixed.\nConfigure application hosts separately with monitoring agents. Reruns inspect actual state,\nresume pending activation, and leave healthy unchanged services running.\n", .{ policy.metrics.retention_days, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, policy.traces.retention, policy.traces.cleanup_usage_percent }));
    if (command == .agents_install) try input.write("\nInstall Vector for selected journald services and host metrics. Optional\nprivate application endpoints enable vmagent. The installer must inspect and bound\njournald and verify station signal arrival before reporting success.\nUse configured OpenSSH aliases for both hosts; no secret is requested here.\nOTel traces agents remain unavailable.\n");
    if (command == .firewall) try input.write("\nFirewall management is unavailable; even --plan is rejected before SSH.\nIntended policy: admin IPs may access SSH and Grafana; agent IPs may submit\ntelemetry only. DragonTools will manage monitoring-related rules only and\nmust preserve unrelated administrator configuration. This helper previews\nfuture configuration; it cannot claim that access restrictions are applied.\n");
    while (true) {
        if (step == .review) {
            const args = try answers.argv(input.a);
            var options = try parse.parse(input.a, args);
            defer options.deinit(input.a);
            try preview(input, args, options);
            if (command == .verify or command == .status) {
                const proceed = input.yesNo("Run this read-only check?", "This uses the ordinary CLI read-only workflow and its strict SSH checks.") catch |err| switch (err) {
                    error.Back => {
                        step = history.pop() orelse return error.Back;
                        continue;
                    },
                    else => return err,
                };
                if (proceed) return args;
                return error.Cancelled;
            }
            try input.write("\n  1. Show plan only\n  2. Apply\n  3. Go back\n  4. Cancel\n");
            const selected = input.choice("Action", "4", &.{ "1", "2", "3", "4" }, "Plan routes through --plan. Apply requires a separate default-No confirmation.") catch |err| switch (err) {
                error.Back => "3",
                else => return err,
            };
            if (eq(selected, "3")) {
                step = history.pop() orelse return error.Back;
                continue;
            }
            if (eq(selected, "4")) return error.Cancelled;
            if (eq(selected, "1")) {
                var planned: std.ArrayList([]const u8) = .empty;
                try planned.appendSlice(input.a, args);
                try planned.append(input.a, "--plan");
                const plan_args = try planned.toOwnedSlice(input.a);
                var validated = try parse.parse(input.a, plan_args);
                defer validated.deinit(input.a);
                try input.write("Selected ordinary CLI --plan; no wizard deployment or planner is used.\n");
                try commandPreview(input, plan_args);
                return plan_args;
            }
            const confirmed = input.yesNo("Continue?", "Only yes authorizes the existing CLI mutation; Enter cancels.") catch |err| switch (err) {
                error.Back => continue,
                else => return err,
            };
            if (confirmed) return args;
            return error.Cancelled;
        }
        const next = answerStep(input, &answers, step) catch |err| switch (err) {
            error.Back => {
                step = history.pop() orelse return error.Back;
                continue;
            },
            else => return err,
        };
        try history.append(input.a, step);
        step = next;
    }
}

fn answerStep(input: Input, answers: *Answers, step: Step) !Step {
    switch (step) {
        .config => {
            answers.config_path = try input.prompt("Application monitoring config", "./monitoring.toml", false, "--config", "One strict application monitoring.toml file. Normal dispatch validates it before SSH. No station secrets belong in this file.");
            return .review;
        },
        .host => {
            if (answers.command == .agents_install) {
                answers.host = try input.prompt("Application host SSH alias", null, false, "--ssh-host", "Use the application's configured OpenSSH alias. Enroll its verified host key in known_hosts first.");
                return .station;
            }
            answers.host = try input.prompt("Monitoring station host", null, false, "--host", "Use a hostname or IP address. Enroll the verified host key in known_hosts first.");
            return .user;
        },
        .user => {
            answers.user = try input.prompt("SSH user", "root", false, "--user", "Use root or a user with noninteractive sudo -n privileges.");
            return .port;
        },
        .port => {
            answers.port = try input.prompt("SSH port", "22", false, "--port", "The server's SSH port, from 1 to 65535.");
            return .authentication;
        },
        .authentication => {
            try input.write("\nSSH authentication:\n  1. Default SSH agent and OpenSSH identities\n  2. Custom SSH agent socket\n  3. Identity file\n  4. 1Password SSH agent socket\n  5. Private key from 1Password (unavailable)\n");
            answers.authentication = try input.choice("Authentication", "1", &.{ "1", "2", "3", "4", "5" }, "Only one authentication mode is used. Strict host-key checks always remain enabled. Identity passphrases cannot be prompted; use an agent.");
            answers.credential = "";
            return if (answers.authFlag() != null) .credential else answers.afterConnection();
        },
        .credential => {
            const flag = answers.authFlag().?;
            if (eq(answers.authentication, "5")) try input.write("Private-key references are unavailable and are rejected before SSH. Only\nreference syntax is checked; no key will be fetched or written to a file.\n");
            answers.credential = try input.prompt(if (eq(answers.authentication, "5")) "1Password private-key reference" else if (eq(answers.authentication, "3")) "Identity file (absolute path)" else "SSH agent socket (absolute path)", null, false, flag, "For 1Password agent mode, use the socket path configured in 1Password. Never paste a private key or token.");
            return answers.afterConnection();
        },
        .extras => {
            answers.extras = try input.yesNo("Collect roadmap-only domain/TLS/IP/Telegram settings?", "Choose no for the working eight-service station. Configure probes and Telegram separately with CLI --config. Supplying roadmap flags makes the CLI reject the operation before SSH, even in plan mode.");
            if (answers.extras) try input.write("These optional integrations are unavailable. Any supplied roadmap flags\nwill be validated, then rejected before SSH, including in --plan mode.\n");
            return if (answers.extras) .domain else .review;
        },
        .domain => {
            answers.domain = try input.prompt("Monitoring domain (optional; Enter skips)", null, true, "--domain", "A future Grafana/TLS domain. Domain configuration is not implemented.");
            return .tls;
        },
        .tls => {
            const modes = spec.flag("--tls").?.values;
            var choices: std.ArrayList([]const u8) = .empty;
            defer choices.deinit(input.a);
            try choices.append(input.a, "none");
            try choices.appendSlice(input.a, modes);
            const label = try std.mem.join(input.a, ", ", choices.items);
            answers.tls = try input.choice(try std.fmt.allocPrint(input.a, "TLS: {s}", .{label}), "none", choices.items, "Roadmap DNS-01 modes: manual TXT challenge or a scoped Cloudflare token. Neither is implemented.");
            if (!eq(answers.tls, "none")) try parse.validateValue("--tls", answers.tls);
            return if (eq(answers.tls, "cloudflare")) .cloudflare else .admin;
        },
        .cloudflare => {
            answers.cloudflare = try input.prompt("Cloudflare token 1Password reference", null, false, "--cloudflare-token-op", "Use an op:// reference only. Protected credential files are not yet supported by the CLI. No secret will be resolved here.");
            return .admin;
        },
        .admin, .firewall_admin => {
            try input.write("Intended admin allowance: SSH and Grafana from these source IPs.\nAgents use a separate telemetry-only allowance. Rules are not implemented.\n");
            answers.admins = try input.list("Admin IP (Enter finishes)", "--admin-ip", step == .firewall_admin, "Use individual IPv4 or IPv6 addresses. This release does not apply firewall rules.");
            return if (step == .firewall_admin) .firewall_agents else .agents;
        },
        .agents, .firewall_agents => {
            answers.agents = try input.list("Agent IP (optional; Enter finishes)", "--agent-ip", false, "Use the source IP of a monitored server. Agents must not inherit SSH, Grafana, or backend administrative access.");
            return if (step == .firewall_agents) .review else .telegram;
        },
        .telegram => {
            answers.telegram = try input.yesNo("Telegram notifications?", "This legacy wizard flow produces unavailable flags. Working Telegram uses paired op references in [telegram] through CLI --config. No token is requested or resolved here.");
            return if (answers.telegram) .telegram_token else .review;
        },
        .telegram_token => {
            answers.telegram_token = try input.prompt("Telegram bot token 1Password reference", null, false, "--telegram-bot-token-op", "Use an op:// reference, never paste a token. This legacy flag is unavailable; use [telegram] in a CLI --config file for the working integration.");
            return .telegram_channel;
        },
        .telegram_channel => {
            answers.telegram_channel = try input.prompt("Telegram channel ID", null, false, "--telegram-channel-id", "Use the numeric channel/chat ID, which may be negative.");
            return .review;
        },
        .station => {
            answers.station = try input.prompt("Monitoring station SSH alias", null, false, "--station", "Use the station connection name in your OpenSSH configuration, not an ingestion URL. DragonTools owns the ports.");
            return .services;
        },
        .services => {
            answers.services = try input.list("Service", "--service", true, "Use a complete .service unit name. Only selected units' journal entries are forwarded.");
            return .metrics_targets;
        },
        .metrics_targets => {
            answers.metrics_targets = try input.list("Metrics target (optional; Enter finishes)", "--metrics-target", false, "Use name=http://127.0.0.1:PORT/metrics. Only HTTP/HTTPS localhost/private literal endpoints are accepted; vmagent is omitted without targets.");
            return .review;
        },
        .review => unreachable,
    }
}

fn commandPreview(input: Input, args: []const []const u8) !void {
    const displayed = try input.a.dupe([]const u8, args);
    defer input.a.free(displayed);
    // References may legally contain Unicode. Hide these in terminal output so
    // they cannot introduce directional controls or non-ASCII terminal escapes.
    for (args, 0..) |arg, i| {
        if (i == 0) continue;
        const metadata = spec.flag(args[i - 1]) orelse continue;
        if (metadata.kind != .reference) continue;
        for (arg) |byte| {
            if (byte < 32 or byte > 126) {
                displayed[i] = "[reference hidden: non-ASCII]";
                break;
            }
        }
    }
    const quoted = try remote.shell(input.a, displayed);
    try input.write("\nDragonTools will run the equivalent of:\n\ndragontool ");
    try input.write(quoted);
    try input.write("\n\n");
}

fn preview(input: Input, args: []const []const u8, options: parse.Options) !void {
    if (spec.applicationCommand(options.command)) {
        try input.write("\nApplication monitoring: ordinary CLI dispatch validates the config before SSH.\nHost metrics are automatic; logs, private metrics, probes and alerts follow the file.\nPlan is local; apply uses the target/station OpenSSH aliases declared in the file.\nNo secret is resolved by this wizard.\n");
        try commandPreview(input, args);
        return;
    }

    try commandPreview(input, args);
    const summary = if (options.command == .agents_install) try std.fmt.allocPrint(input.a, "Connect monitored server: Vector and optional vmagent\nApplication host SSH alias: {s}\n", .{options.ssh_host.?}) else try std.fmt.allocPrint(input.a, "{s}\nHost: {s}\nSSH user: {s}\nSSH port: {d}\n", .{ switch (options.command) {
        .install => "Monitoring station: VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana",
        .verify => "Verify monitoring station (read-only health checks)",
        .status => "Monitoring status (read-only state summary)",
        .agents_install => "Connect monitored server: Vector and optional vmagent",
        .firewall => "Monitoring firewall (unavailable)",
        else => "Monitoring operation",
    }, options.ssh_host orelse options.host, options.user, options.port });
    try input.write(summary);
    if (options.command == .install) {
        try input.write(try std.fmt.allocPrint(input.a, "Domain: {s}\nAdmin IPs: {d}\nAgent IPs: {d}\nTLS: {s}\nTelegram: {s}\nStorage: metrics {d} days; {d}% data filesystem reserve.\nLogs: disk-bound retention, logical limit {s}; partition budget {d}% of filesystem capacity (other writers excluded).\nTraces: disk-bound retention, logical limit {s}; partition budget {d}% of filesystem capacity (other writers excluded).\nListeners: loopback:8428 (metrics), loopback:9428 (logs), loopback:{d} (traces), loopback:3000 (Grafana).\nBlackbox: loopback:9115; Alertmanager: loopback:9093; vmalert logs/metrics: loopback:8880/8881.\nProbes and Telegram require the CLI --config path; this wizard does not configure them.\nGrafana local authentication is enabled. Access via SSH forwarding only.\nMetrics, Logs and Traces are provisioned; dashboards are unavailable.\nApplication hosts use monitoring agents separately. An unchanged rerun requires no restart.\n", .{ options.domain orelse "none", options.admin_ips.items.len, options.agent_ips.items.len, options.tls orelse "none", if (options.telegram_token_op != null) "requested (unavailable)" else "disabled", policy.metrics.retention_days, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, policy.traces.retention, policy.traces.cleanup_usage_percent, vt.port }));
    }
    if (options.command == .agents_install) try input.write(try std.fmt.allocPrint(input.a, "Station SSH alias: {s}\nServices: {d}\nApplication metrics targets: {d}\nSSH users and authentication come from OpenSSH configuration.\n", .{ options.station orelse "none", options.services.items.len, options.metrics_targets.items.len }));
    if (options.command == .firewall) try input.write(try std.fmt.allocPrint(input.a, "Admin IPs: {d}\nAgent IPs: {d}\nNo firewall rules can be applied in this release.\n", .{ options.admin_ips.items.len, options.agent_ips.items.len }));
    if (options.unsupported()) try input.write("Unavailable configuration: the ordinary CLI will reject this request\nbefore SSH, including --plan. No installation success will be reported.\n");
    try input.write("Printable ASCII secret references are shown literally; other references\nare hidden in this preview. No secrets have been resolved.\n");
}

const Script = struct {
    a: std.mem.Allocator,
    lines: []const []const u8,
    position: usize = 0,
    output: std.ArrayList(u8) = .empty,
    cancel_at: ?usize = null,
    oversized_at: ?usize = null,

    fn io(self: *Script) IO {
        return .{ .context = self, .readLine = read, .write = write };
    }

    fn read(context: *anyopaque) !?[]const u8 {
        const self: *Script = @ptrCast(@alignCast(context));
        if (self.cancel_at == self.position) return error.Cancelled;
        if (self.oversized_at == self.position) {
            self.position += 1;
            return error.InputTooLong;
        }
        if (self.position >= self.lines.len) return null;
        defer self.position += 1;
        return self.lines[self.position];
    }

    fn write(context: *anyopaque, message: []const u8) !void {
        const self: *Script = @ptrCast(@alignCast(context));
        try self.output.appendSlice(self.a, message);
    }

    fn contains(self: Script, text: []const u8) bool {
        return std.mem.indexOf(u8, self.output.items, text) != null;
    }
};

test "wizard defaults generate the same supported install plan as regular CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var script: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "", "", "1" } };
    const args = (try run(a, script.io())).?;
    const expected = [_][]const u8{ "monitoring", "install", "--host", "monitor.example.com", "--user", "root", "--port", "22", "--plan" };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |value, actual| try std.testing.expectEqualStrings(value, actual);
    var options = try parse.parse(a, args);
    defer options.deinit(a);
    try std.testing.expect(options.plan);
    try std.testing.expect(!options.unsupported());
    try std.testing.expect(script.contains("Metrics retention is 90 days"));
    try std.testing.expect(script.contains("VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana"));
    try std.testing.expect(script.contains("logical limit 100y; partition budget 75%"));
    try std.testing.expect(script.contains("20%"));
    try std.testing.expect(script.contains("dragontool 'monitoring' 'install'"));
}

test "wizard retries required, malformed and oversized input with authoritative validators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var script: Script = .{ .a = a, .oversized_at = 2, .lines = &.{ "1", "", "oversized", "bad;host", "monitor.example.com", "bad user", "ops", "0", "2222", "9", "3", "relative", "/tmp/key", "", "1" } };
    const args = (try run(a, script.io())).?;
    var options = try parse.parse(a, args);
    defer options.deinit(a);
    try std.testing.expectEqualStrings("ops", options.user);
    try std.testing.expectEqual(@as(u16, 2222), options.port);
    try std.testing.expectEqualStrings("/tmp/key", options.identity.?);
    try std.testing.expect(script.contains("A value is required."));
    try std.testing.expect(script.contains("Input is too long."));
    try std.testing.expect(script.contains("Invalid host."));
    try std.testing.expect(script.contains("Invalid SSH user."));
    try std.testing.expect(script.contains("Invalid port."));
    try std.testing.expect(script.contains("Invalid path."));
    try std.testing.expect(!script.contains("bad;host"));
}

test "wizard applying requires explicit yes and Enter cancels without a command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var no: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "", "", "2", "" } };
    try std.testing.expect((try run(a, no.io())) == null);
    try std.testing.expect(no.contains("Continue? [y/N]"));
    try std.testing.expect(no.contains("Cancelled. No operation was started."));
    var yes: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "", "", "2", "yes" } };
    var options = try parse.parse(a, (try run(a, yes.io())).?);
    defer options.deinit(a);
    try std.testing.expect(!options.plan);
    try std.testing.expect(!options.unsupported());
}

test "wizard quit, EOF, Ctrl+C and default action cancel cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var quit: Script = .{ .a = a, .lines = &.{ "1", "quit" } };
    try std.testing.expect((try run(a, quit.io())) == null);
    var eof: Script = .{ .a = a, .lines = &.{"1"} };
    try std.testing.expect((try run(a, eof.io())) == null);
    var interrupt: Script = .{ .a = a, .cancel_at = 1, .lines = &.{"1"} };
    try std.testing.expect((try run(a, interrupt.io())) == null);
    var action: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "", "", "" } };
    try std.testing.expect((try run(a, action.io())) == null);
}

test "wizard back revisits previous field and contextual help uses shared metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var script: Script = .{ .a = a, .lines = &.{ "1", "old.example.com", "back", "?", "new.example.com", "", "", "", "", "1" } };
    var options = try parse.parse(a, (try run(a, script.io())).?);
    defer options.deinit(a);
    try std.testing.expectEqualStrings("new.example.com", options.host);
    try std.testing.expect(script.contains(spec.flag("--host").?.description));
    try std.testing.expect(!script.contains("old.example.com"));
}

test "wizard roadmap credentials remain references and command preview is shell quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference = "op://Infrastructure/Cloudflare's $(literal)/token";
    var script: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "4", "/tmp/agent.sock", "yes", "monitor.example.com", "cloudflare", "plaintext-token", reference, "999.1.1.1", "203.0.113.20", "", "203.0.113.30", "", "yes", "op://Infrastructure/Telegram/token", "bad-id", "-1234", "1" } };
    const args = (try run(a, script.io())).?;
    var options = try parse.parse(a, args);
    defer options.deinit(a);
    try std.testing.expect(options.unsupported());
    try std.testing.expect(options.plan);
    try std.testing.expectEqualStrings(reference, options.cloudflare_token_op.?);
    try std.testing.expectEqualStrings("/tmp/agent.sock", options.ssh_sock.?);
    try std.testing.expect(script.contains("'op://Infrastructure/Cloudflare'\\''s $(literal)/token'"));
    try std.testing.expect(!script.contains("plaintext-token"));
    try std.testing.expect(script.contains("Invalid IP address."));
    try std.testing.expect(script.contains("Invalid Telegram channel ID."));
    try std.testing.expect(script.contains("No installation success will be reported."));
}

test "wizard manual TLS skips Cloudflare and disabled Telegram skips reference prompts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var script: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "", "yes", "", "manual", "", "", "", "1" } };
    var options = try parse.parse(a, (try run(a, script.io())).?);
    defer options.deinit(a);
    try std.testing.expectEqualStrings("manual", options.tls.?);
    try std.testing.expect(options.cloudflare_token_op == null);
    try std.testing.expect(options.telegram_token_op == null);
    try std.testing.expect(!script.contains("Cloudflare token 1Password reference:"));
    try std.testing.expect(!script.contains("Telegram bot token 1Password reference:"));
}

test "wizard hides non-ASCII references in previews without changing CLI arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference = "op://Infrastructure/\xe2\x80\xaeKey/private_key";
    var script: Script = .{ .a = a, .lines = &.{ "1", "monitor.example.com", "", "", "5", reference, "", "1" } };
    var options = try parse.parse(a, (try run(a, script.io())).?);
    defer options.deinit(a);
    try std.testing.expectEqualStrings(reference, options.ssh_op_path.?);
    try std.testing.expect(options.unsupported());
    try std.testing.expect(script.contains("[reference hidden: non-ASCII]"));
    try std.testing.expect(!script.contains(reference));
    for (script.output.items) |byte| try std.testing.expect(byte < 128 and byte != 27);
}

test "wizard agent command validates station aliases repeated services and private metrics targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var script: Script = .{ .a = a, .lines = &.{ "2", "app", "http://monitoring", "monitoring", "bad.service;id", "one.service", "yes", "one.service", "two.service", "", "app=http://public.example/metrics", "app=http://127.0.0.1:16000/metrics", "", "1" } };
    var options = try parse.parse(a, (try run(a, script.io())).?);
    defer options.deinit(a);
    try std.testing.expectEqual(spec.Command.agents_install, options.command);
    try std.testing.expectEqual(@as(usize, 2), options.services.items.len);
    try std.testing.expectEqualStrings("two.service", options.services.items[1]);
    try std.testing.expect(!options.unsupported());
    try std.testing.expectEqualStrings("monitoring", options.station.?);
    try std.testing.expectEqualStrings("app", options.ssh_host.?);
    try std.testing.expectEqual(@as(usize, 1), options.metrics_targets.items.len);
    try std.testing.expect(script.contains("Invalid SSH alias."));
    try std.testing.expect(script.contains("Duplicate selection."));
    try std.testing.expect(script.contains("Invalid metrics target."));
    try std.testing.expect(script.contains("Invalid service."));
    try std.testing.expect(script.contains("inspect and bound\njournald"));
}

test "wizard firewall remains unavailable and requires admin IP plus confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var script: Script = .{ .a = a, .lines = &.{ "5", "monitor.example.com", "", "", "", "", "203.0.113.20", "", "", "2", "yes" } };
    var options = try parse.parse(a, (try run(a, script.io())).?);
    defer options.deinit(a);
    try std.testing.expectEqual(spec.Command.firewall, options.command);
    try std.testing.expectEqual(@as(usize, 1), options.admin_ips.items.len);
    try std.testing.expect(options.unsupported());
    try std.testing.expect(script.contains("A value is required."));
    try std.testing.expect(script.contains("Continue? [y/N]"));
    try std.testing.expect(script.contains("preserve unrelated administrator configuration"));
}

test "wizard verification and status use regular read-only commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "3", "4" }, [_]spec.Command{ .verify, .status }) |choice, command| {
        var script: Script = .{ .a = a, .lines = &.{ choice, "monitor.example.com", "", "", "", "yes" } };
        var options = try parse.parse(a, (try run(a, script.io())).?);
        defer options.deinit(a);
        try std.testing.expectEqual(command, options.command);
        try std.testing.expect(!options.plan);
        try std.testing.expect(!script.contains("Collect roadmap-only"));
        try std.testing.expect(!script.contains("  2. Apply"));
    }
}

test "wizard information and CLI help are local and ASCII only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: Script = .{ .a = a, .lines = &.{"6"} };
    try std.testing.expect((try run(a, info.io())) == null);
    try std.testing.expect(info.contains("Implemented today"));
    try std.testing.expect(info.contains("Roadmap only"));
    try std.testing.expect(info.contains("no automatic reboot"));
    try std.testing.expect(info.contains("component updates notification only"));
    try std.testing.expect(!info.contains("Monitoring station host:"));
    for (info.output.items) |byte| try std.testing.expect(byte < 128 and byte != 27);
    var help: Script = .{ .a = a, .lines = &.{"7"} };
    var options = try parse.parse(a, (try run(a, help.io())).?);
    defer options.deinit(a);
    try std.testing.expect(options.help);
}

test "application wizard previews regular config CLI with local plan and default no mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Script = .{ .a = a, .lines = &.{ "8", "", "1" } };
    const args = (try run(a, plan.io())).?;
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("apply", args[1]);
    try std.testing.expectEqualStrings("./monitoring.toml", args[3]);
    try std.testing.expectEqualStrings("--plan", args[4]);
    try std.testing.expect(plan.contains("dragontool 'monitoring' 'apply' '--config' './monitoring.toml'"));
    var denied: Script = .{ .a = a, .lines = &.{ "8", "examples/doers-monitoring.toml", "2", "" } };
    try std.testing.expect((try run(a, denied.io())) == null);
    try std.testing.expect(denied.contains("[y/N]"));
    var confirmed: Script = .{ .a = a, .lines = &.{ "8", "examples/doers-monitoring.toml", "2", "yes" } };
    const apply = (try run(a, confirmed.io())).?;
    try std.testing.expectEqual(@as(usize, 4), apply.len);
    try std.testing.expectEqualStrings("examples/doers-monitoring.toml", apply[3]);
}
