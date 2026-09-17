//! Observed from pinned Vector 0.58.0 on a local Linux/aarch64 fixture.
//! The Prometheus exporter and remote-write sink share namespace/name encoding.
//! This is not a claim of supported-host/systemd or station integration validation.
const std = @import("std");
pub const cpu = "host_cpu_seconds_total";
pub const memory_available = "host_memory_available_bytes";
pub const memory_total = "host_memory_total_bytes";
pub const filesystem_free = "host_filesystem_free_bytes";
pub const network_receive_bytes = "host_network_receive_bytes_total";
pub const network_transmit_bytes = "host_network_transmit_bytes_total";
pub const filesystem_ratio = "host_filesystem_used_ratio";
pub const inode_ratio = "host_filesystem_inodes_used_ratio";
pub const inode_total = "host_filesystem_inodes_total";
pub const running = "vector_uptime_seconds";
pub const buffer_bytes = "vector_buffer_size_bytes";
pub const fixture = @embedFile("vector_metrics_fixture.prom");

test "host metric contract matches actual pinned Linux Vector output" {
    for ([_][]const u8{ cpu, memory_available, memory_total, filesystem_ratio, filesystem_free, inode_ratio, inode_total, network_receive_bytes, network_transmit_bytes, running, buffer_bytes }) |name| {
        const prefix = try std.fmt.allocPrint(std.testing.allocator, "\n{s}{{", .{name});
        defer std.testing.allocator.free(prefix);
        try std.testing.expect(std.mem.indexOf(u8, fixture, prefix) != null);
    }
    for ([_][]const u8{ "mode=\"idle\"", "cpu=\"0\"", "mountpoint=", "filesystem=", "host=\"fixture-host\"" }) |label| try std.testing.expect(std.mem.indexOf(u8, fixture, label) != null);
}
