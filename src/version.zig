const std = @import("std");
const crypto = @import("pki/mbedtls.zig");
pub const version = @import("build_options").version;
pub const zig_version = @import("builtin").zig_version_string;
pub const metadata = .{ .dragontool = version, .zig = zig_version, .mbedtls = crypto.version, .tf_psa_crypto = crypto.psa_version, .minimum_approved_mbedtls = crypto.minimum_approved, .mbedtls_archive_sha256 = crypto.archive_sha256 };
pub fn render(a: std.mem.Allocator, json: bool, agent: bool) ![]const u8 {
    if (json) return std.json.Stringify.valueAlloc(a, metadata, .{});
    return std.fmt.allocPrint(a, "{s} {s}\nZig {s}\nMbed TLS {s} (minimum approved {s})\nTF-PSA-Crypto {s}\n", .{ if (agent) "DragonTool Agent" else "DragonTool", version, zig_version, crypto.version, crypto.minimum_approved, crypto.psa_version });
}
