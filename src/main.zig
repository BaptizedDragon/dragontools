const std = @import("std");
const cli = @import("cli/parse.zig");
const help = @import("cli/help.zig");
const completion = @import("cli/completion.zig");
const terminal = @import("cli/terminal.zig");
const policy = @import("monitoring/policy.zig");
const vt = @import("components/victoriatraces.zig");
const plan = @import("monitoring/plan.zig");
fn print(io: std.Io, message: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, message) catch {};
}
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
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
    if (options.plan) {
        print(init.io, try plan.render(a));
        return;
    }
    var ssh: @import("system/ssh.zig").Ssh = .{ .allocator = a, .io = init.io, .options = options };
    const r = ssh.asRemote();
    var report: @import("monitoring/install.zig").Report = .{};
    switch (options.command) {
        .install, .verify => {
            print(init.io, if (options.command == .install) "Installing VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana over SSH...\n" else "Verifying VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana over SSH...\n");
            const result = if (options.command == .install) @import("monitoring/install.zig").install(a, r, &report) else @import("monitoring/verify.zig").verify(a, r, &report);
            result catch |err| {
                const advice = if (options.command == .install)
                    "The failed step may have partially changed the host. Later steps were not attempted. Fix the cause and rerun the same command; pending restart intent is preserved. No rollback was attempted."
                else
                    "Verification is read-only. Later checks were not attempted. Correct the cause and repeat verification.";
                print(init.io, try std.fmt.allocPrint(a, "Failed at {s}; {d} steps completed, {d} change steps confirmed. Component: {s}. {s} Check SSH/prerequisites for detection failures, or inspect the managed unit and journal for later failures.\n", .{ @tagName(report.phase), report.completed, report.changes, if (report.component) |component| component.name() else "host", advice }));
                return err;
            };
            if (options.command == .install and report.changes == 0) print(init.io, "No changes required.\n");
            print(init.io, try std.fmt.allocPrint(a, "VictoriaMetrics: loopback:8428\n  healthy; self-scraped metrics queryable\n  retention: {s}; free-space reserve: {d} bytes ({d}% of filesystem capacity)\nVictoriaLogs: loopback:9428\n  healthy; writable storage\n  retention: disk-bound; logical limit: {s}; native partition budget: {d}% of filesystem capacity\nVictoriaTraces: loopback:{d}\n  healthy; writable storage\n  retention: disk-bound; logical limit: {s}; native partition budget: {d}% of filesystem capacity\n  Logs/traces cleanup is periodic and preserves the newest two partitions; other writers can fill the filesystem earlier.\nGrafana: loopback:3000\n  healthy; local authentication enabled\n  Metrics and Traces datasource records and backend queries checked\n  authenticated Grafana query/UI validation remains a manual integration check\nAccess through an explicit SSH tunnel; change the initial administrator password at first login.\n", .{ policy.metrics.retention, report.reserve_bytes, policy.metrics.reserve_percent, policy.logs.retention, policy.logs.cleanup_usage_percent, vt.port, policy.traces.retention, policy.traces.cleanup_usage_percent }));
        },
        .status => {
            const output = @import("monitoring/status.zig").status(a, r, &report) catch |err| {
                print(init.io, try std.fmt.allocPrint(a, "Failed at {s}; Component: {s}.\n", .{ @tagName(report.phase), report.component.?.name() }));
                return err;
            };
            print(init.io, output);
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
    _ = @import("cli/parse.zig");
    _ = @import("cli/spec.zig");
    _ = @import("cli/help.zig");
    _ = @import("cli/completion.zig");
    _ = @import("cli/wizard.zig");
    _ = @import("cli/terminal.zig");
    _ = @import("secrets/secret.zig");
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
    _ = @import("components/grafana_unit.zig");
    _ = @import("components/grafana_config.zig");
    _ = @import("monitoring/grafana_verify.zig");
    _ = @import("monitoring/grafana_install.zig");
    _ = @import("monitoring/tests.zig");
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
