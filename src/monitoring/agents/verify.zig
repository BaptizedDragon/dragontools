//! Agent verification is read-only, including cross-host signal queries.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const host = @import("../../system/host.zig");
const common = @import("common.zig");
const model = @import("model.zig");
const configs = @import("config.zig");
const ingress = @import("ingestion.zig");
const ready = @import("../readiness.zig");
const vector = @import("../../components/vector.zig");
const caddy = @import("../../components/caddy.zig");
const vmagent = @import("../../components/vmagent.zig");
pub const File = struct { path: []const u8, content: []const u8 };
pub fn commandLine(a: std.mem.Allocator, kind: common.Kind, registration: model.Registration) ![]const u8 {
    return switch (kind) {
        .ingestion => a.dupe(u8, @import("ingress_units.zig").auth_command),
        .caddy => a.dupe(u8, @import("ingress_units.zig").caddy_command),
        .vector => std.fmt.allocPrint(a, vector.root ++ "/current/vector {s}", .{try configs.vectorArguments(a)}),
        .vmagent => std.fmt.allocPrint(a, vmagent.root ++ "/current/vmagent-prod {s}", .{try configs.vmagentArguments(a, registration.station)}),
    };
}
pub fn configFile(a: std.mem.Allocator, kind: common.Kind, registration: model.Registration) !File {
    return switch (kind) {
        .ingestion => .{ .path = ingress.executable, .content = ingress.program },
        .caddy => .{ .path = caddy.config_path, .content = @embedFile("Caddyfile") },
        .vector => .{ .path = vector.config_path, .content = try configs.renderVectorRegistration(a, registration) },
        .vmagent => .{ .path = vmagent.config_path, .content = try configs.renderVmagentRegistration(a, registration) },
    };
}
pub fn spec(a: std.mem.Allocator, kind: common.Kind, registration: model.Registration, arch: host.Arch) ![]const u8 {
    const command = try commandLine(a, kind, registration);
    const files = [_]File{try configFile(a, kind, registration)};
    return std.json.Stringify.valueAlloc(a, .{
        .kind = @tagName(kind),
        .owner = common.owner(kind),
        .service = common.serviceName(kind),
        .station = registration.station,
        .unit = try common.unit(a, kind, command),
        .command = command,
        .files = &files,
        .listener = switch (kind) {
            .vector => "127.0.0.1:8686",
            .vmagent => "127.0.0.1:8429",
            .ingestion => "",
            .caddy => "0.0.0.0:9443",
        },
        .version = switch (kind) {
            .vector => vector.version,
            .vmagent => vmagent.version,
            .ingestion => "",
            .caddy => caddy.version,
        },
        .binary = if (kind == .vector) "vector" else if (kind == .caddy) "caddy" else "vmagent-prod",
        .digest = switch (kind) {
            .vector => vector.artifact(arch).binary_sha256,
            .vmagent => vmagent.artifact(arch).binary_sha256,
            .caddy => caddy.artifact(arch).binary_sha256,
            .ingestion => "",
        },
    }, .{});
}
pub fn service(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, registration: model.Registration, arch: host.Arch, kind: common.Kind) !void {
    const data = try spec(a, kind, registration, arch);
    _ = try ready.deterministic(a, r, &report.state, if (kind == .caddy) .caddy_service else .managed_state, try common.python(a, ingress.checks_program, &.{ "managed", data }));
    if (kind == .vector or kind == .vmagent) {
        _ = try ready.deterministic(a, r, &report.state, .managed_state, try ingress.verifyCredentialsCommand(a, if (kind == .vector) .vector else .vmagent, registration.host, registration.station));
    }
    try ready.poll(a, r, &report.state, if (kind == .caddy) .caddy_listener else .service_active, ready.active_ms, try common.python(a, ingress.checks_program, &.{ "active", data }), ready.ready);
    if (kind == .vector or kind == .vmagent) {
        try ready.poll(a, r, &report.state, .http_ready, ready.http_ms, try common.python(a, ingress.checks_program, &.{ "http", data }), ready.ready);
        const guard = try common.python(a, ingress.checks_program, &.{ "active", data });
        try endpointSignal(a, r, report, registration, @tagName(kind), .metrics, guard);
        if (kind == .vector and registration.services.len > 0) try endpointSignal(a, r, report, registration, "vector", .logs, guard);
    }
}
pub const network_guidance = "DragonTools does not manage DNS or provider firewalls. Ensure the station hostname resolves and TCP 9443 (metrics) and, when logs are selected, TCP 9444 (logs) are allowed.\n";
pub fn networkFailure(check: ?ready.Check) bool {
    return check == .dns_unresolved or check == .tcp_unreachable or check == .tcp_metrics_unreachable or check == .tcp_logs_unreachable;
}
pub fn enrollmentEndpoints(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, registration: model.Registration, kind: []const u8) !void {
    try endpointSignal(a, r, report, registration, kind, .metrics, null);
    if (registration.services.len > 0) try endpointSignal(a, r, report, registration, kind, .logs, null);
}
fn endpointSignal(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, registration: model.Registration, kind: []const u8, signal: ingress.Signal, guard: ?[]const u8) !void {
    secureEndpointGuarded(a, r, report, try ingress.endpointForSignal(a, registration.station, kind, registration.host, signal), guard) catch |err| {
        report.state.check = switch (report.state.check orelse .secure_endpoint) {
            .tcp_unreachable => if (signal == .metrics) .tcp_metrics_unreachable else .tcp_logs_unreachable,
            .ingestion_rejected => if (signal == .metrics) .metrics_ingestion_rejected else .logs_ingestion_rejected,
            else => report.state.check,
        };
        return err;
    };
}

