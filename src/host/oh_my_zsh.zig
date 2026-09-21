const std = @import("std");
const remote = @import("../system/remote.zig");
const managed_rc = @import("zshrc.zig");
const login_shell = @import("login_shell.zig");

// Official immutable codeload archive, downloaded and SHA-256 calculated during
// review. Oh My Zsh does not publish a separate checksum/signature for this tree.
// https://github.com/ohmyzsh/ohmyzsh/commit/0ee67f042872d1dfab74270c31867771ca35aef4
// Catalog: 1159 regular files, 417 directories, nine relative internal symlinks;
// no hardlinks, devices, absolute paths, traversal, or members beneath symlinks.
// Links: plugins/per-directory-history/per-directory-history.plugin.zsh ->
// per-directory-history.zsh; themes/macovsky-ruby.zsh-theme -> macovsky.zsh-theme;
// plugins/zsh-syntax-highlighting/highlighters/{brackets,cursor,line,main,pattern,
// regexp,root}/README.md -> ../../docs/highlighters/<same-name>.md.
pub const revision = "0ee67f042872d1dfab74270c31867771ca35aef4";
pub const archive_sha256 = "73a7017cd5cde1d76b4044df9f100c6aeae0feb9820e8529f8c90063d2af3cb9";
pub const archive_url = "https://codeload.github.com/ohmyzsh/ohmyzsh/tar.gz/" ++ revision;

pub const Account = struct { name: []const u8, uid: u32, gid: u32, home: []const u8, shell: []const u8 };
pub const Phase = enum { inspect, packages, source, zshrc, login_shell, verify };
pub const InstallOptions = struct {
    target_user: ?[]const u8 = null,
    set_default_shell: bool = false,
    update_managed_zshrc: bool = false,
};
pub const ZshrcStatus = enum { created, updated, current, preserved, recognized_old, modified_managed };
pub const Report = struct {
    phase: Phase = .inspect,
    changes: usize = 0,
    target: ?Account = null,
    zsh_changed: bool = false,
    omz_changed: bool = false,
    zshrc_changed: bool = false,
    zshrc_status: ZshrcStatus = .preserved,
    shell_requested: bool = false,
    shell_changed: bool = false,
    original_shell: []const u8 = "",
    zsh_path: []const u8 = "",

    fn call(_: *Report, r: remote.Remote, op: remote.Operation, command: []const u8) ![]const u8 {
        const result = try r.run(op, command);
        switch (result.code) {
            0 => return result.output,
            60 => return error.UnsupportedHostDistribution,
            61 => return error.MissingHostPrerequisite,
            62 => return error.TargetUserNotFound,
            63 => return error.UnsafeTargetHome,
            64 => return error.OhMyZshPathConflict,
            65 => return error.UnsafeZshrcPath,
            66 => return error.TargetAccountChanged,
            67 => return error.NoninteractivePrivilegesRequired,
            68 => return error.OhMyZshChecksumMismatch,
            69 => return error.OhMyZshArchiveConflict,
            70 => return error.HostConfigurationBusy,
            255 => return error.SshConnectionFailed,
            else => return error.HostOperationFailed,
        }
    }
};

// These scripts do not source user initialization or downloaded code. OpenSSH
// itself invokes the account's login shell to process each remote command.
const inspect_script =
    \\set -eu
    \\PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
    \\LC_ALL=C; export LC_ALL
    \\test -r /etc/os-release || exit 60
    \\. /etc/os-release
    \\case "${ID-}" in ubuntu|debian) ;; *) exit 60 ;; esac
    \\for cmd in getent id stat dirname tar sha256sum mktemp mv ln rm chmod chgrp awk env mkdir cat cmp flock; do command -v "$cmd" >/dev/null 2>&1 || exit 61; done
    \\target=$1
    \\if test -z "$target"; then target=$(id -un); fi
    \\entry=$(getent passwd "$target") || exit 62
    \\test -n "$entry" || exit 62
    \\printf '%s\n' "$entry" | awk -F: 'NF != 7 || NR != 1 { exit 1 } END { if (NR != 1) exit 1 }' || exit 62
    \\printf '%s\n' "$entry" | awk -F: '{printf "%s\n%s\n%s\n%s\n%s\n", $1, $3, $4, $6, $7}'
