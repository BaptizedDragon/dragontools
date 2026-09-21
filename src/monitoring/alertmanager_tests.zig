const std = @import("std");
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
const am = @import("alertmanager.zig");
const component = @import("../components/alertmanager.zig");
const Secret = @import("../secrets/secret.zig").Secret;

const Fake = struct {
    resources: [5]bool = .{ false, false, false, false, false },
    pending: bool = false,
    active: bool = false,
    telegram: bool = false,
    stored: []const u8 = "",
    downloads: usize = 0,
    restarts: usize = 0,
    finalizations: usize = 0,
    secret_calls: usize = 0,
    notifications: usize = 0,
    health_calls: usize = 0,
    http_calls: usize = 0,
    transient_http: usize = 0,
    permanent_http: bool = false,
    deterministic_failure: bool = false,
    secret_failure: bool = false,
    now: i64 = 0,
    sleeps: usize = 0,
    template: ?[]const u8 = null,
    template_writes: usize = 0,
    fn interface(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute, .execute_secret = secret, .execute_input = publicInput, .clock = .{ .context = self, .now_ms = nowMs, .sleep_ms = sleepMs } };
    }
    fn publicInput(ctx: *anyopaque, op: remote.Operation, input: remote.Input, _: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqualStrings(am.telegram_template, input.bytes);
        try std.testing.expect(std.mem.indexOf(u8, input.command, "define \"dragontools.telegram.message\"") == null);
        if (self.template) |old| if (std.mem.eql(u8, old, input.bytes)) return .{ .code = 0, .output = if (op == .config) "unchanged" else "" };
        if (op == .health) return .{ .code = 1 };
        try std.testing.expectEqual(remote.Operation.config, op);
        self.template = input.bytes;
        self.template_writes += 1;
        self.pending = true;
        return .{ .code = 0, .output = "changed" };
    }
    fn nowMs(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn sleepMs(ctx: *anyopaque, delay: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.sleeps == 0) try std.testing.expectEqual(@as(u32, 500), delay);
        try std.testing.expect(delay > 0 and delay <= 1000);
        self.sleeps += 1;
        self.now += delay;
    }
    fn secret(ctx: *anyopaque, op: remote.Operation, command: []const u8, payload: *const Secret, _: u32) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(remote.Operation.credentials, op);
        try std.testing.expect(std.mem.indexOf(u8, command, "123456:fixture-private-token") == null);
        try std.testing.expect(std.mem.indexOf(u8, command, "-1001234567890") == null);
        self.secret_calls += 1;
        if (self.secret_failure) return .{ .code = 86 };
        if (std.mem.eql(u8, self.stored, payload.protectedBytes())) return .{ .code = 0, .output = "unchanged" };
        self.stored = payload.protectedBytes();
        self.pending = true;
        self.active = false;
        return .{ .code = 0, .output = "changed" };
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (op == .config and std.mem.startsWith(u8, command, "runuser")) return .{ .code = 0 };
        const resource: ?usize = switch (op) {
            .user => 0,
            .directories => 1,
            .binary => 2,
            .config => 3,
            .unit => 4,
            else => null,
        };
        if (resource) |i| {
            if (op == .config) self.telegram = std.mem.indexOf(u8, command, "chat_id_file:") != null;
            if (self.resources[i]) return .{ .code = 0, .output = "unchanged" };
            self.resources[i] = true;
            if (i >= 2) self.pending = true;
            if (op == .binary) self.downloads += 1;
            return .{ .code = 0, .output = "changed" };
        }
        switch (op) {
            .detect => return .{ .code = 0, .output = "ubuntu\n24.04\nx86_64\n" },
            .activate => {
                if (self.active and !self.pending) return .{ .code = 0, .output = "unchanged" };
                self.active = true;
                self.restarts += 1;
                return .{ .code = 0, .output = "changed" };
            },
            .health => {
                self.health_calls += 1;
                if (std.mem.indexOf(u8, command, "dragontools-alertmanager-managed_state") != null) return .{ .code = if (self.deterministic_failure) 1 else 0 };
                if (std.mem.indexOf(u8, command, "'check' '# Managed") != null) return .{ .code = 0, .output = if (self.telegram) "enabled" else "disabled" };
                if (!self.active) return .{ .code = 75 };
                if (std.mem.indexOf(u8, command, "dragontools-alertmanager-http_ready") != null) {
                    self.http_calls += 1;
                    if (self.permanent_http or self.http_calls <= self.transient_http) return .{ .code = 75 };
                }
                return .{ .code = 0 };
            },
            .finalize => {
                self.pending = false;
                self.finalizations += 1;
                return .{ .code = 0 };
            },
            .notify_test => {
                self.notifications += 1;
                return .{ .code = 0 };
            },
            else => return error.UnexpectedOperation,
        }
    }
};

