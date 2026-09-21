const std = @import("std");
const remote = @import("../system/remote.zig");
const omz = @import("oh_my_zsh.zig");
const zshrc = @import("zshrc.zig");

const PathState = enum { absent, present, conflict, symlink };
// This models only this concrete workflow's persisted state. It does not execute
// apt or pretend to be a Linux host; shell filesystem tests are separate.
const Fake = struct {
    account_output: []const u8 = "sshuser\n1001\n1002\n/srv/users/sshuser\n/bin/bash\n",
    supported: bool = true,
    missing_user: bool = false,
    unsafe_home: bool = false,
    zsh: bool = false,
    zsh_path: []const u8 = "/usr/bin/zsh",
    zsh_path_buffer: [4098]u8 = undefined,
    source: PathState = .absent,
    rc: PathState = .absent,
    rc_bytes: []const u8 = "",
    local_changes: []const u8 = "custom theme and branch retained",
    login_shell: []const u8 = "/bin/bash",
    shell_override: ?[]const u8 = null,
    account_buffer: [8192]u8 = undefined,
    shell_calls: usize = 0,
    chsh_calls: usize = 0,
    shell_listed: bool = true,
    shell_privileges: bool = true,
    chsh_failure: bool = false,
    shell_verify_failure: bool = false,
    shell_verifications: usize = 0,
    requested_user: ?[]const u8 = null,
    writes: usize = 0,
    packages: usize = 0,
    downloads: usize = 0,
    source_writes: usize = 0,
    rc_writes: usize = 0,
    package_calls: usize = 0,
    fail_after: ?remote.Operation = null,
    interrupted_download: bool = false,
    abandoned_private_stage: bool = false,
    unrelated_temp_bytes: []const u8 = "unrelated user data",

    fn asRemote(self: *Fake) remote.Remote {
        return .{ .context = self, .execute = execute };
    }
    fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        switch (op) {
            .host_inspect => {
                if (!self.supported) return .{ .code = 60 };
                if (self.missing_user) return .{ .code = 62 };
                if (std.mem.indexOf(u8, command, "dragontools-host-inspect") != null) {
                    if (self.requested_user) |user| {
                        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                        defer arena.deinit();
                        const quoted = try remote.quote(arena.allocator(), user);
                        try std.testing.expect(std.mem.endsWith(u8, command, quoted));
                    } else try std.testing.expect(std.mem.endsWith(u8, command, "''"));
                    const account = try omz.parseAccount(self.account_output);
                    self.login_shell = self.shell_override orelse account.shell;
                    return .{ .code = 0, .output = try std.fmt.bufPrint(&self.account_buffer, "{s}\n{d}\n{d}\n{s}\n{s}\n", .{ account.name, account.uid, account.gid, account.home, self.login_shell }) };
                }
                if (self.unsafe_home) return .{ .code = 63 };
                if (self.source == .conflict or self.source == .symlink) return .{ .code = 64 };
                if (self.rc == .conflict or self.rc == .symlink) return .{ .code = 65 };
                return .{ .code = 0, .output = if (self.source == .present) "present" else "absent" };
            },
            .host_packages => {
                self.package_calls += 1;
                try std.testing.expect(std.mem.endsWith(u8, command, if (self.source == .present) "'0'" else "'1'"));
                if (self.zsh) return .{ .code = 0, .output = "unchanged" };
                self.zsh = true;
                self.packages += 1;
                self.writes += 1;
                if (self.fail_after == op) return .{ .code = 1 };
                return .{ .code = 0, .output = "zsh-installed" };
            },
            .host_source => {
                if (self.source == .present) return .{ .code = 0, .output = "unchanged" };
                self.downloads += 1;
                if (self.interrupted_download) {
                    self.abandoned_private_stage = true;
                    return .{ .code = 1 };
                }
                self.source = .present;
                self.source_writes += 1;
                self.writes += 1;
                if (self.fail_after == op) return .{ .code = 1 };
            },
            .host_zshrc => {
                var output: []const u8 = "created";
                if (self.rc == .present) {
                    if (std.mem.eql(u8, self.rc_bytes, zshrc.content)) return .{ .code = 0, .output = "current" };
                    if (std.mem.eql(u8, self.rc_bytes, zshrc.legacy_content) or std.mem.eql(u8, self.rc_bytes, zshrc.legacy_v1_content)) {
                        if (std.mem.indexOf(u8, command, "update=1\n") == null) return .{ .code = 0, .output = "recognized-old" };
                        output = "updated";
                    } else {
                        const first_line = self.rc_bytes[0 .. std.mem.indexOfScalar(u8, self.rc_bytes, '\n') orelse self.rc_bytes.len];
                        const marked = std.mem.eql(u8, first_line, zshrc.marker) or std.mem.eql(u8, first_line, "# DragonTools managed .zshrc v1");
                        return .{ .code = 0, .output = if (marked) "modified-managed" else "preserved" };
                    }
                }
                self.rc = .present;
                self.rc_bytes = omz.zshrc_content;
                self.rc_writes += 1;
                self.writes += 1;
                if (self.fail_after == op) return .{ .code = 1 };
                return .{ .code = 0, .output = output };
            },
            .host_verify => {
                if (!self.zsh or self.source != .present or self.rc != .present) return .{ .code = 1 };
                if (std.mem.indexOf(u8, command, "dragontools-host-shell-verify") != null) {
                    self.shell_verifications += 1;
                    if (self.shell_verify_failure or !std.mem.eql(u8, self.login_shell, self.zsh_path)) return .{ .code = 73 };
                    return .{ .code = 0, .output = "verified" };
                }
                return .{ .code = 0, .output = try std.fmt.bufPrint(&self.zsh_path_buffer, "{s}\n", .{self.zsh_path}) };
            },
            .host_shell => {
                self.shell_calls += 1;
                try std.testing.expect(std.mem.indexOf(u8, command, self.zsh_path) != null);
                if (!self.shell_listed) return .{ .code = 71 };
                if (std.mem.eql(u8, self.login_shell, self.zsh_path)) return .{ .code = 0, .output = "unchanged" };
                if (!self.shell_privileges) return .{ .code = 67 };
                self.chsh_calls += 1;
                if (self.chsh_failure) return .{ .code = 72 };
                self.writes += 1;
                self.login_shell = self.zsh_path;
                self.shell_override = self.login_shell;
                if (self.fail_after == op) return .{ .code = 255 };
                return .{ .code = 0, .output = "changed" };
            },
            else => return error.UnexpectedOperation,
        }
        return .{ .code = 0, .output = "changed" };
    }
};