;

pub fn inspectCommand(a: std.mem.Allocator, target_user: ?[]const u8) ![]const u8 {
    return remote.shell(a, &.{ "/bin/sh", "-c", inspect_script, "dragontools-host-inspect", target_user orelse "" });
}

pub fn parseAccount(value: []const u8) !Account {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, value, "\n"), '\n');
    const name = lines.next() orelse return error.InvalidHostAccount;
    const uid = std.fmt.parseInt(u32, lines.next() orelse return error.InvalidHostAccount, 10) catch return error.InvalidHostAccount;
    const gid = std.fmt.parseInt(u32, lines.next() orelse return error.InvalidHostAccount, 10) catch return error.InvalidHostAccount;
    const home = lines.next() orelse return error.InvalidHostAccount;
    const shell = lines.next() orelse return error.InvalidHostAccount;
    if (lines.next() != null or !validName(name) or !validPath(home) or !validPath(shell) or std.mem.eql(u8, home, "/")) return error.InvalidHostAccount;
    return .{ .name = name, .uid = uid, .gid = gid, .home = home, .shell = shell };
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or value[0] == '-') return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}
pub fn validPath(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096 or value[0] != '/') return false;
    var parts = std.mem.splitScalar(u8, value[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._-", c) == null) return false;
    }
    return true;
}

// Check account identity on each operation, then discard inherited environment.
// Any writes in a non-root target's home run under that target's UID, never root.
const target_wrapper =
    \\set -eu
    \\PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
    \\name=$1; uid=$2; gid=$3; home=$4; shell=$5; script=$6
    \\entry=$(getent passwd "$name") || exit 62
    \\actual=$(printf '%s\n' "$entry" | awk -F: '{print $1 ":" $3 ":" $4 ":" $6 ":" $7}')
    \\test "$actual" = "$name:$uid:$gid:$home:$shell" || exit 66
    \\if test "$(id -u)" = "$uid"; then
    \\  exec env -i "HOME=$home" "USER=$name" "LOGNAME=$name" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/sh -c "$script" dragontools-host-user "$home" "$uid" "$gid"
    \\fi
    \\test -x /usr/sbin/runuser || exit 61
    \\if test "$(id -u)" = 0; then
    \\  exec /usr/sbin/runuser -u "$name" -- env -i "HOME=$home" "USER=$name" "LOGNAME=$name" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/sh -c "$script" dragontools-host-user "$home" "$uid" "$gid"
    \\fi
    \\command -v sudo >/dev/null 2>&1 && sudo -n -- true >/dev/null 2>&1 || exit 67
    \\exec sudo -n -- /usr/sbin/runuser -u "$name" -- env -i "HOME=$home" "USER=$name" "LOGNAME=$name" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/sh -c "$script" dragontools-host-user "$home" "$uid" "$gid"
;

pub fn targetCommand(a: std.mem.Allocator, account: Account, script: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "/bin/sh", "-c", target_wrapper, "dragontools-host-target", account.name, try std.fmt.allocPrint(a, "{d}", .{account.uid}), try std.fmt.allocPrint(a, "{d}", .{account.gid}), account.home, account.shell, script });
}

