//! Actual verifier and selected-service guard fixtures; no SSH or real services.
const std = @import("std");
const common = @import("common.zig");

test "production Caddy managed state uses typed credentials and converges without sensitive output" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/caddy_checks_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "production ingress managed state converges and missing empty properties remain failures" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/ingress_managed_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "agent runtime and signal verifier entrypoints classify drift and delayed arrival without stderr" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/agent_checks_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "selected journal service requires the canonical unit and default namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const command = try common.selectedService(a, "application.service");
    for ([_][]const u8{ "healthy", "missing", "alias", "namespace" }) |scenario| {
        // Intercept the outer sh invocation so the inner process can access the
        // shell-local systemctl fixture, while preserving -eu and quoted args.
        const script = try std.fmt.allocPrint(a,
            \\scenario={s}
            \\systemctl() {{
            \\  case "$2" in
            \\    --property=LoadState) if test "$scenario" = missing; then printf not-found; else printf loaded; fi;;
            \\    --property=Id) if test "$scenario" = alias; then printf real.service; else printf application.service; fi;;
            \\    --property=LogNamespace) if test "$scenario" = namespace; then printf isolated; fi;;
            \\    *) return 1;;
            \\  esac
            \\}}
            \\sh() {{ body=$3; shift 3; shift; (set -eu; eval "$body"); }}
            \\{s}
        , .{ scenario, command });
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectEqual(@as(u8, if (std.mem.eql(u8, scenario, "healthy")) 0 else 1), result.term.exited);
    }
}

test "native host event observer filesystem transitions are persistent bounded and read-only on verify" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/host_events_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "host event timer verifier rejects unit metadata drift and stale observations read-only" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/host_events_checks_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "host event activation recovers failed oneshot and interrupted timer then stays unchanged" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/host_events_activation_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
