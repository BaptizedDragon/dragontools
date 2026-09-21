const std = @import("std");
const vmalert = @import("vmalert.zig");

test "vmalert rule API fixtures require evaluated policy and allow pending firing probes" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/vmalert_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "vmalert actual runtime guards retry absence but reject invariant failures without stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\set -eu
        \\scenario=$1; shift
        \\root=$(mktemp -d "${TMPDIR:-/tmp}/dragontools-vmalert-probe.XXXXXX")
        \\trap 'rm -rf "$root"' EXIT HUP INT TERM
        \\mkdir -p "$root/proc/123"
        \\printf '%s' "$3" > "$root/proc/123/cmdline"
        \\if test "$scenario" = args; then printf unexpected > "$root/proc/123/cmdline"; fi
        \\ss() {
        \\  test "$scenario" != ss_failure || return 1
        \\  if test "$2" = -lunp; then
        \\    if test "$scenario" = udp; then printf '%s\n' 'UNCONN 0 0 0.0.0.0:9999 0.0.0.0:* users:("fixture",pid=123,fd=4)'; fi
        \\    return 0
        \\  fi
        \\  test "$scenario" != missing_listener || return 0
        \\  address=127.0.0.1; owner_pid=123
        \\  if test "$scenario" = public; then address=0.0.0.0; fi
        \\  if test "$scenario" = foreign_listener; then owner_pid=999; fi
        \\  printf 'LISTEN 0 4096 %s:%s 0.0.0.0:* users:("fixture",pid=%s,fd=3)\n' "$address" "$port" "$owner_pid"
        \\  if test "$#" -eq 2 && test "$scenario" = extra; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9999 0.0.0.0:* users:("fixture",pid=123,fd=4)'
        \\  fi
        \\}
        \\systemctl() {
        \\  if test "$1" = is-active; then test "$scenario" != inactive; return; fi
        \\  if test "$scenario" = missing_pid; then printf 0; else printf 123; fi
        \\}
        \\stat() { if test "$scenario" = owner; then printf root:root; else printf 'dt-%s:dt-%s' "$id" "$id"; fi; }
        \\# Real checksum consumers drain stdin on success and mismatch alike.
        \\sha256sum() { cat >/dev/null; test "$scenario" != checksum; }
    ;
    const guard = try std.mem.replaceOwned(u8, a, vmalert.runtime, "/proc/", "$root/proc/");
    const script = try std.fmt.allocPrint(a, "{s}\n{s}\ntest -n \"$listeners\" || exit 75\nprintf ready", .{ fixture, guard });
    const Case = struct { scenario: []const u8, code: u8 };
    for ([_]vmalert.Kind{ .logs, .metrics }) |kind| {
        for ([_]Case{
            .{ .scenario = "ready", .code = 0 },
            .{ .scenario = "missing_pid", .code = 75 },
            .{ .scenario = "missing_listener", .code = 75 },
            .{ .scenario = "inactive", .code = 75 },
            .{ .scenario = "public", .code = 1 },
            .{ .scenario = "foreign_listener", .code = 1 },
            .{ .scenario = "extra", .code = 1 },
            .{ .scenario = "owner", .code = 1 },
            .{ .scenario = "args", .code = 1 },
            .{ .scenario = "checksum", .code = 1 },
            .{ .scenario = "udp", .code = 1 },
            .{ .scenario = "ss_failure", .code = 1 },
        }) |case| {
            const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", case.scenario, vmalert.name(kind), "expected-hash", "binary\n-fixed-argument", try std.fmt.allocPrint(a, "{d}", .{vmalert.port(kind)}) } });
            try std.testing.expectEqual(case.code, result.term.exited);
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqualStrings(if (case.code == 0) "ready" else "", result.stdout);
        }
    }
}