test "host utility defaults to actual SSH login account and converges to a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var first: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), .{}, &first);
    try std.testing.expectEqualStrings("sshuser", first.target.?.name);
    try std.testing.expectEqualStrings("/srv/users/sshuser", first.target.?.home);
    try std.testing.expectEqual(@as(u32, 1001), first.target.?.uid);
    try std.testing.expect(first.zsh_changed and first.omz_changed and first.zshrc_changed);
    try std.testing.expectEqual(@as(usize, 3), first.changes);
    try std.testing.expectEqualStrings("/bin/bash", fake.login_shell);
    try std.testing.expectEqualStrings("/bin/bash", first.target.?.shell);
    try std.testing.expectEqualStrings("/usr/bin/zsh", first.zsh_path);
    try std.testing.expectEqualStrings(omz.zshrc_content, fake.rc_bytes);
    var second: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), .{}, &second);
    try std.testing.expectEqual(@as(usize, 0), second.changes);
    try std.testing.expect(!second.zsh_changed and !second.omz_changed and !second.zshrc_changed);
    try std.testing.expectEqual(@as(usize, 3), fake.writes);
    try std.testing.expectEqual(@as(usize, 1), fake.packages);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    try std.testing.expectEqual(@as(usize, 1), fake.source_writes);
    try std.testing.expectEqual(@as(usize, 1), fake.rc_writes);
    try std.testing.expectEqual(@as(usize, 0), fake.shell_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.chsh_calls);
}

test "explicit target uses getent identity and actual home; missing accounts do not mutate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .requested_user = "vasyl", .account_output = "vasyl\n1050\n1051\n/srv/custom-home\n/bin/zsh\n" };
    var report: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), .{ .target_user = "vasyl" }, &report);
    try std.testing.expectEqualStrings("vasyl", report.target.?.name);
    try std.testing.expectEqualStrings("/srv/custom-home", report.target.?.home);
    var missing: Fake = .{ .missing_user = true };
    var failed: omz.Report = .{};
    try std.testing.expectError(error.TargetUserNotFound, omz.install(arena.allocator(), missing.asRemote(), .{ .target_user = "absent" }, &failed));
    try std.testing.expectEqual(@as(usize, 0), missing.writes);
    try std.testing.expectEqual(@as(usize, 0), missing.package_calls);
}

