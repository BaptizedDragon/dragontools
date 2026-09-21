const std = @import("std");

test "Blackbox read-only integration observer fixtures validate stored failure and alert hold" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/blackbox_observe_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
const blackbox = @import("blackbox.zig");
const bb = @import("../components/blackbox_exporter.zig");

pub const loaded_config =
    \\modules:
    \\    http_2xx:
    \\        prober: http
    \\        timeout: 5s
    \\        http:
    \\            preferred_ip_protocol: ip4
    \\            ip_protocol_fallback: true
    \\            method: GET
    \\            follow_redirects: true
    \\            enable_http2: false
    \\        tcp:
    \\            ip_protocol_fallback: true
    \\        icmp:
    \\            ip_protocol_fallback: true
    \\            ttl: 64
    \\        dns:
    \\            ip_protocol_fallback: true
    \\            recursion_desired: true
    \\
;
pub const exporter_metrics =
    \\# TYPE blackbox_exporter_build_info gauge
    \\blackbox_exporter_build_info{branch="HEAD",goarch="amd64",goos="linux",goversion="go1.25.4",revision="5a059be",tags="unknown",version="0.28.0"} 1
    \\blackbox_exporter_config_last_reload_successful 1
    \\
;

test "Blackbox verifies the loaded HTTP module and rejects unsafe or foreign loaded configuration" {
    const a = std.testing.allocator;
    try blackbox.validateLoadedConfig(a, loaded_config);
    // The zero TLS struct may be omitted by upstream's YAML marshaler.
    try blackbox.validateLoadedConfig(a, bb.config["# Managed by DragonTools\n".len..]);
    const Replacement = struct { before: []const u8, after: []const u8 };
    for ([_]Replacement{
        .{ .before = "prober: http", .after = "prober: icmp" },
        .{ .before = "timeout: 5s", .after = "timeout: 30s" },
        .{ .before = "method: GET", .after = "method: POST" },
        .{ .before = "enable_http2: false", .after = "enable_http2: true" },
        .{ .before = "follow_redirects: true", .after = "follow_redirects: false" },
        .{ .before = "preferred_ip_protocol: ip4", .after = "preferred_ip_protocol: ip6" },
        .{ .before = "http_2xx:", .after = "foreign:" },
        .{ .before = "method: GET", .after = "method: GET\n            method: GET" },
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, a, loaded_config, change.before, change.after);
        defer a.free(changed);
        try std.testing.expectError(error.InvalidBlackboxConfig, blackbox.validateLoadedConfig(a, changed));
    }
    const insecure = try std.mem.replaceOwned(u8, a, bb.config["# Managed by DragonTools\n".len..], "insecure_skip_verify: false", "insecure_skip_verify: true");
    defer a.free(insecure);
    try std.testing.expectError(error.InvalidBlackboxConfig, blackbox.validateLoadedConfig(a, insecure));
    for ([_][]const u8{ "", "Healthy", "<html>ok</html>", loaded_config ++ "foreign: {}\n" }) |bad| try std.testing.expectError(error.InvalidBlackboxConfig, blackbox.validateLoadedConfig(a, bad));
}

test "Blackbox self-observation distinguishes exporter readiness from target availability" {
    const a = std.testing.allocator;
    try blackbox.validateMetrics(a, exporter_metrics);
    try blackbox.validateMetrics(a, exporter_metrics ++ "probe_success 0\n");
    try std.testing.expectError(error.NotReady, blackbox.validateMetrics(a, "# still starting\n"));
    try std.testing.expectError(error.NotReady, blackbox.validateMetrics(a, "go_goroutines 5\n"));
    const stale = try std.mem.replaceOwned(u8, a, exporter_metrics, "version=\"0.28.0\"", "version=\"0.27.0\"");
    defer a.free(stale);
    try std.testing.expectError(error.InvalidBlackboxMetrics, blackbox.validateMetrics(a, stale));
    const bad_reload = try std.mem.replaceOwned(u8, a, exporter_metrics, "reload_successful 1", "reload_successful 0");
    defer a.free(bad_reload);
    try std.testing.expectError(error.InvalidBlackboxMetrics, blackbox.validateMetrics(a, bad_reload));
    try std.testing.expectError(error.InvalidBlackboxMetrics, blackbox.validateMetrics(a, "<html>healthy</html>"));
    try std.testing.expectError(error.InvalidBlackboxMetrics, blackbox.validateMetrics(a, exporter_metrics ++ exporter_metrics));
}

