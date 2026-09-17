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
const vmagent = @import("../../components/vmagent.zig");
pub const File = struct { path: []const u8, content: []const u8 };
pub fn commandLine(a: std.mem.Allocator, kind: common.Kind, registration: model.Registration) ![]const u8 {
    return switch (kind) {
        .ingestion => a.dupe(u8, "/usr/bin/python3 -I -B " ++ ingress.executable),
        .vector => std.fmt.allocPrint(a, vector.root ++ "/current/vector {s}", .{try configs.vectorArguments(a)}),
        .vmagent => std.fmt.allocPrint(a, vmagent.root ++ "/current/vmagent-prod {s}", .{try configs.vmagentArguments(a, registration.station)}),
    };
}
pub fn configFile(a: std.mem.Allocator, kind: common.Kind, registration: model.Registration) !File {
    return switch (kind) {
        .ingestion => .{ .path = ingress.executable, .content = ingress.program },
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
        .station = registration.station,
        .unit = try common.unit(a, kind, command),
        .command = command,
        .files = &files,
        .listener = switch (kind) {
            .vector => "127.0.0.1:8686",
            .vmagent => "127.0.0.1:8429",
            .ingestion => "0.0.0.0:9443",
        },
        .version = switch (kind) {
            .vector => vector.version,
            .vmagent => vmagent.version,
            .ingestion => "",
        },
        .binary = if (kind == .vector) "vector" else "vmagent-prod",
        .digest = switch (kind) {
            .vector => vector.artifact(arch).binary_sha256,
            .vmagent => vmagent.artifact(arch).binary_sha256,
            .ingestion => "",
        },
    }, .{});
}
pub fn service(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, registration: model.Registration, arch: host.Arch, kind: common.Kind) !void {
    const data = try spec(a, kind, registration, arch);
    _ = try ready.deterministic(a, r, &report.state, .managed_state, try common.python(a, ingress.checks_program, &.{ "managed", data }));
    if (kind != .ingestion) {
        _ = try ready.deterministic(a, r, &report.state, .managed_state, try ingress.verifyCredentialsCommand(a, if (kind == .vector) .vector else .vmagent, registration.host, registration.station));
    }
    try ready.poll(a, r, &report.state, .service_active, ready.active_ms, try common.python(a, ingress.checks_program, &.{ "active", data }), ready.ready);
    if (kind != .ingestion) {
        try ready.poll(a, r, &report.state, .http_ready, ready.http_ms, try common.python(a, ingress.checks_program, &.{ "http", data }), ready.ready);
        try secureEndpoint(a, r, report, try common.python(a, ingress.checks_program, &.{ "endpoint", data }));
    }
}
pub const network_guidance = "DragonTools does not manage DNS or provider firewalls. Ensure the station hostname resolves and TCP 9443 is allowed.\n";
pub fn networkFailure(check: ?ready.Check) bool {
    return check == .dns_unresolved or check == .tcp_unreachable;
}
/// Keep fixed diagnostic exit codes separate from raw remote output. Only
/// reachability/HTTP absence retries; a bad server/client identity fails closed.
pub fn secureEndpoint(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, command: []const u8) !void {
    const Probe = struct {
        source: remote.Remote,
        report: *model.Report,
        fn execute(ctx: *anyopaque, op: remote.Operation, cmd: []const u8) anyerror!remote.Result {
            return executeTimed(ctx, op, cmd, ready.http_ms);
        }
        fn executeTimed(ctx: *anyopaque, op: remote.Operation, cmd: []const u8, budget: u32) anyerror!remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const result = try self.source.runTimed(op, cmd, budget);
            self.report.state.check = switch (result.code) {
                91 => .dns_unresolved,
                92 => .tcp_unreachable,
                93 => .server_tls_invalid,
                94 => .client_certificate_rejected,
                95 => .ingestion_rejected,
                else => .secure_endpoint,
            };
            return switch (result.code) {
                91, 92, 95 => .{ .code = 75 },
                93, 94 => .{ .code = 1 },
                else => result,
            };
        }
    };
    var probe = Probe{ .source = r, .report = report };
    const adapted = remote.Remote{ .context = &probe, .execute = Probe.execute, .execute_timed = Probe.executeTimed, .clock = r.clock };
    try ready.poll(a, adapted, &report.state, .secure_endpoint, ready.http_ms, command, ready.ready);
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
    for (registration.services) |selected| _ = try report.call(app, .service_exists, try common.selectedService(a, selected));
    report.component = .station;
    _ = try report.call(station, .health, @import("install.zig").station_preflight);
    try service(a, station, report, registration, machine.arch, .ingestion);
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
