//! Execute generated scripts against private temporary files. GNU/BSD stat,
//! exclusive ln and mv spellings, and Linux flock are substituted on macOS.
//! This validates local preservation/publication, not an Ubuntu SSH deployment.
const std = @import("std");
const zshrc = @import("zshrc.zig");

fn quote(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    const escaped = try std.mem.replaceOwned(u8, a, value, "'", "'\\''");
    return std.mem.concat(a, u8, &.{ "'", escaped, "'" });
}

const preflight =
    \\set -eu
    \\home=$1; expected_uid=$2; expected_gid=$3; rc=$home/.zshrc
    \\test ! -L "$home" && test -d "$home" || exit 63
    \\test ! -L "$rc" || exit 65
    \\if test -e "$rc"; then test -f "$rc" || exit 65; fi
    \\
;

const substitutes =
    \\set -eu
    \\stat() {
    \\  test "$1" = -c; format=$2; shift 2
    \\  if test "$1" = --; then shift; fi
    \\  if test "${DT_FAIL-}" = wrong-owner && test "$format" = '%u'; then printf 999999; return; fi
    \\  if test "$format" = '%g' && test "$1" = "$rc"; then
    \\    case "${DT_FAIL-}" in chgrp-denied|chgrp-lying) printf '%s' "$((expected_gid + 10000))"; return ;; esac
    \\  fi
    \\  if test "$(uname -s)" = Darwin; then
    \\    case "$format" in
    \\      '%u') format='%u' ;; '%g') format='%g' ;; '%h') format='%l' ;; '%a') format='%Lp' ;; '%d') format='%d' ;;
    \\      '%d:%i:%u:%g:%a:%h:%s:%y:%z') format='%d:%i:%u:%g:%Lp:%l:%z:%m:%c' ;;
    \\      *) exit 90 ;;
    \\    esac
    \\    command /usr/bin/stat -f "$format" "$1"
    \\  else command stat -c "$format" -- "$1"; fi
    \\}
    \\flock() {
    \\  test "$1" = -n && test "$2" = 9
    \\  test "${DT_FAIL-}" != locked || return 1
    \\  if test "$(uname -s)" != Darwin; then command flock "$@"; fi
    \\}
    \\mktemp() { printf 'temporary\n' >> "$DT_ROOT/writes"; command mktemp "$@"; }
    \\chgrp() {
    \\  printf 'chgrp\n' >> "$DT_ROOT/writes"
    \\  case "${DT_FAIL-}" in chgrp-denied) return 1 ;; chgrp-lying) return 0 ;; esac
    \\  command chgrp "$@"
    \\}
    \\chmod() {
    \\  printf 'chmod\n' >> "$DT_ROOT/writes"
    \\  if test "${DT_FAIL-}" = before-publication; then return 1; fi
    \\  if test "${DT_FAIL-}" = edited-before-update; then printf 'concurrent config\n' > "$rc"; fi
    \\  if test "${DT_FAIL-}" = replaced-before-update; then command cp "$DT_ROOT/legacy" "$rc.new"; command mv "$rc.new" "$rc"; fi
    \\  if test "${DT_FAIL-}" = symlink-before-update; then command rm "$rc"; command ln -s "$DT_ROOT/sentinel" "$rc"; fi
    \\  command chmod "$@"
    \\}
    \\ln() {
    \\  test "$1" = -T && test "$2" = --; shift 2
    \\  printf 'publish-create\n' >> "$DT_ROOT/writes"
    \\  if test "${DT_FAIL-}" = create-race; then printf 'concurrent config\n' > "$2"; fi
    \\  if test -e "$2" || test -L "$2"; then return 1; fi
    \\  command ln "$1" "$2"
    \\  if test "${DT_FAIL-}" = created; then exit 1; fi
    \\}
    \\mv() {
    \\  test "$1" = -T && test "$2" = --; shift 2
    \\  printf 'publish-update\n' >> "$DT_ROOT/writes"
    \\  command mv -f "$1" "$2"
    \\  if test "${DT_FAIL-}" = updated; then exit 1; fi
    \\}
    \\
;

