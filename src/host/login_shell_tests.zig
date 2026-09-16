//! The rendered scripts run against fixture account files and executables only.
//! No real passwd database, chsh, sudo, or remote host is used.
const std = @import("std");
const shell = @import("login_shell.zig");
const host = @import("oh_my_zsh.zig");
const remote = @import("../system/remote.zig");

const account: host.Account = .{ .name = "operator", .uid = 1001, .gid = 1002, .home = "/srv/operator", .shell = "/bin/bash" };

const Fake = struct {
    current_zsh: bool = false,
    changes: usize = 0,
    verifies: usize = 0,
    fail_after_change: bool = false,
    verify_code: u8 = 0,
    change_code: u8 = 0,

    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute };
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        switch (op) {
            .host_shell => {
                try std.testing.expect(std.mem.indexOf(u8, command, "dragontools-host-shell") != null);
                if (self.change_code != 0) return .{ .code = self.change_code };
                if (self.current_zsh) return .{ .code = 0, .output = "unchanged" };
                self.current_zsh = true;
                self.changes += 1;
                if (self.fail_after_change) return .{ .code = 255 };
                return .{ .code = 0, .output = "changed" };
            },
            .host_verify => {
                self.verifies += 1;
                try std.testing.expect(std.mem.indexOf(u8, command, "dragontools-host-shell-verify") != null);
                try std.testing.expect(std.mem.indexOf(u8, command, "chsh") == null);
                try std.testing.expect(std.mem.indexOf(u8, command, "sudo") == null);
                return .{ .code = self.verify_code, .output = "verified" };
            },
            else => return error.UnexpectedOperation,
        }
    }
};

test "login shell change verifies actual state and retries after a committed interruption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    try std.testing.expect(try shell.change(a, fake.asRemote(), account, "/usr/bin/zsh"));
    try shell.verify(a, fake.asRemote(), account, "/usr/bin/zsh");
    try std.testing.expect(!try shell.change(a, fake.asRemote(), account, "/usr/bin/zsh"));
    try shell.verify(a, fake.asRemote(), account, "/usr/bin/zsh");
    try std.testing.expectEqual(@as(usize, 1), fake.changes);
    try std.testing.expectEqual(@as(usize, 2), fake.verifies);
    var interrupted: Fake = .{ .fail_after_change = true };
    try std.testing.expectError(error.SshConnectionFailed, shell.change(a, interrupted.asRemote(), account, "/usr/bin/zsh"));
    interrupted.fail_after_change = false;
    try std.testing.expect(!try shell.change(a, interrupted.asRemote(), account, "/usr/bin/zsh"));
    try shell.verify(a, interrupted.asRemote(), account, "/usr/bin/zsh");
    try std.testing.expectEqual(@as(usize, 1), interrupted.changes);
    try std.testing.expectEqual(@as(usize, 1), interrupted.verifies);
}

test "login shell errors are named and failed read-only verification cannot succeed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failed: Fake = .{ .verify_code = 73 };
    try std.testing.expect(try shell.change(a, failed.asRemote(), account, "/usr/bin/zsh"));
    try std.testing.expectError(error.LoginShellVerificationFailed, shell.verify(a, failed.asRemote(), account, "/usr/bin/zsh"));
    const cases = [_]struct { code: u8, expected: anyerror }{
        .{ .code = 62, .expected = error.TargetUserNotFound },
        .{ .code = 66, .expected = error.TargetAccountChanged },
        .{ .code = 67, .expected = error.NoninteractivePrivilegesRequired },
        .{ .code = 70, .expected = error.ZshExecutableUnavailable },
        .{ .code = 71, .expected = error.ZshNotListedInEtcShells },
        .{ .code = 72, .expected = error.LoginShellChangeFailed },
    };
    for (cases) |case| {
        var fake: Fake = .{ .change_code = case.code };
        try std.testing.expectError(case.expected, shell.change(a, fake.asRemote(), account, "/usr/bin/zsh"));
        try std.testing.expectEqual(@as(usize, 0), fake.changes);
        try std.testing.expectEqual(@as(usize, 0), fake.verifies);
    }
    var untouched: Fake = .{};
    try std.testing.expectError(error.InvalidZshPath, shell.change(a, untouched.asRemote(), account, "/usr/bin/zsh;exec"));
    try std.testing.expectEqual(@as(usize, 0), untouched.changes);
}

