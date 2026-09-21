//! Bounded cgroup v2 observations, resolved from systemd on every poll. The
//! normalized contract avoids persisting cgroup paths or retaining an old path
//! after a unit moves. Vector transports these absolute metric events unchanged.
const std = @import("std");
const targets = @import("../monitoring/agents/targets.zig");
pub const Identity = struct { application: []const u8, environment: []const u8, host: []const u8, service: []const u8 };
pub const Sample = struct { name: []const u8, value: f64, counter: bool = false };
pub const Snapshot = struct {
    values: std.ArrayList(Sample) = .empty,
    fn add(self: *Snapshot, a: std.mem.Allocator, name: []const u8, value: u64, divisor: f64, counter: bool) !void {
        try self.values.append(a, .{ .name = name, .value = @as(f64, @floatFromInt(value)) / divisor, .counter = counter });
    }
};
fn number(value: []const u8) !u64 {
    const text = std.mem.trim(u8, value, "\r\n \t");
    if (text.len == 0) return error.InvalidCgroupValue;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidCgroupValue;
    return std.fmt.parseInt(u64, text, 10);
}
fn read(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?[]const u8 {
    const file = dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) return null else return err;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer); // cgroupfs files advertise size zero.
    return try reader.interface.allocRemaining(a, .limited(65536));
}
pub fn controlGroup(properties: []const u8, unit: []const u8) !?[]const u8 {
    var id: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var group: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, properties, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Id=")) {
            if (id != null) return error.InvalidUnit;
            id = line[3..];
        }
        if (std.mem.startsWith(u8, line, "ActiveState=")) {
            if (state != null) return error.InvalidUnit;
            state = line[12..];
        }
        if (std.mem.startsWith(u8, line, "ControlGroup=")) {
            if (group != null) return error.InvalidUnit;
            group = line[13..];
        }
    }
    if (!std.mem.eql(u8, id orelse return error.InvalidUnit, unit)) return error.InvalidUnit;
    if (!std.mem.eql(u8, state orelse return error.InvalidUnit, "active")) return null;
    const path = group orelse return error.InvalidUnit;
    if (path.len == 0) return null;
    if (path.len > 4096 or path[0] != '/' or path.len == 1) return error.InvalidCgroupPath;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidCgroupPath;
        for (part) |c| if (c < 32 or c == 127) return error.InvalidCgroupPath;
    }
    return path[1..];
}
pub fn collect(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, properties: []const u8, unit: []const u8) !Snapshot {
    var result: Snapshot = .{};
    const path = try controlGroup(properties, unit);
    if (path == null) {
        try result.add(a, "cgroup_available", 0, 1, false);
        return result;
    }
    const controllers = try read(a, io, root, "cgroup.controllers");
    if (controllers == null) return error.CgroupV2Required;
    // Walk without following links, including intermediate components.
    var current = try root.openDir(io, ".", .{ .follow_symlinks = false });
    defer current.close(io);
    var parts = std.mem.splitScalar(u8, path.?, '/');
    while (parts.next()) |part| {
        const next = current.openDir(io, part, .{ .follow_symlinks = false }) catch |err| if (err == error.FileNotFound) {
            try result.add(a, "cgroup_available", 0, 1, false);
            return result;
        } else return err;
        current.close(io);
        current = next;
    }
    const cpu = try read(a, io, current, "cpu.stat") orelse return error.CgroupCpuUnavailable;
    var lines = std.mem.splitScalar(u8, cpu, '\n');
    var usage = false;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key = fields.next() orelse continue;
        const value = try number(fields.next() orelse return error.InvalidCgroupValue);
        if (fields.next() != null) return error.InvalidCgroupValue;
        inline for (.{ .{ "usage_usec", "cpu_seconds_total" }, .{ "user_usec", "cpu_user_seconds_total" }, .{ "system_usec", "cpu_system_seconds_total" }, .{ "throttled_usec", "cpu_throttled_seconds_total" }, .{ "nr_throttled", "cpu_throttled_periods_total" } }) |mapping| {
            if (std.mem.eql(u8, key, mapping[0])) {
                try result.add(a, mapping[1], value, if (std.mem.eql(u8, key, "nr_throttled")) 1 else 1000000, true);
                if (std.mem.eql(u8, key, "usage_usec")) usage = true;
            }
        }
    }
    if (!usage) return error.CgroupCpuUnavailable;
    inline for (.{ .{ "memory.current", "memory_current_bytes" }, .{ "memory.peak", "memory_peak_bytes" }, .{ "memory.max", "memory_limit_bytes" }, .{ "pids.current", "tasks_current" }, .{ "pids.max", "tasks_limit" } }) |mapping| {
        if (try read(a, io, current, mapping[0])) |text| {
            if (!std.mem.eql(u8, std.mem.trim(u8, text, "\n \r"), "max")) try result.add(a, mapping[1], try number(text), 1, false);
        } else if (std.mem.eql(u8, mapping[0], "memory.current")) return error.CgroupMemoryUnavailable;
    }
    if (try read(a, io, current, "memory.events")) |text| {
        var events = std.mem.tokenizeAny(u8, text, "\r\n \t");
        while (events.next()) |key| {
            const value = try number(events.next() orelse return error.InvalidCgroupValue);
            if (std.mem.eql(u8, key, "oom")) try result.add(a, "oom_total", value, 1, true);
            if (std.mem.eql(u8, key, "oom_kill")) try result.add(a, "oom_kill_total", value, 1, true);
        }
    }
    if (try read(a, io, current, "io.stat")) |text| {
        var reads: u64 = 0;
        var writes: u64 = 0;
        var devices = std.mem.splitScalar(u8, text, '\n');
        while (devices.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next() orelse continue;
            while (fields.next()) |field| {
                if (std.mem.startsWith(u8, field, "rbytes=")) {
                    reads = try std.math.add(u64, reads, try number(field[7..]));
                }
                if (std.mem.startsWith(u8, field, "wbytes=")) {
                    writes = try std.math.add(u64, writes, try number(field[7..]));
                }
            }
        }
        // An existing empty io.stat means no device I/O yet. A missing file
        // means unsupported, and remains absent rather than synthesized.
        try result.add(a, "io_read_bytes_total", reads, 1, true);
        try result.add(a, "io_write_bytes_total", writes, 1, true);
    }
    try result.add(a, "cgroup_available", 1, 1, false);
    try result.add(a, "tasks_supported", @intFromBool(try read(a, io, current, "pids.current") != null), 1, false);
    return result;
}
pub fn render(a: std.mem.Allocator, snapshot: Snapshot, identity: Identity) ![]const u8 {
    for ([_][]const u8{ identity.application, identity.environment, identity.service }) |name| try targets.validateName(name);
    if (identity.host.len != 35 or !std.mem.startsWith(u8, identity.host, "dt-")) return error.InvalidHost;
    for (identity.host[3..]) |c| if (!std.ascii.isHex(c)) return error.InvalidHost;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (snapshot.values.items) |sample| {
        const name = try std.fmt.allocPrint(a, "dragontools_service_{s}", .{sample.name});
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(name, .{}, &out.writer);
        try out.writer.writeAll(",\"kind\":\"absolute\",\"tags\":");
        try std.json.Stringify.value(identity, .{}, &out.writer);
        // Vector 0.58.0 all_metrics uses as_float(), not integer coercion. Keep
        // an exponent even for whole-valued counters/gauges (including zero).
        try out.writer.print(",\"{s}\":{{\"value\":{e}}}}}\n", .{ if (sample.counter) "counter" else "gauge", sample.value });
    }
    return out.toOwnedSlice();
}
pub fn run(a: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len != 5) return error.InvalidServiceMetricArguments;
    const identity: Identity = .{ .application = args[0], .environment = args[1], .host = args[2], .service = args[3] };
    try targets.validateService(args[4]);
    _ = try render(a, .{}, identity);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    const response = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/systemctl", "show", args[4], "--property=Id,ActiveState,ControlGroup" }, .environ_map = &env, .stdout_limit = .limited(8192), .stderr_limit = .limited(1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } } });
    if (response.term != .exited or response.term.exited != 0) return error.ServiceObservationUnavailable;
    const root = try std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup", .{ .follow_symlinks = false });
    defer root.close(io);
    const snapshot = try collect(a, io, root, response.stdout, args[4]);
    try std.Io.File.stdout().writeStreamingAll(io, try render(a, snapshot, identity));
}

