//! Exercise the real non-secret writer against isolated local fixture files.
//! Ownership is modeled because tests need no root privileges. Only GNU/BSD
//! stat/mv spellings differ on macOS; actual compare, staging, modes and rename run.
const std = @import("std");
const remote = @import("../system/remote.zig");
const files = @import("../system/files.zig");
const grafana = @import("../components/grafana.zig");
const config = @import("../components/grafana_config.zig");

const substitutes =
    \\set -eu
    \\stat() {
    \\  test "$1" = -c; format=$2; shift 2
    \\  case "$format" in
    \\    '%u:%g') printf '0:0' ;;
    \\    '%a') if test "$(uname -s)" = Darwin; then command /usr/bin/stat -f '%Lp' "$1"; else command stat -c '%a' "$1"; fi ;;
    \\    *) exit 90 ;;
    \\  esac
    \\}
    \\mktemp() { printf 'stage\n' >> "$DT_ROOT/writes"; command mktemp "$@"; }
    \\chmod() { printf 'chmod\n' >> "$DT_ROOT/writes"; command chmod "$@"; }
    \\chown() { test "$1" = root:root; printf 'chown\n' >> "$DT_ROOT/writes"; }
    \\mv() {
    \\  test "$1" = -fT
    \\  printf 'publish\n' >> "$DT_ROOT/writes"
    \\  test -f "$DT_ROOT/grafana-restart-required"
    \\  test "${DT_FAIL-}" != before-publication || return 1
    \\  if test "$(uname -s)" = Darwin; then shift; command mv -f "$@"; else command mv "$@"; fi
    \\  if test "${DT_FAIL-}" = after-publication; then exit 1; fi
    \\}
    \\# Keep remote.shell's quoted argv and execute its complete generated body.
    \\# Map only the known remote paths into the private local fixture boundary.
    \\sh() {
    \\  test "$1" = -eu && test "$2" = -c && test "$4" = dragontools-write
    \\  body=$3
    \\  case "$5" in
    \\    /etc/dragontools/grafana/grafana.ini) target="$DT_ROOT/grafana.ini" ;;
    \\    /etc/dragontools/grafana/provisioning/datasources/dragontools.yaml) target="$DT_ROOT/dragontools.yaml" ;;
    \\    *) exit 90 ;;
    \\  esac
    \\  test "$7" = /var/lib/dragontools/grafana-restart-required
    \\  (set -- "$target" "$6" "$DT_ROOT/grafana-restart-required"; eval "$body")
    \\}
    \\
;

