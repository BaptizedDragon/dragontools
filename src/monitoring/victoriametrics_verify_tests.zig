const std = @import("std");
const verify = @import("verify.zig");
const systemd = @import("../system/systemd.zig");

test "VictoriaMetrics actual runtime guard distinguishes startup absence from invariant failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\set -eu
        \\scenario=$1; shift
        \\root=$(mktemp -d "${TMPDIR:-/tmp}/dragontools-metrics-probe.XXXXXX")
        \\trap 'rm -rf "$root"' EXIT HUP INT TERM
        \\mkdir -p "$root/proc/123"
        \\printf '%s\000' /opt/dragontools/components/victoriametrics/current/victoria-metrics-prod -storageDataPath=/var/lib/dragontools/victoriametrics -retentionPeriod=90d -storage.minFreeDiskSpaceBytes=2000 -httpListenAddr=127.0.0.1:8428 -selfScrapeInterval=15s > "$root/proc/123/cmdline"
        \\if test "$scenario" = args; then printf unexpected > "$root/proc/123/cmdline"; fi
        \\ss() {
        \\  test "$scenario" != missing_listener || return 0
        \\  if test "$scenario" = public; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:8428 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  elif test "$scenario" = foreign_listener; then
        \\    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8428 0.0.0.0:* users:("fixture",pid=999,fd=3)'
        \\  else
        \\    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8428 0.0.0.0:* users:("fixture",pid=123,fd=3)'
        \\  fi
        \\  if test "$#" -eq 2 && test "$scenario" = extra; then
        \\    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:9999 0.0.0.0:* users:("fixture",pid=123,fd=4)'
        \\  fi
        \\}
        \\systemctl() {
        \\  if test "$1" = is-active; then test "$scenario" != inactive; return; fi
        \\  if test "$scenario" = missing_pid; then printf 0; else printf 123; fi
        \\}
        \\id() { printf 200; }
        \\stat() { if test "$scenario" = owner; then printf 0:0; else printf 200:200; fi; }
        \\sha256sum() { test "$scenario" != checksum; }
    ;
    const guard = try std.mem.replaceOwned(u8, a, verify.process_script, "/proc/", "$root/proc/");
    const script = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\nprintf ready", .{ fixture, guard, verify.listener_ready });
    const Case = struct { scenario: []const u8, code: u8 };
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
    }) |case| {
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", case.scenario, "expected-hash", "unused-unit", "2000", "-retentionPeriod=90d" } });
        try std.testing.expectEqual(case.code, result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(if (case.code == 0) "ready" else "", result.stdout);
    }
}

test "VictoriaMetrics deterministic verifier accepts rendered unit policy and rejects effective drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unit = try systemd.render(a, 2000);
    const fixture =
        \\set -eu
        \\scenario=$1; shift
        \\root=$(mktemp -d "${TMPDIR:-/tmp}/dragontools-metrics-policy.XXXXXX")
        \\trap 'rm -rf "$root"' EXIT HUP INT TERM
        \\printf '%s' "$2" > "$root/unit"
        \\mkdir -p "$root/opt/dragontools/components/victoriametrics/v1.151.0"
        \\: > "$root/opt/dragontools/components/victoriametrics/v1.151.0/victoria-metrics-prod"
        \\ln -s v1.151.0 "$root/opt/dragontools/components/victoriametrics/current"
        \\systemctl() {
        \\  test "$1" = show && test "$2" = -p
        \\  case "$3" in
        \\    FragmentPath) printf '%s' "$root/unit";;
        \\    LoadState) printf loaded;;
        \\    UnitFileState) printf enabled;;
        \\    NeedDaemonReload) printf no;;
        \\    DropInPaths|AmbientCapabilities) :;;
        \\    PrivateDevices|LockPersonality) printf no;;
        \\    ProtectSystem) if test "$scenario" = drift; then printf full; else printf strict; fi;;
        \\    *) sed -n "s/^$3=//p" "$root/unit";;
        \\  esac
        \\}
        \\stat() { if test "$3" = "$root/unit"; then printf 0:0:644; else printf 0:0:755; fi; }
        \\sha256sum() { return 0; }
    ;
    const with_unit = try std.mem.replaceOwned(u8, a, verify.managed_script, "/etc/systemd/system/dragontools-victoriametrics.service", "$root/unit");
    const managed = try std.mem.replaceOwned(u8, a, with_unit, "/opt/dragontools", "$root/opt/dragontools");
    const script = try std.fmt.allocPrint(a, "{s}\n{s}\nprintf ready", .{ fixture, managed });
    for ([_][]const u8{ "ready", "drift" }) |scenario| {
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script, "fixture", scenario, "expected-hash", unit, "2000", "-retentionPeriod=90d" } });
        try std.testing.expectEqualStrings("", result.stderr);
        const ready = std.mem.eql(u8, scenario, "ready");
        try std.testing.expectEqual(@as(u8, if (ready) 0 else 1), result.term.exited);
        try std.testing.expectEqualStrings(if (ready) "ready" else "", result.stdout);
    }
}
