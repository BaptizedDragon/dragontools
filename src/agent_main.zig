const std = @import("std");
const protocol = @import("agent/protocol.zig");
const runtime = @import("agent/runtime.zig");
const j = @import("agent/json.zig");
const diagnostics = @import("agent/diagnostics.zig");
// A panic must not dump private allocator contents, source expressions or stacks.
pub const panic = std.debug.FullPanic(quietPanic);
fn quietPanic(_: []const u8, _: ?usize) noreturn {
    std.process.exit(86);
}
pub fn main(init: std.process.Init) void {
    var enabled = false;
    var stage: diagnostics.Stage = .request;
    const code = entry(init, &enabled, &stage) catch |err| blk: {
        if (enabled) {
            var buffer: [diagnostics.limit]u8 = undefined;
            const message = diagnostics.failure(stage, err).render(&buffer);
            std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        }
        break :blk protocol.exitCode(err);
    };
    if (code != 0) std.process.exit(code);
}
fn entry(init: std.process.Init, enabled: *bool, stage: *diagnostics.Stage) !u8 {
    try runtime.protect();
    var wiping: @import("agent/secure_allocator.zig").SecureAllocator = .{ .child = std.heap.page_allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "version")) {
        try j.require(args.len == 2 or args.len == 3 and std.mem.eql(u8, args[2], "--json"));
        try std.Io.File.stdout().writeStreamingAll(init.io, try @import("version.zig").render(a, args.len == 3, true));
        return 0;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "maintenance")) {
        const m = @import("maintenance/main.zig");
        try j.require(std.mem.eql(u8, args[2], "check") or std.mem.eql(u8, args[2], "metrics"));
        const state = try m.collect(a, init.io);
        const output = if (std.mem.eql(u8, args[2], "metrics")) try m.metrics(a, state, @import("version.zig").version) else try m.json(a, state);
        try std.Io.File.stdout().writeStreamingAll(init.io, output);
        return 0;
    }
    enabled.* = args.len == 4 and std.mem.eql(u8, args[1], "internal") and std.mem.eql(u8, args[2], "--stdin") and std.mem.eql(u8, args[3], "--diagnostics");
    try j.require(enabled.* or args.len == 3 and std.mem.eql(u8, args[1], "internal") and std.mem.eql(u8, args[2], "--stdin"));
    const request = try @import("agent/request.zig").read(a, init.io, std.Io.File.stdin());
    const action = request.action;
    const arguments = request.args;
    stage.* = .native_initialization;
    const root = try std.Io.Dir.openDirAbsolute(init.io, "/", .{});
    defer root.close(init.io);
    stage.* = .operation_lock;
    const operation_lock = try runtime.lock(init.io, root);
    defer operation_lock.close(init.io);
    stage.* = .native_initialization;
    var system: runtime.Runtime = .{ .a = a, .io = init.io };
    var ctx = try system.context(root, protocol.stationAction(action));
    ctx.diagnostic_stage = stage;
    stage.* = .enrollment;
    const output = try protocol.dispatch(ctx, action, arguments);
    // Defense in depth around the closed public output protocol.
    try j.require(output.len <= 393216 and std.mem.indexOf(u8, output, "PRIVATE KEY") == null);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
    return 0;
}
