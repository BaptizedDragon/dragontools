//! Closed diagnostic vocabulary. Never serialize arbitrary errors or remote text.
const std = @import("std");

pub const EnrollmentStage = enum {
    station_ensure,
    station_inspect,
    station_stage,
    station_registration_prepare,
    station_registration_read,
    station_finalize,
    client_prepare,
    client_stage,
    client_commit,
    client_rollback,
    agent_credential_install,
    credential_verify,
};
pub fn enrollmentStage(action: []const u8) ?EnrollmentStage {
    const actions = .{
        .{ "station-ensure", EnrollmentStage.station_ensure },           .{ "station-verify", EnrollmentStage.credential_verify },
        .{ "ensure", EnrollmentStage.station_ensure },                   .{ "inspect", EnrollmentStage.station_inspect },
        .{ "stage", EnrollmentStage.station_stage },                     .{ "stage-registration", EnrollmentStage.station_registration_prepare },
        .{ "registration", EnrollmentStage.station_registration_read },  .{ "finalize", EnrollmentStage.station_finalize },
        .{ "client-prepare", EnrollmentStage.client_prepare },           .{ "client-stage", EnrollmentStage.client_stage },
        .{ "client-commit", EnrollmentStage.client_commit },             .{ "client-rollback", EnrollmentStage.client_rollback },
        .{ "client-install", EnrollmentStage.agent_credential_install }, .{ "verify-agent", EnrollmentStage.credential_verify },
        .{ "verify", EnrollmentStage.credential_verify },                .{ "endpoint", EnrollmentStage.credential_verify },
    };
    inline for (actions) |pair| if (std.mem.eql(u8, action, pair[0])) return pair[1];
    return null;
}
pub const Stage = enum {
    request,
    native_initialization,
    enrollment,
    station_registration_prepare,
    managed_directories,
    registry_prepare,
    ca_state,
    ca_key_generation,
    ca_certificate_generation,
    ca_certificate_validation,
    ca_key_serialization,
    ca_publication,
    server_state,
    server_key_generation,
    server_certificate_generation,
    server_certificate_validation,
    server_key_serialization,
    server_publication,
};
pub const AgentError = enum {
    CryptoKeyGenerationFailed,
    CertificateGenerationFailed,
    CertificateValidationFailed,
    FilesystemStateRefused,
    InvalidManagedState,
    AgentInternalError,
    CaMaintenanceRequired,
    ClientIdentityInconsistent,
    RegistryPermissions,
    IngressHostnameRequired,
    DnsUnresolved,
    TcpUnreachable,
    ServerTlsInvalid,
    ClientCertificateRejected,
    IngestionRejected,
};
pub const Detail = enum {
    agent_internal_error,
    ca_maintenance,
    client_identity_inconsistent,
    registry_permissions,
    ingress_hostname_required,
    dns_unresolved,
    tcp_unreachable,
    server_tls_invalid,
    client_certificate_rejected,
    ingestion_rejected,
};
pub fn detail(code: u8) ?Detail {
    return switch (code) {
        86 => .agent_internal_error,
        87 => .ca_maintenance,
        88 => .client_identity_inconsistent,
        89 => .registry_permissions,
        90 => .ingress_hostname_required,
        91 => .dns_unresolved,
        92 => .tcp_unreachable,
        93 => .server_tls_invalid,
        94 => .client_certificate_rejected,
        95 => .ingestion_rejected,
        else => null,
    };
}
pub const limit = 256;
pub const Diagnostic = struct {
    stage: Stage,
    reason: AgentError,
    pub fn render(self: Diagnostic, buffer: *[limit]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "AgentStage: {s}\nAgentError: {s}\n", .{ @tagName(self.stage), @tagName(self.reason) }) catch unreachable;
    }
};
pub fn failure(stage: Stage, err: anyerror) Diagnostic {
    const reason: AgentError = switch (err) {
        error.CaMaintenanceRequired => .CaMaintenanceRequired,
        error.ClientIdentityInconsistent => .ClientIdentityInconsistent,
        error.RegistryPermissions => .RegistryPermissions,
        error.IngressHostnameRequired => .IngressHostnameRequired,
        error.DnsUnresolved => .DnsUnresolved,
        error.TcpUnreachable => .TcpUnreachable,
        error.ServerTlsInvalid => .ServerTlsInvalid,
        error.ClientCertificateRejected => .ClientCertificateRejected,
        error.IngestionRejected => .IngestionRejected,
        else => switch (stage) {
            .ca_key_generation, .server_key_generation => .CryptoKeyGenerationFailed,
            .ca_certificate_generation, .server_certificate_generation => .CertificateGenerationFailed,
            .ca_certificate_validation, .server_certificate_validation => .CertificateValidationFailed,
            .managed_directories, .registry_prepare, .ca_publication, .server_publication => .FilesystemStateRefused,
            .ca_state, .server_state, .station_registration_prepare => .InvalidManagedState,
            else => if (err == error.CredentialStateRefused) .InvalidManagedState else .AgentInternalError,
        },
    };
    return .{ .stage = stage, .reason = reason };
}
/// Reject the entire message on unknown fields, extra output, or oversized data.
/// The caller retains only enums, never a slice of untrusted stderr.
pub fn parse(bytes: []const u8) ?Diagnostic {
    if (bytes.len > limit) return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const stage_line = lines.next() orelse return null;
    const reason_line = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, stage_line, "AgentStage: ") or !std.mem.startsWith(u8, reason_line, "AgentError: ")) return null;
    if ((lines.next() orelse return null).len != 0 or lines.next() != null) return null;
    return .{
        .stage = std.meta.stringToEnum(Stage, stage_line["AgentStage: ".len..]) orelse return null,
        .reason = std.meta.stringToEnum(AgentError, reason_line["AgentError: ".len..]) orelse return null,
    };
}

test "agent diagnostics accept only bounded complete enum messages" {
    var buffer: [limit]u8 = undefined;
    const expected = failure(.ca_key_generation, error.InvalidPki);
    try std.testing.expectEqual(expected, parse(expected.render(&buffer)).?);
    for ([_][]const u8{
        "AgentError: -----BEGIN PRIVATE KEY-----\n",
        "AgentStage: ca_key_generation\nAgentError: ArbitraryError\n",
        "AgentStage: /private/path\nAgentError: InvalidManagedState\n",
        "AgentStage: ca_key_generation\nAgentError: CryptoKeyGenerationFailed\nsecret",
        "secret\nAgentStage: ca_key_generation\nAgentError: CryptoKeyGenerationFailed\n",
        "x" ** (limit + 1),
    }) |bytes| try std.testing.expect(parse(bytes) == null);
}
