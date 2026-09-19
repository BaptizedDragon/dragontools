//! Application config coordinates the existing concrete agent/station workflows.
const std = @import("std");
const cli = @import("../../cli/parse.zig");
const config = @import("../../config/application.zig");
const remote = @import("../../system/remote.zig");
const Ssh = @import("../../system/ssh.zig").Ssh;
const host = @import("../../system/host.zig");
const model = @import("../agents/model.zig");
const agent_apps = @import("../agents/apps.zig");
const agent_install = @import("../agents/install.zig");
const station_apps = @import("station.zig");

fn print(io: std.Io, value: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, value) catch {};
}

pub fn scope(a: std.mem.Allocator, value: config.Config) !model.ApplicationScope {
    const services = try a.alloc(model.AppService, value.services.len);
    for (value.services, services) |service, *result| result.* = .{
        .name = service.name,
        .systemd = service.systemd,
        .logs = service.logs,
        .metrics_url = service.metrics_url,
    };
    return .{ .name = value.application.name, .environment = value.application.environment, .services = services };
}

/// The caller owns the operation arena. Status/verify take the same desired
/// contract but never publish manifests, export credentials or clear intent.
pub fn execute(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, report: *model.Report, value: config.Config, command: cli.Command) ![]const u8 {
    const endpoint = value.station_hostname;
    const identity = try agent_install.identify(a, app, report);
    report.component = .station;
    // Refuse namespace/ownership conflicts before touching the target manifest.
    try station_apps.preflight(a, station, &report.state, value, identity);
    const registration = try agent_apps.prepare(a, app, report, try scope(a, value), identity, endpoint, command == .app_apply);
    if (command == .app_status) {
        const agents = try @import("../agents/status.zig").statusForApplication(a, app, station, registration, value.application.name);
        const station_state = try station_apps.status(a, station, &report.state, value, identity);
        return std.fmt.allocPrint(a, "Target host:\n{s}{s}", .{ agents, station_state });
    }
    if (command == .app_apply) {
        try agent_install.install(a, app, station, report, registration);
    } else {
        try @import("../agents/verify.zig").verify(a, app, station, report, registration);
    }
    report.component = .station;
    const machine = try host.parse(try report.call(station, .detect, host.detect_command));
    if (command == .app_apply) {
        try station_apps.apply(a, station, &report.state, machine.arch, value, identity);
    } else {
        try station_apps.verify(a, station, &report.state, machine.arch, value, identity);
    }
    var logs: usize = 0;
    var metrics: usize = 0;
    for (value.services) |service| {
        if (service.logs) logs += 1;
        if (service.metrics_url != null) metrics += 1;
    }
    return std.fmt.allocPrint(a, "{s}{s}host metrics flowing\n{s}\n{s}\nprobes registered: {d}\napplication alerts loaded\nTraces: skipped (unsupported). No test notification sent.\n", .{
        if (command == .app_apply and report.state.changes == 0) "No changes required.\n" else "",
        report.enrollmentSummary(),
        if (logs > 0) "selected service logs flowing (quiet-service metadata included)" else "selected service logs: disabled",
        if (metrics > 0) "application metrics flowing" else "application metrics: not configured",
        value.probes.len,
    });
}

pub fn stationSummary(a: std.mem.Allocator, value: config.Config) ![]const u8 {
    return std.fmt.allocPrint(a, "Station:\n  SSH: {s}\n  metrics: https://{s}:9443\n  logs: https://{s}:9444\n", .{ value.station_ssh_host, value.station_hostname, value.station_hostname });
}

test "application station summary and SSH transport keep administrative alias separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value = try config.parse(a, config.example);
    defer value.deinit();
    const summary = try stationSummary(a, value);
    try std.testing.expectEqualStrings("Station:\n  SSH: monitoring\n  metrics: https://monitoring.baptizeddragon.com:9443\n  logs: https://monitoring.baptizeddragon.com:9444\n", summary);
    var ssh: Ssh = .{ .allocator = a, .io = std.testing.io, .options = .{ .command = .agents_install, .ssh_host = value.station_ssh_host } };
    const args = try ssh.argv("true");
    try std.testing.expectEqualStrings("monitoring", args[args.len - 2]);
    for (args) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "-G"));
        try std.testing.expect(std.mem.indexOf(u8, arg, value.station_hostname) == null);
    }
}

