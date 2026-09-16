const std = @import("std");
const remote = @import("../system/remote.zig");
const omz = @import("oh_my_zsh.zig");

const PathState = enum { absent, present, conflict, symlink };
// This models only this concrete workflow's persisted state. It does not execute
// apt or pretend to be a Linux host; shell filesystem tests are separate.
const Fake = struct {
    account_output: []const u8 = "sshuser\n1001\n1002\n/srv/users/sshuser\n/bin/bash\n",
    supported: bool = true,
    missing_user: bool = false,
    unsafe_home: bool = false,
    zsh: bool = false,
    source: PathState = .absent,
    rc: PathState = .absent,
    rc_bytes: []const u8 = "",
    local_changes: []const u8 = "custom theme and branch retained",
    login_shell: []const u8 = "/bin/bash",
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
                    return .{ .code = 0, .output = self.account_output };
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
                if (self.rc == .present) return .{ .code = 0, .output = "unchanged" };
                self.rc = .present;
                self.rc_bytes = omz.zshrc_content;
                self.rc_writes += 1;
                self.writes += 1;
                if (self.fail_after == op) return .{ .code = 1 };
            },
            .host_verify => {
                if (!self.zsh or self.source != .present or self.rc != .present) return .{ .code = 1 };
                return .{ .code = 0, .output = "/usr/bin/zsh\n" };
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
    try omz.install(arena.allocator(), fake.asRemote(), null, &first);
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
    try omz.install(arena.allocator(), fake.asRemote(), null, &second);
    try std.testing.expectEqual(@as(usize, 0), second.changes);
    try std.testing.expect(!second.zsh_changed and !second.omz_changed and !second.zshrc_changed);
    try std.testing.expectEqual(@as(usize, 3), fake.writes);
    try std.testing.expectEqual(@as(usize, 1), fake.packages);
    try std.testing.expectEqual(@as(usize, 1), fake.downloads);
    try std.testing.expectEqual(@as(usize, 1), fake.source_writes);
    try std.testing.expectEqual(@as(usize, 1), fake.rc_writes);
}

test "explicit target uses getent identity and actual home; missing accounts do not mutate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .requested_user = "vasyl", .account_output = "vasyl\n1050\n1051\n/srv/custom-home\n/bin/zsh\n" };
    var report: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), "vasyl", &report);
    try std.testing.expectEqualStrings("vasyl", report.target.?.name);
    try std.testing.expectEqualStrings("/srv/custom-home", report.target.?.home);
    var missing: Fake = .{ .missing_user = true };
    var failed: omz.Report = .{};
    try std.testing.expectError(error.TargetUserNotFound, omz.install(arena.allocator(), missing.asRemote(), "absent", &failed));
    try std.testing.expectEqual(@as(usize, 0), missing.writes);
    try std.testing.expectEqual(@as(usize, 0), missing.package_calls);
}

test "existing source, zsh and zshrc remain untouched even when zshrc does not load OMZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const original = "# user's bytes\nexport SPECIAL='hello'\n\x00not even parsed\n";
    var fake: Fake = .{ .zsh = true, .source = .present, .rc = .present, .rc_bytes = original };
    var report: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), null, &report);
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
    try std.testing.expectError(error.UnsupportedHostDistribution, omz.install(arena.allocator(), unsupported.asRemote(), null, &report));
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
        try std.testing.expectError(case.expected, omz.install(arena.allocator(), fake.asRemote(), null, &failed));
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
        try std.testing.expectError(error.HostOperationFailed, omz.install(arena.allocator(), fake.asRemote(), null, &first));
        fake.fail_after = null;
        var retry: omz.Report = .{};
        try omz.install(arena.allocator(), fake.asRemote(), null, &retry);
        try std.testing.expectEqual(@as(usize, 1), fake.packages);
        try std.testing.expectEqual(@as(usize, 1), fake.downloads);
        try std.testing.expectEqual(@as(usize, 1), fake.source_writes);
        try std.testing.expectEqual(@as(usize, 1), fake.rc_writes);
        var third: omz.Report = .{};
        try omz.install(arena.allocator(), fake.asRemote(), null, &third);
        try std.testing.expectEqual(@as(usize, 0), third.changes);
    }
}

test "interrupted private download never becomes final source and unrelated temp data survives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{ .interrupted_download = true };
    var first: omz.Report = .{};
    try std.testing.expectError(error.HostOperationFailed, omz.install(arena.allocator(), fake.asRemote(), null, &first));
    try std.testing.expectEqual(PathState.absent, fake.source);
    try std.testing.expectEqual(@as(usize, 0), fake.rc_writes);
    fake.interrupted_download = false;
    var retry: omz.Report = .{};
    try omz.install(arena.allocator(), fake.asRemote(), null, &retry);
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
    for ([_][]const u8{ omz.home_preflight, omz.packages_script, omz.source_script, omz.zshrc_script, omz.verify_script }) |script| {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "--proto '=https'") != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, omz.archive_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "sha256sum --check --status").? < std.mem.indexOf(u8, omz.source_script, "tar --extract").?);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "mv -T -n") != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.zshrc_script, "ln -T") != null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "chsh") == null);
    try std.testing.expect(std.mem.indexOf(u8, omz.source_script, "tools/install.sh") == null);
}
