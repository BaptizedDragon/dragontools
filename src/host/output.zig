//! Local, command-specific presentation; no SSH or credential resolution.
const std = @import("std");
const Options = @import("../cli/parse.zig").Options;
const host = @import("oh_my_zsh.zig");
const remote = @import("../system/remote.zig");

pub fn plan(a: std.mem.Allocator, options: Options) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\Host personalization plan (local; SSH not attempted).
        \\Connection: {s}
        \\Target: {s}; actual home comes from the remote account database.
        \\Would ensure:
        \\  zsh installed, using noninteractive apt only when missing on Ubuntu/Debian.
        \\  Oh My Zsh installed only if absent, from reviewed commit {s}.
        \\  A minimal .zshrc created only if absent; existing .zshrc preserved.
        \\Would not:
        \\  Change the login shell, create users, or update existing Oh My Zsh.
        \\  Overwrite existing .zshrc or modify monitoring services.
        \\Actual state, prerequisites, and privileges are checked during installation.
        \\
    , .{
        if (options.ssh_host != null) "OpenSSH configuration alias" else "explicit direct SSH",
        if (options.target_user != null) "explicit target account (resolved on remote host)" else "SSH login user (resolved on remote host)",
        host.revision,
    });
}

pub fn result(a: std.mem.Allocator, report: host.Report) ![]const u8 {
    const target = report.target orelse return error.MissingHostReport;
    const shell_hint = if (std.mem.eql(u8, std.fs.path.basename(target.shell), "zsh"))
        ""
    else
        try std.fmt.allocPrint(a, "To make zsh the login shell, run manually on the host:\n  {s}\n", .{try remote.shell(a, &.{ "chsh", "-s", report.zsh_path, target.name })});
    return std.fmt.allocPrint(a, "zsh {s}.\nOh My Zsh {s} for {s}.\n{s}\nCurrent login shell: {s}\n{s}{s}", .{
        if (report.zsh_changed) "installed" else "already installed",
        if (report.omz_changed) "installed" else "already present",
        target.name,
        if (report.zshrc_changed) ".zshrc created." else "Existing .zshrc preserved. Configure it manually if needed.",
        target.shell,
        shell_hint,
        if (report.changes == 0) "\nNo changes required.\n" else "",
    });
}

test "host plan stays local and does not invent a resolved alias user or home" {
    const a = std.testing.allocator;
    const text = try plan(a, .{ .ssh_host = "private-alias" });
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "SSH login user (resolved on remote host)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "private-alias") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/root") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "No changes required.") == null);
    const explicit = try plan(a, .{ .host = "private-host", .target_user = "private-user" });
    defer a.free(explicit);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "explicit target account") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "private-user") == null);
}

test "host output distinguishes preserved files and no-op from confirmed changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: host.Report = .{
        .target = .{ .name = "ops", .home = "/srv/ops", .shell = "/bin/bash", .uid = 1000, .gid = 1000 },
        .zsh_path = "/usr/bin/zsh",
    };
    const unchanged = try result(a, report);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Oh My Zsh already present for ops.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Existing .zshrc preserved.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "No changes required.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "'chsh' '-s' '/usr/bin/zsh' 'ops'") != null);
    report.changes = 3;
    report.zsh_changed = true;
    report.omz_changed = true;
    report.zshrc_changed = true;
    report.target.?.shell = "/usr/bin/zsh";
    const changed = try result(a, report);
    try std.testing.expect(std.mem.indexOf(u8, changed, "zsh installed.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "Oh My Zsh installed for ops.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, ".zshrc created.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "No changes required.") == null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "chsh") == null);
}