pub const home_preflight =
    \\set -eu
    \\home=$1; expected_uid=$2; expected_gid=$3
    \\test "$(id -u)" = "$expected_uid" || exit 63
    \\test "$(stat -c '%u' -- "$home")" = "$expected_uid" || exit 63
    \\check=$home
    \\while :; do
    \\  test ! -L "$check" && test -d "$check" || exit 63
    \\  owner=$(stat -c '%u' -- "$check")
    \\  test "$owner" = 0 || test "$owner" = "$expected_uid" || exit 63
    \\  mode=$(stat -c '%a' -- "$check")
    \\  test "$((0$mode & 0022))" = 0 || exit 63
    \\  test "$check" != / || break
    \\  check=$(dirname -- "$check")
    \\done
    \\test -w "$home" && test -x "$home" || exit 63
    \\omz=$home/.oh-my-zsh; rc=$home/.zshrc
    \\test ! -L "$omz" || exit 64
    \\if test -e "$omz"; then
    \\  test -d "$omz" && test ! -L "$omz/oh-my-zsh.sh" && test -f "$omz/oh-my-zsh.sh" || exit 64
    \\  for subdir in lib plugins themes tools; do test ! -L "$omz/$subdir" && test -d "$omz/$subdir" || exit 64; done
    \\fi
    \\test ! -L "$rc" || exit 65
    \\if test -e "$rc"; then test -f "$rc" || exit 65; fi
;

const preflight_script = home_preflight ++ "\nif test -d \"$omz\"; then printf present; else printf absent; fi\n";

// apt refresh happens only if an actually missing required package needs install.
// curl and CA certificates are needed only when the source directory is absent.
pub const packages_script =
    \\set -eu
    \\PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
    \\need_source=$1; zsh_missing=0
    \\set --
    \\if ! command -v zsh >/dev/null 2>&1; then set -- "$@" zsh; zsh_missing=1; fi
    \\if test "$need_source" = 1; then
    \\  if ! command -v curl >/dev/null 2>&1; then set -- "$@" curl; fi
    \\  if test ! -s /etc/ssl/certs/ca-certificates.crt; then set -- "$@" ca-certificates; fi
    \\fi
    \\if test "$#" = 0; then printf unchanged; exit 0; fi
    \\command -v apt-get >/dev/null 2>&1 || exit 61
    \\. /etc/os-release
    \\case "${ID-}" in ubuntu|debian) ;; *) exit 60 ;; esac
    \\if test "$(id -u)" = 0; then
    \\  env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
    \\  env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall --no-install-recommends -y "$@" >/dev/null 2>&1
    \\else
    \\  command -v sudo >/dev/null 2>&1 && sudo -n -- true >/dev/null 2>&1 || exit 67
    \\  sudo -n -- env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
    \\  sudo -n -- env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall --no-install-recommends -y "$@" >/dev/null 2>&1
    \\fi
    \\command -v zsh >/dev/null 2>&1 || exit 61
    \\if test "$zsh_missing" = 1; then printf zsh-installed; else printf prerequisites-installed; fi
;

pub const source_script = home_preflight ++ "\n" ++
    \\if test -d "$omz"; then printf unchanged; exit 0; fi
    \\umask 077
    \\tmp=$(mktemp -d "$home/.oh-my-zsh.dragontool.XXXXXXXXXX")
    \\trap 'rm -rf -- "$tmp"' EXIT
    \\trap 'exit 1' HUP INT TERM
    \\curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --max-filesize 16777216 --output "$tmp/source.tar.gz"
++ " " ++ archive_url ++ "\n" ++
    \\printf '%s  %s\n'
++ " " ++ archive_sha256 ++ " \"$tmp/source.tar.gz\" | sha256sum --check --status || exit 68\n" ++
    \\mkdir "$tmp/tree"
    \\tar --extract --gzip --file "$tmp/source.tar.gz" --directory "$tmp/tree" --strip-components=1 --no-same-owner --no-same-permissions
    \\test ! -L "$tmp/tree/oh-my-zsh.sh" && test -f "$tmp/tree/oh-my-zsh.sh" || exit 69
    \\for subdir in lib plugins themes tools; do test ! -L "$tmp/tree/$subdir" && test -d "$tmp/tree/$subdir" || exit 69; done
    \\test ! -L "$omz" || exit 64
    \\mv -T -n -- "$tmp/tree" "$omz"
    \\if test -d "$tmp/tree"; then
    \\  test ! -L "$omz" && test -d "$omz" && test ! -L "$omz/oh-my-zsh.sh" && test -f "$omz/oh-my-zsh.sh" || exit 64
    \\  printf unchanged
    \\else
    \\  printf changed
    \\fi
