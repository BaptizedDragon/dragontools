//! Official signed VictoriaLogs plugin; persistent, root-owned and versioned.
const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const id = "victoriametrics-logs-datasource";
pub const version = "0.32.0";
pub const data = "/var/lib/dragontools/grafana";
pub const plugins_path = data ++ "/plugins";
pub const versions_path = data ++ "/plugins-versions";
pub const release_path = versions_path ++ "/" ++ id ++ "/" ++ version;
pub const content_path = release_path ++ "/content";
pub const active_path = plugins_path ++ "/" ++ id;
pub const active_target = "../plugins-versions/" ++ id ++ "/" ++ version ++ "/content";
pub const executable = "victoriametrics_logs_backend_plugin";
pub const archive_url = "https://grafana.com/api/plugins/" ++ id ++ "/versions/" ++ version ++ "/download";
pub const url = archive_url;
pub const archive_sha256 = "8204d097b17f53b1c3a71761047734b7980bd983710c6cfcef8d938abe5eeef0";
pub const tree_sha256 = "b251e3c695e333e4a22d4b8f1aeaee9893ff0e14e3a6170d356a74de2f97cadd";

// Reviewed 2026-09-16. VictoriaMetrics identifies this official plugin at:
// https://docs.victoriametrics.com/victorialogs/integrations/grafana/
// Archive SHA-256 matches packages.any.sha256 in the official version metadata:
// https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.32.0
// The exact ZIP is 78,122,569 bytes; 36 files/2 directories, 222,316,035 bytes.
// It is one multi-platform package, including Linux amd64/arm64 backend binaries,
// not architecture-independent backend code. Preserve all signed files verbatim.
// MANIFEST.txt is signed commercial by VictoriaMetrics, key 7e4d0c6a708866e7;
// Grafana still verifies that signature. No unsigned-plugin allowance is used.
// Local review also verified its PGP signature against Grafana v13.2.2's pinned
// static key (F33B25B691074E84636570F37E4D0C6A708866E7), with an isolated keyring.
// The canonical full-tree catalog pin and executable pins below were computed
// from this digest-verified ZIP. Its catalog stays OUTSIDE the signed content.
// Future version changes must retain reviewed prior version/catalog entries here
// to authorize switching only a known historical active link; no marker adoption.
pub const trusted_releases = "{\"" ++ version ++ "\":\"" ++ tree_sha256 ++ "\"}";

pub fn binarySHA256(arch: Arch) []const u8 {
    return switch (arch) {
        .amd64 => "2643c939ab73d0103299125d084fc90b8577b9e29cecfeb8964b83af01916253",
        .arm64 => "f928f880759c0fa148dc832d87a174664c66af5998d9b76bc36d2eaa1b8ea4b2",
    };
}

pub fn binaryPath(a: std.mem.Allocator, arch: Arch) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}_linux_{s}", .{ content_path, executable, @tagName(arch) });
}

pub const artifact_script = @embedFile("grafana_victorialogs_artifact.py");
pub const verify_script = artifact_script[0..std.mem.indexOf(u8, artifact_script, "# BEGIN MUTATING INSTALLATION").?] ++
    \\try:
    \\    require(len(sys.argv) == 6)
    \\    verify(sys.argv[2], sys.argv[3], json.loads(sys.argv[4]), sys.argv[5])
    \\except Refusal as failure:
    \\    sys.exit(failure.code)
    \\except Exception:
    \\    sys.exit(1)
    \\
;

pub fn installCommand(a: std.mem.Allocator) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", artifact_script, "dragontools-grafana-victorialogs-plugin", "install", data, version, archive_url, archive_sha256, trusted_releases, @import("grafana.zig").pending });
}

/// Read-only, contains no installation functions, and is silent on success.
pub fn verifyCommand(a: std.mem.Allocator) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", verify_script, "dragontools-grafana-victorialogs-plugin", data, version, trusted_releases, @import("grafana.zig").pending });
}

test "official VictoriaLogs plugin has fixed catalog archive and architecture pins" {
    try std.testing.expectEqualStrings("victoriametrics-logs-datasource", id);
    try std.testing.expectEqualStrings("0.32.0", version);
    try std.testing.expectEqualStrings("https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.32.0/download", archive_url);
    for ([_][]const u8{ archive_sha256, tree_sha256, binarySHA256(.amd64), binarySHA256(.arm64) }) |pin| {
        try std.testing.expectEqual(@as(usize, 64), pin.len);
        for (pin) |c| try std.testing.expect(std.ascii.isHex(c));
    }
    try std.testing.expect(!std.mem.eql(u8, binarySHA256(.amd64), binarySHA256(.arm64)));
    const command = try installCommand(std.testing.allocator);
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, archive_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, command, tree_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "latest") == null);
    try std.testing.expect(std.mem.startsWith(u8, content_path, "/var/lib/dragontools/grafana/"));
}

test "plugin verification embeds only read-only inspection" {
    const command = try verifyCommand(std.testing.allocator);
    defer std.testing.allocator.free(command);
    for ([_][]const u8{ "chmod", "chown", "os.replace", "os.mkdir", "os.unlink", "curl", "os.symlink", "mark_dirty", "subprocess.run" }) |mutation| {
        try std.testing.expect(std.mem.indexOf(u8, command, mutation) == null);
    }
    try std.testing.expect(command.len < 40 * 1024);
}

test "plugin fixture tests exercise ZIP rejection publication recovery and no-op" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/grafana_victorialogs_artifact_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
