//! Narrow mTLS ingestion and protected agent certificate transport. No payload
//! belongs in command arguments or the ordinary managed-file writer.
const std = @import("std");
const remote = @import("../../system/remote.zig");
pub const program = @embedFile("ingestion.py");
pub const pki_program = @embedFile("pki.py");
pub const port = 9443;
pub const user = "dt-ingest";
pub const executable = "/opt/dragontools/ingestion/ingestion.py";
pub const directory = "/etc/dragontools/ingestion";
pub const marker = "/var/lib/dragontools/ingestion-restart-required";
pub const Kind = enum { vector, vmagent };

pub fn ensureCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, registration_json: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", pki_program, "ensure", host, endpoint, registration_json });
}
pub fn exportCommand(a: std.mem.Allocator, host: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", pki_program, "export", host });
}
pub fn readRegistrationCommand(a: std.mem.Allocator, host: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", pki_program, "registration", host });
}
pub fn installCredentialsCommand(a: std.mem.Allocator, kind: Kind) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", pki_program, "import", @tagName(kind) });
}
pub fn verifyCredentialsCommand(a: std.mem.Allocator, kind: Kind, host: []const u8, endpoint: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", pki_program, "verify-agent", @tagName(kind), host, endpoint });
}
pub fn verifyStationCommand(a: std.mem.Allocator, host: []const u8, endpoint: []const u8, registration_json: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", pki_program, "verify", host, endpoint, registration_json });
}

test "agent certificates use dedicated protected import and export commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.startsWith(u8, program, "# Managed by DragonTools\n"));
    try std.testing.expect(std.mem.endsWith(u8, try installCredentialsCommand(a, .vector), "'import' 'vector'"));
    try std.testing.expect(std.mem.endsWith(u8, try installCredentialsCommand(a, .vmagent), "'import' 'vmagent'"));
    try std.testing.expect(std.mem.endsWith(u8, try exportCommand(a, "host-one"), "'export' 'host-one'"));
    try std.testing.expect(std.mem.indexOf(u8, pki_program, "sys.stdin.buffer.read(65537)") != null);
    try std.testing.expect(std.mem.indexOf(u8, program, "ssl.CERT_REQUIRED") != null);
    try std.testing.expect(std.mem.indexOf(u8, program, "ssl.TLSVersion.TLSv1_2") != null);
}

test "local mTLS ingestion fixtures enforce routes registration bounds and credential no-op" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/agent_ingestion_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("", result.stderr);
}
