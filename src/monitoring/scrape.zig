//! Reconcile native VM scraping independently from VictoriaMetrics restart intent.
const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const vm = @import("../components/victoriametrics.zig");
const install = @import("install.zig");
const readiness = @import("readiness.zig");
const verify = @import("verify.zig");
const probes = @import("probes.zig");
const read_helper = @embedFile("scrape.py");
const mutate_helper = read_helper ++ "\n" ++ @embedFile("scrape_mutate.py") ++ "\nsys.exit(mutate_main())\n";
const reader = read_helper ++ "\nsys.exit(read_main())\n";
const launcher = "import base64,sys,zlib; source=base64.b64decode(sys.argv.pop(1),validate=True); exec(zlib.decompress(source))";

fn encoded(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try a.alloc(u8, encoder.calcSize(bytes.len)), bytes);
}

fn encodedHelper(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var compressed: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    defer compressed.deinit();
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor: std.compress.flate.Compress = try .init(&compressed.writer, &buffer, .zlib, .default);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();
    return encoded(a, compressed.written());
}

fn configDigest(a: std.mem.Allocator, config: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(config, &digest, .{});
    return std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

fn inputs(a: std.mem.Allocator, report: *install.Report) !struct { config: []const u8, targets: []const u8 } {
    const normalized = try a.alloc(probes.Probe, report.probes.len);
    for (report.probes, normalized) |probe, *target| target.* = .{ .name = probe.name, .url = try probes.normalizeUrl(a, probe.url) };
    return .{
        .config = try probes.renderScrape(a, report.probes),
        .targets = try std.json.Stringify.valueAlloc(a, normalized, .{}),
    };
}

fn mutation(a: std.mem.Allocator, report: *install.Report, arch: host.Arch, mode: []const u8) ![]const u8 {
    const values = try inputs(a, report);
    const preparing = std.mem.eql(u8, mode, "prepare");
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", launcher, try encodedHelper(a, mutate_helper), mode, if (preparing) try encoded(a, values.config) else try configDigest(a, values.config), try encoded(a, if (preparing) "[]" else values.targets), vm.artifact(arch).binary_sha256 });
}

fn readCommand(a: std.mem.Allocator, report: *install.Report, mode: []const u8) ![]const u8 {
    const values = try inputs(a, report);
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", launcher, try encodedHelper(a, reader), mode, try configDigest(a, values.config), try encoded(a, values.targets) });
}

fn guarded(a: std.mem.Allocator, report: *install.Report, arch: host.Arch, mode: []const u8, check: readiness.Check) ![]const u8 {
    return verify.command(a, arch, report, try std.mem.concat(a, u8, &.{ verify.process_script, verify.listener_ready, try readCommand(a, report, mode), "\n" }), check);
}

pub fn prepare(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    report.component = .victoriametrics;
    _ = try report.call(r, .config, try mutation(a, report, arch, "prepare"));
}

pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    report.component = .victoriametrics;
    _ = try readiness.deterministic(a, r, report, .managed_state, try readCommand(a, report, "managed"));
    try readiness.poll(a, r, report, .scrape_ready, readiness.telemetry_ms, try guarded(a, report, arch, "ready", .scrape_ready), readiness.ready);
    try readiness.poll(a, r, report, .probe_metrics_ready, readiness.telemetry_ms, try guarded(a, report, arch, "stored", .probe_metrics_ready), readiness.ready);
}

pub fn reconcile(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, arch: host.Arch) !void {
    report.component = .victoriametrics;
    _ = try report.call(r, .activate, try mutation(a, report, arch, "reconcile"));
    try health(a, r, report, arch);
    _ = try report.call(r, .finalize, try mutation(a, report, arch, "finalize"));
}

pub fn status(a: std.mem.Allocator, r: remote.Remote, report: *install.Report) ![]const u8 {
    report.component = .victoriametrics;
    const output = try report.call(r, .status, try readCommand(a, report, "status"));
    const parsed = std.json.parseFromSlice([]const []const u8, a, output, .{}) catch return error.InvalidProbeStatus;
    defer parsed.deinit();
    if (parsed.value.len != report.probes.len) return error.InvalidProbeStatus;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeAll("External probes (recorded metrics; at most 90s old):\n");
    if (report.probes.len == 0) try out.writer.writeAll("  none configured\n");
    for (report.probes, parsed.value) |probe, state| {
        if (!std.mem.eql(u8, state, "healthy") and !std.mem.eql(u8, state, "unhealthy") and !std.mem.eql(u8, state, "unknown")) return error.InvalidProbeStatus;
        try out.writer.print("  {s}  {s}\n", .{ probe.name, state });
    }
    return out.toOwnedSlice();
}

