//! A logical state model only; no distro metadata collection yet.
const std = @import("std");
pub const State = enum { current, available, failed, unknown };
pub fn parse(value: []const u8) !State {
    return std.meta.stringToEnum(State, std.mem.trim(u8, value, " \n")) orelse error.InvalidUpdateState;
}
pub const Policy = struct {
    security_install_allowed: bool = true,
    component_auto_upgrade: bool = false,
    automatic_reboot: bool = false,
};
test "unknown update state is not current; failed checks stay failed" {
    try std.testing.expectEqual(State.failed, try parse("failed\n"));
    try std.testing.expectEqual(State.unknown, try parse("unknown"));
    try std.testing.expectError(error.InvalidUpdateState, parse("unexpected"));
    try std.testing.expect(!(Policy{}).automatic_reboot);
}