fn fixture(a: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const command = try files.writeCommand(a, path, content, grafana.pending);
    const runner = try std.mem.concat(a, u8, &.{ substitutes, command, "\n" });
    const setup =
        \\set -eu
        \\base=$(cd /tmp && pwd -P)
        \\DT_ROOT=$(mktemp -d "$base/dragontools-grafana-files.XXXXXXXXXX"); export DT_ROOT
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\touch "$DT_ROOT/writes"
        \\
    ;
    const input_files = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/runner\"\nprintf '%s' {s} > \"$DT_ROOT/expected\"\nfile=\"$DT_ROOT/{s}\"\n", .{ try remote.quote(a, runner), try remote.quote(a, content), std.fs.path.basename(path) });
    const cases =
        \\marker="$DT_ROOT/grafana-restart-required"
        \\check() {
        \\  code=0
        \\  /bin/sh "$DT_ROOT/runner" > "$DT_ROOT/output" 2> "$DT_ROOT/errors" || code=$?
        \\  test "$code" = "$1"
        \\  test "$(cat "$DT_ROOT/output")" = "$2"
        \\  test ! -s "$DT_ROOT/errors"
        \\  for entry in "$file".??????; do
        \\    if test "$entry" != "$file.Abc123"; then test ! -e "$entry" && test ! -L "$entry"; fi
        \\  done
        \\  for other in victoriametrics victorialogs victoriatraces; do test ! -e "$DT_ROOT/$other-restart-required"; done
        \\}
        \\signature() {
        \\  if test "$(uname -s)" = Darwin; then stat -f '%i:%m:%Lp' "$1"; else stat -c '%i:%Y:%a' "$1"; fi
        \\}
        \\# Foreign content, binary bytes and mode remain byte-for-byte untouched.
        \\printf '\000administrator config\377\n' > "$file"
        \\chmod 600 "$file"
        \\cp "$file" "$DT_ROOT/original"
        \\original_signature=$(signature "$file")
        \\check 40 ''
        \\cmp "$file" "$DT_ROOT/original"
        \\test "$(signature "$file")" = "$original_signature"
        \\test ! -s "$DT_ROOT/writes" && test ! -e "$marker"
        \\rm "$file"
        \\ln -s "$DT_ROOT/original" "$file"
        \\check 43 ''
        \\test -L "$file"
        \\cmp "$file" "$DT_ROOT/original"
        \\test ! -s "$DT_ROOT/writes" && test ! -e "$marker"
        \\rm "$file"
        \\mkdir "$file"
        \\check 40 ''
        \\rmdir "$file"
        \\ln -s "$DT_ROOT/original" "$marker"
        \\check 43 ''
        \\test ! -e "$file"
        \\rm "$marker"
        \\# First publication marks only Grafana and cleans only its own staging.
        \\printf 'unrelated interrupted staging\n' > "$file.Abc123"
        \\check 0 changed
        \\cmp "$file" "$DT_ROOT/expected"
        \\test -f "$marker"
        \\test "$(cat "$file.Abc123")" = 'unrelated interrupted staging'
        \\rm "$marker"
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\unchanged_signature=$(signature "$file")
        \\check 0 unchanged
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(signature "$file")" = "$unchanged_signature"
        \\test ! -e "$marker"
        \\# Metadata repair preserves bytes/inode, downloads nothing, and needs no restart.
        \\chmod 600 "$file"
        \\check 0 changed
        \\cmp "$file" "$DT_ROOT/expected"
        \\test ! -e "$marker"
        \\test "$(signature "$file")" = "$unchanged_signature"
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\check 0 unchanged
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\# A failed rename leaves the previous managed file and restart intent intact.
        \\printf '# Managed by DragonTools\nold configuration\n' > "$file"
        \\cp "$file" "$DT_ROOT/old"
        \\DT_FAIL=before-publication; export DT_FAIL
        \\check 1 ''
        \\cmp "$file" "$DT_ROOT/old"
        \\test -f "$marker"
        \\marker_signature=$(signature "$marker")
        \\unset DT_FAIL
        \\check 0 changed
        \\cmp "$file" "$DT_ROOT/expected"
        \\test "$(signature "$marker")" = "$marker_signature"
        \\check 0 unchanged
        \\test -f "$marker"
        \\# A lost reply after publication must not lose intent or rewrite on retry.
        \\rm "$marker"
        \\printf '# Managed by DragonTools\nanother old configuration\n' > "$file"
        \\DT_FAIL=after-publication; export DT_FAIL
        \\check 1 ''
        \\cmp "$file" "$DT_ROOT/expected"
        \\test -f "$marker"
        \\marker_signature=$(signature "$marker")
        \\unchanged_signature=$(signature "$file")
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\unset DT_FAIL
        \\check 0 unchanged
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(signature "$file")" = "$unchanged_signature"
        \\test "$(signature "$marker")" = "$marker_signature"
        \\printf 'Grafana atomic file checks passed\n'
        \\
    ;
    const script = try std.mem.concat(a, u8, &.{ setup, input_files, cases });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("Grafana atomic file fixture: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("Grafana atomic file checks passed\n", result.stdout);
}

test "Grafana ini writer executes safe no-op metadata and publication failure recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try fixture(arena.allocator(), config.ini_path, config.ini);
}

test "Grafana datasource writer executes safe no-op metadata and publication failure recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try fixture(arena.allocator(), config.datasources_path, config.datasources);
}