;

pub const zshrc_content = managed_rc.content;

pub fn zshrcScript(a: std.mem.Allocator, update: bool) ![]const u8 {
    return managed_rc.script(a, home_preflight, update);
}

pub const verify_script = home_preflight ++ "\n" ++
    \\test -d "$omz" && test -f "$rc"
    \\zsh_path=$(command -v zsh) || exit 61
    \\test -x "$zsh_path" || exit 61
    \\printf '%s\n' "$zsh_path"
;

pub fn install(a: std.mem.Allocator, r: remote.Remote, options: InstallOptions, report: *Report) !void {
    report.phase = .inspect;
    report.shell_requested = options.set_default_shell;
    const account = try parseAccount(try report.call(r, .host_inspect, try inspectCommand(a, options.target_user)));
    if (options.target_user) |requested| if (!std.mem.eql(u8, requested, account.name)) return error.InvalidHostAccount;
    report.target = account;
    report.original_shell = account.shell;
    const present = try report.call(r, .host_inspect, try targetCommand(a, account, preflight_script));
    if (!std.mem.eql(u8, present, "present") and !std.mem.eql(u8, present, "absent")) return error.InvalidHostResponse;
    report.phase = .packages;
    const packages = try report.call(r, .host_packages, try remote.shell(a, &.{ "/bin/sh", "-c", packages_script, "dragontools-host-packages", if (std.mem.eql(u8, present, "absent")) "1" else "0" }));
    if (std.mem.eql(u8, packages, "zsh-installed")) {
        report.zsh_changed = true;
        report.changes += 1;
    } else if (std.mem.eql(u8, packages, "prerequisites-installed")) {
        report.changes += 1;
    } else if (!std.mem.eql(u8, packages, "unchanged")) return error.InvalidHostResponse;
    report.phase = .source;
    report.omz_changed = try changed(try report.call(r, .host_source, try targetCommand(a, account, source_script)));
    if (report.omz_changed) report.changes += 1;
    report.phase = .zshrc;
    report.zshrc_status = try parseZshrcStatus(try report.call(r, .host_zshrc, try targetCommand(a, account, try zshrcScript(a, options.update_managed_zshrc))));
    report.zshrc_changed = report.zshrc_status == .created or report.zshrc_status == .updated;
    if (report.zshrc_changed) report.changes += 1;
    report.phase = .verify;
    const zsh_path = std.mem.trimEnd(u8, try report.call(r, .host_verify, try targetCommand(a, account, verify_script)), "\n");
    if (!validPath(zsh_path)) return error.InvalidHostResponse;
    report.zsh_path = zsh_path;
    if (options.set_default_shell) {
        report.phase = .login_shell;
        report.shell_changed = try login_shell.change(a, r, account, zsh_path);
        if (report.shell_changed) report.changes += 1;
        report.phase = .verify;
        try login_shell.verify(a, r, account, zsh_path);
        report.target.?.shell = zsh_path;
    }
}

fn parseZshrcStatus(value: []const u8) !ZshrcStatus {
    if (std.mem.eql(u8, value, "recognized-old")) return .recognized_old;
    if (std.mem.eql(u8, value, "modified-managed")) return .modified_managed;
    return std.meta.stringToEnum(ZshrcStatus, value) orelse error.InvalidHostResponse;
}

fn changed(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "changed")) return true;
    if (std.mem.eql(u8, value, "unchanged")) return false;
    return error.InvalidHostResponse;
}

test {
    _ = @import("tests.zig");
    _ = @import("package_tests.zig");
    _ = @import("zshrc.zig");
    _ = @import("login_shell.zig");
}

test "account inspection and target privilege wrappers are valid POSIX shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ inspect_script, target_wrapper }) |script| {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
}
