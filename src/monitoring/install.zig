const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const fs = @import("../system/filesystem.zig");
const vm = @import("../components/victoriametrics.zig");
const vl = @import("../components/victorialogs.zig");
const vt = @import("../components/victoriatraces.zig");
const units = @import("../system/systemd.zig");
const vl_unit = @import("../components/victorialogs_unit.zig");
const vt_unit = @import("../components/victoriatraces_unit.zig");
pub const Component = enum {
    victoriametrics,
    victorialogs,
    victoriatraces,
    grafana,

    pub fn name(self: Component) []const u8 {
        return switch (self) {
            .victoriametrics => "VictoriaMetrics",
            .victorialogs => "VictoriaLogs",
            .victoriatraces => "VictoriaTraces",
            .grafana => "Grafana",
        };
    }
};
pub const Report = struct {
    phase: remote.Operation = .detect,
    check: ?@import("readiness.zig").Check = null,
    component: ?Component = null,
    changes: usize = 0,
    reserve_bytes: u64 = 0,
    completed: usize = 0,
    pub fn call(self: *Report, r: remote.Remote, op: remote.Operation, command: []const u8) ![]const u8 {
        self.phase = op;
        if (op != .health) self.check = null;
        const result = try r.run(op, command);
        return self.accept(result);
    }
    pub fn accept(self: *Report, result: remote.Result) ![]const u8 {
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
// These helpers instantiate only the concrete managed component paths.
// Existing directories receive only the metadata change they actually need.
const parent_directories =
    \\set -eu
    \\changed=0
    \\for dir in /var/lib/dragontools /opt/dragontools /opt/dragontools/components; do
    \\  test ! -L "$dir" || exit 43
    \\  if test -e "$dir"; then
    \\    test -d "$dir" || exit 40
    \\    if test "$(stat -c '%u:%g' "$dir")" != 0:0; then chown root:root "$dir"; changed=1; fi
    \\    if test "$(stat -c '%a' "$dir")" != 755; then chmod 755 "$dir"; changed=1; fi
    \\  else
    \\    install -d -o root -g root -m 755 "$dir"
    \\    changed=1
    \\  fi
    \\done
;
fn dataDirectory(comptime component: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\dir=/var/lib/dragontools/{s}; owner=dt-{s}
        \\test ! -L "$dir" || exit 43
        \\if test -e "$dir"; then
        \\  test -d "$dir" || exit 40
        \\  if test "$(stat -c '%u:%g' "$dir")" != "$(id -u "$owner"):$(id -g "$owner")"; then chown "$owner:$owner" "$dir"; changed=1; fi
        \\  if test "$(stat -c '%a' "$dir")" != 750; then chmod 750 "$dir"; changed=1; fi
        \\else
        \\  install -d -o "$owner" -g "$owner" -m 750 "$dir"
        \\  changed=1
        \\fi
        \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
    , .{ component, component });
}
const directories = parent_directories ++ "\n" ++ dataDirectory("victoriametrics");
const victorialogs_directories = "set -eu\nchanged=0\n" ++ dataDirectory("victorialogs");
const victoriatraces_directories = "set -eu\nchanged=0\n" ++ dataDirectory("victoriatraces");

// NeedDaemonReload can be global after enable/disable. It requires a reload,
// never a component restart. Only the component's binary/unit writer records
// restart intent, which survives a reload performed for another component.
fn activation(comptime component: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\set -eu
        \\unit=dragontools-{s}.service; pending=/var/lib/dragontools/{s}-restart-required
        \\changed=0
        \\test ! -L "$pending" || exit 43
        \\if test -e "$pending"; then test -f "$pending" && test "$(stat -c '%u:%g' "$pending")" = 0:0 || exit 40; fi
        \\enabled_now=0
        \\enabled_state=$(systemctl is-enabled "$unit") || {{ test "$enabled_state" = disabled || exit 1; }}
        \\case "$enabled_state" in enabled|disabled|enabled-runtime) ;; *) exit 1 ;; esac
        \\if test "$enabled_state" != enabled; then
        \\  systemctl enable --no-reload "$unit" >/dev/null 2>&1
        \\  enabled_now=1
        \\  changed=1
        \\fi
        \\reload=$(systemctl show -p NeedDaemonReload --value "$unit")
        \\loaded=$(systemctl show -p LoadState --value "$unit")
        \\case "$reload" in yes|no) ;; *) exit 1 ;; esac
        \\if test "$reload" = yes || test "$loaded" = not-found || test "$enabled_now" = 1; then
        \\  systemctl daemon-reload
        \\  changed=1
        \\fi
        \\test "$(systemctl show -p LoadState --value "$unit")" = loaded
        \\if test -e "$pending"; then
        \\  systemctl restart "$unit"
        \\  changed=1
        \\elif ! systemctl is-active --quiet "$unit"; then
        \\  systemctl start "$unit"
        \\  changed=1
        \\fi
        \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
    , .{ component, component });
}
pub const activate = activation("victoriametrics");
pub const activate_victorialogs = activation("victorialogs");
pub const activate_victoriatraces = activation("victoriatraces");
pub const activate_grafana = activation("grafana");
pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *Report) !void {
    report.component = null;
    const machine = try host.parse(try report.call(r, .detect, host.detect_command));
    report.component = .victoriametrics;
    _ = try report.call(r, .user, host.victoriametrics_preflight ++ "\n" ++ @import("../system/users.zig").ensure_victoriametrics);
    _ = try report.call(r, .directories, directories);
    report.reserve_bytes = try fs.reserve(try fs.capacity(try report.call(r, .capacity, capacity_command)));
    _ = try report.call(r, .binary, try vm.binaryCommand(a, machine.arch));
    const unit = try units.render(a, report.reserve_bytes);
    _ = try report.call(r, .unit, try @import("../system/files.zig").writeCommand(a, units.unit_path, unit, vm.pending));
    _ = try report.call(r, .activate, activate);
    try @import("verify.zig").health(a, r, report, machine.arch);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/victoriametrics-restart-required");

    report.component = .victorialogs;
    _ = try report.call(r, .user, host.victorialogs_preflight ++ "\n" ++ @import("../system/users.zig").ensure_victorialogs);
    _ = try report.call(r, .directories, victorialogs_directories);
    _ = try report.call(r, .binary, try vl.binaryCommand(a, machine.arch));
    _ = try report.call(r, .unit, try @import("../system/files.zig").writeCommand(a, vl_unit.unit_path, try vl_unit.render(a), vl.pending));
    _ = try report.call(r, .activate, activate_victorialogs);
    try @import("victorialogs_verify.zig").health(a, r, report, machine.arch);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/victorialogs-restart-required");

    report.component = .victoriatraces;
    _ = try report.call(r, .user, host.victoriatraces_preflight ++ "\n" ++ @import("../system/users.zig").ensure_victoriatraces);
    _ = try report.call(r, .directories, victoriatraces_directories);
    _ = try report.call(r, .binary, try vt.binaryCommand(a, machine.arch));
    _ = try report.call(r, .unit, try @import("../system/files.zig").writeCommand(a, vt_unit.unit_path, try vt_unit.render(a), vt.pending));
    _ = try report.call(r, .activate, activate_victoriatraces);
    try @import("victoriatraces_verify.zig").health(a, r, report, machine.arch);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/victoriatraces-restart-required");

    report.component = .grafana;
    try @import("grafana_install.zig").install(a, r, report, machine.arch);
}