pub fn run(init: std.process.Init, options: cli.Options) !void {
    const a = init.arena.allocator();
    const value = options.application_config orelse return error.ApplicationConfigurationRequired;
    if (options.plan) {
        print(init.io, try @import("plan.zig").render(a, value));
        return;
    }
    // Reuse native alias authentication/elevation and bounded agent transport.
    var app: Ssh = .{ .allocator = a, .io = init.io, .options = .{ .command = .agents_install, .ssh_host = value.target_ssh_host } };
    var station: Ssh = .{ .allocator = a, .io = init.io, .options = .{ .command = .agents_install, .ssh_host = value.station_ssh_host } };
    var report: model.Report = .{};
    print(init.io, switch (options.command) {
        .app_apply => "Applying application monitoring over SSH...\n",
        .app_verify => "Verifying application monitoring (read-only)...\n",
        .app_status => "Inspecting application monitoring (read-only)...\n",
        else => unreachable,
    });
    print(init.io, try stationSummary(a, value));
    if (options.command == .app_apply) {
        var logs = false;
        var metrics = false;
        for (value.services) |service| {
            logs = logs or service.logs;
            metrics = metrics or service.metrics_url != null;
        }
        print(init.io, "Host metrics: configure Vector shipping through Caddy :9443\n");
        print(init.io, if (metrics) "Metrics: configure vmagent scrape and mTLS remote write :9443\n" else "Application metrics: not configured\n");
        print(init.io, if (logs) "Logs: configure Vector journald shipping through Caddy :9444\n" else "Logs: disabled\n");
        print(init.io, "Traces: skipped (unsupported)\n");
    }
    const output = execute(a, app.asRemote(), station.asRemote(), &report, value, options.command) catch |err| {
        print(init.io, try std.fmt.allocPrint(a, "Application monitoring failed. Component: {s}. Check: {s}. {s}\n", .{
            @tagName(report.component),
            if (report.state.check) |check| @tagName(check) else @tagName(report.state.phase),
            if (options.command == .app_apply) "Completed changes may remain; pending intent is preserved. Correct the cause and rerun the same application config." else "This command is read-only; no configuration or restart intent was changed.",
        }));
        print(init.io, try report.state.credentialDiagnostics(a));
        if (report.component == .ingestion or report.component == .caddy or report.component == .station) print(init.io, "Station ingress is owned by monitoring install. Run monitoring install on the station with its configured --ingress-hostname, then retry. Application apply does not bootstrap or repair base ingress.\n");
        if (report.state.check == .dns_unresolved) print(init.io, "Monitoring station hostname does not resolve. DragonTools does not manage DNS. Configure the DNS record and rerun the same command.\n");
        if (report.state.check == .tcp_metrics_unreachable or report.state.check == .tcp_logs_unreachable) {
            const port: u16 = if (report.state.check == .tcp_logs_unreachable) 9444 else 9443;
            print(init.io, try std.fmt.allocPrint(a, "Monitoring ingestion is not reachable: {s}:{d}.\nDragonTools does not manage DNS or provider firewalls. Ensure the hostname resolves and TCP {d} is permitted from this host.\n", .{ value.station_hostname, port, port }));
        }
        if (report.state.check == .legacy_ingress_conflict) print(init.io, "A historical public ingestion unit is still installed. It was preserved. Complete a coordinated migration to the separate Caddy metrics/log ports before applying this configuration.\n");
        if (report.state.check == .client_identity_inconsistent) print(init.io, "The managed client identity is inconsistent. Existing files were preserved; restore a verified local backup or correct conflicting metadata before retrying.\n");
        if (report.state.check == .ca_maintenance) print(init.io, "The private CA requires explicit maintenance. It was not rotated or replaced.\n");
        return err;
    };
    print(init.io, output);
}

test {
    _ = @import("plan.zig");
    _ = station_apps;
}

test "application ownership conflict stops before target mutation or credential transport" {
    const Fake = struct {
        calls: usize = 0,
        station: bool = false,
        fn call(ctx: *anyopaque, op: remote.Operation, cmd: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.station) {
                try std.testing.expectEqual(remote.Operation.health, op);
                return .{ .code = 40 };
            }
            try std.testing.expectEqual(remote.Operation.detect, op);
            try std.testing.expectEqualStrings("cat /etc/machine-id", cmd);
            return .{ .code = 0, .output = "0123456789abcdef0123456789abcdef\n" };
        }
        fn asRemote(self: *@This()) remote.Remote {
            return .{ .context = self, .execute = call };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var value = try config.parse(std.testing.allocator,
        \\version=1
        \\[application]
        \\name='doers'
        \\environment='production'
        \\[target]
        \\ssh_host='replace-me-app'
        \\[station]
        \\ssh_host='replace-me-station'
        \\hostname='monitoring.baptizeddragon.com'
    );
    defer value.deinit();
    var app: Fake = .{};
    var station: Fake = .{ .station = true };
    var report: model.Report = .{};
    try std.testing.expectError(error.UnmanagedFileConflict, execute(arena.allocator(), app.asRemote(), station.asRemote(), &report, value, .app_apply));
    try std.testing.expectEqual(@as(usize, 1), app.calls);
    try std.testing.expectEqual(@as(usize, 1), station.calls);
    try std.testing.expectEqual(@as(usize, 0), report.state.changes);
}

test "probe and alert edits do not change the desired application agent scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base =
        \\version=1
        \\[application]
        \\name='doers'
        \\environment='production'
        \\[target]
        \\ssh_host='replace-me-app'
        \\[station]
        \\ssh_host='replace-me-station'
        \\hostname='monitoring.baptizeddragon.com'
        \\[[service]]
        \\name='web'
        \\systemd='web.service'
        \\[service.logs]
        \\enabled=true
    ;
    var before = try config.parse(a, base);
    defer before.deinit();
    var after = try config.parse(a, base ++
        \\
        \\[[probe]]
        \\name='web'
        \\url='https://example.com/healthz'
        \\[[alert]]
        \\name='Errors'
        \\source='logs'
        \\level='error'
        \\window='5m'
        \\threshold=10
        \\severity='warning'
    );
    defer after.deinit();
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, try scope(a, before), .{}), try std.json.Stringify.valueAlloc(a, try scope(a, after), .{}));
}