test "zshrc templates use a server prompt and exact legacy recognition bytes" {
    try std.testing.expect(std.mem.startsWith(u8, zshrc.content, zshrc.marker ++ "\n"));
    try std.testing.expect(std.mem.indexOf(u8, zshrc.content, "ZSH_THEME=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zshrc.content, "plugins=(git)") != null);
    const prompt = std.mem.indexOf(u8, zshrc.content, "PROMPT='%n@%m %~ %# '").?;
    try std.testing.expect(prompt > std.mem.indexOf(u8, zshrc.content, "source \"$ZSH/oh-my-zsh.sh\"").?);
    try std.testing.expectEqualStrings("export ZSH=\"$HOME/.oh-my-zsh\"\n\nZSH_THEME=\"robbyrussell\"\n\nplugins=(git)\n\nsource \"$ZSH/oh-my-zsh.sh\"\n", zshrc.legacy_content);
    try std.testing.expectEqualStrings("# DragonTools managed .zshrc v1\nexport ZSH=\"$HOME/.oh-my-zsh\"\n\nZSH_THEME=\"\"\n\nplugins=(git)\n\nsource \"$ZSH/oh-my-zsh.sh\"\n\nPROMPT='%n@%m %~ %% '\n", zshrc.legacy_v1_content);
    try std.testing.expect(std.mem.indexOf(u8, zshrc.content, "root@") == null);
    try std.testing.expect(std.mem.indexOf(u8, zshrc.content, "monitoring") == null);
}

test "zshrc shell scripts preserve arbitrary bytes migrate exactly and safely recover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const setup =
        \\set -eu
        \\base=$(cd /tmp && pwd -P)
        \\DT_ROOT=$(mktemp -d "$base/dragontools-zshrc.XXXXXXXXXX"); export DT_ROOT
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\uid=$(id -u); gid=$(id -g)
        \\touch "$DT_ROOT/writes"
        \\
    ;
    const normal = try zshrc.script(a, preflight, false);
    const update = try zshrc.script(a, preflight, true);
    for ([_][]const u8{ normal, update }) |script| {
        const parsed = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", script } });
        try std.testing.expectEqualStrings("", parsed.stderr);
        try std.testing.expectEqual(@as(u8, 0), parsed.term.exited);
    }
    const files = try std.fmt.allocPrint(
        a,
        "printf '%s' {s} > \"$DT_ROOT/normal\"\nprintf '%s' {s} > \"$DT_ROOT/update\"\nprintf '%s' {s} > \"$DT_ROOT/expected\"\nprintf '%s' {s} > \"$DT_ROOT/legacy\"\nprintf '%s' {s} > \"$DT_ROOT/legacy-v1\"\n",
        .{ try quote(a, try std.mem.concat(a, u8, &.{ substitutes, normal })), try quote(a, try std.mem.concat(a, u8, &.{ substitutes, update })), try quote(a, zshrc.content), try quote(a, zshrc.legacy_content), try quote(a, zshrc.legacy_v1_content) },
    );
    const cases =
        \\new_home() { home="$DT_ROOT/$1"; mkdir -m 700 "$home"; unset DT_FAIL; }
        \\normal() { /bin/sh "$DT_ROOT/normal" "$home" "$uid" "$gid"; }
        \\update() { /bin/sh "$DT_ROOT/update" "$home" "$uid" "$gid"; }
        \\assert_no_staging() { for entry in "$home"/.zshrc.dragontool.*; do test ! -e "$entry"; done; }
        \\assert_no_writes() { cmp "$DT_ROOT/writes" "$DT_ROOT/before"; }
        \\new_home fresh
        \\test "$(normal)" = created
        \\cmp "$home/.zshrc" "$DT_ROOT/expected"
        \\assert_no_staging
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(normal)" = current
        \\test "$(update)" = current
        \\assert_no_writes
        \\# Neither mode changes arbitrary content, even binary bytes.
        \\printf '\000private arbitrary config\377\n' > "$home/.zshrc"
        \\chmod 600 "$home/.zshrc"
        \\cp "$home/.zshrc" "$DT_ROOT/custom"
        \\test "$(normal)" = preserved
        \\test "$(update)" = preserved
        \\cmp "$home/.zshrc" "$DT_ROOT/custom"
        \\assert_no_writes
        \\# A managed marker never authorizes discarding custom edits.
        \\cp "$DT_ROOT/expected" "$home/.zshrc"
        \\printf '\nexport CUSTOM=keep\n' >> "$home/.zshrc"
        \\cp "$home/.zshrc" "$DT_ROOT/custom"
        \\test "$(normal)" = modified-managed
        \\test "$(update)" = modified-managed
        \\cmp "$home/.zshrc" "$DT_ROOT/custom"
        \\assert_no_writes
        \\# Exact v0 bytes are recognized but require explicit migration.
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\chmod 600 "$home/.zshrc"
        \\test "$(normal)" = recognized-old
        \\cmp "$home/.zshrc" "$DT_ROOT/legacy"
        \\assert_no_writes
        \\test "$(update)" = updated
        \\cmp "$home/.zshrc" "$DT_ROOT/expected"
        \\if test "$(uname -s)" = Darwin; then test "$(stat -f '%Lp' "$home/.zshrc")" = 600; else test "$(stat -c '%a' "$home/.zshrc")" = 600; fi
        \\assert_no_staging
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(update)" = current
        \\test "$(normal)" = current
        \\assert_no_writes
        \\# Exact marked v1 is also historical and requires explicit migration.
        \\cp "$DT_ROOT/legacy-v1" "$home/.zshrc"
        \\chmod 640 "$home/.zshrc"
        \\test "$(normal)" = recognized-old
        \\cmp "$home/.zshrc" "$DT_ROOT/legacy-v1"
        \\assert_no_writes
        \\test "$(update)" = updated
        \\cmp "$home/.zshrc" "$DT_ROOT/expected"
        \\if test "$(uname -s)" = Darwin; then test "$(stat -f '%Lp' "$home/.zshrc")" = 640; else test "$(stat -c '%a' "$home/.zshrc")" = 640; fi
        \\assert_no_staging
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(update)" = current
        \\assert_no_writes
        \\# Edits to v1 and unknown version markers never authorize replacement.
        \\cp "$DT_ROOT/legacy-v1" "$home/.zshrc"
        \\printf '\nexport CUSTOM=keep\n' >> "$home/.zshrc"
        \\cp "$home/.zshrc" "$DT_ROOT/custom"
        \\test "$(update)" = modified-managed
        \\cmp "$home/.zshrc" "$DT_ROOT/custom"
        \\printf '# DragonTools managed .zshrc v99\nprivate config\n' > "$home/.zshrc"
        \\cp "$home/.zshrc" "$DT_ROOT/custom"
        \\test "$(update)" = preserved
        \\cmp "$home/.zshrc" "$DT_ROOT/custom"
        \\assert_no_writes
        \\# A nearly identical v0, including an extra newline, is not managed.
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\printf '\n' >> "$home/.zshrc"
        \\cp "$home/.zshrc" "$DT_ROOT/custom"
        \\test "$(update)" = preserved
        \\cmp "$home/.zshrc" "$DT_ROOT/custom"
        \\assert_no_writes
        \\# A legacy file writable by other accounts cannot safely be migrated.
        \\new_home shared-writable
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\chmod 666 "$home/.zshrc"
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 65
        \\cmp "$home/.zshrc" "$DT_ROOT/legacy"
        \\assert_no_writes
        \\test "$(normal)" = recognized-old
        \\# Existing current or arbitrary files retain their original mode.
        \\cp "$DT_ROOT/expected" "$home/.zshrc"
        \\test "$(update)" = current
        \\printf 'custom config\n' > "$home/.zshrc"
        \\test "$(update)" = preserved
        \\if test "$(uname -s)" = Darwin; then test "$(stat -f '%Lp' "$home/.zshrc")" = 666; else test "$(stat -c '%a' "$home/.zshrc")" = 666; fi
        \\assert_no_writes
        \\# Preserve an existing supplementary GID rather than the account default.
        \\# Use a real supplementary group where available; otherwise retain the
        \\# real primary group and exercise the change/refusal paths below.
        \\new_home group-preserved
        \\cp "$DT_ROOT/legacy-v1" "$home/.zshrc"
        \\old_gid=$gid
        \\for group in $(id -G); do if test "$group" != "$gid"; then old_gid=$group; break; fi; done
        \\if test "$uid" = 0 && test "$old_gid" = "$gid"; then old_gid=1; fi
        \\chgrp "$old_gid" "$home/.zshrc"
        \\chmod 640 "$home/.zshrc"
        \\if test "$(uname -s)" = Darwin; then before_metadata=$(stat -f '%u:%g:%Lp' "$home/.zshrc"); else before_metadata=$(stat -c '%u:%g:%a' "$home/.zshrc"); fi
        \\test "$(update)" = updated
        \\cmp "$home/.zshrc" "$DT_ROOT/expected"
        \\if test "$(uname -s)" = Darwin; then after_metadata=$(stat -f '%u:%g:%Lp' "$home/.zshrc"); else after_metadata=$(stat -c '%u:%g:%a' "$home/.zshrc"); fi
        \\test "$before_metadata" = "$after_metadata"
        \\assert_no_staging
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(update)" = current
        \\assert_no_writes
        \\# A denied or ineffective staged chgrp never publishes changed bytes.
        \\for failure in chgrp-denied chgrp-lying; do
        \\  new_home "$failure"
        \\  cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\  DT_FAIL=$failure; export DT_FAIL
        \\  code=0; update >/dev/null 2>&1 || code=$?
        \\  test "$code" = 65
        \\  cmp "$home/.zshrc" "$DT_ROOT/legacy"
        \\  assert_no_staging
        \\done
        \\unset DT_FAIL
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\# Failure before publication preserves legacy; retry then converges.
        \\new_home interrupted
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\DT_FAIL=before-publication; export DT_FAIL
        \\if update >/dev/null 2>&1; then exit 91; fi
        \\cmp "$home/.zshrc" "$DT_ROOT/legacy"
        \\assert_no_staging
        \\DT_FAIL=updated
        \\if update >/dev/null 2>&1; then exit 92; fi
        \\cmp "$home/.zshrc" "$DT_ROOT/expected"
        \\unset DT_FAIL
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\test "$(update)" = current
        \\assert_no_writes
        \\assert_no_staging
        \\# Existing concurrent create wins exclusive publication.
        \\new_home create-race
        \\DT_FAIL=create-race; export DT_FAIL
        \\test "$(normal)" = preserved
        \\test "$(cat "$home/.zshrc")" = 'concurrent config'
        \\assert_no_staging
        \\# Intervening edits and replacements are not overwritten.
        \\new_home edited-before-update
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\DT_FAIL=edited-before-update; export DT_FAIL
        \\test "$(update)" = preserved
        \\test "$(cat "$home/.zshrc")" = 'concurrent config'
        \\assert_no_staging
        \\new_home replaced-before-update
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\DT_FAIL=replaced-before-update; export DT_FAIL
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 65
        \\cmp "$home/.zshrc" "$DT_ROOT/legacy"
        \\assert_no_staging
        \\# Wrong owner, aliases through hardlinks, and lock contention fail.
        \\new_home owner
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\DT_FAIL=wrong-owner; export DT_FAIL
        \\cp "$DT_ROOT/writes" "$DT_ROOT/before"
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 65
        \\assert_no_writes
        \\unset DT_FAIL
        \\ln "$home/.zshrc" "$home/alias"
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 65
        \\cmp "$home/alias" "$DT_ROOT/legacy"
        \\assert_no_writes
        \\rm "$home/alias"
        \\DT_FAIL=locked; export DT_FAIL
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 70
        \\assert_no_writes
        \\# Neither initial nor intervening symlinks are followed.
        \\new_home symlink
        \\printf sentinel > "$DT_ROOT/sentinel"
        \\ln -s "$DT_ROOT/sentinel" "$home/.zshrc"
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 65
        \\test "$(cat "$DT_ROOT/sentinel")" = sentinel
        \\rm "$home/.zshrc"
        \\cp "$DT_ROOT/legacy" "$home/.zshrc"
        \\DT_FAIL=symlink-before-update; export DT_FAIL
        \\code=0; update >/dev/null 2>&1 || code=$?
        \\test "$code" = 65
        \\test "$(cat "$DT_ROOT/sentinel")" = sentinel
        \\assert_no_staging
        \\printf 'zshrc fixture checks passed\n'
        \\
    ;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", try std.mem.concat(a, u8, &.{ setup, files, cases }) } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("zshrc fixture: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("zshrc fixture checks passed\n", result.stdout);
}

test "zshrc prompt expands username hostname and current directory after loading OMZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const available = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "command -v zsh" } });
    if (available.term != .exited or available.term.exited != 0) return error.SkipZigTest;
    const body =
        \\set -eu
        \\DT_ROOT=$(mktemp -d /tmp/dragontools-zshrc-prompt.XXXXXXXXXX)
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\mkdir "$DT_ROOT/.oh-my-zsh"
        \\printf 'PROMPT="theme omitted hostname"\n' > "$DT_ROOT/.oh-my-zsh/oh-my-zsh.sh"
        \\
    ;
    const write = try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/.zshrc\"\n", .{try quote(a, zshrc.content)});
    const check =
        \\HOME="$DT_ROOT" zsh -f -c 'source "$HOME/.zshrc"; cd "$HOME"; test "$ZSH_THEME" = "" && test "$plugins[1]" = git; actual=$(print -P "$PROMPT"); terminator="%"; if (( EUID == 0 )); then terminator="#"; fi; expected="$(id -un)@${HOST%%.*} ~ $terminator "; test "$actual" = "$expected"'
        \\printf 'zshrc prompt expansion passed\n'
        \\
    ;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", try std.mem.concat(a, u8, &.{ body, write, check }) } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("zshrc prompt: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("zshrc prompt expansion passed\n", result.stdout);
}
