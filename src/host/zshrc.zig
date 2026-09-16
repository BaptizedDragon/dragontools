const std = @import("std");

pub const marker = "# DragonTools managed .zshrc v2";
pub const content = marker ++ "\n" ++
    \\export ZSH="$HOME/.oh-my-zsh"
    \\
    \\ZSH_THEME=""
    \\
    \\plugins=(git)
    \\
    \\source "$ZSH/oh-my-zsh.sh"
    \\
    \\PROMPT='%n@%m %~ %# '
    \\
;

// Exact previous marked template. Never substitute a marker-only ownership test.
pub const legacy_v1_content =
    \\# DragonTools managed .zshrc v1
    \\export ZSH="$HOME/.oh-my-zsh"
    \\
    \\ZSH_THEME=""
    \\
    \\plugins=(git)
    \\
    \\source "$ZSH/oh-my-zsh.sh"
    \\
    \\PROMPT='%n@%m %~ %% '
    \\
;

// Exact bytes emitted by the initial DragonTools implementation, including its
// final newline. Similar configurations and marker-only claims are not adopted.
pub const legacy_content =
    \\export ZSH="$HOME/.oh-my-zsh"
    \\
    \\ZSH_THEME="robbyrussell"
    \\
    \\plugins=(git)
    \\
    \\source "$ZSH/oh-my-zsh.sh"
    \\
;

const classify =
    \\classify() {
    \\  test ! -L "$rc" || exit 65
    \\  if test ! -e "$rc"; then state=absent; return; fi
    \\  test -f "$rc" || exit 65
    \\  if cmp -s -- "$rc" - <<'DRAGONTOOLS_CURRENT'
    \\
++ content ++
    \\DRAGONTOOLS_CURRENT
    \\  then state=current; return; fi
    \\  if cmp -s -- "$rc" - <<'DRAGONTOOLS_LEGACY_V1'
    \\
++ legacy_v1_content ++
    \\DRAGONTOOLS_LEGACY_V1
    \\  then state=recognized-old; return; fi
    \\  if cmp -s -- "$rc" - <<'DRAGONTOOLS_LEGACY'
    \\
++ legacy_content ++
    \\DRAGONTOOLS_LEGACY
    \\  then state=recognized-old; return; fi
    \\  first=
    \\  IFS= read -r first < "$rc" || :
    \\  case "$first" in
    \\    '# DragonTools managed .zshrc v1'|'# DragonTools managed .zshrc v2') state=modified-managed ;;
    \\    *) state=preserved ;;
    \\  esac
    \\}
    \\
;

// `home_preflight` is the existing target-user/path guard; the caller executes
// this through targetCommand. These scripts never source existing user content.
// Flocking the existing home directory serializes DragonTools writers without a
// persistent lock file. An external editor must not run during explicit updates:
// portable shell has no atomic compare-and-replace against uncooperative writers.
pub fn script(a: std.mem.Allocator, home_preflight: []const u8, update: bool) ![]const u8 {
    return std.mem.concat(a, u8, &.{ home_preflight, "\n", classify, if (update) "update=1\n" else "update=0\n", publication });
}

const publication =
    \\classify
    \\case "$state" in
    \\  absent) ;;
    \\  recognized-old) if test "$update" != 1; then printf '%s' "$state"; exit 0; fi ;;
    \\  *) printf '%s' "$state"; exit 0 ;;
    \\esac
    \\# Advisory locking is scoped to this invocation and touches no file.
    \\exec 9< "$home"
    \\flock -n 9 || exit 70
    \\classify
    \\case "$state" in
    \\  absent) ;;
    \\  recognized-old) if test "$update" != 1; then printf '%s' "$state"; exit 0; fi ;;
    \\  *) printf '%s' "$state"; exit 0 ;;
    \\esac
    \\original=$state; mode=644
    \\if test "$original" = recognized-old; then
    \\  test "$(stat -c '%u' -- "$rc")" = "$expected_uid" || exit 65
    \\  test "$(stat -c '%h' -- "$rc")" = 1 || exit 65
    \\  identity=$(stat -c '%d:%i:%u:%g:%a:%h:%s:%y:%z' -- "$rc")
    \\  mode=$(stat -c '%a' -- "$rc")
    \\  case "$mode" in [0-7]|[0-7][0-7]|[0-7][0-7][0-7]) ;; *) exit 65 ;; esac
    \\  test "$((0$mode & 0022))" = 0 || exit 65
    \\  original_gid=$(stat -c '%g' -- "$rc")
    \\  case "$original_gid" in ''|*[!0-9]*) exit 65 ;; esac
    \\fi
    \\umask 077
    \\tmp=$(mktemp -d "$home/.zshrc.dragontool.XXXXXXXXXX")
    \\trap 'rm -rf -- "$tmp"' EXIT
    \\trap 'exit 1' HUP INT TERM
    \\test ! -L "$tmp" && test -d "$tmp" || exit 65
    \\test "$(stat -c '%d' -- "$tmp")" = "$(stat -c '%d' -- "$home")" || exit 65
    \\cat > "$tmp/zshrc" <<'DRAGONTOOLS_CURRENT'
    \\
++ content ++
    \\DRAGONTOOLS_CURRENT
    \\if test "$original" = recognized-old; then
    \\  if test "$(stat -c '%g' -- "$tmp/zshrc")" != "$original_gid"; then
    \\    chgrp "$original_gid" "$tmp/zshrc" || exit 65
    \\  fi
    \\fi
    \\chmod "$mode" "$tmp/zshrc" || exit 65
    \\test "$(stat -c '%u' -- "$tmp/zshrc")" = "$expected_uid" || exit 65
    \\test "$(stat -c '%a' -- "$tmp/zshrc")" = "$mode" || exit 65
    \\if test "$original" = recognized-old; then
    \\  test "$(stat -c '%g' -- "$tmp/zshrc")" = "$original_gid" || exit 65
    \\fi
    \\if test "$original" = absent; then
    \\  if ln -T -- "$tmp/zshrc" "$rc" 2>/dev/null; then
    \\    printf created
    \\  else
    \\    classify
    \\    test "$state" != absent || exit 65
    \\    printf '%s' "$state"
    \\  fi
    \\else
    \\  # Recheck both identity/metadata and complete bytes immediately before
    \\  # atomic replacement. Arbitrary contents are never copied into staging.
    \\  classify
    \\  if test "$state" != recognized-old; then printf '%s' "$state"; exit 0; fi
    \\  test "$(stat -c '%d:%i:%u:%g:%a:%h:%s:%y:%z' -- "$rc")" = "$identity" || exit 65
    \\  mv -T -- "$tmp/zshrc" "$rc"
    \\  printf updated
    \\fi
    \\
;

test {
    _ = @import("zshrc_tests.zig");
}
