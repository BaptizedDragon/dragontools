//! Execute the concrete package script with an isolated PATH containing only
//! fixture executables. No system apt, sudo, package database or network is used.
const std = @import("std");
const host = @import("oh_my_zsh.zig");
const remote = @import("../system/remote.zig");

test "package script installs only missing requirements refreshes once and rejects unsupported OS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path_script = try std.mem.replaceOwned(u8, a, host.packages_script, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "PATH=$DT_ROOT/bin");
    const os_script = try std.mem.replaceOwned(u8, a, path_script, "/etc/os-release", "\"$DT_ROOT/os-release\"");
    const script = try std.mem.replaceOwned(u8, a, os_script, "/etc/ssl/certs/ca-certificates.crt", "\"$DT_ROOT/ca-certificates.crt\"");
    const setup =
        \\set -eu
        \\DT_ROOT=$(mktemp -d /tmp/dragontools-host-packages.XXXXXXXXXX); export DT_ROOT
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\mkdir "$DT_ROOT/bin"
        \\printf 'ID=ubuntu\n' > "$DT_ROOT/os-release"
        \\printf cert > "$DT_ROOT/ca-certificates.crt"
        \\touch "$DT_ROOT/apt-calls" "$DT_ROOT/sudo-calls"
        \\cat > "$DT_ROOT/executable" <<'PROGRAM'
        \\#!/bin/sh
        \\exit 0
        \\PROGRAM
        \\chmod 755 "$DT_ROOT/executable"
        \\cp "$DT_ROOT/executable" "$DT_ROOT/bin/curl"
        \\cat > "$DT_ROOT/bin/id" <<'PROGRAM'
        \\#!/bin/sh
        \\test "$1" = -u || exit 90
        \\printf '%s\n' "${DT_UID-0}"
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/env" <<'PROGRAM'
        \\#!/bin/sh
        \\test "$1" = DEBIAN_FRONTEND=noninteractive || exit 91
        \\exec /usr/bin/env "$@"
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/sudo" <<'PROGRAM'
        \\#!/bin/sh
        \\printf '%s\n' "$*" >> "$DT_ROOT/sudo-calls"
        \\test "$1" = -n && test "$2" = -- || exit 92
        \\shift 2
        \\test "${DT_DENY-0}" = 0 || exit 1
        \\if test "$1" = true; then exit 0; fi
        \\exec "$@"
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/apt-get" <<'PROGRAM'
        \\#!/bin/sh
        \\set -eu
        \\test "$DEBIAN_FRONTEND" = noninteractive || exit 93
        \\printf '%s\n' "$*" >> "$DT_ROOT/apt-calls"
        \\if test "$1" = update; then test "$#" = 1; exit; fi
        \\test "$1" = install && test "$2" = --reinstall && test "$3" = --no-install-recommends && test "$4" = -y || exit 94
        \\shift 4
        \\for package; do
        \\  case "$package" in
        \\    zsh|curl) /bin/cp "$DT_ROOT/executable" "$DT_ROOT/bin/$package" ;;
        \\    ca-certificates) printf cert > "$DT_ROOT/ca-certificates.crt" ;;
        \\    *) exit 95 ;;
        \\  esac
        \\done
        \\PROGRAM
        \\chmod 755 "$DT_ROOT/bin/id" "$DT_ROOT/bin/env" "$DT_ROOT/bin/sudo" "$DT_ROOT/bin/apt-get"
        \\
    ;
    const write_script = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/packages\"\n", .{try remote.quote(a, script)});
    const cases =
        \\packages() { /bin/sh "$DT_ROOT/packages" "$1"; }
        \\test "$(packages 1)" = zsh-installed
        \\test "$(cat "$DT_ROOT/apt-calls")" = "$(printf 'update\ninstall --reinstall --no-install-recommends -y zsh')"
        \\test ! -s "$DT_ROOT/sudo-calls"
        \\cp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\test "$(packages 1)" = unchanged
        \\cmp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\# Existing source needs neither downloader nor a CA package repair.
        \\rm "$DT_ROOT/bin/curl" "$DT_ROOT/ca-certificates.crt"
        \\test "$(packages 0)" = unchanged
        \\cmp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\: > "$DT_ROOT/apt-calls"
        \\test "$(packages 1)" = prerequisites-installed
        \\test "$(cat "$DT_ROOT/apt-calls")" = "$(printf 'update\ninstall --reinstall --no-install-recommends -y curl ca-certificates')"
        \\# Unsupported OS is rejected before apt, even when zsh is missing.
        \\rm "$DT_ROOT/bin/zsh"
        \\printf 'ID=alpine\n' > "$DT_ROOT/os-release"
        \\cp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\code=0; packages 1 >/dev/null 2>&1 || code=$?
        \\test "$code" = 60
        \\cmp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\# Non-root installation uses only explicit noninteractive sudo.
        \\printf 'ID=debian\n' > "$DT_ROOT/os-release"
        \\DT_UID=1000; DT_DENY=1; export DT_UID DT_DENY
        \\code=0; packages 1 >/dev/null 2>&1 || code=$?
        \\test "$code" = 67
        \\cmp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\DT_DENY=0
        \\: > "$DT_ROOT/apt-calls"
        \\test "$(packages 1)" = zsh-installed
        \\test "$(cat "$DT_ROOT/apt-calls")" = "$(printf 'update\ninstall --reinstall --no-install-recommends -y zsh')"
        \\cp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\cp "$DT_ROOT/sudo-calls" "$DT_ROOT/sudo-before"
        \\test "$(packages 1)" = unchanged
        \\cmp "$DT_ROOT/apt-calls" "$DT_ROOT/before"
        \\cmp "$DT_ROOT/sudo-calls" "$DT_ROOT/sudo-before"
        \\printf 'package-script fixture checks passed\n'
        \\
    ;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", try std.mem.concat(a, u8, &.{ setup, write_script, cases }) } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("host package fixture: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("package-script fixture checks passed\n", result.stdout);
}