test "Alertmanager installs with discard receiver and reruns without download restart or notification" {
    var fake: Fake = .{};
    var first: workflow.Report = .{};
    try am.install(std.testing.allocator, fake.interface(), &first, .amd64);
    try std.testing.expect(first.changes > 0);
    try std.testing.expect(!fake.pending);
    var again: workflow.Report = .{};
    try am.install(std.testing.allocator, fake.interface(), &again, .amd64);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    try std.testing.expectEqual(@as(usize, 0), fake.secret_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.notifications);
}

test "Alertmanager Telegram stdin publication converges then verifies without credentials or notification" {
    const payload = try Secret.init(std.testing.allocator, "{\"token\":\"123456:fixture-private-token\",\"chat_id\":\"-1001234567890\"}");
    defer payload.deinit();
    var fake: Fake = .{};
    var first: workflow.Report = .{ .telegram_configured = true, .telegram_credentials = payload };
    try am.install(std.testing.allocator, fake.interface(), &first, .arm64);
    var again: workflow.Report = .{ .telegram_configured = true, .telegram_credentials = payload };
    try am.install(std.testing.allocator, fake.interface(), &again, .arm64);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.restarts);
    var verify: workflow.Report = .{ .telegram_configured = true };
    try am.health(std.testing.allocator, fake.interface(), &verify, .arm64);
    try std.testing.expectEqual(@as(usize, 2), fake.secret_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.notifications);
    try std.testing.expectEqual(@as(usize, 0), verify.changes);
}

test "Alertmanager delayed health succeeds and failure retains restart intent through read-only verify" {
    var fake: Fake = .{ .transient_http = 2 };
    var report: workflow.Report = .{};
    try am.install(std.testing.allocator, fake.interface(), &report, .amd64);
    try std.testing.expectEqual(@as(usize, 3), fake.http_calls);
    try std.testing.expectEqual(@as(i64, 1500), fake.now);
    try std.testing.expect(!fake.pending);
    fake.permanent_http = true;
    fake.resources[4] = false;
    var failed: workflow.Report = .{};
    try std.testing.expectError(error.ReadinessTimedOut, am.install(std.testing.allocator, fake.interface(), &failed, .amd64));
    try std.testing.expect(fake.pending);
    try std.testing.expectEqual(@as(usize, 1), fake.finalizations);
    fake.permanent_http = false;
    var verified: workflow.Report = .{};
    try am.health(std.testing.allocator, fake.interface(), &verified, .amd64);
    try std.testing.expect(fake.pending);
    var recovered: workflow.Report = .{};
    try am.install(std.testing.allocator, fake.interface(), &recovered, .amd64);
    try std.testing.expect(!fake.pending);
    var again: workflow.Report = .{};
    try am.install(std.testing.allocator, fake.interface(), &again, .amd64);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 3), fake.restarts);
}

test "Alertmanager deterministic policy failure is never retried or finalized" {
    var fake: Fake = .{ .active = true, .pending = true, .deterministic_failure = true };
    var report: workflow.Report = .{};
    try std.testing.expectError(error.RemoteOperationFailed, am.health(std.testing.allocator, fake.interface(), &report, .amd64));
    try std.testing.expectEqual(@as(usize, 1), fake.health_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.sleeps);
    try std.testing.expectEqual(@as(usize, 0), fake.finalizations);
    try std.testing.expect(fake.pending);
}