/// Keep fixed diagnostic exit codes separate from raw remote output. Only
/// reachability/HTTP absence retries; a bad server/client identity fails closed.
pub fn secureEndpoint(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, command: anytype) !void {
    return secureEndpointGuarded(a, r, report, command, null);
}
fn secureEndpointGuarded(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, command: anytype, runtime_guard: ?[]const u8) !void {
    const Probe = struct {
        source: remote.Remote,
        runtime_guard: ?[]const u8,
        report: *model.Report,
        fn execute(ctx: *anyopaque, op: remote.Operation, cmd: []const u8) anyerror!remote.Result {
            return executeTimed(ctx, op, cmd, ready.http_ms);
        }
        fn executeTimed(ctx: *anyopaque, op: remote.Operation, cmd: []const u8, budget: u32) anyerror!remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const result = try self.source.runTimed(op, cmd, budget);
            return self.accept(result);
        }
        fn executeInput(ctx: *anyopaque, op: remote.Operation, input: remote.Input, budget: u32) anyerror!remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const deadline = ready.now(self.source) + budget;
            if (self.runtime_guard) |guard| {
                const result = try self.source.runTimed(.health, guard, budget);
                if (result.code != 0) {
                    self.report.state.check = .service_active;
                    return result;
                }
            }
            const remaining = deadline - ready.now(self.source);
            if (remaining <= 0) return error.Timeout;
            return self.accept(try self.source.runTimed(op, input, @intCast(remaining)));
        }
        fn accept(self: *@This(), result: remote.Result) remote.Result {
            self.report.state.check = switch (result.code) {
                91 => .dns_unresolved,
                92 => .tcp_unreachable,
                93 => .server_tls_invalid,
                94 => .client_certificate_rejected,
                95 => .ingestion_rejected,
                else => .secure_endpoint,
            };
            return switch (result.code) {
                91, 92, 95 => .{ .code = 75, .agent_exit_code = result.code, .diagnostic = result.diagnostic },
                93, 94 => .{ .code = 1, .agent_exit_code = result.code, .diagnostic = result.diagnostic },
                else => result,
            };
        }
    };
    var probe = Probe{ .source = r, .report = report, .runtime_guard = runtime_guard };
    const adapted = remote.Remote{ .context = &probe, .execute = Probe.execute, .execute_timed = Probe.executeTimed, .execute_input = Probe.executeInput, .clock = r.clock };
    try ready.poll(a, adapted, &report.state, .secure_endpoint, ready.http_ms, command, ready.ready);
}

test "native endpoint guard and TLS probe share one deadline and deterministic guard failures do not retry" {
    const Fake = struct {
        elapsed: i64 = 0,
        guard_ms: i64 = 17000,
        guard_code: u8 = 0,
        guards: usize = 0,
        probes: usize = 0,
        fn now(raw: *anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.elapsed;
        }
        fn sleep(_: *anyopaque, _: u32) anyerror!void {
            return error.UnexpectedRetry;
        }
        fn run(raw: *anyopaque, op: remote.Operation, command: []const u8) anyerror!remote.Result {
            return timed(raw, op, command, ready.http_ms);
        }
        fn timed(raw: *anyopaque, _: remote.Operation, _: []const u8, budget: u32) anyerror!remote.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(ready.http_ms, budget);
            self.guards += 1;
            self.elapsed += self.guard_ms;
            return .{ .code = self.guard_code };
        }
        fn input(raw: *anyopaque, _: remote.Operation, _: remote.Input, budget: u32) anyerror!remote.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u32, 13000), budget);
            self.probes += 1;
            self.elapsed += 12000;
            return .{ .code = 0 };
        }
        fn remoteValue(self: *@This()) remote.Remote {
            return .{ .context = self, .execute = run, .execute_timed = timed, .execute_input = input, .clock = .{ .context = self, .now_ms = now, .sleep_ms = sleep } };
        }
    };
    const request: remote.Input = .{ .command = "fixed helper", .bytes = "public request" };
    for (0..3) |scenario| {
        var fake: Fake = .{};
        var report: model.Report = .{};
        if (scenario == 1) fake.guard_ms = ready.http_ms;
        if (scenario == 2) fake.guard_code = 1;
        const result = secureEndpointGuarded(std.testing.allocator, fake.remoteValue(), &report, request, "fixed guard");
        switch (scenario) {
            0 => try result,
            1 => try std.testing.expectError(error.ReadinessTimedOut, result),
            2 => {
                try std.testing.expectError(error.RemoteOperationFailed, result);
                try std.testing.expectEqual(ready.Check.service_active, report.state.check.?);
            },
            else => unreachable,
        }
        try std.testing.expectEqual(@as(usize, 1), fake.guards);
        try std.testing.expectEqual(@as(usize, if (scenario == 0) 1 else 0), fake.probes);
    }
}