const Fake = struct {
    resources: [5]bool = .{ false, false, false, false, false },
    pending: bool = false,
    active: bool = false,
    downloads: usize = 0,
    restarts: usize = 0,
    finalizations: usize = 0,
    health_calls: usize = 0,
    http_calls: usize = 0,
    transient_http: usize = 0,
    permanent_http: bool = false,
    deterministic_failure: bool = false,
    now: i64 = 0,
    sleeps: usize = 0,
    captured: [5][]const u8 = undefined,
    capture_a: ?std.mem.Allocator = null,
    capture_count: usize = 0,

    fn remoteInterface(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
    }
    fn nowMs(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn sleepMs(ctx: *anyopaque, delay: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.sleeps == 0) try std.testing.expectEqual(@as(u32, 500), delay) else try std.testing.expect(delay > 0 and delay <= 1000);
        self.sleeps += 1;
        self.now += delay;
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const resource: ?usize = switch (op) {
            .user => 0,
            .directories => 1,
            .binary => 2,
            .config => 3,
            .unit => 4,
            else => null,
        };
        if (resource) |i| {
            if (self.resources[i]) return .{ .code = 0, .output = "unchanged" };
            self.resources[i] = true;
            if (i >= 2) self.pending = true;
            if (op == .binary) self.downloads += 1;
            return .{ .code = 0, .output = "changed" };
        }
        switch (op) {
            .activate => {
                if (!self.pending and self.active) return .{ .code = 0, .output = "unchanged" };
                self.active = true;
                self.restarts += 1;
                return .{ .code = 0, .output = "changed" };
            },
            .health => {
                self.health_calls += 1;
                if (self.capture_a) |a| {
                    if (self.capture_count >= self.captured.len) return error.UnexpectedRetry;
                    self.captured[self.capture_count] = try a.dupe(u8, command);
                    self.capture_count += 1;
                }
                if (std.mem.indexOf(u8, command, "dragontools-blackbox-exporter-managed_state") != null) return .{ .code = if (self.deterministic_failure) 1 else 0 };
                if (!self.active) return .{ .code = 75 };
                if (std.mem.indexOf(u8, command, "dragontools-blackbox-exporter-http_ready") != null) {
                    self.http_calls += 1;
                    if (self.permanent_http or self.http_calls <= self.transient_http) return .{ .code = 75 };
                    return .{ .code = 0, .output = "Healthy" };
                }
                if (std.mem.indexOf(u8, command, "dragontools-blackbox-exporter-provisioning_ready") != null) return .{ .code = 0, .output = loaded_config };
                if (std.mem.indexOf(u8, command, "dragontools-blackbox-exporter-storage_ready") != null) return .{ .code = 0, .output = exporter_metrics };
                return .{ .code = 0 };
            },
            .finalize => {
                self.pending = false;
                self.finalizations += 1;
                return .{ .code = 0 };
            },
            else => return error.UnexpectedOperation,
        }
    }
};

test "Blackbox first install and configuration repair converge then rerun without download or restart" {
    var fake: Fake = .{};
    var first: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &first, .amd64);
    try std.testing.expect(first.changes > 0);
    try std.testing.expect(!fake.pending);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    var again: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &again, .amd64);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    fake.resources[3] = false;
    var repaired: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &repaired, .amd64);
    try std.testing.expectEqual(@as(usize, 2), fake.restarts);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    var last: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &last, .amd64);
    try std.testing.expectEqual(@as(usize, 0), last.changes);
    try std.testing.expectEqual(@as(usize, 2), fake.restarts);
}

test "Blackbox delayed readiness finalizes and unchanged retry stays a no-op" {
    var fake: Fake = .{ .transient_http = 2 };
    var first: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &first, .arm64);
    try std.testing.expectEqual(@as(usize, 3), fake.http_calls);
    try std.testing.expectEqual(@as(usize, 2), fake.sleeps);
    try std.testing.expectEqual(@as(i64, 1500), fake.now);
    try std.testing.expect(!fake.pending);
    var again: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &again, .arm64);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
}

