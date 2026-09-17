//! Credentials travel only through the private SSH stdin channel. Remote command
//! text contains fixed source and paths; results contain fixed semantic tokens.
const std = @import("std");
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
pub const helper = @embedFile("grafana_credentials.py");
pub const Mode = enum { bootstrap, reconcile, verify, logs_verify };

pub fn command(a: std.mem.Allocator, mode: Mode) ![]const u8 {
    return remote.shell(a, &.{ "runuser", "--user", "dt-grafana", "--", "python3", "-I", "-B", "-c", helper, @tagName(mode) });
}

fn run(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, mode: Mode) !bool {
    const payload = report.grafana_credentials orelse return false;
    const script = try command(a, mode);
    defer a.free(script);
    report.phase = if (mode == .logs_verify) .health else .credentials;
    report.check = switch (mode) {
        .bootstrap => .credentials_bootstrap,
        .reconcile, .verify => .credentials_authenticated,
        .logs_verify => .logs_datasource_ready,
    };
    const result = try r.runSecret(.credentials, script, payload, 120_000);
    switch (result.code) {
        0 => {},
        80 => return error.InvalidGrafanaCredentials,
        81 => return error.GrafanaAdministratorConflict,
        82 => return error.GrafanaCredentialResetFailed,
        83 => return error.GrafanaCredentialVerificationFailed,
        84 => return error.GrafanaCredentialApiUnavailable,
        85 => return error.GrafanaCredentialBootstrapFailed,
        86 => return error.GrafanaLogsQueryFailed,
        87 => return error.GrafanaLogsQueryTimedOut,
        88 => return error.GrafanaLogsPluginNotLoaded,
        else => {
            _ = try report.accept(result);
            return error.GrafanaCredentialVerificationFailed;
        },
    }
    const changed = std.mem.eql(u8, result.output, "changed");
    if ((!changed and !std.mem.eql(u8, result.output, "unchanged")) or ((mode == .verify or mode == .logs_verify) and changed)) {
        return if (mode == .logs_verify) error.GrafanaLogsQueryFailed else error.GrafanaCredentialVerificationFailed;
    }
    _ = try report.accept(result);
    return changed;
}

/// Complete fresh initialization using the desired credentials before activation.
/// Existing databases are inspected only; reconciliation follows normal health.
pub fn bootstrap(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report) !void {
    if (try run(a, r, report, .bootstrap)) report.emit(.credentials_updated);
}

pub fn reconcile(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report) !void {
    if (report.grafana_credentials == null) {
        report.emit(.credentials_unmanaged);
        return;
    }
    if (try run(a, r, report, .reconcile)) report.emit(.credentials_updated);
    report.emit(.credentials_verified);
}

pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report) !void {
    if (report.grafana_credentials == null) {
        report.emit(.credentials_unmanaged);
        return;
    }
    _ = try run(a, r, report, .verify);
    report.emit(.credentials_verified);
}

/// Read-only authenticated plugin health and query checks. No references means
/// this specific evidence is unavailable; the caller reports that limitation.
pub fn verifyLogs(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report) !void {
    report.logs_query_verified = false;
    if (report.grafana_credentials == null) return;
    _ = try run(a, r, report, .logs_verify);
    report.logs_query_verified = true;
}

test "Grafana credential helper remains static and uses private stdin" {
    const a = std.testing.allocator;
    const text = try command(a, .reconcile);
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "'runuser' '--user' 'dt-grafana' '--' 'python3' '-I' '-B' '-c'"));
    try std.testing.expect(std.mem.endsWith(u8, text, "'reconcile'"));
    try std.testing.expect(std.mem.indexOf(u8, helper, "sys.stdin.buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper, "shell=True") == null);
    try std.testing.expect(std.mem.indexOf(u8, helper, "NamedTemporaryFile") == null);
    const plugin = @import("../components/grafana_victorialogs_plugin.zig");
    try std.testing.expect(std.mem.indexOf(u8, helper, "LOGS_TYPE = \"" ++ plugin.id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper, "LOGS_VERSION = \"" ++ plugin.version ++ "\"") != null);
}

test "Grafana credential executable fixtures cover bootstrap reset rename no-op and failure redaction" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/grafana_credentials_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "Logs verification requires configured credentials and never accepts mutation" {
    const Secret = @import("../secrets/secret.zig").Secret;
    const Fake = struct {
        calls: usize = 0,
        result: remote.Result = .{ .code = 0, .output = "unchanged" },
        fn execute(_: *anyopaque, _: remote.Operation, _: []const u8) !remote.Result {
            return error.UnexpectedUnprotectedTransport;
        }
        fn executeSecret(ctx: *anyopaque, op: remote.Operation, text: []const u8, payload: *const Secret, budget_ms: u32) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            try std.testing.expectEqual(remote.Operation.credentials, op);
            try std.testing.expectEqual(@as(u32, 120_000), budget_ms);
            try std.testing.expect(std.mem.endsWith(u8, text, "'logs_verify'"));
            try std.testing.expect(std.mem.indexOf(u8, text, "secret-fixture") == null);
            try std.testing.expectEqualStrings("secret-fixture", payload.protectedBytes());
            return self.result;
        }
    };
    const a = std.testing.allocator;
    var fake: Fake = .{};
    const r: remote.Remote = .{ .context = &fake, .execute = Fake.execute, .execute_secret = Fake.executeSecret };
    var report: workflow.Report = .{};
    try verifyLogs(a, r, &report);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!report.logs_query_verified);
    const payload = try Secret.init(a, "secret-fixture");
    defer payload.deinit();
    report.grafana_credentials = payload;
    try verifyLogs(a, r, &report);
    try std.testing.expect(report.logs_query_verified);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@import("readiness.zig").Check.logs_datasource_ready, report.check.?);
    fake.result = .{ .code = 0, .output = "changed" };
    try std.testing.expectError(error.GrafanaLogsQueryFailed, verifyLogs(a, r, &report));
    try std.testing.expect(!report.logs_query_verified);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    fake.result = .{ .code = 86, .output = "suppressed" };
    try std.testing.expectError(error.GrafanaLogsQueryFailed, verifyLogs(a, r, &report));
    fake.result.code = 87;
    try std.testing.expectError(error.GrafanaLogsQueryTimedOut, verifyLogs(a, r, &report));
    fake.result.code = 88;
    try std.testing.expectError(error.GrafanaLogsPluginNotLoaded, verifyLogs(a, r, &report));
}
