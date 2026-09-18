const std = @import("std");
const protocol = @import("agent/protocol.zig");
const runtime = @import("agent/runtime.zig");
const j = @import("agent/json.zig");
pub fn main(init: std.process.Init) void {
    const code = entry(init) catch |err| protocol.exitCode(err);
    if (code != 0) std.process.exit(code);
}
fn entry(init: std.process.Init) !u8 {
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
    try j.require(args.len == 3 and std.mem.eql(u8, args[1], "internal") and std.mem.eql(u8, args[2], "--stdin"));
    const buffer = try a.alloc(u8, 512 * 1024 + 1);
    var used: usize = 0;
    while (used < buffer.len) {
        const n = try std.Io.File.stdin().readStreaming(init.io, &.{buffer[used..]});
        if (n == 0) break;
        used += n;
    }
    try j.require(used < buffer.len);
    const request = try j.parse(a, buffer[0..used], 512 * 1024);
    try j.keys(request, &.{ "action", "args" });
    const action = try j.field(request, "action");
    const values = try j.array(try j.get(request, "args"), 4);
    const arguments = try a.alloc([]const u8, values.len);
    for (values, arguments) |value, *argument| argument.* = try j.text(value);
    const root = try std.Io.Dir.openDirAbsolute(init.io, "/", .{});
    defer root.close(init.io);
    const operation_lock = try runtime.lock(init.io, root);
    defer operation_lock.close(init.io);
    var system: runtime.Runtime = .{ .a = a, .io = init.io };
    const ctx = try system.context(root, protocol.stationAction(action));
    const output = try protocol.dispatch(ctx, action, arguments);
    // Defense in depth around the closed public output protocol.
    try j.require(output.len <= 393216 and std.mem.indexOf(u8, output, "PRIVATE KEY") == null);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
    return 0;
}
