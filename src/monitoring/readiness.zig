//! Bounded, read-only readiness polling; deterministic mismatches never retry.
const std = @import("std");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");

pub const Check = enum {
    managed_state,
    application_ownership,
    plugin_integrity,
    service_active,
    http_ready,
    self_scrape_ready,
    storage_ready,
    provisioning_ready,
    backend_ready,
    logs_backend_ready,
    logs_datasource_ready,
    credentials_bootstrap,
    credentials_authenticated,
    scrape_ready,
    probe_metrics_ready,
    rules_ready,
    secure_endpoint,
    host_metrics_ready,
    log_stream_ready,
    application_metrics_ready,
};
pub const active_ms = 15_000;
pub const http_ms = 30_000;
pub const telemetry_ms = 45_000;
pub const Validator = *const fn (std.mem.Allocator, []const u8) anyerror!void;

fn now(r: remote.Remote) i64 {
    if (r.clock) |clock| return clock.now_ms(clock.context);
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}
fn sleep(r: remote.Remote, milliseconds: u32) !void {
    if (r.clock) |clock| return clock.sleep_ms(clock.context, milliseconds);
    try std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(milliseconds), .awake);
}

pub fn deterministic(_: std.mem.Allocator, r: remote.Remote, report: *install.Report, check: Check, command: []const u8) ![]const u8 {
    report.check = check;
    return report.call(r, .health, command);
}

pub fn ready(_: std.mem.Allocator, _: []const u8) !void {}

/// Exit 75 and error.NotReady are the only transient outcomes. The caller must
/// keep invariant checks outside that classification, including on later probes.
/// Production SSH receives the remaining budget as an absolute process deadline;
/// a slow command, connection or response cannot start a fresh retry window.
pub fn poll(a: std.mem.Allocator, r: remote.Remote, report: *install.Report, check: Check, deadline_ms: u32, command: []const u8, validator: Validator) !void {
    report.phase = .health;
    report.check = check;
    report.startVerification();
    const started = now(r);
    const deadline = started + deadline_ms;
    var delay_ms: u32 = 500;
    while (true) {
        const remaining = deadline - now(r);
        if (remaining <= 0) return error.ReadinessTimedOut;
        const result = r.runTimed(.health, command, @intCast(remaining)) catch |err| switch (err) {
            error.Timeout => return error.ReadinessTimedOut,
            else => return err,
        };
        var ready_now = false;
        if (result.code != 75) {
            const output = try report.accept(result);
            ready_now = if (validator(a, output)) |_| true else |err| switch (err) {
                error.NotReady => false,
                else => return err,
            };
        }
        const left = deadline - now(r);
        if (left <= 0) return error.ReadinessTimedOut;
        if (ready_now) return;
        if (now(r) - started >= 2000) report.waitingForReadiness();
        try sleep(r, @intCast(@min(left, delay_ms)));
        if (now(r) - started >= 2000) report.waitingForReadiness();
        delay_ms = 1000;
    }
}

test {
    _ = @import("readiness_tests.zig");
}
