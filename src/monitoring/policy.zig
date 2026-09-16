//! Opinionated storage defaults and prospective alert policies.
//! Retention/alert policy alone does not install or activate a component.
const std = @import("std");

const metrics_retention_days: u16 = 90;
pub const metrics = .{
    .retention_days = metrics_retention_days,
    .retention = std.fmt.comptimePrint("{d}d", .{metrics_retention_days}),
    .reserve_percent = @as(u8, 20),
};
pub const disk = .{
    .info_percent = @as(u8, 60),
    .warning_percent = @as(u8, 70),
    // Native VL/VT retention target, separate from alert severity.
    .cleanup_percent = @as(u8, 75),
    .critical_percent = @as(u8, 80),
};
// Pinned VL/VT compare their own partition bytes with this percentage of total
// filesystem capacity. This is not a cap on overall usage from all writers.
pub const logs = .{
    .retention = "100y",
    .cleanup_usage_percent = disk.cleanup_percent,
};
// Both elastic consumers deliberately share the same logical/native policy.
pub const traces = logs;
pub const host = .{
    .down_for = "2m",
    .cpu_percent = @as(u8, 90),
    .cpu_for = "10m",
    .cpu_rate_window = "5m",
    .memory_percent = @as(u8, 90),
    .memory_for = "5m",
    .disk_for = "5m",
    .inode_percent = @as(u8, 90),
    .inode_for = "5m",
};
pub const service = .{
    .down_for = "2m",
    .restart_count = @as(u8, 3),
    .restart_window = "5m",
    .restart_for = "1m",
};
pub const log_alerts = .{
    .error_count = @as(u8, 5),
    .error_window = "5m",
    .critical_count = @as(u8, 1),
    .critical_window = "1m",
    .evaluation_interval = "1m",
};

/// Preserve the original ceil(capacity / 5) algorithm, including zero rejection
/// and overflow safety. Never multiply capacity by a percentage before dividing.
pub fn metricsReserve(capacity: u64) !u64 {
    if (capacity == 0) return error.InvalidCapacity;
    const divisor = @divExact(100, @as(u64, metrics.reserve_percent));
    return capacity / divisor + @intFromBool(capacity % divisor != 0);
}

test "storage and disk policy defaults" {
    try std.testing.expectEqual(@as(u16, 90), metrics.retention_days);
    try std.testing.expectEqualStrings("90d", metrics.retention);
    try std.testing.expectEqual(@as(u8, 20), metrics.reserve_percent);
    try std.testing.expectEqualStrings("100y", logs.retention);
    try std.testing.expectEqualStrings("100y", traces.retention);
    try std.testing.expectEqual(@as(u8, 75), logs.cleanup_usage_percent);
    try std.testing.expectEqual(@as(u8, 75), traces.cleanup_usage_percent);
    try std.testing.expectEqual(@as(u8, 60), disk.info_percent);
    try std.testing.expectEqual(@as(u8, 70), disk.warning_percent);
    try std.testing.expectEqual(@as(u8, 75), disk.cleanup_percent);
    try std.testing.expectEqual(@as(u8, 80), disk.critical_percent);
}
test "host and service alert defaults" {
    try std.testing.expectEqualStrings("2m", host.down_for);
    try std.testing.expectEqual(@as(u8, 90), host.cpu_percent);
    try std.testing.expectEqualStrings("10m", host.cpu_for);
    try std.testing.expectEqualStrings("5m", host.cpu_rate_window);
    try std.testing.expectEqual(@as(u8, 90), host.memory_percent);
    try std.testing.expectEqualStrings("5m", host.memory_for);
    try std.testing.expectEqualStrings("5m", host.disk_for);
    try std.testing.expectEqual(@as(u8, 90), host.inode_percent);
    try std.testing.expectEqualStrings("5m", host.inode_for);
    try std.testing.expectEqualStrings("2m", service.down_for);
    try std.testing.expectEqual(@as(u8, 3), service.restart_count);
    try std.testing.expectEqualStrings("5m", service.restart_window);
    try std.testing.expectEqualStrings("1m", service.restart_for);
}
test "log alert defaults aggregate errors and trigger critical events without holdoff" {
    try std.testing.expectEqual(@as(u8, 5), log_alerts.error_count);
    try std.testing.expectEqualStrings("5m", log_alerts.error_window);
    try std.testing.expectEqual(@as(u8, 1), log_alerts.critical_count);
    try std.testing.expectEqualStrings("1m", log_alerts.critical_window);
    try std.testing.expectEqualStrings("1m", log_alerts.evaluation_interval);
}
test "metrics reserve retains round-up and maximum-capacity behavior" {
    try std.testing.expectError(error.InvalidCapacity, metricsReserve(0));
    for ([_]u64{ 1, 4, 5, 6, 100, 101, std.math.maxInt(u64) }) |capacity| {
        try std.testing.expectEqual(capacity / 5 + @intFromBool(capacity % 5 != 0), try metricsReserve(capacity));
    }
}
