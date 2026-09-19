//! Station-owned mTLS transport. No application or client identity is needed.
const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const files = @import("../system/files.zig");
const Report = @import("install.zig").Report;
const ready = @import("readiness.zig");
const common = @import("agents/common.zig");
const credentials = @import("agents/ingestion.zig");
const units = @import("agents/ingress_units.zig");
const caddy = @import("../components/caddy.zig");
const checks = @import("agents/verify.zig");

pub const legacy_guard = "test ! -e /etc/systemd/system/dragontools-ingestion.service && test ! -L /etc/systemd/system/dragontools-ingestion.service && test \"$(systemctl show -p LoadState --value dragontools-ingestion.service)\" = not-found";
const program_directory = "set -eu\npath=/opt/dragontools/ingress-auth\ntest ! -L \"$path\" || exit 43\nif test -e \"$path\"; then test -d \"$path\" && test \"$(stat -c '%u:%g:%a' \"$path\")\" = 0:0:755 || exit 40; printf unchanged; else install -d -o root -g root -m 755 \"$path\"; printf changed; fi";

pub fn spec(a: std.mem.Allocator, kind: common.Kind, arch: host.Arch) ![]const u8 {
    std.debug.assert(kind == .ingestion or kind == .caddy);
    return checks.serviceSpec(a, kind, arch, if (kind == .caddy) units.caddy_command else units.auth_command, if (kind == .caddy) .{ .path = caddy.config_path, .content = @embedFile("agents/Caddyfile") } else .{ .path = credentials.executable, .content = credentials.program });
}
pub fn service(a: std.mem.Allocator, r: remote.Remote, report: *Report, arch: host.Arch, kind: common.Kind) !void {
    const data = try spec(a, kind, arch);
    _ = try ready.deterministic(a, r, report, if (kind == .caddy) .caddy_service else .managed_state, try common.python(a, credentials.checks_program, &.{ "managed", data }));
    try ready.poll(a, r, report, if (kind == .caddy) .caddy_listener else .service_active, ready.active_ms, try common.python(a, credentials.checks_program, &.{ "active", data }), ready.ready);
    if (kind == .ingestion) {
        const guard = try common.python(a, credentials.checks_program, &.{ "active", data });
        const probe = try common.python(a, @embedFile("ingress_health.py"), &.{"--authorization"});
        try ready.poll(a, r, report, .http_ready, ready.http_ms, try std.fmt.allocPrint(a, "{s} && {s}", .{ guard, probe }), ready.ready);
    }
}
pub fn pki(a: std.mem.Allocator, r: remote.Remote, report: *Report) !void {
    _ = try ready.deterministic(a, r, report, .station_ingress_required, try credentials.request(a, &.{ "station-verify", report.ingress_hostname orelse "" }));
}
pub fn tls(a: std.mem.Allocator, r: remote.Remote, report: *Report, arch: host.Arch) !void {
    // Recheck process/listener invariants on every retry, never retry unsafe drift.
    const guard = try common.python(a, credentials.checks_program, &.{ "active", try spec(a, .caddy, arch) });
    const probe = try common.python(a, @embedFile("ingress_health.py"), &.{report.ingress_hostname orelse ""});
    try ready.poll(a, r, report, .ingress_tls_ready, ready.http_ms, try std.fmt.allocPrint(a, "{s} && {s}", .{ guard, probe }), ready.ready);
}
pub fn verifyBase(a: std.mem.Allocator, r: remote.Remote, report: *Report, arch: host.Arch) !void {
    _ = try ready.deterministic(a, r, report, .legacy_ingress_conflict, legacy_guard);
    try pki(a, r, report);
    try service(a, r, report, arch, .ingestion);
    try service(a, r, report, arch, .caddy);
    try tls(a, r, report, arch);
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *Report, arch: host.Arch) !void {
    report.beginComponent(.ingress_auth);
    _ = try ready.deterministic(a, r, report, .legacy_ingress_conflict, legacy_guard);
    try pki(a, r, report);
    try service(a, r, report, arch, .ingestion);
    report.endComponent();
    report.beginComponent(.caddy);
    try service(a, r, report, arch, .caddy);
    try tls(a, r, report, arch);
    report.endComponent();
}
pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *Report, arch: host.Arch) !void {
    report.beginComponent(.ingress_auth);
    _ = try ready.deterministic(a, r, report, .legacy_ingress_conflict, legacy_guard);
    _ = try report.call(r, .detect, "command -v python3 >/dev/null || exit 12");
    _ = try report.call(r, .user, try common.preflight(a, .ingestion));
    _ = try report.call(r, .directories, try common.directories(a, .ingestion));
    _ = try report.call(r, .credentials, try credentials.request(a, &.{ "station-ensure", report.ingress_hostname orelse "" }));
    _ = try report.call(r, .directories, program_directory);
    _ = try report.call(r, .config, try files.writeCommand(a, credentials.executable, credentials.program, credentials.marker));
    _ = try report.call(r, .unit, try files.writeCommand(a, try common.unitPath(a, .ingestion), units.auth, credentials.marker));
    _ = try report.call(r, .activate, common.activation(.ingestion));
    try service(a, r, report, arch, .ingestion);
    // Authorization health is a rejection on its private sockets, independent
    // of both Caddy and registry size. Finalize its own restart intent only.
    _ = try report.call(r, .finalize, try common.finalize(a, .ingestion));
    report.endComponent();
    report.beginComponent(.caddy);
    _ = try report.call(r, .user, try common.preflight(a, .caddy));
    _ = try report.call(r, .directories, try common.directories(a, .caddy));
    _ = try report.call(r, .binary, try caddy.binaryCommand(a, arch));
    _ = try report.call(r, .config, try files.writeCommand(a, caddy.config_path, @embedFile("agents/Caddyfile"), try common.marker(a, .caddy)));
    _ = try report.call(r, .config, "CREDENTIALS_DIRECTORY=/etc/dragontools/ingestion/server /opt/dragontools/components/caddy/current/caddy validate --config /etc/dragontools/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1");
    _ = try report.call(r, .unit, try files.writeCommand(a, try common.unitPath(a, .caddy), units.caddy, try common.marker(a, .caddy)));
    _ = try report.call(r, .activate, common.activation(.caddy));
    try pki(a, r, report);
    try service(a, r, report, arch, .caddy);
    try tls(a, r, report, arch);
    _ = try report.call(r, .finalize, try common.finalize(a, .caddy));
    report.endComponent();
}