test "existing source, zsh and zshrc remain untouched even when zshrc does not load OMZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const original = "# user's bytes\nexport SPECIAL='hello'\n\x00not even parsed\n";
    var fake: Fake = .{ .zsh = true, .source = .present, .rc = .present, .rc_bytes = original };
    var report: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), .{}, &report);
    try std.testing.expectEqual(@as(usize, 0), fake.writes);
    try std.testing.expectEqual(@as(usize, 0), fake.downloads);
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqualStrings(original, fake.rc_bytes);
    try std.testing.expectEqualStrings("custom theme and branch retained", fake.local_changes);
    try std.testing.expectEqualStrings("/bin/bash", fake.login_shell);
}

test "unsupported distro and all unsafe target paths fail before package mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var unsupported: Fake = .{ .supported = false };
    var report: omz.Report = .{};
    try std.testing.expectError(error.UnsupportedHostDistribution, omz.install(arena.allocator(), unsupported.asRemote(), .{}, &report));
    try std.testing.expectEqual(@as(usize, 0), unsupported.package_calls);
    const cases = [_]struct { fake: Fake, expected: anyerror }{
        .{ .fake = .{ .unsafe_home = true }, .expected = error.UnsafeTargetHome },
        .{ .fake = .{ .source = .conflict }, .expected = error.OhMyZshPathConflict },
        .{ .fake = .{ .source = .symlink }, .expected = error.OhMyZshPathConflict },
        .{ .fake = .{ .rc = .conflict }, .expected = error.UnsafeZshrcPath },
        .{ .fake = .{ .rc = .symlink }, .expected = error.UnsafeZshrcPath },
    };
    for (cases) |case| {
        var fake = case.fake;
        var failed: omz.Report = .{};
        try std.testing.expectError(case.expected, omz.install(arena.allocator(), fake.asRemote(), .{}, &failed));
        try std.testing.expectEqual(@as(usize, 0), fake.package_calls);
        try std.testing.expectEqual(@as(usize, 0), fake.writes);
    }
}

test "interruptions after each committed mutation converge without repeating completed work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]remote.Operation{ .host_packages, .host_source, .host_zshrc }) |op| {
        var fake: Fake = .{ .fail_after = op };
        var first: omz.Report = .{};
        try std.testing.expectError(error.HostOperationFailed, omz.install(arena.allocator(), fake.asRemote(), .{}, &first));
        fake.fail_after = null;
        var retry: omz.Report = .{};
        try omz.install(arena.allocator(), fake.asRemote(), .{}, &retry);
        try std.testing.expectEqual(@as(usize, 1), fake.packages);
        try std.testing.expectEqual(@as(usize, 1), fake.downloads);
        try std.testing.expectEqual(@as(usize, 1), fake.source_writes);
        try std.testing.expectEqual(@as(usize, 1), fake.rc_writes);
        var third: omz.Report = .{};
        try omz.install(arena.allocator(), fake.asRemote(), .{}, &third);
        try std.testing.expectEqual(@as(usize, 0), third.changes);
    }
}

test "interrupted private download never becomes final source and unrelated temp data survives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .interrupted_download = true };
    var first: omz.Report = .{};
    try std.testing.expectError(error.HostOperationFailed, omz.install(arena.allocator(), fake.asRemote(), .{}, &first));
    try std.testing.expectEqual(PathState.absent, fake.source);
    try std.testing.expectEqual(@as(usize, 0), fake.rc_writes);
    fake.interrupted_download = false;
    var retry: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), .{}, &retry);
    try std.testing.expectEqual(@as(usize, 1), fake.source_writes);
    try std.testing.expectEqual(@as(usize, 1), fake.packages);
    try std.testing.expectEqualStrings("unrelated user data", fake.unrelated_temp_bytes);
    // SIGKILL can leave a private staging directory; it is never adopted or
    // recursively purged by a future run. Fresh private staging safely recovers.
    try std.testing.expect(fake.abandoned_private_stage);
}

