//! Credentials travel only through the private SSH stdin channel. Remote command
//! text contains fixed source and paths; results contain fixed semantic tokens.
const std = @import("std");
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
pub const helper = @embedFile("grafana_credentials.py");
pub const Mode = enum { bootstrap, reconcile, verify };

pub fn command(a: std.mem.Allocator, mode: Mode) ![]const u8 {
    return remote.shell(a, &.{ "runuser", "--user", "dt-grafana", "--", "python3", "-I", "-B", "-c", helper, @tagName(mode) });
}

fn run(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, mode: Mode) !bool {
    const payload = report.grafana_credentials orelse return false;
    const script = try command(a, mode);
    defer a.free(script);
    report.phase = .credentials;
    report.check = if (mode == .bootstrap) .credentials_bootstrap else .credentials_authenticated;
    const result = try r.runSecret(.credentials, script, payload, 120_000);
    switch (result.code) {
        0 => {},
        80 => return error.InvalidGrafanaCredentials,
        81 => return error.GrafanaAdministratorConflict,
        82 => return error.GrafanaCredentialResetFailed,
        83 => return error.GrafanaCredentialVerificationFailed,
        84 => return error.GrafanaCredentialApiUnavailable,
        85 => return error.GrafanaCredentialBootstrapFailed,
        else => {
            _ = try report.accept(result);
            return error.GrafanaCredentialVerificationFailed;
        },
    }
    const changed = std.mem.eql(u8, result.output, "changed");
    if ((!changed and !std.mem.eql(u8, result.output, "unchanged")) or (mode == .verify and changed)) return error.GrafanaCredentialVerificationFailed;
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

test "Grafana credential helper remains static and uses private stdin" {
    const a = std.testing.allocator;
    const text = try command(a, .reconcile);
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "'runuser' '--user' 'dt-grafana' '--' 'python3' '-I' '-B' '-c'"));
    try std.testing.expect(std.mem.endsWith(u8, text, "'reconcile'"));
    try std.testing.expect(std.mem.indexOf(u8, helper, "sys.stdin.buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper, "shell=True") == null);
    try std.testing.expect(std.mem.indexOf(u8, helper, "NamedTemporaryFile") == null);
}

test "Grafana credential executable fixtures cover bootstrap reset rename no-op and failure redaction" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/grafana_credentials_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
