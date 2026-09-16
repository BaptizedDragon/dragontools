//! Execute the actual home scripts against temporary files. Only downloads,
//! extraction, checksum success, and GNU/BSD command differences are substituted.
//! This exercises publication/preservation/recovery, not an Ubuntu installation.
const std = @import("std");
const host = @import("oh_my_zsh.zig");
const remote = @import("../system/remote.zig");

const substitutes =
    \\set -eu
    \\stat() {
    \\  test "$1" = -c; format=$2; shift 2
    \\  if test "$1" = --; then shift; fi
    \\  # The fixture lives below /tmp; only its existing outer ancestors are
    \\  # modeled as private. Permissions/types inside the fixture are real.
    \\  case "$1" in "$DT_ROOT"|"$DT_ROOT"/*) ;; *) if test "$format" = '%a'; then printf 755; return; fi ;; esac
    \\  if test "$(uname -s)" = Darwin; then
    \\    case "$format" in '%a') format='%Lp' ;; esac
    \\    command /usr/bin/stat -f "$format" "$1"
    \\  else command stat -c "$format" -- "$1"; fi
    \\}
    \\mktemp() { printf 'temporary\n' >> "$DT_ROOT/writes"; command mktemp "$@"; }
    \\chown() { exit 90; }
    \\chmod() { printf 'chmod\n' >> "$DT_ROOT/writes"; command chmod "$@"; }
    \\curl() {
    \\  printf 'download\n' >> "$DT_ROOT/writes"
    \\  case "$*" in *'--proto =https --proto-redir =https'*'--max-time 120'*) ;; *) exit 91 ;; esac
    \\  while test "$1" != --output; do shift; done
    \\  printf archive > "$2"
    \\  test "${DT_FAIL-}" != download
    \\}
    \\sha256sum() {
    \\  test "$1" = --check && test "$2" = --status
    \\  cat >/dev/null
    \\  test "${DT_FAIL-}" != checksum
    \\}
    \\tar() {
    \\  printf 'extract\n' >> "$DT_ROOT/writes"
    \\  while test "$1" != --directory; do shift; done
    \\  tree=$2
    \\  printf 'pinned loader\n' > "$tree/oh-my-zsh.sh"
    \\  if test "${DT_FAIL-}" = extraction; then return 1; fi
    \\  mkdir "$tree/lib" "$tree/plugins" "$tree/themes" "$tree/tools"
    \\}
    \\mv() {
    \\  test "$1" = -T && test "$2" = -n && test "$3" = --; shift 3
    \\  printf 'publish-source\n' >> "$DT_ROOT/writes"
    \\  if test "${DT_FAIL-}" = source-race; then mkdir "$2"; printf keep > "$2/unrelated"; fi
    \\  if test -e "$2" || test -L "$2"; then return 0; fi
    \\  command mv "$1" "$2"
    \\  test "${DT_FAIL-}" != source-published
    \\}
    \\ln() {
    \\  test "$1" = -T && test "$2" = --; shift 2
    \\  printf 'publish-rc\n' >> "$DT_ROOT/writes"
    \\  if test "${DT_FAIL-}" = rc-race; then printf 'concurrent config\n' > "$2"; fi
    \\  if test -e "$2" || test -L "$2"; then return 1; fi
    \\  command ln "$1" "$2"
    \\  if test "${DT_FAIL-}" = rc-published; then exit 1; fi
    \\}
    \\
;

test "home scripts execute no-op preservation exclusive publication and interrupted recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const setup =
        \\set -eu
        \\base=$(cd /tmp && pwd -P)
        \\DT_ROOT=$(mktemp -d "$base/dragontools-host-shell.XXXXXXXXXX"); export DT_ROOT
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\uid=$(id -u); gid=$(id -g)
        \\touch "$DT_ROOT/writes"
        \\
    ;
    const source = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/source\"\n", .{try remote.quote(a, substitutes ++ host.source_script)});
    const zshrc = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/zshrc\"\n", .{try remote.quote(a, substitutes ++ host.zshrc_script)});
    const preflight = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/preflight\"\n", .{try remote.quote(a, substitutes ++ host.home_preflight)});
    const rc_content = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/expected-rc\"\n", .{try remote.quote(a, host.zshrc_content)});
    const cases =
        \\new_home() { home="$DT_ROOT/$1"; mkdir -m 700 "$home"; unset DT_FAIL; }
        \\source_step() { /bin/sh "$DT_ROOT/source" "$home" "$uid" "$gid"; }
        \\rc_step() { /bin/sh "$DT_ROOT/zshrc" "$home" "$uid" "$gid"; }
        \\preflight_step() { /bin/sh "$DT_ROOT/preflight" "$home" "$uid" "$gid"; }
        \\assert_no_staging() { for entry in "$home"/.oh-my-zsh.dragontool.* "$home"/.zshrc.dragontool.*; do case "$entry" in */.oh-my-zsh.dragontool.leftover) continue ;; esac; test ! -e "$entry"; done; }
        \\new_home first
        \\test "$(source_step)" = changed
        \\test "$(rc_step)" = changed
        \\cmp "$home/.zshrc" "$DT_ROOT/expected-rc"
        \\assert_no_staging
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(source_step)" = unchanged
        \\test "$(rc_step)" = unchanged
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\# Existing custom contents and restrictive permissions remain intact.
        \\printf '\000custom shell content\377\n' > "$home/.zshrc"
        \\chmod 600 "$home/.zshrc"
        \\cp "$home/.zshrc" "$DT_ROOT/custom-rc"
        \\printf 'local edits\n' > "$home/.oh-my-zsh/oh-my-zsh.sh"
        \\test "$(source_step)" = unchanged
        \\test "$(rc_step)" = unchanged
        \\cmp "$home/.zshrc" "$DT_ROOT/custom-rc"
        \\test "$(cat "$home/.oh-my-zsh/oh-my-zsh.sh")" = 'local edits'
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\if test "$(uname -s)" = Darwin; then test "$(stat -f '%Lp' "$home/.zshrc")" = 600; else test "$(stat -c '%a' "$home/.zshrc")" = 600; fi
        \\# Fail after download/extraction: final path absent; retry is safe.
        \\for failure in download checksum extraction; do
        \\  new_home "$failure"
        \\  mkdir "$home/.oh-my-zsh.dragontool-unrelated"
        \\  printf keep > "$home/.oh-my-zsh.dragontool-unrelated/data"
        \\  mkdir "$home/.oh-my-zsh.dragontool.leftover"
        \\  printf 'old interrupted extraction' > "$home/.oh-my-zsh.dragontool.leftover/data"
        \\  DT_FAIL=$failure; export DT_FAIL
        \\  if source_step >/dev/null 2>&1; then exit 92; fi
        \\  test ! -e "$home/.oh-my-zsh"
        \\  assert_no_staging
        \\  unset DT_FAIL
        \\  test "$(source_step)" = changed
        \\  test "$(cat "$home/.oh-my-zsh.dragontool-unrelated/data")" = keep
        \\  test "$(cat "$home/.oh-my-zsh.dragontool.leftover/data")" = 'old interrupted extraction'
        \\done
        \\# Failure after publication must not cause a second source download.
        \\new_home source-published
        \\DT_FAIL=source-published; export DT_FAIL
        \\if source_step >/dev/null 2>&1; then exit 93; fi
        \\test -f "$home/.oh-my-zsh/oh-my-zsh.sh"
        \\unset DT_FAIL
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(source_step)" = unchanged
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\# An unexpected directory appearing during source publication survives.
        \\new_home source-race
        \\DT_FAIL=source-race; export DT_FAIL
        \\if source_step >/dev/null 2>&1; then exit 94; fi
        \\test "$(cat "$home/.oh-my-zsh/unrelated")" = keep
        \\test ! -e "$home/.oh-my-zsh/oh-my-zsh.sh"
        \\assert_no_staging
        \\# A concurrently created .zshrc must win exclusive publication.
        \\new_home rc-race
        \\test "$(source_step)" = changed
        \\DT_FAIL=rc-race; export DT_FAIL
        \\test "$(rc_step)" = unchanged
        \\test "$(cat "$home/.zshrc")" = 'concurrent config'
        \\assert_no_staging
        \\# An interrupted response after .zshrc publication is a no-op on retry.
        \\new_home rc-published
        \\test "$(source_step)" = changed
        \\DT_FAIL=rc-published; export DT_FAIL
        \\if rc_step >/dev/null 2>&1; then exit 95; fi
        \\unset DT_FAIL
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(rc_step)" = unchanged
        \\cmp "$home/.zshrc" "$DT_ROOT/expected-rc"
        \\cmp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\# Refuse unsafe/conflicting path types without changing their targets.
        \\new_home unsafe
        \\printf sentinel > "$DT_ROOT/sentinel"
        \\ln -s "$DT_ROOT/sentinel" "$home/.zshrc"
        \\if preflight_step >/dev/null 2>&1; then exit 96; fi
        \\test "$(cat "$DT_ROOT/sentinel")" = sentinel
        \\rm "$home/.zshrc"
        \\ln -s "$DT_ROOT/sentinel" "$home/.oh-my-zsh"
        \\if preflight_step >/dev/null 2>&1; then exit 97; fi
        \\rm "$home/.oh-my-zsh"
        \\mkdir "$home/.oh-my-zsh"
        \\if preflight_step >/dev/null 2>&1; then exit 98; fi
        \\rmdir "$home/.oh-my-zsh"
        \\chmod 0777 "$home"
        \\if preflight_step >/dev/null 2>&1; then exit 99; fi
        \\chmod 0700 "$home"
        \\ln -s "$home" "$DT_ROOT/link-home"
        \\home="$DT_ROOT/link-home"
        \\if preflight_step >/dev/null 2>&1; then exit 100; fi
        \\printf 'home-script fixture checks passed\n'
        \\
    ;
    const script = try std.mem.concat(a, u8, &.{ setup, source, zshrc, preflight, rc_content, cases });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("host shell fixture: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("home-script fixture checks passed\n", result.stdout);
}