pub fn signals(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, report: *model.Report, registration: model.Registration, comptime mode: []const u8) !void {
    const process = if (std.mem.eql(u8, mode, "app")) "vmagent" else "vector";
    const start_command = try common.python(a, "import subprocess,sys,time; v=int(subprocess.check_output(['systemctl','show','-p','ExecMainStartTimestampMonotonic','--value','dragontools-'+sys.argv[1]+'.service'],stderr=subprocess.DEVNULL)); assert v>0; print(time.time()-time.monotonic()+v/1000000)", &.{process});
    const started = std.mem.trim(u8, try report.call(app, .status, start_command), " \n");
    const stamp = std.fmt.parseFloat(f64, started) catch return error.InvalidAgentStartTime;
    if (!std.math.isFinite(stamp) or stamp < 0) return error.InvalidAgentStartTime;
    report.component = .signals;
    const check: ready.Check = if (std.mem.eql(u8, mode, "host")) .host_metrics_ready else if (std.mem.eql(u8, mode, "logs")) .log_stream_ready else .application_metrics_ready;
    try ready.poll(a, station, &report.state, check, ready.telemetry_ms, try common.python(a, @embedFile("signals.py"), &.{ mode, try registration.selected(report.application).json(a), started }), ready.ready);
}
pub fn verify(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, report: *model.Report, registration: model.Registration) !void {
    report.component = .application_host;
    const machine = try host.parse(try report.call(app, .detect, host.detect_command));
    try @import("helper.zig").verify(a, app, report, machine.arch);
    for (registration.services) |selected| _ = try report.call(app, .service_exists, try common.selectedService(a, selected));
    report.component = .station;
    const station_machine = try host.parse(try report.call(station, .detect, host.detect_command));
    try @import("helper.zig").verify(a, station, report, station_machine.arch);
    _ = try report.call(station, .health, @import("install.zig").station_preflight);
    report.component = .ingestion;
    try service(a, station, report, registration, station_machine.arch, .ingestion);
    report.component = .caddy;
    try service(a, station, report, registration, station_machine.arch, .caddy);
    report.component = .ingestion;
    _ = try report.call(station, .health, try ingress.verifyStationCommand(a, registration.host, registration.station, try registration.json(a)));
    report.component = .journald;
    _ = try report.call(app, .health, try @import("journald.zig").command(a, false));
    report.component = .vector;
    try service(a, app, report, registration, machine.arch, .vector);
    try signals(a, app, station, report, registration, "host");
    try signals(a, app, station, report, registration, "logs");
    if (registration.metricsCount() > 0) {
        report.component = .vmagent;
        try service(a, app, report, registration, machine.arch, .vmagent);
        try signals(a, app, station, report, registration, "app");
        report.vmagent_installed = true;
    } else {
        _ = try report.call(app, .health, unused_vmagent);
    }
}
pub const unused_vmagent =
    \\set -eu
    \\path=/etc/systemd/system/dragontools-vmagent.service
    \\test ! -L "$path" || exit 43
    \\if test ! -e "$path"; then exit 0; fi
    \\test -f "$path" && test "$(stat -c '%u:%g' "$path")" = 0:0 || exit 40
    \\grep -qx '# Managed by DragonTools' "$path" || exit 40
    \\test -z "$(systemctl show -p DropInPaths --value dragontools-vmagent.service)" || exit 42
    \\test "$(systemctl show -p ActiveState --value dragontools-vmagent.service)" = inactive
    \\test "$(systemctl show -p UnitFileState --value dragontools-vmagent.service)" = disabled
;