test "scrape helper fixtures distinguish down services from a broken monitoring mechanism" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/scrape_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "scrape verification retries startup and retains reload intent until finalization" {
    const Fake = struct {
        now: i64 = 0,
        pending: bool = true,
        ready_attempts: usize = 0,
        stored_attempts: usize = 0,
        timeout: bool = false,
        deterministic_failure: bool = false,
        finalized: usize = 0,
        fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return switch (op) {
                .activate => .{ .code = 0, .output = if (self.pending) "changed" else "unchanged" },
                .health => blk: {
                    if (std.mem.indexOf(u8, command, "dragontools-victoriametrics-scrape_ready") != null) {
                        self.ready_attempts += 1;
                        break :blk .{ .code = if (self.ready_attempts <= 2) 75 else 0 };
                    }
                    if (std.mem.indexOf(u8, command, "dragontools-victoriametrics-probe_metrics_ready") != null) {
                        self.stored_attempts += 1;
                        break :blk .{ .code = if (self.timeout or self.stored_attempts <= 2) 75 else 0 };
                    }
                    break :blk .{ .code = if (self.deterministic_failure) 1 else 0 };
                },
                .finalize => blk: {
                    self.pending = false;
                    self.finalized += 1;
                    break :blk .{ .code = 0 };
                },
                else => error.UnexpectedScrapeFixtureOperation,
            };
        }
        fn nowMs(ctx: *anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.now;
        }
        fn sleepMs(ctx: *anyopaque, duration: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.now += duration;
        }
        fn remoteFor(self: *@This()) remote.Remote {
            return .{ .context = self, .execute = execute, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    var report: install.Report = .{ .station_enabled = true };
    try reconcile(a, fake.remoteFor(), &report, .amd64);
    try std.testing.expectEqual(@as(usize, 3), fake.ready_attempts);
    try std.testing.expectEqual(@as(usize, 3), fake.stored_attempts);
    try std.testing.expectEqual(@as(i64, 3000), fake.now);
    try std.testing.expect(!fake.pending);
    try std.testing.expectEqual(@as(usize, 1), fake.finalized);
    report.changes = 0;
    try reconcile(a, fake.remoteFor(), &report, .amd64);
    try std.testing.expectEqual(@as(usize, 0), report.changes);

    fake = .{ .timeout = true };
    try std.testing.expectError(error.ReadinessTimedOut, reconcile(a, fake.remoteFor(), &report, .arm64));
    try std.testing.expect(fake.pending);
    try std.testing.expectEqual(@as(usize, 0), fake.finalized);
    fake = .{ .deterministic_failure = true };
    try std.testing.expectError(error.RemoteOperationFailed, health(a, fake.remoteFor(), &report, .amd64));
    try std.testing.expectEqual(@as(usize, 0), fake.ready_attempts);
    try std.testing.expectEqual(@as(i64, 0), fake.now);
    try std.testing.expect(fake.pending);
}

test "near-limit scrape configurations fit SSH argv across target distributions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ssh: @import("../system/ssh.zig").Ssh = .{ .allocator = a, .io = std.testing.io, .options = .{ .ssh_host = "monitoring" } };
    for ([_]usize{ 32, 64 }) |count| {
        var source: std.Io.Writer.Allocating = .init(a);
        try source.writer.writeAll("version=1\n");
        const entry_budget = (@import("../config/monitoring.zig").max_bytes - source.written().len) / count;
        for (0..count) |index| {
            const prefix = try std.fmt.allocPrint(a, "[[probe]]\nname=\"p{d}\"\nurl=\"https://e/", .{index});
            try source.writer.writeAll(prefix);
            const path = try a.alloc(u8, entry_budget - prefix.len - 2);
            @memset(path, '\'');
            try source.writer.writeAll(path);
            try source.writer.writeAll("\"\n");
        }
        const padding = try a.alloc(u8, @import("../config/monitoring.zig").max_bytes - source.written().len);
        @memset(padding, '#');
        try source.writer.writeAll(padding);
        try std.testing.expectEqual(@import("../config/monitoring.zig").max_bytes, source.written().len);
        var config = try @import("../config/monitoring.zig").parse(a, source.written());
        defer config.deinit();
        var report: install.Report = .{ .station_enabled = true, .probes = config.probes };
        for ([_][]const u8{
            try mutation(a, &report, .amd64, "prepare"),
            try mutation(a, &report, .amd64, "reconcile"),
            try mutation(a, &report, .amd64, "finalize"),
            try readCommand(a, &report, "managed"),
            try readCommand(a, &report, "status"),
            try guarded(a, &report, .amd64, "ready", .scrape_ready),
            try guarded(a, &report, .amd64, "stored", .probe_metrics_ready),
        }) |command| {
            const argv = try ssh.argv(command);
            try std.testing.expect(argv[argv.len - 1].len < 120 * 1024);
            const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", command } });
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        }
    }
    for ([_][]const u8{ "os.unlink", "os.chmod", "os.chown", "os.replace", "subprocess", "systemctl restart", "request(\"/-/reload\"" }) |mutation_text| try std.testing.expect(std.mem.indexOf(u8, reader, mutation_text) == null);
}

test "scrape compressed helper launcher preserves Python source and arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = "literal ' and $(not-a-command)";
    const source = "import sys; print(sys.argv[1],end='')";
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "-c", launcher, try encodedHelper(a, source), payload } });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings(payload, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