test "Alertmanager verification enforces configured Telegram mode without obtaining secrets" {
    var fake: Fake = .{ .active = true, .telegram = true };
    var disabled: workflow.Report = .{};
    try std.testing.expectError(error.TelegramConfigurationMismatch, am.health(std.testing.allocator, fake.interface(), &disabled, .amd64));
    fake.telegram = false;
    var enabled: workflow.Report = .{ .telegram_configured = true };
    try std.testing.expectError(error.TelegramConfigurationMismatch, am.health(std.testing.allocator, fake.interface(), &enabled, .amd64));
    try std.testing.expectEqual(@as(usize, 0), fake.secret_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.sleeps);
    try std.testing.expectEqual(@as(usize, 0), fake.notifications);
}

test "Alertmanager secret failure preserves intent and only explicit notify test submits an alert" {
    const payload = try Secret.init(std.testing.allocator, "opaque fixture payload");
    defer payload.deinit();
    var fake: Fake = .{ .secret_failure = true };
    var failed: workflow.Report = .{ .telegram_configured = true, .telegram_credentials = payload };
    try std.testing.expectError(error.TelegramSecretPublicationFailed, am.install(std.testing.allocator, fake.interface(), &failed, .amd64));
    try std.testing.expect(fake.pending);
    try std.testing.expectEqual(@as(usize, 0), fake.finalizations);
    fake.secret_failure = false;
    var recovered: workflow.Report = .{ .telegram_configured = true, .telegram_credentials = payload };
    try am.install(std.testing.allocator, fake.interface(), &recovered, .amd64);
    var notify: workflow.Report = .{ .telegram_configured = true };
    try am.notifyTest(std.testing.allocator, fake.interface(), &notify);
    try std.testing.expectEqual(@as(usize, 1), fake.notifications);
    try std.testing.expectEqual(@as(usize, 2), fake.secret_calls);
    var absent: workflow.Report = .{};
    try std.testing.expectError(error.TelegramConfigurationRequired, am.notifyTest(std.testing.allocator, fake.interface(), &absent));
    try std.testing.expectEqual(@as(usize, 1), fake.notifications);
}

test "Alertmanager supported Telegram file refs and hardening keep both values out of ordinary configuration" {
    for ([_][]const u8{ "group_by: [alertname, source, probe, target]", "group_wait: 30s", "group_interval: 5m", "repeat_interval: 4h" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, am.enabled_config, field) != null);
        try std.testing.expect(std.mem.indexOf(u8, am.disabled_config, field) != null);
    }
    for ([_][]const u8{ "bot_token_file:", "chat_id_file:", "send_resolved: true", "warning|critical", "parse_mode: HTML", am.template_path, "dragontools.telegram.message" }) |field| try std.testing.expect(std.mem.indexOf(u8, am.enabled_config, field) != null);
    for ([_][]const u8{ "bot_token:", "chat_id:", "123456:fixture-private-token", "-1001234567890" }) |field| try std.testing.expect(std.mem.indexOf(u8, am.enabled_config, field) == null);
    for ([_][]const u8{ "--cluster.listen-address=", "--web.listen-address=127.0.0.1:9093", "StandardOutput=null", "StandardError=null", "ProtectSystem=strict", "User=dt-alertmanager" }) |field| try std.testing.expect(std.mem.indexOf(u8, am.unit_text, field) != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]@import("../system/host.zig").Arch{ .amd64, .arm64 }) |arch| {
        const command = try component.binaryCommand(arena.allocator(), arch);
        const wrapped = try std.fmt.allocPrint(arena.allocator(), "sh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command});
        const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", wrapped } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
}

test "Telegram template changes preserve Alertmanager intent until verification and rerun is unchanged" {
    const payload = try Secret.init(std.testing.allocator, "opaque fixture payload");
    defer payload.deinit();
    var fake: Fake = .{};
    var report: workflow.Report = .{ .telegram_configured = true, .telegram_credentials = payload };
    try am.install(std.testing.allocator, fake.interface(), &report, .amd64);
    fake.template = "previous managed presentation";
    fake.permanent_http = true;
    try std.testing.expectError(error.ReadinessTimedOut, am.install(std.testing.allocator, fake.interface(), &report, .amd64));
    try std.testing.expect(fake.pending);
    fake.permanent_http = false;
    try am.health(std.testing.allocator, fake.interface(), &report, .amd64);
    try std.testing.expect(fake.pending);
    try am.install(std.testing.allocator, fake.interface(), &report, .amd64);
    try std.testing.expect(!fake.pending);
    const restarts = fake.restarts;
    report.changes = 0;
    try am.install(std.testing.allocator, fake.interface(), &report, .amd64);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(restarts, fake.restarts);
    try std.testing.expectEqual(@as(usize, 2), fake.template_writes);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    try std.testing.expectEqual(@as(usize, 0), fake.notifications);
}

test "Telegram HTML presentation snapshots are bounded escaped and state aware" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/telegram_template_test.py" } });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\nOK\n") != null);
}

