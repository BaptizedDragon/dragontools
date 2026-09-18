//! Public CSR/certificate exchange; every private key remains on its owning host.
const std = @import("std");
const remote = @import("../../system/remote.zig");
pub const program = @embedFile("ingestion.py");
pub const checks_program = @embedFile("checks.py");
pub const port = 9443;
pub const user = "dt-ingest";
pub const executable = "/opt/dragontools/ingestion/ingestion.py";
pub const directory = "/etc/dragontools/ingestion";
pub const client_directory = "/etc/dragontools/monitoring-client";
pub const marker = "/var/lib/dragontools/ingestion-restart-required";
pub const Kind = enum { vector, vmagent };
pub const Action = enum { unchanged, enroll, renew, migrate, reenroll };
pub const Prepared = struct {
    action: Action,
    csr: ?[]const u8,
    recovered_key: bool = false,
    certificate_sha256: ?[]const u8,
};

pub const Inspection = struct {
    host: []const u8,
    station: []const u8,
    @"ca.crt": []const u8,
    legacy: bool,
    legacy_expired: bool,
    legacy_active: bool,
    certificate_sha256: ?[]const u8,
    pending_certificate_sha256: ?[]const u8,
};
pub fn parseInspection(a: std.mem.Allocator, data: []const u8, host: []const u8, endpoint: []const u8) !Inspection {
    if (data.len > 32768 or std.mem.indexOf(u8, data, "PRIVATE KEY") != null) return error.InvalidEnrollmentResponse;
    const parsed = try std.json.parseFromSlice(Inspection, a, data, .{ .allocate = .alloc_always });
    const value = parsed.value;
    if (!std.mem.eql(u8, host, value.host) or !std.mem.eql(u8, endpoint, value.station)) return error.InvalidEnrollmentResponse;
    if (value.certificate_sha256) |fp| try validateFingerprint(fp);
    if (value.pending_certificate_sha256) |fp| try validateFingerprint(fp);
    return value;
}
pub fn parsePrepared(a: std.mem.Allocator, data: []const u8) !Prepared {
    if (data.len > 16384 or std.mem.indexOf(u8, data, "PRIVATE KEY") != null) return error.InvalidEnrollmentResponse;
    const parsed = try std.json.parseFromSlice(Prepared, a, data, .{ .allocate = .alloc_always });
    const value = parsed.value;
    if (value.csr) |csr| {
        if (csr.len > 8192 or !std.mem.startsWith(u8, csr, "-----BEGIN CERTIFICATE REQUEST-----\n") or !std.mem.endsWith(u8, csr, "-----END CERTIFICATE REQUEST-----\n")) return error.InvalidEnrollmentResponse;
    } else if (value.action != .unchanged) return error.InvalidEnrollmentResponse;
    if (value.certificate_sha256) |fingerprint| try validateFingerprint(fingerprint);
    if (value.action == .unchanged and value.certificate_sha256 == null) return error.InvalidEnrollmentResponse;
    return value;
}
pub fn validateFingerprint(value: []const u8) !void {
    if (value.len != 64) return error.InvalidEnrollmentResponse;
    for (value) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidEnrollmentResponse;
}
pub fn publicBundleFingerprint(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    if (data.len > 32768 or std.mem.indexOf(u8, data, "PRIVATE KEY") != null) return error.InvalidEnrollmentResponse;
    const Bundle = struct { host: []const u8, station: []const u8, @"ca.crt": []const u8, @"client.crt": []const u8, certificate_sha256: []const u8 };
    const parsed = try std.json.parseFromSlice(Bundle, a, data, .{ .allocate = .alloc_always });
    try validateFingerprint(parsed.value.certificate_sha256);
    return parsed.value.certificate_sha256;
}
pub fn request(a: std.mem.Allocator, arguments: []const []const u8) !remote.Input {
    if (arguments.len == 0) return error.InvalidEnrollmentRequest;
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .action = arguments[0], .args = arguments[1..] }, .{});
    if (bytes.len > 512 * 1024 or std.mem.indexOf(u8, bytes, "PRIVATE KEY") != null) return error.InvalidEnrollmentRequest;
    return .{ .command = try remote.shell(a, &.{ "/opt/dragontools/agent/current/dragontool-agent", "internal", "--stdin" }), .bytes = bytes };
}
pub fn ensureCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, registration_json: []const u8) !remote.Input {
    return request(a, &.{ "ensure", host, endpoint, registration_json });
}
pub fn inspectCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8) !remote.Input {
    return request(a, &.{ "inspect", host, endpoint });
}
pub fn stageCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, registration_json: []const u8, csr: []const u8) !remote.Input {
    return request(a, &.{ "stage", host, endpoint, registration_json, csr });
}
pub fn reconcileCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, registration_json: []const u8) !remote.Input {
    return request(a, &.{ "stage-registration", host, endpoint, registration_json });
}
pub fn finalizeCommand(a: std.mem.Allocator, host: []const u8, fingerprint: []const u8) !remote.Input {
    return request(a, &.{ "finalize", host, fingerprint });
}
pub fn prepareClientCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, inspection: []const u8) !remote.Input {
    if (inspection.len > 32768 or std.mem.indexOf(u8, inspection, "PRIVATE KEY") != null) return error.InvalidEnrollmentResponse;
    return request(a, &.{ "client-prepare", host, endpoint, inspection });
}
pub fn stageClientCommand(a: std.mem.Allocator, bundle: []const u8) !remote.Input {
    return request(a, &.{ "client-stage", bundle });
}
pub fn finishClientCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, commit: bool) !remote.Input {
    return request(a, &.{ if (commit) "client-commit" else "client-rollback", host, endpoint });
}
pub fn readRegistrationCommand(a: std.mem.Allocator, host: []const u8) !remote.Input {
    return request(a, &.{ "registration", host });
}
pub fn installCredentialsCommand(a: std.mem.Allocator, kind: Kind, host: []const u8, endpoint: []const u8) !remote.Input {
    return request(a, &.{ "client-install", @tagName(kind), host, endpoint });
}
pub fn verifyCredentialsCommand(a: std.mem.Allocator, kind: Kind, host: []const u8, endpoint: []const u8) !remote.Input {
    return request(a, &.{ "verify-agent", @tagName(kind), host, endpoint });
}
pub fn endpointCommand(a: std.mem.Allocator, endpoint: []const u8, kind: []const u8, host: []const u8) !remote.Input {
    return request(a, &.{ "endpoint", endpoint, kind, host });
}
pub fn verifyStationCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, registration_json: []const u8) !remote.Input {
    return request(a, &.{ "verify", host, endpoint, registration_json });
}

test "enrollment exchanges bounded public CSR and certificates with no private transfer API" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.startsWith(u8, program, "# Managed by DragonTools\n"));
    try std.testing.expectEqualStrings("{\"action\":\"client-install\",\"args\":[\"vector\",\"host\",\"station\"]}", (try installCredentialsCommand(a, .vector, "host", "station")).bytes);
    try std.testing.expect(std.mem.indexOf(u8, program, "ssl.CERT_REQUIRED") != null);
    try std.testing.expect(std.mem.indexOf(u8, program, "ssl.TLSVersion.TLSv1_2") != null);
    try std.testing.expectError(error.InvalidEnrollmentResponse, parsePrepared(a, "PRIVATE KEY"));
    try std.testing.expectError(error.InvalidEnrollmentResponse, parsePrepared(a, "{\"action\":\"enroll\",\"csr\":null,\"certificate_sha256\":null}"));
}

test "local mTLS ingestion fixtures enforce routes registration bounds and credential no-op" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/agent_ingestion_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("", result.stderr);
}

// Native lifecycle/parity tests now run through build.zig test-agent.
