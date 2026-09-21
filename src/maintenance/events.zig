//! Small host transition observer. No package commands, networking or reboot.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/file.h");
    @cInclude("unistd.h");
});
const Metadata = extern struct { uid: u64, gid: u64, mode: u64, nlink: u64 };
extern "c" fn dragontools_file_metadata(c_int, *Metadata) c_int;
pub const directory = "/var/lib/dragontools/host-events";
pub const State = struct { version: u8 = 1, required: bool, sequence: u64 = 0 };
pub const Observation = struct { host: []const u8 = "dt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", required: bool, packages: []const u8 = "", kernel: []const u8, uptime: u64 };
pub const HostEvent = struct {
    host: []const u8,
    level: []const u8,
    event: []const u8,
    event_id: []const u8,
    kernel: []const u8,
    uptime_seconds: u64,
    uptime_human: []const u8,
    packages: []const []const u8,
    packages_count: usize,
    packages_text: []const u8,
};
fn require(ok: bool) !void {
    if (!ok) return error.HostEventStateRefused;
}
pub fn duration(a: std.mem.Allocator, seconds: u64) ![]const u8 {
    if (seconds < 60) return std.fmt.allocPrint(a, "{d}s", .{seconds});
    if (seconds < 3600) return std.fmt.allocPrint(a, "{d}m", .{seconds / 60});
    if (seconds < 86400) return std.fmt.allocPrint(a, "{d}h {d}m", .{ seconds / 3600, seconds % 3600 / 60 });
    return std.fmt.allocPrint(a, "{d}d {d}h", .{ seconds / 86400, seconds % 86400 / 3600 });
}
fn package(value: []const u8) bool {
    if (value.len < 2 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |ch| if (!(ch >= 'a' and ch <= 'z') and !std.ascii.isDigit(ch) and std.mem.indexOfScalar(u8, "+.-:", ch) == null) return false;
    return true;
}
pub fn transition(a: std.mem.Allocator, previous: ?State, observation: Observation) !struct { state: State, event: ?HostEvent } {
    var next = previous orelse State{ .required = false };
    try require(next.version == 1);
    if (next.required == observation.required) return .{ .state = next, .event = null };
    next.required = observation.required;
    next.sequence = std.math.add(u64, next.sequence, 1) catch return error.HostEventStateRefused;
    try require(observation.kernel.len > 0 and observation.kernel.len <= 128);
    for (observation.kernel) |ch| try require(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, ".-_+", ch) != null);
    try require(observation.packages.len <= 1048576);
    var unique: std.StringHashMap(void) = .init(a);
    defer unique.deinit();
    var selected: std.ArrayList([]const u8) = .empty;
    var text: std.Io.Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, observation.packages, '\n');
    if (observation.required) while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (!package(name) or unique.contains(name)) continue;
        try unique.put(name, {});
        if (selected.items.len < 20) {
            try selected.append(a, name);
            try text.writer.print("• {s}\n", .{name});
        }
    };
    if (unique.count() > selected.items.len) try text.writer.print("+ {d} more\n", .{unique.count() - selected.items.len});
    return .{ .state = next, .event = .{
        .host = observation.host,
        .level = if (next.required) "warning" else "info",
        .event = if (next.required) "host_reboot_required" else "host_reboot_requirement_cleared",
        .event_id = try std.fmt.allocPrint(a, "{x:0>16}", .{next.sequence}),
        .kernel = observation.kernel,
        .uptime_seconds = observation.uptime,
        .uptime_human = try duration(a, observation.uptime),
        .packages = try selected.toOwnedSlice(a),
        .packages_count = unique.count(),
        .packages_text = try text.toOwnedSlice(),
    } };
}
fn metadata(fd: c_int, mode: u32, file: bool) !void {
    var st: Metadata = undefined;
    try require(dragontools_file_metadata(fd, &st) == 0);
    try require(st.uid == std.c.getuid() and st.gid == std.c.getgid() and st.mode & 0o7777 == mode);
    try require(st.mode & std.posix.S.IFMT == (if (file) @as(u64, std.posix.S.IFREG) else @as(u64, std.posix.S.IFDIR)));
    if (file) try require(st.nlink == 1);
}
pub fn open(io: std.Io, root: std.Io.Dir) !std.Io.Dir {
    var parent = try root.openDir(io, ".", .{ .iterate = true });
    errdefer parent.close(io);
    for ([_][]const u8{ "var", "lib", "dragontools", "host-events" }) |part| {
        const child = try parent.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        parent.close(io);
        parent = child;
        var st: Metadata = undefined;
        try require(dragontools_file_metadata(parent.handle, &st) == 0 and (st.uid == 0 or st.uid == std.c.getuid()) and st.mode & 0o022 == 0);
    }
    try metadata(parent.handle, 0o700, false);
    return parent;
}
fn read(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, limit: usize, managed: bool) !?[]const u8 {
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return null else return err;
    try require(st.kind == .file);
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    if (managed) try metadata(file.handle, 0o600, true);
    // /proc files have zero stat size: bound the actual stream read instead.
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return try reader.interface.allocRemaining(a, .limited(limit));
}
pub fn load(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?State {
    // Inspect recoverable staging even during read-only verification/no-op checks.
    _ = try read(a, io, dir, "reboot-required.next", 256, true);
    const value = try read(a, io, dir, "reboot-required.state", 256, true) orelse return null;
    const parsed = try std.json.parseFromSlice(State, a, value, .{});
    defer parsed.deinit();
    try require(parsed.value.version == 1);
    return parsed.value;
}
fn publish(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, state: State) !void {
    // A fixed private staging file is recoverable only after proving metadata.
    if (try read(a, io, dir, "reboot-required.next", 256, true) != null) try dir.deleteFile(io, "reboot-required.next");
    const file = try dir.createFile(io, "reboot-required.next", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    defer dir.deleteFile(io, "reboot-required.next") catch {};
    try file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, state, .{}));
    try file.sync(io);
    try dir.rename("reboot-required.next", dir, "reboot-required.state", io);
    try (std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } }).sync(io);
}
pub fn observe(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !Observation {
    const runtime_dir = try root.openDir(io, "run", .{ .follow_symlinks = false });
    defer runtime_dir.close(io);
    const marker = try read(a, io, runtime_dir, "reboot-required", 4096, false);
    const packages = if (marker != null) try read(a, io, runtime_dir, "reboot-required.pkgs", 1048576, false) orelse "" else "";
    const kernel = try root.readFileAlloc(io, "proc/sys/kernel/osrelease", a, .limited(256));
    const uptime = try root.readFileAlloc(io, "proc/uptime", a, .limited(256));
    var parts = std.mem.tokenizeAny(u8, uptime, ". \n");
    return .{ .host = try @import("../monitoring/agents/model.zig").hostId(a, try root.readFileAlloc(io, "etc/machine-id", a, .limited(128))), .required = marker != null, .packages = packages, .kernel = std.mem.trim(u8, kernel, "\r\n"), .uptime = try std.fmt.parseInt(u64, parts.next() orelse return error.HostEventStateRefused, 10) };
}
/// Output precedes state commit: an interrupted commit can replay the same stable
/// event_id. Alertmanager deduplicates it; unchanged successful checks emit nothing.
pub fn check(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, observation: Observation, output: *std.Io.Writer) !void {
    try metadata(dir.handle, 0o700, false);
    try require(c.flock(dir.handle, c.LOCK_EX | c.LOCK_NB) == 0);
    defer _ = c.flock(dir.handle, c.LOCK_UN);
    const previous = try load(a, io, dir);
    const result = try transition(a, previous, observation);
    if (result.event) |event| {
        try std.json.Stringify.value(event, .{}, output);
        try output.writeByte('\n');
        try output.flush();
    }
    if (previous == null or result.event != null) try publish(a, io, dir, result.state);
}
pub fn run(a: std.mem.Allocator, io: std.Io, verify: bool) !void {
    const root = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    defer root.close(io);
    const dir = try open(io, root);
    defer dir.close(io);
    if (verify) {
        try require(try load(a, io, dir) != null);
        return;
    }
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try check(a, io, dir, try observe(a, io, root), &writer.interface);
}

test "host events transitions and persistent no-op with bounded package details" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var output: std.Io.Writer.Allocating = .init(a);
    var observation: Observation = .{ .required = false, .kernel = "7.0.0-test", .uptime = 123456 };
    try check(a, io, tmp.dir, observation, &output.writer);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    const initial = try tmp.dir.statFile(io, "reboot-required.state", .{});
    try check(a, io, tmp.dir, observation, &output.writer);
    try std.testing.expectEqual(initial.mtime, (try tmp.dir.statFile(io, "reboot-required.state", .{})).mtime);
    observation.required = true;
    observation.packages = " libc6\n\nlibc6\nlinux-image-7.0\nnot a package\n";
    try check(a, io, tmp.dir, observation, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"packages_count\":2") != null);
    const emitted = output.written().len;
    try check(a, io, tmp.dir, observation, &output.writer);
    try std.testing.expectEqual(emitted, output.written().len);
    observation.required = false;
    try check(a, io, tmp.dir, observation, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "host_reboot_requirement_cleared") != null);
    try std.testing.expectEqual(@as(u64, 2), (try load(a, io, tmp.dir)).?.sequence);
    const first = try transition(a, null, .{ .required = true, .kernel = "kernel", .uptime = 45 });
    try std.testing.expectEqual(@as(usize, 0), first.event.?.packages_count);
    var packages: std.Io.Writer.Allocating = .init(a);
    for (0..27) |i| try packages.writer.print("package-{d}\n", .{i});
    const many = (try transition(a, null, .{ .required = true, .packages = packages.written(), .kernel = "kernel", .uptime = 120 })).event.?;
    try std.testing.expectEqual(@as(usize, 27), many.packages_count);
    try std.testing.expectEqual(@as(usize, 20), many.packages.len);
    try std.testing.expect(std.mem.endsWith(u8, many.packages_text, "+ 7 more\n"));
    for ([_]u64{ 45, 120, 4320, 273600 }, [_][]const u8{ "45s", "2m", "1h 12m", "3d 4h" }) |seconds, expected| try std.testing.expectEqualStrings(expected, try duration(a, seconds));
}
