const std = @import("std");
const cli = @import("cli/parse.zig");
const help = @import("cli/help.zig");
const completion = @import("cli/completion.zig");
const terminal = @import("cli/terminal.zig");
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
    if (options.plan) {
        print(init.io, "Plan: detect Ubuntu 24.04/26.04 + systemd; ensure dedicated user and data directory; verify pinned VictoriaMetrics v1.151.0 archive and binary SHA-256; install versioned executable and hardened unit; restart only if changed/inactive; verify health and self-scraped metrics.\nStorage: 90d retention; 20% capacity reserve calculated on host.\nNetwork: 127.0.0.1:8428 only. Firewall and other components unavailable. No remote operations performed.\n");
        return;
    }
    var ssh: @import("system/ssh.zig").Ssh = .{ .allocator = a, .io = init.io, .options = options };
    const r = ssh.asRemote();
    var report: @import("monitoring/install.zig").Report = .{};
    switch (options.command) {
        .install, .verify => {
            print(init.io, if (options.command == .install) "Installing VictoriaMetrics slice over SSH...\n" else "Verifying VictoriaMetrics slice over SSH...\n");
            const result = if (options.command == .install) @import("monitoring/install.zig").install(a, r, &report) else @import("monitoring/verify.zig").verify(a, r, &report);
            result catch |err| {
                print(init.io, try std.fmt.allocPrint(a, "Failed at {s}; {d} steps completed, {d} change steps confirmed. The failed step may have partially changed the host. Later steps were not attempted. Check SSH/prerequisites for detection failures, or inspect the managed unit and journal for later failures; fix the cause and rerun the same command. No rollback was attempted.\n", .{ @tagName(report.phase), report.completed, report.changes }));
                return err;
            };
            if (options.command == .install and report.changes == 0) print(init.io, "No changes required.\n");
            print(init.io, try std.fmt.allocPrint(a, "VictoriaMetrics: healthy; self-scraped metrics queryable.\nStorage: 90d retention; free-space reserve {d} bytes (20% of filesystem capacity).\nNetwork: loopback:8428.\n", .{report.reserve_bytes}));
        },
        .status => print(init.io, try @import("monitoring/status.zig").status(r)),
        else => unreachable,
    }
    print(init.io, "Not yet available: VictoriaLogs, VictoriaTraces, Grafana, vmalert, Alertmanager, agents, firewall, TLS, Telegram, update monitoring and maintenance.\n");
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
    _ = @import("monitoring/tests.zig");
    _ = @import("monitoring/verify.zig");
    _ = @import("system/services.zig");
    _ = @import("update/model.zig");
}