fn sampleValue(snapshot: Snapshot, name: []const u8) ?f64 {
    for (snapshot.values.items) |value| if (std.mem.eql(u8, value.name, name)) return value.value;
    return null;
}
test "cgroup v2 finite unlimited optional files multi-device IO and dynamic ControlGroup" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try temp.dir.writeFile(io, .{ .sub_path = "cgroup.controllers", .data = "cpu memory pids io\n" });
    try temp.dir.createDirPath(io, "slice/one.service");
    const dir = try temp.dir.openDir(io, "slice/one.service", .{});
    defer dir.close(io);
    const files = .{
        .{ "cpu.stat", "usage_usec 1500000\nuser_usec 1000000\nsystem_usec 500000\nnr_throttled 3\nthrottled_usec 20000\n" },
        .{ "memory.current", "123456\n" },
        .{ "memory.peak", "234567\n" },
        .{ "memory.max", "1048576\n" },
        .{ "memory.events", "low 0\nhigh 0\nmax 2\noom 4\noom_kill 1\n" },
        .{ "pids.current", "14\n" },
        .{ "pids.max", "256\n" },
        .{ "io.stat", "8:0 rbytes=100 wbytes=200 rios=1 wios=2\n8:1 rbytes=300 wbytes=400 rios=3 wios=4\n" },
    };
    inline for (files) |file| try dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    const properties = "Id=one.service\nActiveState=active\nControlGroup=/slice/one.service\n";
    const first = try collect(a, io, temp.dir, properties, "one.service");
    try std.testing.expectEqual(@as(?f64, 1.5), sampleValue(first, "cpu_seconds_total"));
    try std.testing.expectEqual(@as(?f64, 0.02), sampleValue(first, "cpu_throttled_seconds_total"));
    try std.testing.expectEqual(@as(?f64, 1048576), sampleValue(first, "memory_limit_bytes"));
    try std.testing.expectEqual(@as(?f64, 14), sampleValue(first, "tasks_current"));
    try std.testing.expectEqual(@as(?f64, 400), sampleValue(first, "io_read_bytes_total"));
    try std.testing.expectEqual(@as(?f64, 600), sampleValue(first, "io_write_bytes_total"));
    try std.testing.expectEqual(@as(?f64, 4), sampleValue(first, "oom_total"));
    try std.testing.expectEqual(@as(?f64, 1), sampleValue(first, "oom_kill_total"));
    try dir.writeFile(io, .{ .sub_path = "io.stat", .data = "" });
    const quiet_io = try collect(a, io, temp.dir, properties, "one.service");
    try std.testing.expectEqual(@as(?f64, 0), sampleValue(quiet_io, "io_read_bytes_total"));
    const serialized = try render(a, quiet_io, .{ .application = "sample", .environment = "test", .host = "dt-0123456789abcdef0123456789abcdef", .service = "one" });
    var json_lines = std.mem.tokenizeScalar(u8, serialized, '\n');
    while (json_lines.next()) |line| {
        const event = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        const value = event.value.object.get("counter") orelse event.value.object.get("gauge").?;
        // JSON decoder must see Float, including integer-valued and zero metrics.
        try std.testing.expect(value.object.get("value").? == .float);
    }
    try dir.writeFile(io, .{ .sub_path = "memory.max", .data = "max\n" });
    try dir.writeFile(io, .{ .sub_path = "pids.max", .data = "max\n" });
    for ([_][]const u8{ "memory.peak", "memory.events", "io.stat", "pids.current" }) |name| try dir.deleteFile(io, name);
    const unlimited = try collect(a, io, temp.dir, properties, "one.service");
    for ([_][]const u8{ "memory_limit_bytes", "tasks_limit", "memory_peak_bytes", "oom_total", "io_read_bytes_total", "tasks_current" }) |name| try std.testing.expectEqual(@as(?f64, null), sampleValue(unlimited, name));
    try std.testing.expectEqual(@as(?f64, 0), sampleValue(unlimited, "tasks_supported"));
    try temp.dir.createDirPath(io, "new.slice/one.service");
    try temp.dir.writeFile(io, .{ .sub_path = "new.slice/one.service/cpu.stat", .data = "usage_usec 100000\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "new.slice/one.service/memory.current", .data = "100\n" });
    const restarted = try collect(a, io, temp.dir, "Id=one.service\nActiveState=active\nControlGroup=/new.slice/one.service\n", "one.service");
    try std.testing.expectEqual(@as(?f64, 0.1), sampleValue(restarted, "cpu_seconds_total"));
    try std.testing.expectEqual(@as(?f64, 100), sampleValue(restarted, "memory_current_bytes"));
}
test "inactive missing and unsafe cgroups never invent resource zeros or unbounded labels" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "Id=one.service\nActiveState=inactive\nControlGroup=\n", "Id=one.service\nActiveState=active\nControlGroup=\n" }) |properties| {
        const state = try collect(a, std.testing.io, temp.dir, properties, "one.service");
        try std.testing.expectEqual(@as(usize, 1), state.values.items.len);
        try std.testing.expectEqual(@as(?f64, 0), sampleValue(state, "cgroup_available"));
    }
    try std.testing.expectError(error.InvalidCgroupPath, controlGroup("Id=one.service\nActiveState=active\nControlGroup=/../private\n", "one.service"));
    try std.testing.expectError(error.InvalidUnit, controlGroup("Id=alias.service\nActiveState=active\nControlGroup=/slice/one.service\n", "one.service"));
    const identity: Identity = .{ .application = "orders", .environment = "production", .host = "dt-0123456789abcdef0123456789abcdef", .service = "api" };
    var state: Snapshot = .{};
    try state.add(a, "cpu_seconds_total", 500000, 1000000, true);
    const output = try render(a, state, identity);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("tags").?.object.count());
    try std.testing.expectEqualStrings("absolute", parsed.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(f64, 0.5), parsed.value.object.get("counter").?.object.get("value").?.float);
    var invalid = identity;
    invalid.service = "user/request";
    try std.testing.expectError(error.InvalidMetricsTargetName, render(a, state, invalid));
}