test "Alertmanager executable protected-file and API fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/alertmanager_test.py" } });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\nOK\n") != null);
}

test "Alertmanager runtime guard rejects public extra UDP wrong-owner and wrong-argument processes without retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\set -eu
        \\scenario=$1; shift
        \\root=$(mktemp -d "${TMPDIR:-/tmp}/dragontools-alertmanager-guard.XXXXXX")
        \\trap 'rm -rf "$root"' EXIT HUP INT TERM
        \\mkdir -p "$root/proc/123"
        \\printf '%s\000' /opt/dragontools/components/alertmanager/current/alertmanager --config.file=/etc/dragontools/alertmanager/alertmanager.yml --storage.path=/var/lib/dragontools/alertmanager --web.listen-address=127.0.0.1:9093 --cluster.listen-address= --log.level=info > "$root/proc/123/cmdline"
        \\if test "$scenario" = args; then printf unexpected > "$root/proc/123/cmdline"; fi
        \\ss() {
        \\  test "$scenario" != ss_initial || return 2
        \\  if test "$scenario" = ss_tcp && test "$#" -eq 2 && test "$2" = -ltnp; then return 2; fi
        \\  if test "$scenario" = ss_udp && test "$2" = -lunp; then return 2; fi
        \\  test "$scenario" != missing_listener || return 0
        \\  if test "$2" = -lunp; then
        \\    if test "$scenario" = udp; then printf '%s\n' 'UNCONN 0 0 0.0.0.0:9094 0.0.0.0:* users:("fixture",pid=123,fd=3)'; fi
        \\    return 0
        \\  fi
        \\  if test "$scenario" = public; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9093 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  else
        \\    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:9093 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  fi
        \\  if test "$#" -eq 2 && test "$scenario" = extra; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9999 0.0.0.0:* users:("fixture",pid=123,fd=4)'
        \\  fi
        \\}
        \\systemctl() {
        \\  if test "$1" = is-active; then test "$scenario" != inactive; return; fi
        \\  if test "$scenario" = missing_pid; then printf 0; else printf 123; fi
        \\}
        \\stat() { if test "$scenario" = owner; then printf root:root; else printf dt-alertmanager:dt-alertmanager; fi; }
        \\sha256sum() { cat >/dev/null; test "$scenario" != checksum; }
    ;
    const guard = try std.mem.replaceOwned(u8, a, am.runtime_guard, "/proc/", "$root/proc/");
    const script = try std.fmt.allocPrint(a, "{s}\n{s}\nsystemctl is-active --quiet dragontools-alertmanager.service || exit 75\ntest -n \"$listeners\" || exit 75\nprintf ready", .{ fixture, guard });
    const Case = struct { scenario: []const u8, code: u8 };
    for ([_]Case{
        .{ .scenario = "ready", .code = 0 },
        .{ .scenario = "missing_pid", .code = 75 },
        .{ .scenario = "missing_listener", .code = 75 },
        .{ .scenario = "inactive", .code = 75 },
        .{ .scenario = "public", .code = 1 },
        .{ .scenario = "extra", .code = 1 },
        .{ .scenario = "udp", .code = 1 },
        .{ .scenario = "owner", .code = 1 },
        .{ .scenario = "args", .code = 1 },
        .{ .scenario = "checksum", .code = 1 },
        .{ .scenario = "ss_initial", .code = 2 },
        .{ .scenario = "ss_tcp", .code = 2 },
        .{ .scenario = "ss_udp", .code = 2 },
    }) |case| {
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", case.scenario, "expected-hash" } });
        try std.testing.expectEqual(case.code, result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(if (case.code == 0) "ready" else "", result.stdout);
    }
}
