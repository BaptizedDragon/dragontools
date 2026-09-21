const std = @import("std");
const grafana = @import("grafana_install.zig");
const remote = @import("../system/remote.zig");
const config = @import("../components/grafana_config.zig");

test "Grafana preflight preserves foreign configuration data and symlinks before mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const etc = try std.mem.replaceOwned(u8, a, grafana.preflight, "/etc/", "${DT_ROOT}/etc/");
    const body = try std.mem.replaceOwned(u8, a, etc, "/var/", "${DT_ROOT}/var/");
    const substitutes =
        \\runuser() { return 0; }
        \\systemctl() { test "$1" = show; printf '%s' "${DT_DROPINS-}"; }
        \\stat() { test "$1" = -c && test "$2" = '%u:%g'; printf '0:0'; }
        \\
    ;
    const setup =
        \\set -eu
        \\DT_ROOT=$(mktemp -d /tmp/dragontools-grafana-preflight.XXXXXXXXXX); export DT_ROOT
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\mkdir -p "$DT_ROOT/etc/systemd/system" "$DT_ROOT/var/lib/dragontools"
        \\
    ;
    const write = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/preflight\"\n", .{try remote.quote(a, substitutes ++ "\n")});
    const append = try std.fmt.allocPrint(a, "printf '%s' {s} >> \"$DT_ROOT/preflight\"\n", .{try remote.quote(a, body)});
    const cases =
        \\check() {
        \\  code=0
        \\  /bin/sh "$DT_ROOT/preflight" > "$DT_ROOT/output" 2> "$DT_ROOT/errors" || code=$?
        \\  test "$code" = "$1"
        \\  test ! -s "$DT_ROOT/output" && test ! -s "$DT_ROOT/errors"
        \\}
        \\check 0
        \\base="$DT_ROOT/etc/dragontools/grafana"
        \\data="$DT_ROOT/var/lib/dragontools/grafana"
        \\mkdir -p "$base/provisioning/datasources" "$base/provisioning/dashboards" "$data"
        \\check 0
        \\printf '\000private config\377\n' > "$base/grafana.ini"
        \\cp "$base/grafana.ini" "$DT_ROOT/original"
        \\check 40
        \\cmp "$base/grafana.ini" "$DT_ROOT/original"
        \\rm "$base/grafana.ini"
        \\printf '# Managed by DragonTools\n' > "$base/grafana.ini"
        \\printf '# Managed by DragonTools\n' > "$base/provisioning/datasources/dragontools.yaml"
        \\check 0
        \\# A failed first plugin download/publication leaves managed plugin state.
        \\# The ini must already exist so the next preflight can resume safely.
        \\mkdir -p "$data/plugins" "$data/plugins-versions/victoriametrics-logs-datasource"
        \\check 0
        \\mv "$base/grafana.ini" "$DT_ROOT/managed.ini"
        \\check 40
        \\mv "$DT_ROOT/managed.ini" "$base/grafana.ini"
        \\check 0
        \\printf 'unmanaged provisioning\n' > "$base/provisioning/datasources/other.yaml"
        \\check 40
        \\test "$(cat "$base/provisioning/datasources/other.yaml")" = 'unmanaged provisioning'
        \\rm "$base/provisioning/datasources/other.yaml"
        \\printf 'foreign YAML disguised as staging\n' > "$base/provisioning/datasources/dragontools.yaml.a.yaml"
        \\check 40
        \\test "$(cat "$base/provisioning/datasources/dragontools.yaml.a.yaml")" = 'foreign YAML disguised as staging'
        \\rm "$base/provisioning/datasources/dragontools.yaml.a.yaml"
        \\# A killed adjacent writer's temporary bytes are left alone and ignored.
        \\printf 'partial pending write\n' > "$base/provisioning/datasources/dragontools.yaml.Abc123"
        \\check 0
        \\test "$(cat "$base/provisioning/datasources/dragontools.yaml.Abc123")" = 'partial pending write'
        \\mv "$base/grafana.ini" "$DT_ROOT/managed.ini"
        \\ln -s "$DT_ROOT/original" "$base/grafana.ini"
        \\check 43
        \\cmp "$base/grafana.ini" "$DT_ROOT/original"
        \\rm "$base/grafana.ini"
        \\mv "$DT_ROOT/managed.ini" "$base/grafana.ini"
        \\unit="$DT_ROOT/etc/systemd/system/dragontools-grafana.service"
        \\printf '[Unit]\nDescription=administrator Grafana\n' > "$unit"
        \\check 40
        \\printf '# Managed by DragonTools\n' > "$unit"
        \\DT_DROPINS=foreign.conf; export DT_DROPINS
        \\check 42
        \\unset DT_DROPINS
        \\ln -s "$DT_ROOT/original" "$DT_ROOT/var/lib/dragontools/grafana-restart-required"
        \\check 43
        \\rm "$DT_ROOT/var/lib/dragontools/grafana-restart-required"
        \\mv "$base/grafana.ini" "$DT_ROOT/managed.ini"
        \\printf 'administrator database\n' > "$data/grafana.db"
        \\check 40
        \\test "$(cat "$data/grafana.db")" = 'administrator database'
        \\mv "$DT_ROOT/managed.ini" "$base/grafana.ini"
        \\check 0
        \\check 0
        \\test "$(cat "$data/grafana.db")" = 'administrator database'
        \\printf 'Grafana preflight checks passed\n'
        \\
    ;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", try std.mem.concat(a, u8, &.{ setup, write, append, cases }) } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("Grafana preflight fixture: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("Grafana preflight checks passed\n", result.stdout);
}

test "Grafana file writers mark only Grafana before atomic publication and preserve matching files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = @import("../system/files.zig");
    const pending = @import("../components/grafana.zig").pending;
    for ([_][]const u8{ config.ini_path, config.datasources_path }, [_][]const u8{ config.ini, config.datasources }) |path, content| {
        const command = try files.writeCommand(a, path, content, pending);
        try std.testing.expect(std.mem.indexOf(u8, command, "cmp -s -").? < std.mem.indexOf(u8, command, "mktemp").?);
        try std.testing.expect(std.mem.indexOf(u8, command, ": > \"$3\"").? < std.mem.indexOf(u8, command, "mv -fT").?);
        try std.testing.expect(std.mem.indexOf(u8, command, pending) != null);
        for ([_][]const u8{ "victoriametrics-restart", "victorialogs-restart", "victoriatraces-restart", "systemctl" }) |unexpected| {
            try std.testing.expect(std.mem.indexOf(u8, command, unexpected) == null);
        }
    }
}

test {
    _ = @import("grafana_files_tests.zig");
}
