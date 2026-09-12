const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const fs = @import("../system/filesystem.zig");
const vm = @import("../components/victoriametrics.zig");
const units = @import("../system/systemd.zig");
pub const Report = struct {
    phase: remote.Operation = .detect,
    changes: usize = 0,
    reserve_bytes: u64 = 0,
    completed: usize = 0,
    pub fn call(self: *Report, r: remote.Remote, op: remote.Operation, command: []const u8) ![]const u8 {
        self.phase = op;
        const result = try r.run(op, command);
        switch (result.code) {
            0 => {},
            10 => return error.RootPrivilegesRequired,
            11 => return error.SystemdRequired,
            12 => return error.MissingRemotePrerequisite,
            40 => return error.UnmanagedFileConflict,
            41 => return error.ServiceAccountConflict,
            42 => return error.SystemdDropInConflict,
            43 => return error.UnexpectedManagedSymlink,
            255 => return error.SshConnectionFailed,
            else => return error.RemoteOperationFailed,
        }
        self.completed += 1;
        if (std.mem.eql(u8, result.output, "changed")) self.changes += 1;
        return result.output;
    }
};
pub const capacity_command = "stat -f -c '%b %S' /var/lib/dragontools/victoriametrics";
const directories =
    \\set -eu
    \\changed=0
    \\for dir in /var/lib/dragontools /opt/dragontools /opt/dragontools/components; do
    \\  test ! -L "$dir"
    \\  if test ! -d "$dir" || test "$(stat -c '%u:%g:%a' "$dir")" != 0:0:755; then install -d -o root -g root -m 755 "$dir"; changed=1; fi
    \\done
    \\dir=/var/lib/dragontools/victoriametrics
    \\test ! -L "$dir"
    \\if test ! -d "$dir" || test "$(stat -c '%U:%G:%a' "$dir")" != dt-victoriametrics:dt-victoriametrics:750; then install -d -o dt-victoriametrics -g dt-victoriametrics -m 750 "$dir"; changed=1; fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;
pub const activate =
    \\set -eu
    \\changed=0
    \\if test -e /var/lib/dragontools/victoriametrics-restart-required; then
    \\  systemctl daemon-reload
    \\  systemctl restart dragontools-victoriametrics.service
    \\  changed=1
    \\elif ! systemctl is-active --quiet dragontools-victoriametrics.service; then
    \\  systemctl start dragontools-victoriametrics.service
    \\  changed=1
    \\fi
    \\if ! systemctl is-enabled --quiet dragontools-victoriametrics.service; then systemctl enable dragontools-victoriametrics.service >/dev/null 2>&1; changed=1; fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;
pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *Report) !void {
    const machine = try host.parse(try report.call(r, .detect, host.detect_command));
    _ = try report.call(r, .user, @import("../system/users.zig").ensure_victoriametrics);
    _ = try report.call(r, .directories, directories);
    report.reserve_bytes = try fs.reserve(try fs.capacity(try report.call(r, .capacity, capacity_command)));
    _ = try report.call(r, .binary, try vm.binaryCommand(a, machine.arch));
    const unit = try units.render(a, report.reserve_bytes);
    _ = try report.call(r, .unit, try @import("../system/files.zig").writeCommand(a, units.unit_path, unit, vm.pending));
    _ = try report.call(r, .activate, activate);
    try @import("verify.zig").health(a, r, report, machine.arch);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/victoriametrics-restart-required");
}
