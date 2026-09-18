//! CLI adapter. No separate deployment engine and no controller-side database.
const std = @import("std");
const cli = @import("../../cli/parse.zig");
const Ssh = @import("../../system/ssh.zig").Ssh;
const model = @import("model.zig");
const targets = @import("targets.zig");
const ingress = @import("ingestion.zig");
fn print(io: std.Io, value: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, value) catch {};
}
pub const plan = "Agent installation plan (local; SSH not attempted).\nVector: selected journald logs, host metrics, internal telemetry; bounded disk buffers.\nvmagent: installed only for explicitly configured private application metrics targets.\nStation: register machine URI identity; sign public CSRs; Caddy mTLS metrics on 9443 and logs on 9444. Client private keys stay on the monitored host.\nRaw backends remain loopback-only. No firewall rules change; allow station TCP 9443 for metrics and TCP 9444 for selected logs; 9445 remains reserved and closed.\nBound journald with a managed drop-in only when necessary; retain stricter administrator limits.\nRestart only affected services; verify recent station signals before finalization.\nOTel traces and systemd-service state alerts remain unavailable.\nNo remote operations performed.\n";
/// Native OpenSSH resolves the configured station name. Only its validated
/// HostName becomes the application-reachable TLS endpoint; identities, proxies,
/// and controller SSH credentials are never copied to the application host.
pub fn endpoint(a: std.mem.Allocator, io: std.Io, alias: []const u8) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = &.{ "ssh", "-G", "--", alias }, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
    defer {
        std.crypto.secureZero(u8, result.stderr);
        a.free(result.stderr);
        a.free(result.stdout);
    }
    if (result.term != .exited or result.term.exited != 0) return error.StationConnectionResolutionFailed;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "hostname ")) {
        const name = line[9..];
        try model.validateEndpoint(name);
        return a.dupe(u8, name);
    };
    return error.StationConnectionResolutionFailed;
}
fn lessService(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
fn lessTarget(_: void, left: targets.Target, right: targets.Target) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
pub fn run(init: std.process.Init, options: cli.Options) !void {
    const a = init.arena.allocator();
    if (options.plan) {
        print(init.io, plan);
        return;
    }
    const hostname = try endpoint(a, init.io, options.station.?);
    var app: Ssh = .{ .allocator = a, .io = init.io, .options = options };
    var station: Ssh = .{ .allocator = a, .io = init.io, .options = .{ .command = options.command, .ssh_host = options.station } };
    var report: model.Report = .{};
    const id = try @import("install.zig").identify(a, app.asRemote(), &report);
    var registration: model.Registration = undefined;
    if (options.command == .agents_install) {
        // Application repositories own shared agent state once registered. Raw
        // replacement would silently remove other applications' signal paths.
        _ = try report.call(app.asRemote(), .health, "test ! -e /etc/dragontools/agent-apps && test ! -L /etc/dragontools/agent-apps");
        const services = try a.dupe([]const u8, options.services.items);
        const metrics_targets = try a.dupe(targets.Target, options.metrics_targets.items);
        std.mem.sort([]const u8, services, {}, lessService);
        std.mem.sort(targets.Target, metrics_targets, {}, lessTarget);
        registration = .{ .host = id, .station = hostname, .services = services, .metrics_targets = metrics_targets };
    } else {
        registration = try model.Registration.parse(a, try report.call(station.asRemote(), .status, try ingress.readRegistrationCommand(a, id)));
        if (!std.mem.eql(u8, registration.host, id) or !std.mem.eql(u8, registration.station, hostname)) return error.AgentRegistrationMismatch;
        // Optional explicit selections are assertions during read-only commands.
        if (options.services.items.len != 0) {
            const services = try a.dupe([]const u8, options.services.items);
            std.mem.sort([]const u8, services, {}, lessService);
            if (services.len != registration.services.len) return error.AgentRegistrationMismatch;
            for (services, registration.services) |x, y| if (!std.mem.eql(u8, x, y)) return error.AgentRegistrationMismatch;
        }
        if (options.metrics_targets.items.len != 0) {
            const values = try a.dupe(targets.Target, options.metrics_targets.items);
            std.mem.sort(targets.Target, values, {}, lessTarget);
            if (values.len != registration.metrics_targets.len) return error.AgentRegistrationMismatch;
            for (values, registration.metrics_targets) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.url, y.url)) return error.AgentRegistrationMismatch;
        }
    }
    if (options.command == .agents_status) {
        print(init.io, try @import("status.zig").status(a, app.asRemote(), station.asRemote(), registration));
        return;
    }
    print(init.io, if (options.command == .agents_install) "Installing monitored-host agents over SSH...\n" else "Verifying monitored-host agents (read-only)...\n");
    const result = if (options.command == .agents_install) @import("install.zig").install(a, app.asRemote(), station.asRemote(), &report, registration) else @import("verify.zig").verify(a, app.asRemote(), station.asRemote(), &report, registration);
    result catch |err| {
        print(init.io, try std.fmt.allocPrint(a, "Agent verification/install failed. Component: {s}. Check: {s}. {s}\n", .{ @tagName(report.component), if (report.state.check) |check| @tagName(check) else @tagName(report.state.phase), if (report.configured) "Configuration was applied; signal delivery has not been fully verified. Pending restart intent remains; rerun the same command." else "Later steps were not attempted. Completed changes may remain; rerun after correcting the cause." }));
        print(init.io, try report.state.credentialDiagnostics(a));
        if (@import("verify.zig").networkFailure(report.state.check)) print(init.io, @import("verify.zig").network_guidance);
        if (report.state.check == .client_identity_inconsistent) print(init.io, "The managed client identity is inconsistent. Existing files were preserved; restore a verified local backup or correct conflicting metadata before retrying.\n");
        if (report.state.check == .ca_maintenance) print(init.io, "The private CA requires explicit maintenance. It was not rotated or replaced.\n");
        return err;
    };
    print(init.io, report.enrollmentSummary());
    if (options.command == .agents_install and report.state.changes == 0) print(init.io, "No changes required.\n");
    print(init.io, "Vector\n  active; enabled\n  host metrics flowing\n  selected log stream identities flowing (quiet-service metadata included)\n");
    print(init.io, if (registration.metrics_targets.len > 0) "vmagent\n  active; enabled\n  application metrics flowing\n" else "vmagent\n  not required (no application metrics targets)\n");
    print(init.io, "OTel traces: unavailable. No test errors or notifications generated.\n");
}
