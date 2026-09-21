const std = @import("std");
const remote = @import("remote.zig");
pub fn require(a: std.mem.Allocator, r: remote.Remote, service: []const u8) !void {
    if (!@import("../cli/parse.zig").token(service, "_.@:-") or !std.mem.endsWith(u8, service, ".service")) return error.InvalidService;
    const command = try remote.shell(a, &.{ "systemctl", "show", "--property=LoadState", "--value", "--", service });
    const result = try r.run(.service_exists, command);
    if (result.code != 0 or !std.mem.eql(u8, std.mem.trim(u8, result.output, " \n"), "loaded")) return error.MissingService;
}
test "missing selected systemd unit is rejected" {
    const Fake = struct {
        fn execute(_: *anyopaque, _: remote.Operation, _: []const u8) !remote.Result {
            return .{ .code = 0, .output = "not-found\n" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    try std.testing.expectError(error.MissingService, require(arena.allocator(), .{ .context = &context, .execute = Fake.execute }, "missing.service"));
}
