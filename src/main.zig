const std = @import("std");
const cli = @import("cli/parse.zig");
const usage =
    \\DragonTools 0.1.0-dev — opinionated monitoring over SSH
    \\Usage:
    \\  dragontool monitoring install --host HOST [--plan] [SSH options]
    \\  dragontool monitoring verify --host HOST [SSH options]
    \\  dragontool monitoring status --host HOST [SSH options]
    \\  dragontool monitoring agents {install|verify|status} --host HOST
    \\  dragontool monitoring firewall --host HOST
    \\SSH: --user USER (root), --port PORT (22), --ssh-sock /absolute/path
    \\     --identity /absolute/path (mutually exclusive with --ssh-sock)
    \\Default: SSH agent/default OpenSSH identities, strict known-host verification.
    \\--plan prints the intended slice without SSH or mutations.
    \\Implemented: VictoriaMetrics only, loopback:8428, retention 90d, reserve 20%.
    \\Unavailable options (validated, then rejected before SSH):
    \\  --ssh-op-path op://...; --service NAME.service (repeatable)
    \\  --station-ip IP; --admin-ip IP; --agent-ip IP (IPs repeatable)
    \\  --domain DOMAIN; --tls manual|cloudflare; --cloudflare-token-op op://...
    \\  --telegram-bot-token-op op://...; --telegram-channel-id ID
    \\Agents, firewall, TLS, Telegram, remaining station components and maintenance
    \\are roadmap work. Install success covers the VictoriaMetrics slice only.
    \\
;
fn print(io: std.Io, message: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, message) catch {};
}
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const msg = std.fmt.allocPrint(init.arena.allocator(), "Error: {s}. No argument values or remote stderr are printed. See --help.\n", .{@errorName(err)}) catch "Error: operation failed.\n";
        std.Io.File.stderr().writeStreamingAll(init.io, msg) catch {};
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var options = try cli.parse(a, args[1..]);
    defer options.deinit(a);
    if (options.help) {
        print(init.io, usage);
        return;
    }
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