test "login shell scripts change only a differing listed shell and preserve no-op privilege independence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const setup =
        \\set -eu
        \\DT_ROOT=$(mktemp -d /tmp/dragontools-login-shell.XXXXXXXXXX); export DT_ROOT
        \\trap 'rm -rf "$DT_ROOT"' EXIT
        \\mkdir "$DT_ROOT/bin"
        \\touch "$DT_ROOT/chsh-calls" "$DT_ROOT/sudo-calls"
        \\cat > "$DT_ROOT/bin/zsh" <<'PROGRAM'
        \\#!/bin/sh
        \\exit 0
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/id" <<'PROGRAM'
        \\#!/bin/sh
        \\test "$1" = -u || exit 90
        \\printf '%s\n' "${DT_LOGIN_UID-0}"
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/getent" <<'PROGRAM'
        \\#!/bin/sh
        \\test "$1" = passwd && test "$2" = operator || exit 90
        \\test -s "$DT_ROOT/passwd" || exit 2
        \\/bin/cat "$DT_ROOT/passwd"
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/chsh" <<'PROGRAM'
        \\#!/bin/sh
        \\test "$#" = 3 && test "$1" = -s && test "$2" = "$DT_ROOT/bin/zsh" && test "$3" = operator || exit 90
        \\test "${DT_LOGIN_UID-0}" = 0 || exit 91
        \\printf '%s\n' called >> "$DT_ROOT/chsh-calls"
        \\test "${DT_CHSH_FAIL-0}" = 0 || exit 1
        \\test "${DT_CHSH_NOOP-0}" = 0 || exit 0
        \\printf 'operator:x:1001:1002:Operator:/srv/operator:%s\n' "$2" > "$DT_ROOT/passwd"
        \\PROGRAM
        \\cat > "$DT_ROOT/bin/sudo" <<'PROGRAM'
        \\#!/bin/sh
        \\printf '%s\n' called >> "$DT_ROOT/sudo-calls"
        \\test "$1" = -n && test "$2" = -- || exit 92
        \\shift 2
        \\test "${DT_DENY-0}" = 0 || exit 1
        \\if test "$1" = true; then exit 0; fi
        \\if test "${DT_SWAP_IDENTITY-0}" = 1; then
        \\  printf 'operator:x:1001:9999:Operator:/srv/operator:/bin/bash\n' > "$DT_ROOT/passwd"
        \\fi
        \\DT_LOGIN_UID=0; export DT_LOGIN_UID
        \\exec "$@"
        \\PROGRAM
        \\chmod 755 "$DT_ROOT/bin/"*
        \\
    ;
    var command: std.ArrayList(u8) = .empty;
    try command.appendSlice(a, setup);
    for ([_][]const u8{ shell.change_script, shell.mutation_script, shell.verify_script }, [_][]const u8{ "change", "mutation", "verify" }) |original, name| {
        const parsed = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", original } });
        try std.testing.expectEqual(@as(u8, 0), parsed.term.exited);
        const path = try std.mem.replaceOwned(u8, a, original, "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "PATH=$DT_ROOT/bin:/usr/bin:/bin");
        const shells = try std.mem.replaceOwned(u8, a, path, "/etc/shells", "\"$DT_ROOT/shells\"");
        const chsh = try std.mem.replaceOwned(u8, a, shells, "/usr/bin/chsh", "\"$DT_ROOT/bin/chsh\"");
        const fixture = try std.mem.replaceOwned(u8, a, chsh, "/usr/bin/sudo", "\"$DT_ROOT/bin/sudo\"");
        try command.appendSlice(a, try std.fmt.allocPrint(a, "printf '%s' {s} > \"$DT_ROOT/{s}\"\n", .{ try remote.quote(a, fixture), name }));
    }
    const cases =
        \\reset_account() { printf 'operator:x:1001:1002:Operator:/srv/operator:/bin/bash\n' > "$DT_ROOT/passwd"; }
        \\reset_account
        \\printf '# fixture shells\n/bin/bash\n%s\n' "$DT_ROOT/bin/zsh" > "$DT_ROOT/shells"
        \\change_shell() { /bin/sh "$DT_ROOT/change" operator 1001 1002 /srv/operator /bin/bash "$DT_ROOT/bin/zsh" "$(cat "$DT_ROOT/mutation")"; }
        \\verify_shell() { /bin/sh "$DT_ROOT/verify" operator 1001 1002 /srv/operator /bin/bash "$DT_ROOT/bin/zsh"; }
        \\# Explicit mutation from bash to the discovered path, followed by no-op.
        \\test "$(change_shell)" = changed
        \\test "$(cat "$DT_ROOT/chsh-calls")" = called
        \\test ! -s "$DT_ROOT/sudo-calls"
        \\test "$(verify_shell)" = verified
        \\test "$(change_shell)" = unchanged
        \\test "$(cat "$DT_ROOT/chsh-calls")" = called
        \\# A correct shell is still a no-op without any available privilege.
        \\DT_LOGIN_UID=1001; DT_DENY=1; export DT_LOGIN_UID DT_DENY
        \\test "$(change_shell)" = unchanged
        \\test ! -s "$DT_ROOT/sudo-calls"
        \\cp "$DT_ROOT/chsh-calls" "$DT_ROOT/chsh-before"
        \\# Membership is mandatory even if the current shell is already correct.
        \\printf '/bin/bash\n' > "$DT_ROOT/shells"
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 71
        \\test ! -s "$DT_ROOT/sudo-calls"
        \\cmp "$DT_ROOT/chsh-before" "$DT_ROOT/chsh-calls"
        \\reset_account
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 71
        \\cmp "$DT_ROOT/chsh-before" "$DT_ROOT/chsh-calls"
        \\printf '%s\n' "$DT_ROOT/bin/zsh" > "$DT_ROOT/shells"
        \\# Privilege failure leaves bash intact; read-only verification cannot repair it.
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 67
        \\cmp "$DT_ROOT/chsh-before" "$DT_ROOT/chsh-calls"
        \\cp "$DT_ROOT/sudo-calls" "$DT_ROOT/sudo-before"
        \\code=0; verify_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 73
        \\cmp "$DT_ROOT/sudo-before" "$DT_ROOT/sudo-calls"
        \\# The privileged child reinspects identity before changing anything.
        \\DT_DENY=0; DT_SWAP_IDENTITY=1; export DT_SWAP_IDENTITY
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 66
        \\cmp "$DT_ROOT/chsh-before" "$DT_ROOT/chsh-calls"
        \\DT_SWAP_IDENTITY=0
        \\reset_account
        \\test "$(change_shell)" = changed
        \\cp "$DT_ROOT/chsh-calls" "$DT_ROOT/chsh-before"
        \\cp "$DT_ROOT/sudo-calls" "$DT_ROOT/sudo-before"
        \\test "$(change_shell)" = unchanged
        \\cmp "$DT_ROOT/chsh-before" "$DT_ROOT/chsh-calls"
        \\cmp "$DT_ROOT/sudo-before" "$DT_ROOT/sudo-calls"
        \\# A changed home and an unexpected third shell are conflicts.
        \\printf 'operator:x:1001:1002:Operator:/srv/elsewhere:/bin/bash\n' > "$DT_ROOT/passwd"
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 66
        \\printf 'operator:x:1001:1002:Operator:/srv/operator:/bin/fish\n' > "$DT_ROOT/passwd"
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 66
        \\cmp "$DT_ROOT/chsh-before" "$DT_ROOT/chsh-calls"
        \\cmp "$DT_ROOT/sudo-before" "$DT_ROOT/sudo-calls"
        \\# Failed or lying chsh commands cannot report successful verification.
        \\reset_account
        \\DT_LOGIN_UID=0; DT_CHSH_FAIL=1; export DT_CHSH_FAIL
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 72
        \\DT_CHSH_FAIL=0; DT_CHSH_NOOP=1; export DT_CHSH_NOOP
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 73
        \\DT_CHSH_NOOP=0
        \\chmod 644 "$DT_ROOT/bin/zsh"
        \\code=0; change_shell >/dev/null 2>&1 || code=$?
        \\test "$code" = 70
        \\printf 'login-shell fixture checks passed\n'
        \\
    ;
    try command.appendSlice(a, cases);
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", command.items } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("login shell fixture: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("login-shell fixture checks passed\n", result.stdout);
}
