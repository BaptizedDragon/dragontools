const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("oh_my_zsh.zig");

// These helpers do not source user initialization files. OpenSSH still invokes
// the account's shell to process each remote command. The shell pathname is the
// one discovered by the host workflow, not a hard-coded /bin/zsh alias.
pub const preflight_script =
    \\set -eu
    \\PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
    \\LC_ALL=C; export LC_ALL
    \\name=$1; uid=$2; gid=$3; home=$4; original_shell=$5; zsh_path=$6
    \\read_account() {
    \\  entry=$(getent passwd "$name") || exit 62
    \\  identity=$(printf '%s\n' "$entry" | awk -F: 'NF != 7 || NR != 1 { exit 1 } { print $1 ":" $3 ":" $4 ":" $6 } END { if (NR != 1) exit 1 }') || exit 66
    \\  test "$identity" = "$name:$uid:$gid:$home" || exit 66
    \\  current_shell=$(printf '%s\n' "$entry" | awk -F: '{ print $7 }')
    \\  case "$current_shell" in "$original_shell"|"$zsh_path") ;; *) exit 66 ;; esac
    \\}
    \\read_account
    \\test -f "$zsh_path" && test -x "$zsh_path" || exit 70
    \\test -f /etc/shells && test -r /etc/shells || exit 71
    \\awk -v shell="$zsh_path" '$0 == shell { found = 1 } END { exit !found }' /etc/shells || exit 71
;

pub const mutation_script = preflight_script ++ "\n" ++
    \\if test "$current_shell" = "$zsh_path"; then printf unchanged; exit 0; fi
    \\test "$(id -u)" = 0 || exit 67
    \\test -x /usr/bin/chsh || exit 61
    \\/usr/bin/chsh -s "$zsh_path" "$name" >/dev/null 2>&1 || exit 72
    \\read_account
    \\test "$current_shell" = "$zsh_path" || exit 73
    \\printf changed
;

// The login user can inspect account state and return an unchanged result without
// requiring sudo. Revalidation happens again inside the privileged operation.
pub const change_script = preflight_script ++ "\n" ++
    \\if test "$current_shell" = "$zsh_path"; then printf unchanged; exit 0; fi
    \\script=$7
    \\if test "$(id -u)" = 0; then
    \\  exec /bin/sh -c "$script" dragontools-host-shell-root "$name" "$uid" "$gid" "$home" "$original_shell" "$zsh_path"
    \\fi
    \\test -x /usr/bin/sudo && /usr/bin/sudo -n -- true >/dev/null 2>&1 || exit 67
    \\exec /usr/bin/sudo -n -- /bin/sh -c "$script" dragontools-host-shell-root "$name" "$uid" "$gid" "$home" "$original_shell" "$zsh_path"
;

pub const verify_script = preflight_script ++ "\n" ++
    \\test "$current_shell" = "$zsh_path" || exit 73
    \\printf verified
;

pub fn changeCommand(a: std.mem.Allocator, account: host.Account, zsh_path: []const u8) ![]const u8 {
    if (!host.validPath(zsh_path)) return error.InvalidZshPath;
    return remote.shell(a, &.{ "/bin/sh", "-c", change_script, "dragontools-host-shell", account.name, try std.fmt.allocPrint(a, "{d}", .{account.uid}), try std.fmt.allocPrint(a, "{d}", .{account.gid}), account.home, account.shell, zsh_path, mutation_script });
}

pub fn verifyCommand(a: std.mem.Allocator, account: host.Account, zsh_path: []const u8) ![]const u8 {
    if (!host.validPath(zsh_path)) return error.InvalidZshPath;
    return remote.shell(a, &.{ "/bin/sh", "-c", verify_script, "dragontools-host-shell-verify", account.name, try std.fmt.allocPrint(a, "{d}", .{account.uid}), try std.fmt.allocPrint(a, "{d}", .{account.gid}), account.home, account.shell, zsh_path });
}

pub fn change(a: std.mem.Allocator, r: remote.Remote, account: host.Account, zsh_path: []const u8) !bool {
    const output = try checked(try r.run(.host_shell, try changeCommand(a, account, zsh_path)));
    if (std.mem.eql(u8, output, "changed")) return true;
    if (std.mem.eql(u8, output, "unchanged")) return false;
    return error.InvalidHostResponse;
}

/// Read-only account, executable and /etc/shells verification. It never invokes
/// chsh or sudo, including when the expected shell is missing or differs.
pub fn verify(a: std.mem.Allocator, r: remote.Remote, account: host.Account, zsh_path: []const u8) !void {
    const output = try checked(try r.run(.host_verify, try verifyCommand(a, account, zsh_path)));
    if (!std.mem.eql(u8, output, "verified")) return error.InvalidHostResponse;
}

fn checked(result: remote.Result) ![]const u8 {
    switch (result.code) {
        0 => return result.output,
        61 => return error.MissingHostPrerequisite,
        62 => return error.TargetUserNotFound,
        66 => return error.TargetAccountChanged,
        67 => return error.NoninteractivePrivilegesRequired,
        70 => return error.ZshExecutableUnavailable,
        71 => return error.ZshNotListedInEtcShells,
        72 => return error.LoginShellChangeFailed,
        73 => return error.LoginShellVerificationFailed,
        255 => return error.SshConnectionFailed,
        else => return error.HostOperationFailed,
    }
}

test {
    _ = @import("login_shell_tests.zig");
}