test "Blackbox timeout keeps restart intent through read-only verify until installation recovers" {
    var fake: Fake = .{ .permanent_http = true };
    var first: workflow.Report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, blackbox.install(std.testing.allocator, fake.remoteInterface(), &first, .amd64));
    try std.testing.expect(fake.pending);
    try std.testing.expectEqual(@as(usize, 0), fake.finalizations);
    fake.permanent_http = false;
    var verified: workflow.Report = .{};
    try blackbox.health(std.testing.allocator, fake.remoteInterface(), &verified, .amd64);
    try std.testing.expect(fake.pending);
    try std.testing.expectEqual(@as(usize, 0), verified.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    var recovered: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &recovered, .amd64);
    try std.testing.expect(!fake.pending);
    try std.testing.expectEqual(@as(usize, 2), fake.restarts);
    var again: workflow.Report = .{};
    try blackbox.install(std.testing.allocator, fake.remoteInterface(), &again, .amd64);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 2), fake.restarts);
}

test "Blackbox deterministic mismatch stops before polling and preserves pending intent" {
    var fake: Fake = .{ .active = true, .pending = true, .deterministic_failure = true };
    var report: workflow.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, blackbox.health(std.testing.allocator, fake.remoteInterface(), &report, .amd64));
    try std.testing.expectEqual(@as(usize, 1), fake.health_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.sleeps);
    try std.testing.expect(fake.pending);
}

test "Blackbox verification scripts are guarded read-only and never directly probe a target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .active = true, .capture_a = a };
    var report: workflow.Report = .{};
    try blackbox.health(a, fake.remoteInterface(), &report, .arm64);
    try std.testing.expectEqual(@as(usize, 5), fake.capture_count);
    for (fake.captured, 0..) |command, i| {
        for ([_][]const u8{ "systemctl restart", "systemctl start", "systemctl daemon-reload", "rm -f ", "chmod ", "chown ", "sleep ", "/probe?", "https://" }) |mutation| try std.testing.expect(std.mem.indexOf(u8, command, mutation) == null);
        if (i > 0) for ([_][]const u8{ "test \"$actual_args\" = \"$expected_args\"", "dt-blackbox:dt-blackbox", "/proc/$pid/exe", "all_listeners=$(ss -H -ltnp)", "pid=$pid," }) |guard| try std.testing.expect(std.mem.indexOf(u8, command, guard) != null);
        const script = try std.fmt.allocPrint(a, "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command});
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
}

test "Blackbox actual runtime guard distinguishes startup absence from invariant failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\set -eu
        \\scenario=$1; shift
        \\root=$(mktemp -d "${TMPDIR:-/tmp}/dragontools-storage-probe.XXXXXX")
        \\trap 'rm -rf "$root"' EXIT HUP INT TERM
        \\mkdir -p "$root/proc/123"
        \\printf '%s\000' /opt/dragontools/components/blackbox-exporter/current/blackbox_exporter --config.file=/etc/dragontools/blackbox-exporter/blackbox.yml --web.listen-address=127.0.0.1:9115 --history.limit=0 --log.prober=error > "$root/proc/123/cmdline"
        \\if test "$scenario" = args; then printf unexpected > "$root/proc/123/cmdline"; fi
        \\ss() {
        \\  test "$scenario" != missing_listener || return 0
        \\  if test "$scenario" = public; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9115 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  else
        \\    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:9115 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  fi
        \\  if test "$#" -eq 2 && test "$scenario" = extra; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9999 0.0.0.0:* users:("fixture",pid=123,fd=4)'
        \\  fi
        \\}
        \\systemctl() {
        \\  if test "$1" = is-active; then test "$scenario" != inactive; return; fi
        \\  if test "$scenario" = missing_pid; then printf 0; else printf 123; fi
        \\}
        \\stat() { if test "$scenario" = owner; then printf root:root; else printf dt-blackbox:dt-blackbox; fi; }
        \\sha256sum() { cat >/dev/null; test "$scenario" != checksum; }
    ;
    const guard = try std.mem.replaceOwned(u8, a, blackbox.runtime_guard, "/proc/", "$root/proc/");
    const script = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\nprintf ready", .{ fixture, guard, blackbox.listener_ready });
    const Case = struct { scenario: []const u8, code: u8 };
    for ([_]Case{
        .{ .scenario = "ready", .code = 0 },
        .{ .scenario = "missing_pid", .code = 75 },
        .{ .scenario = "missing_listener", .code = 75 },
        .{ .scenario = "inactive", .code = 75 },
        .{ .scenario = "public", .code = 1 },
        .{ .scenario = "extra", .code = 1 },
        .{ .scenario = "owner", .code = 1 },
        .{ .scenario = "args", .code = 1 },
        .{ .scenario = "checksum", .code = 1 },
    }) |case| {
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", case.scenario, "expected-hash" } });
        try std.testing.expectEqual(case.code, result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(if (case.code == 0) "ready" else "", result.stdout);
    }
}
