const std = @import("std");
const cli = @import("cli/parse.zig");
const help = @import("cli/help.zig");
const completion = @import("cli/completion.zig");
const terminal = @import("cli/terminal.zig");
const policy = @import("monitoring/policy.zig");
const vt = @import("components/victoriatraces.zig");
const plan = @import("monitoring/plan.zig");
const progress = @import("monitoring/progress.zig");
const ProgressOutput = struct {
    io: std.Io,
    fn write(context: *anyopaque, event: progress.Event) void {
        const self: *ProgressOutput = @ptrCast(@alignCast(context));
        print(self.io, event.text());
    }
};
fn print(io: std.Io, message: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, message) catch {};
}
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const detail: ?[]const u8 = switch (err) {
            error.ApplicationTracesUnsupported => "Traces are declared but not supported by this DragonTools build. Nothing changed; SSH was not attempted.\n",
            error.ApplicationMetricsAlertsUnsupported => "Custom metrics alerts are not supported by this DragonTools build. Nothing changed; SSH was not attempted.\n",
            error.UnableToReadApplicationConfig => "Unable to read application config. The default is ./monitoring.toml; use --config for an explicit path. Nothing changed; SSH was not attempted.\n",
            else => null,
        };
        if (detail) |message| std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        const msg = std.fmt.allocPrint(init.arena.allocator(), "Error: {s}. Argument values and remote stderr are omitted from this error. See --help.\n", .{@errorName(err)}) catch "Error: operation failed.\n";
        std.Io.File.stderr().writeStreamingAll(init.io, msg) catch {};
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var input: []const []const u8 = args[1..];
    if (try terminal.shouldWelcome(args.len - 1, init.io)) {
        input = try terminal.run(a, init.io) orelse return;
    }
    var options = try cli.parse(a, input);
    defer options.deinit(a);
    if (options.help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, try help.render(a, options.node));
        return;
    }
    if (options.action == .completion) {
        try std.Io.File.stdout().writeStreamingAll(init.io, try completion.render(a, options.shell.?));
        return;
    }
    if (options.action == .wizard) {
        const wizard_args = try terminal.run(a, init.io) orelse return;
        const selected = try cli.parse(a, wizard_args);
        options.deinit(a);
        options = selected;
        if (options.help) {
            try std.Io.File.stdout().writeStreamingAll(init.io, try help.render(a, options.node));
            return;
        }
    }
    try cli.loadAndMerge(a, init.io, &options);
    try execute(init, options);
}
/// Both CLI arguments and wizard answers reach this one existing operation path.
fn execute(init: std.process.Init, options: cli.Options) !void {
    const a = init.arena.allocator();
    if (options.unsupported()) {
        print(init.io, "Requested workflow or integration is not yet available. Nothing changed; SSH was not attempted.\n");
        return error.NotImplemented;
    }
    if (options.command == .install_oh_my_zsh) {
        try personalizeHost(init, options);
        return;
    }
    if (options.command == .app_apply or options.command == .app_verify or options.command == .app_status) {
        try @import("monitoring/apps/dispatch.zig").run(init, options);
        return;
    }
    if (options.command == .agents_install or options.command == .agents_verify or options.command == .agents_status) {
        try @import("monitoring/agents/dispatch.zig").run(init, options);
        return;
    }
    if (options.plan) {
        print(init.io, try plan.renderStation(a, options.grafana_user_op != null, options.telegram_bot_token_op != null, options.probes.len));
        return;
    }
    if (options.command == .notify_test and options.telegram_bot_token_op == null) return error.TelegramConfigurationRequired;
    // Resolve locally before even the first SSH inspection. Status and plan
    // never need secret values. All sensitive allocations have short lifetimes.
    const credentials = if ((options.command == .install or options.command == .verify) and options.grafana_user_op != null) credentials: {
        var provider: @import("secrets/onepassword.zig").Local = .{ .io = init.io };
        const references = @import("secrets/reference.zig");
        break :credentials @import("secrets/grafana.zig").payload(std.heap.page_allocator, provider.resolver(), try references.parseOnePassword(options.grafana_user_op.?), try references.parseOnePassword(options.grafana_password_op.?)) catch |err| {
            print(init.io, switch (err) {
                error.GrafanaUsernameResolutionFailed => "Unable to resolve Grafana administrator username from configured secret reference. Check the local 1Password CLI and its authentication.\n",
                error.GrafanaPasswordResolutionFailed => "Unable to resolve Grafana administrator password from configured secret reference. Check the local 1Password CLI and its authentication.\n",
                else => "Unable to use configured Grafana administrator credentials. Secret contents are omitted.\n",
            });
            return err;
        };
    } else null;
    defer if (credentials) |secret| secret.deinit();
    const telegram = if (options.command == .install and options.telegram_bot_token_op != null) telegram: {
        var provider: @import("secrets/onepassword.zig").Local = .{ .io = init.io };
        const references = @import("secrets/reference.zig");
        break :telegram try @import("secrets/telegram.zig").payload(std.heap.page_allocator, provider.resolver(), try references.parseOnePassword(options.telegram_bot_token_op.?), try references.parseOnePassword(options.telegram_chat_id_op.?));
    } else null;
    defer if (telegram) |secret| secret.deinit();
    var ssh: @import("system/ssh.zig").Ssh = .{ .allocator = a, .io = init.io, .options = options };
    const r = ssh.asRemote();
    var progress_output: ProgressOutput = .{ .io = init.io };
    var report: @import("monitoring/install.zig").Report = .{ .station_enabled = true, .probes = options.probes, .telegram_credentials = telegram, .telegram_configured = options.telegram_bot_token_op != null, .grafana_credentials = credentials, .progress = .{ .context = &progress_output, .write = ProgressOutput.write } };
    switch (options.command) {
        .install, .verify => {
            print(init.io, if (options.command == .install) "Installing the monitoring station over SSH (eight services)...\n" else "Verifying the monitoring station over SSH (eight services)...\n");
            const result = if (options.command == .install) @import("monitoring/install.zig").install(a, r, &report) else @import("monitoring/verify.zig").verify(a, r, &report);
            result catch |err| {
                const advice = if (options.command == .install)
                    "The failed step may have partially changed the host. Later steps were not attempted. Fix the cause and rerun the same command; pending restart intent is preserved. No rollback was attempted."
                else
                    "Verification is read-only. Later checks were not attempted. Correct the cause and repeat verification.";
                print(init.io, try std.fmt.allocPrint(a, "Failed at {s}; {d} steps completed, {d} change steps confirmed. Component: {s}. Check: {s}. {s} Check SSH/prerequisites for detection failures, or inspect the managed unit and journal for later failures.\n", .{ @tagName(report.phase), report.completed, report.changes, if (report.component) |component| component.name() else "host", if (report.check) |check| @tagName(check) else @tagName(report.phase), advice }));
                return err;
            };
            if (options.command == .install and report.changes == 0) print(init.io, "No changes required.\n");
            print(init.io, try std.fmt.allocPrint(a, "VictoriaMetrics: loopback:8428\n  healthy; self-scraped metrics queryable\n  retention: {s}; free-space reserve: {d} bytes ({d}% of filesystem capacity)\nVictoriaLogs: loopback:9428\n  healthy; writable storage\n  retention: disk-bound; logical limit: {s}; native partition budget: {d}% of filesystem capacity\nVictoriaTraces: loopback:{d}\n  healthy; writable storage\n  retention: disk-bound; logical limit: {s}; native partition budget: {d}% of filesystem capacity\n  Logs/traces cleanup is periodic and preserves the newest two partitions; other writers can fill the filesystem earlier.\nGrafana: loopback:3000\n  healthy; local authentication enabled\n  administrator credentials {s}\n  Metrics datasource: provisioning and backend query verified\n  Logs datasource: provisioning and backend query verified\n  Traces datasource: provisioning and backend query verified\n  Logs plugin: {s}\n  Metrics/Traces query-engine and browser UI validation remain manual integration checks\nAccess through an explicit SSH tunnel.{s}\n", .{ policy.metrics.retention, report.reserve_bytes, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, vt.port, policy.traces.retention, policy.traces.cleanup_usage_percent, if (credentials != null) "verified" else "unmanaged", if (report.logs_query_verified) "health and authenticated query verified" else "authenticated query unchecked; configure administrator references to verify", if (credentials != null) "" else " Change the initial administrator password at first login." }));
            print(init.io, try std.fmt.allocPrint(a, "Blackbox exporter: loopback:9115\n  healthy; HTTP/HTTPS GET probes; TLS verification enabled\nVictoriaMetrics native scraper: {d} configured probes\n  loaded definitions and fresh stored probe telemetry verified\n  a down target is valid monitoring state\nvmalert-logs: loopback:8880\n  healthy; VictoriaLogs rules evaluated\nvmalert-metrics: loopback:8881\n  healthy; ServiceProbeFailed evaluates probe_success == 0 for 2m\n  CPUHigh, MemoryPressure, DiskWarning, DiskCritical and InodesCritical use verified Vector metrics\nAlertmanager: loopback:9093\n  healthy; clustering disabled; Telegram {s}\nNo test notification sent.\n", .{ options.probes.len, if (options.telegram_bot_token_op != null) "configured with protected secret files" else "disabled" }));
        },
        .status => {
            const output = @import("monitoring/status.zig").status(a, r, &report) catch |err| {
                print(init.io, try std.fmt.allocPrint(a, "Failed at {s}; Component: {s}.\n", .{ @tagName(report.phase), report.component.?.name() }));
                return err;
            };
            print(init.io, output);
        },
        .notify_test => {
            try @import("monitoring/alertmanager.zig").notifyTest(a, r, &report);
            print(init.io, "Test alert accepted by Alertmanager. Check Telegram for delivery; acceptance does not prove delivery.\n");
        },
        else => unreachable,
    }
    print(init.io, plan.unavailable);
}
fn personalizeHost(init: std.process.Init, options: cli.Options) !void {
    const a = init.arena.allocator();
    const host = @import("host/oh_my_zsh.zig");
    const output = @import("host/output.zig");
    if (options.plan) {
        print(init.io, try output.plan(a, options));
        return;
    }
    var ssh: @import("system/ssh.zig").Ssh = .{ .allocator = a, .io = init.io, .options = options, .elevation = .login_user };
    var report: host.Report = .{};
    print(init.io, "Host personalization\n\n");
    host.install(a, ssh.asRemote(), .{ .target_user = options.target_user, .set_default_shell = options.set_default_shell, .update_managed_zshrc = options.update_managed_zshrc }, &report) catch |err| {
        print(init.io, try std.fmt.allocPrint(a, "Failed at {s}. Completed changes may remain; correct the cause and rerun the same command. Unrecognized user configuration is preserved.\n", .{@tagName(report.phase)}));
        return err;
    };
    print(init.io, try output.result(a, report));
}
test {
    _ = @import("monitoring/apps/dispatch.zig");
    _ = @import("monitoring/agents/apps.zig");
    _ = @import("monitoring/agents/model.zig");
    _ = @import("monitoring/agents/tests.zig");
    _ = @import("monitoring/agents/checks_tests.zig");
    _ = @import("monitoring/agents/journald.zig");
    _ = @import("monitoring/agents/journald_tests.zig");
    _ = @import("monitoring/agents/ingestion.zig");
    _ = @import("monitoring/agents/config.zig");
    _ = @import("components/vector.zig");
    _ = @import("components/vmagent.zig");
    _ = @import("components/blackbox_exporter.zig");
    _ = @import("components/vmalert.zig");
    _ = @import("monitoring/blackbox.zig");
    _ = @import("monitoring/vmalert.zig");
    _ = @import("monitoring/alertmanager.zig");
    _ = @import("secrets/telegram.zig");
    _ = @import("cli/parse.zig");
    _ = @import("cli/spec.zig");
    _ = @import("cli/help.zig");
    _ = @import("cli/completion.zig");
    _ = @import("cli/wizard.zig");
    _ = @import("cli/terminal.zig");
    _ = @import("secrets/secret.zig");
    _ = @import("secrets/reference.zig");
    _ = @import("secrets/process.zig");
    _ = @import("secrets/onepassword.zig");
    _ = @import("secrets/grafana.zig");
    _ = @import("system/remote.zig");
    _ = @import("system/ssh.zig");
    _ = @import("system/host.zig");
    _ = @import("system/filesystem.zig");
    _ = @import("system/files.zig");
    _ = @import("system/systemd.zig");
    _ = @import("components/victoriametrics.zig");
    _ = @import("components/victorialogs.zig");
    _ = @import("components/victorialogs_unit.zig");
    _ = @import("components/victoriatraces.zig");
    _ = @import("components/victoriatraces_unit.zig");
    _ = @import("components/grafana.zig");
    _ = @import("components/grafana_victorialogs_plugin.zig");
    _ = @import("components/grafana_unit.zig");
    _ = @import("components/grafana_config.zig");
    _ = @import("monitoring/grafana_verify.zig");
    _ = @import("monitoring/grafana_install.zig");
    _ = @import("monitoring/grafana_credentials.zig");
    _ = @import("monitoring/progress.zig");
    _ = @import("monitoring/readiness.zig");
    _ = @import("monitoring/tests.zig");
    _ = @import("monitoring/station_tests.zig");
    _ = @import("monitoring/policy.zig");
    _ = @import("monitoring/rules.zig");
    _ = @import("monitoring/verify.zig");
    _ = @import("monitoring/victorialogs_verify.zig");
    _ = @import("monitoring/victoriatraces_verify.zig");
    _ = @import("monitoring/plan.zig");
    _ = @import("monitoring/status.zig");
    _ = @import("system/services.zig");
    _ = @import("update/model.zig");
    _ = @import("host/oh_my_zsh.zig");
    _ = @import("host/output.zig");
    _ = @import("host/shell_tests.zig");
}
