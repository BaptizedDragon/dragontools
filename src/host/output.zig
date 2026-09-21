//! Local, command-specific presentation; no SSH or credential resolution.
const std = @import("std");
const Options = @import("../cli/parse.zig").Options;
const host = @import("oh_my_zsh.zig");

pub fn plan(a: std.mem.Allocator, options: Options) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\Host personalization plan (local; SSH not attempted).
        \\Connection: {s}
        \\Target: {s}; actual home comes from the remote account database.
        \\Would ensure:
        \\  zsh installed, using noninteractive apt only when missing on Ubuntu/Debian.
        \\  Oh My Zsh installed only if absent, from reviewed commit {s}.
        \\  New .zshrc files use a marked user@hostname directory prompt, Oh My Zsh, and git plugin.
        \\  {s}
        \\  {s}
        \\Would not:
        \\  Create users, update existing Oh My Zsh, or modify monitoring services.
        \\  Replace arbitrary or edited .zshrc files.
        \\Actual state, prerequisites, and privileges are checked during installation.
        \\
    , .{
        if (options.ssh_host != null) "OpenSSH configuration alias" else "explicit direct SSH",
        if (options.target_user != null) "explicit target account (resolved on remote host)" else "SSH login user (resolved on remote host)",
        host.revision,
        if (options.update_managed_zshrc) ".zshrc: update only an exact known DragonTools template; preserve arbitrary or edited files." else ".zshrc: create only if absent; preserve existing files (no --update-managed-zshrc).",
        if (options.set_default_shell) "Login shell: set to discovered zsh only if different and listed in /etc/shells." else "Login shell: unchanged (no --set-default-shell).",
    });
}

pub fn result(a: std.mem.Allocator, report: host.Report) ![]const u8 {
    const target = report.target orelse return error.MissingHostReport;
    const shell_result = if (report.shell_changed)
        try std.fmt.allocPrint(a, "Login shell changed: {s} -> {s}.\nReconnect for the new login shell to take effect.\n", .{ report.original_shell, target.shell })
    else if (report.shell_requested)
        try std.fmt.allocPrint(a, "Login shell already {s}.\n", .{target.shell})
    else
        try std.fmt.allocPrint(a, "Current login shell: {s}\n", .{target.shell});
    defer a.free(shell_result);
    const shell_hint = if (!report.shell_requested and !std.mem.eql(u8, target.shell, report.zsh_path))
        "Use --set-default-shell to opt in to changing the login shell; the discovered zsh must be listed in /etc/shells.\n"
    else
        "";
    const rc_result = switch (report.zshrc_status) {
        .created => ".zshrc created. Prompt includes user, hostname, and current directory.",
        .updated => ".zshrc updated from a recognized DragonTools template. Prompt includes user, hostname, and current directory.",
        .current => ".zshrc already matches the DragonTools template.",
        .recognized_old => "Previous DragonTools .zshrc preserved. Use --update-managed-zshrc to migrate the exact previous template.",
        .modified_managed => "Edited or unrecognized marked .zshrc preserved. To adopt the generated configuration, back up and move the file aside manually, then rerun.",
        .preserved => "Existing .zshrc preserved. To adopt the generated configuration, back up and move the file aside manually, then rerun.",
    };
    return std.fmt.allocPrint(a, "zsh {s}.\nOh My Zsh {s} for {s}.\n{s}\n{s}{s}{s}", .{
        if (report.zsh_changed) "installed" else "already installed",
        if (report.omz_changed) "installed" else "already present",
        target.name,
        rc_result,
        shell_result,
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
        .original_shell = "/bin/bash",
    };
    const unchanged = try result(a, report);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Oh My Zsh already present for ops.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Existing .zshrc preserved.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "No changes required.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Use --set-default-shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Prompt includes") == null);
    try std.testing.expect(std.mem.indexOf(u8, unchanged, "Reconnect") == null);
    report.changes = 4;
    report.zsh_changed = true;
    report.omz_changed = true;
    report.zshrc_changed = true;
    report.zshrc_status = .created;
    report.shell_requested = true;
    report.shell_changed = true;
    report.target.?.shell = "/usr/bin/zsh";
    const changed = try result(a, report);
    try std.testing.expect(std.mem.indexOf(u8, changed, "zsh installed.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "Oh My Zsh installed for ops.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, ".zshrc created.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "No changes required.") == null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "chsh") == null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "Login shell changed: /bin/bash -> /usr/bin/zsh.") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "Reconnect for the new login shell to take effect.") != null);
}

test "host plan and preserved-file guidance reflect explicit mutation choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = try plan(a, .{ .ssh_host = "example" });
    try std.testing.expect(std.mem.indexOf(u8, defaults, "Login shell: unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, defaults, "create only if absent") != null);
    const explicit = try plan(a, .{ .ssh_host = "example", .set_default_shell = true, .update_managed_zshrc = true });
    try std.testing.expect(std.mem.indexOf(u8, explicit, "only if different and listed in /etc/shells") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "update only an exact known DragonTools template") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "Login shell: unchanged") == null);
    var report: host.Report = .{ .target = .{ .name = "ops", .home = "/srv/ops", .uid = 1000, .gid = 1000, .shell = "/usr/bin/zsh" }, .zsh_path = "/usr/bin/zsh", .shell_requested = true, .zshrc_status = .recognized_old };
    const old = try result(a, report);
    try std.testing.expect(std.mem.indexOf(u8, old, "Use --update-managed-zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, old, "Login shell already /usr/bin/zsh.") != null);
    try std.testing.expect(std.mem.indexOf(u8, old, "Reconnect") == null);
    report.zshrc_status = .modified_managed;
    const edited = try result(a, report);
    try std.testing.expect(std.mem.indexOf(u8, edited, "back up and move the file aside manually") != null);
}