test "account response validation excludes terminal escapes traversal and executable shell text" {
    const invalid = [_][]const u8{
        "-option\n0\n0\n/root\n/bin/bash\n",
        "root\nnot-an-id\n0\n/root\n/bin/bash\n",
        "root\n0\n0\n/\n/bin/bash\n",
        "root\n0\n0\n/home/../root\n/bin/bash\n",
        "root\n0\n0\n/home/$(touch marker)\n/bin/bash\n",
        "root\n0\n0\n/root\n/bin/bash\x1b[31m\n",
        "root\n0\n0\n/root\n/bin/bash\nextra\n",
    };
    for (invalid) |value| try std.testing.expectError(error.InvalidHostAccount, omz.parseAccount(value));
    const root = try omz.parseAccount("root\n0\n0\n/root\n/bin/bash\n");
    try std.testing.expectEqualStrings("/root", root.home);
    try std.testing.expectEqual(@as(u32, 0), root.uid);
}

test "home scripts are valid POSIX shell and never execute downloaded or existing user code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ omz.home_preflight, omz.packages_script, omz.source_script, try omz.zshrcScript(arena.allocator(), false), omz.verify_script }) |script| {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "--proto '=https'") != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, omz.archive_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "sha256sum --check --status").? < std.mem.indexOf(u8, omz.source_script, "tar --extract").?);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "mv -T -n") != null);
    try std.testing.expect(std.mem.indexOf(u8, try omz.zshrcScript(arena.allocator(), false), "ln -T") != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "chsh") == null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "tools/install.sh") == null);
}

test "default shell is opt-in and a second install never calls chsh again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    var normal: omz.Report = .{};
    try omz.install(a, fake.asRemote(), .{}, &normal);
    try std.testing.expectEqualStrings("/bin/bash", fake.login_shell);
    try std.testing.expectEqual(@as(usize, 0), fake.shell_calls);
    var changed: omz.Report = .{};
    try omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &changed);
    try std.testing.expect(changed.shell_changed and changed.shell_requested);
    try std.testing.expectEqualStrings("/bin/bash", changed.original_shell);
    try std.testing.expectEqualStrings("/usr/bin/zsh", changed.target.?.shell);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.shell_verifications);
    try std.testing.expectEqual(@as(usize, 1), changed.changes);
    const writes = fake.writes;
    var again: omz.Report = .{};
    try omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &again);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(writes, fake.writes);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
    try std.testing.expect(!again.shell_changed);
}

test "login shell failures remain explicit and an interrupted chsh converges from actual state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .zsh = true, .source = .present, .rc = .present, .rc_bytes = zshrc.content, .shell_listed = false };
    var unlisted: omz.Report = .{};
    try std.testing.expectError(error.ZshNotListedInEtcShells, omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &unlisted));
    try std.testing.expectEqual(@as(usize, 0), fake.chsh_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.writes);
    fake.shell_listed = true;
    fake.fail_after = .host_shell;
    var interrupted: omz.Report = .{};
    try std.testing.expectError(error.SshConnectionFailed, omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &interrupted));
    try std.testing.expectEqual(omz.Phase.login_shell, interrupted.phase);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
    fake.fail_after = null;
    fake.shell_verify_failure = true;
    var failed_verify: omz.Report = .{};
    try std.testing.expectError(error.LoginShellVerificationFailed, omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &failed_verify));
    try std.testing.expectEqual(omz.Phase.verify, failed_verify.phase);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
    fake.shell_verify_failure = false;
    var recovered: omz.Report = .{};
    try omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &recovered);
    try std.testing.expectEqual(@as(usize, 0), recovered.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
}

