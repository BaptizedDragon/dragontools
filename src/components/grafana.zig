//! Concrete Grafana OSS artifact; the installed tree contains no writable state.
const std = @import("std");
const remote = @import("../system/remote.zig");
const Arch = @import("../system/host.zig").Arch;

pub const version = "13.2.2";
pub const build = "34846740809";
pub const ui_path = "/";
pub const root = "/opt/dragontools/components/grafana";
pub const pending = "/var/lib/dragontools/grafana-restart-required";
pub const port: u16 = 3000;
pub const listen_address = "127.0.0.1:3000";
pub const Artifact = struct {
    arch: []const u8,
    archive_sha256: []const u8,
    binary_sha256: []const u8,
    tree_sha256: []const u8,
};

// Reviewed 2026-09-16 against the official OSS download page for 13.2.2:
// https://grafana.com/grafana/download/13.2.2?edition=oss
// Archive digests match upstream download metadata. Binary and canonical complete
// catalog digests were computed from those verified archives, using the embedded
// audit code. Both contain 13,358 regular files and 1,689 directories, with no
// links, special entries, traversal or duplicate names. Normalized root-owned
// modes are 0755 for directories/executables and 0644 otherwise. These hashes
// trust upstream publication; they are not an independent publisher signature.
// The local catalog is trusted ONLY after hashing it against tree_sha256, then
// every live entry must match its type/content/mode/ownership. Runtime never
// fetches mutable checksums. Extra paths, symlinks and foreign trees are refused.
pub fn artifact(arch: Arch) Artifact {
    return switch (arch) {
        .amd64 => .{
            .arch = "amd64",
            .archive_sha256 = "9662c838a09824fdb072e5f6fbdd45b62cf541b20f3d609ea5011e6e5f544c8f",
            .binary_sha256 = "85ee554e0daed72d20d0a2259ec94306b5ea393bbdd46faa2613a29426a93fda",
            .tree_sha256 = "9b7215edd035e2ddc45e63747a4fbf7c561ca33f95a399a865126ba3da52c64d",
        },
        .arm64 => .{
            .arch = "arm64",
            .archive_sha256 = "7268f9a576f919f14e6263b344a85b6ac8d768fbda247910c43ce4e12c747a72",
            .binary_sha256 = "1bd236c6d859bc0c901116ef919d68abc9b964a4ad8902c069f83b4b913f27e0",
            .tree_sha256 = "316d14846c1ca1eb1d7847061c21c5994884f809de235e792d02bdbecfe8f368",
        },
    };
}

pub const artifact_script = @embedFile("grafana_artifact.py");

pub fn archiveURL(a: std.mem.Allocator, arch: Arch) ![]const u8 {
    return std.fmt.allocPrint(a, "https://dl.grafana.com/grafana/release/{s}/grafana_{s}_{s}_linux_{s}.tar.gz", .{ version, version, build, artifact(arch).arch });
}

fn command(a: std.mem.Allocator, arch: Arch, mode: []const u8) ![]const u8 {
    const item = artifact(arch);
    const url = try archiveURL(a, arch);
    defer a.free(url);
    return remote.shell(a, &.{
        "python3",             "-I",               "-B",             "-c",    artifact_script,
        "dragontools-grafana", mode,               root,             version, url,
        item.archive_sha256,   item.binary_sha256, item.tree_sha256, pending,
    });
}

pub fn binaryCommand(a: std.mem.Allocator, arch: Arch) ![]const u8 {
    return command(a, arch, "install");
}

/// Read-only and silent on success, suitable for composing with service health.
pub fn integrityCommand(a: std.mem.Allocator, arch: Arch) ![]const u8 {
    const inner = try command(a, arch, "verify");
    defer a.free(inner);
    return std.fmt.allocPrint(a, "{s} >/dev/null", .{inner});
}

test "Grafana OSS official immutable artifact and complete-tree pins cover both architectures" {
    try std.testing.expectEqualStrings("13.2.2", version);
    for ([_]Arch{ .amd64, .arm64 }) |arch| {
        const item = artifact(arch);
        try std.testing.expectEqualStrings(@tagName(arch), item.arch);
        for ([_][]const u8{ item.archive_sha256, item.binary_sha256, item.tree_sha256 }) |hash| {
            try std.testing.expectEqual(@as(usize, 64), hash.len);
            for (hash) |c| try std.testing.expect(std.ascii.isHex(c));
        }
        const url = try archiveURL(std.testing.allocator, arch);
        defer std.testing.allocator.free(url);
        try std.testing.expect(std.mem.startsWith(u8, url, "https://dl.grafana.com/grafana/release/13.2.2/"));
        try std.testing.expect(std.mem.indexOf(u8, url, "latest") == null);
        try std.testing.expect(std.mem.indexOf(u8, url, "enterprise") == null);
        const rendered = try binaryCommand(std.testing.allocator, arch);
        defer std.testing.allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, item.tree_sha256) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, item.archive_sha256) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, item.binary_sha256) != null);
    }
    try std.testing.expect(!std.mem.eql(u8, artifact(.amd64).tree_sha256, artifact(.arm64).tree_sha256));
}

test "Grafana embedded artifact fixture tests exercise extraction publication failures and no-op" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/grafana_artifact_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
