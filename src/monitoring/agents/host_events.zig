//! Dedicated observer timer; installation is application-host owned.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const files = @import("../../system/files.zig");
const ready = @import("../readiness.zig");
const common = @import("common.zig");
const model = @import("model.zig");
const helper = @import("helper.zig");
const Arch = @import("../../system/host.zig").Arch;
pub const service = @embedFile("host-events.service");
pub const timer = @embedFile("host-events.timer");
pub const pending = "/var/lib/dragontools/host-events-restart-required";
pub const account =
    \\set -eu
    \\if getent passwd dt-host-events >/dev/null; then
    \\  test "$(getent passwd dt-host-events | cut -d: -f6)" = /var/lib/dragontools/host-events
    \\  test "$(getent passwd dt-host-events | cut -d: -f7)" = /usr/sbin/nologin
    \\  test "$(id -u dt-host-events)" -ne 0
    \\  test "$(id -gn dt-host-events)" = dt-host-events
    \\  test "$(id -nG dt-host-events)" = dt-host-events
    \\  printf unchanged
    \\else
    \\  getent group dt-host-events >/dev/null && exit 41
    \\  useradd --system --user-group --home-dir /var/lib/dragontools/host-events --no-create-home --shell /usr/sbin/nologin dt-host-events
    \\  printf changed
    \\fi
;
pub const directories =
    \\set -eu
    \\for unit in dragontools-host-events.service dragontools-host-events.timer; do
    \\  case "$unit" in *.service) refused=203;; *.timer) refused=204;; esac
    \\  test -z "$(systemctl show -p DropInPaths --value "$unit")" || exit "$refused"
    \\  path=/etc/systemd/system/$unit
    \\  test ! -L "$path" || exit "$refused"
    \\  if test -e "$path"; then test -f "$path" && test "$(stat -c '%u:%g:%h:%a' "$path")" = 0:0:1:644 || exit "$refused"; fi
    \\done
    \\path=/var/lib/dragontools/host-events-restart-required
    \\test ! -L "$path" || exit 208
    \\if test -e "$path"; then test -f "$path" && test "$(stat -c '%u:%g:%h' "$path")" = 0:0:1 || exit 208; fi
    \\for path in /var/lib/dragontools /var/lib/dragontools/host-events; do test ! -L "$path"; done
    \\test "$(stat -c '%U:%G:%a' /var/lib/dragontools)" = root:root:755
    \\path=/var/lib/dragontools/host-events
    \\if test -e "$path"; then
    \\  test -d "$path" && test "$(stat -c '%U:%G:%a' "$path")" = dt-host-events:dt-host-events:700
    \\  printf unchanged
    \\else install -d -o dt-host-events -g dt-host-events -m 700 "$path"; printf changed; fi
;
pub const activate =
    \\set -eu
    \\changed=0
    \\for unit in dragontools-host-events.service dragontools-host-events.timer; do
    \\  case "$unit" in *.service) refused=203;; *.timer) refused=204;; esac
    \\  test -z "$(systemctl show -p DropInPaths --value "$unit")" || exit "$refused"
    \\  if test "$(systemctl show -p NeedDaemonReload --value "$unit")" = yes; then systemctl daemon-reload || exit "$refused"; changed=1; fi
    \\done
    \\if test -f /var/lib/dragontools/host-events-restart-required; then
    \\  systemctl start dragontools-host-events.service || exit 207
    \\  systemctl restart dragontools-host-events.timer || exit 206
    \\  changed=1
    \\fi
    \\if ! systemctl is-enabled --quiet dragontools-host-events.timer; then systemctl enable dragontools-host-events.timer >/dev/null 2>&1 || exit 205; changed=1; fi
    \\if ! systemctl is-active --quiet dragontools-host-events.timer; then systemctl start dragontools-host-events.timer || exit 206; changed=1; fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;
// The script/checker protocol contains only these fixed semantic exit codes.
// No command, helper output or remote stderr is forwarded to the user.
const failures = [_]ready.Check{
    .host_events_account,      .host_events_helper,     .host_events_state_directory,
    .host_events_service_unit, .host_events_timer_unit, .host_events_timer_enabled,
    .host_events_timer_active, .host_events_last_run,   .host_events_state_safe,
};
fn call(r: remote.Remote, report: *model.Report, op: remote.Operation, check: ready.Check, command: []const u8) ![]const u8 {
    report.state.phase = op;
    report.state.beginRequest(command);
    report.state.check = check;
    if (op == .health) report.state.startVerification();
    const result = try r.run(op, command);
    if (result.code >= 200 and result.code < 200 + failures.len) report.state.check = failures[result.code - 200];
    return report.state.accept(result);
}
pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, arch: Arch) !void {
    report.component = .host_events;
    _ = try call(r, report, .user, .host_events_account, account);
    _ = try call(r, report, .health, .host_events_helper, try helper.inspectCommand(a, arch, true));
    _ = try call(r, report, .directories, .host_events_state_directory, directories);
    _ = try call(r, report, .config, .host_events_service_unit, try files.writeCommand(a, "/etc/systemd/system/dragontools-host-events.service", service, pending));
    _ = try call(r, report, .unit, .host_events_timer_unit, try files.writeCommand(a, "/etc/systemd/system/dragontools-host-events.timer", timer, pending));
    _ = try call(r, report, .activate, .host_events_last_run, activate);
    try verify(a, r, report, arch);
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *model.Report, arch: Arch) !void {
    report.component = .host_events;
    _ = try call(r, report, .health, .host_events_helper, try helper.inspectCommand(a, arch, true));
    const spec = try std.json.Stringify.valueAlloc(a, .{ .service = service, .timer = timer }, .{});
    _ = try call(r, report, .health, .host_events_state_directory, try common.python(a, @embedFile("host_events.py"), &.{ "managed", spec }));
    try ready.poll(a, r, &report.state, .host_events_timer_active, ready.active_ms, try common.python(a, @embedFile("host_events.py"), &.{"timer_active"}), ready.ready);
    try ready.poll(a, r, &report.state, .host_events_last_run, ready.active_ms, try common.python(a, @embedFile("host_events.py"), &.{"last_run"}), ready.ready);
    _ = try call(r, report, .health, .host_events_state_safe, try common.python(a, @embedFile("host_events.py"), &.{"state_safe"}));
}
pub fn finalize(a: std.mem.Allocator, r: remote.Remote, report: *model.Report) !void {
    report.component = .host_events;
    _ = try call(r, report, .finalize, .host_events_state_safe, try remote.shell(a, &.{ "rm", "-f", pending }));
}

test "host events failures map only fixed semantic checks without forwarding remote output" {
    const Fake = struct {
        code: u8,
        calls: usize = 0,
        fn execute(ctx: *anyopaque, _: remote.Operation, _: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return .{ .code = self.code, .output = "PRIVATE-DIAGNOSTIC-SENTINEL" };
        }
    };
    for (failures, 0..) |expected, index| {
        var fake: Fake = .{ .code = @intCast(200 + index) };
        var report: model.Report = .{};
        const r: remote.Remote = .{ .context = &fake, .execute = Fake.execute };
        try std.testing.expectError(error.RemoteOperationFailed, call(r, &report, .activate, .host_events_last_run, "fixed fixture"));
        try std.testing.expectEqual(expected, report.state.check.?);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expect(report.state.agent_diagnostic == null);
        try std.testing.expectEqualStrings("", try report.state.credentialDiagnostics(std.testing.allocator));
    }
}