test "recognized prior template migrates only explicitly and then becomes a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ zshrc.legacy_content, zshrc.legacy_v1_content }) |prior| {
        var fake: Fake = .{ .zsh = true, .source = .present, .rc = .present, .rc_bytes = prior };
        var normal: omz.Report = .{};
        try omz.install(a, fake.asRemote(), .{}, &normal);
        try std.testing.expectEqual(omz.ZshrcStatus.recognized_old, normal.zshrc_status);
        try std.testing.expectEqualStrings(prior, fake.rc_bytes);
        try std.testing.expectEqual(@as(usize, 0), fake.writes);
        var migrated: omz.Report = .{};
        try omz.install(a, fake.asRemote(), .{ .update_managed_zshrc = true }, &migrated);
        try std.testing.expectEqual(omz.ZshrcStatus.updated, migrated.zshrc_status);
        try std.testing.expectEqualStrings(zshrc.content, fake.rc_bytes);
        try std.testing.expectEqual(@as(usize, 1), migrated.changes);
        var again: omz.Report = .{};
        try omz.install(a, fake.asRemote(), .{ .update_managed_zshrc = true }, &again);
        try std.testing.expectEqual(@as(usize, 0), again.changes);
        try std.testing.expectEqual(@as(usize, 1), fake.rc_writes);
        try std.testing.expectEqual(@as(usize, 0), fake.chsh_calls);
    }
}

test "default shell follows the discovered path and preserves the original account shell in its report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .zsh = true, .zsh_path = "/usr/local/bin/zsh", .source = .present, .rc = .present, .rc_bytes = zshrc.content };
    var first: omz.Report = .{};
    try omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &first);
    try std.testing.expectEqualStrings("/usr/local/bin/zsh", fake.login_shell);
    try std.testing.expectEqualStrings("/usr/local/bin/zsh", first.zsh_path);
    try std.testing.expectEqualStrings("/usr/local/bin/zsh", first.target.?.shell);
    try std.testing.expectEqualStrings("/bin/bash", first.original_shell);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
    var again: omz.Report = .{};
    try omz.install(a, fake.asRemote(), .{ .set_default_shell = true }, &again);
    try std.testing.expectEqualStrings("/usr/local/bin/zsh", again.original_shell);
    try std.testing.expectEqual(@as(usize, 0), again.changes);
    try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
}

test "failed chsh preserves arbitrary and current zshrc bytes through recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "# arbitrary configuration\nexport CUSTOM='untouched'\n\x00\xff", zshrc.content }) |original| {
        var fake: Fake = .{ .zsh = true, .source = .present, .rc = .present, .rc_bytes = original, .chsh_failure = true };
        var failed: omz.Report = .{};
        const options: omz.InstallOptions = .{ .set_default_shell = true, .update_managed_zshrc = true };
        try std.testing.expectError(error.LoginShellChangeFailed, omz.install(a, fake.asRemote(), options, &failed));
        try std.testing.expectEqual(omz.Phase.login_shell, failed.phase);
        try std.testing.expectEqualStrings("/bin/bash", fake.login_shell);
        try std.testing.expectEqualStrings(original, fake.rc_bytes);
        try std.testing.expectEqual(@as(usize, 0), fake.rc_writes);
        try std.testing.expectEqual(@as(usize, 0), fake.writes);
        try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
        fake.chsh_failure = false;
        var recovered: omz.Report = .{};
        try omz.install(a, fake.asRemote(), options, &recovered);
        try std.testing.expectEqualStrings(original, fake.rc_bytes);
        try std.testing.expectEqual(@as(usize, 0), fake.rc_writes);
        try std.testing.expectEqual(@as(usize, 1), recovered.changes);
        var again: omz.Report = .{};
        try omz.install(a, fake.asRemote(), options, &again);
        try std.testing.expectEqualStrings(original, fake.rc_bytes);
        try std.testing.expectEqual(@as(usize, 0), again.changes);
        try std.testing.expectEqual(@as(usize, 2), fake.chsh_calls);
    }
}

test "both explicit flags preserve arbitrary and edited managed zshrc bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "# private user content\n\x00\xff", zshrc.content ++ "# my own edits\n" }) |original| {
        var fake: Fake = .{ .zsh = true, .source = .present, .rc = .present, .rc_bytes = original };
        var report: omz.Report = .{};
        try omz.install(a, fake.asRemote(), .{ .set_default_shell = true, .update_managed_zshrc = true }, &report);
        try std.testing.expectEqualStrings(original, fake.rc_bytes);
        try std.testing.expectEqual(@as(usize, 0), fake.rc_writes);
        try std.testing.expectEqual(@as(usize, 1), fake.chsh_calls);
        try std.testing.expect(!report.zshrc_changed);
    }
}
