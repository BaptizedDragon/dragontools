//! Dedicated observer timer; installation is application-host owned.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const files = @import("../../system/files.zig");
const ready = @import("../readiness.zig");
const common = @import("common.zig");
const model = @import("model.zig");
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
    \\  test -z "$(systemctl show -p DropInPaths --value "$unit")"
    \\  path=/etc/systemd/system/$unit
    \\  test ! -L "$path"
    \\  if test -e "$path"; then test -f "$path" && test "$(stat -c '%u:%g:%h:%a' "$path")" = 0:0:1:644; fi
    \\done
    \\path=/var/lib/dragontools/host-events-restart-required
    \\test ! -L "$path"
    \\if test -e "$path"; then test -f "$path" && test "$(stat -c '%u:%g:%h' "$path")" = 0:0:1; fi
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
    \\  test -z "$(systemctl show -p DropInPaths --value "$unit")"
    \\  if test "$(systemctl show -p NeedDaemonReload --value "$unit")" = yes; then systemctl daemon-reload; changed=1; fi
    \\done
    \\if test -f /var/lib/dragontools/host-events-restart-required; then
    \\  systemctl start dragontools-host-events.service
    \\  systemctl restart dragontools-host-events.timer
    \\  changed=1
    \\fi
    \\if ! systemctl is-enabled --quiet dragontools-host-events.timer; then systemctl enable dragontools-host-events.timer >/dev/null 2>&1; changed=1; fi
    \\if ! systemctl is-active --quiet dragontools-host-events.timer; then systemctl start dragontools-host-events.timer; changed=1; fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;
pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *model.Report) !void {
    report.component = .host_events;
    _ = try report.call(r, .user, account);
    _ = try report.call(r, .directories, directories);
    _ = try report.call(r, .config, try files.writeCommand(a, "/etc/systemd/system/dragontools-host-events.service", service, pending));
    _ = try report.call(r, .unit, try files.writeCommand(a, "/etc/systemd/system/dragontools-host-events.timer", timer, pending));
    _ = try report.call(r, .activate, activate);
    try verify(a, r, report);
}
pub fn verify(a: std.mem.Allocator, r: remote.Remote, report: *model.Report) !void {
    report.component = .host_events;
    const spec = try std.json.Stringify.valueAlloc(a, .{ .service = service, .timer = timer }, .{});
    _ = try ready.deterministic(a, r, &report.state, .host_events_state, try common.python(a, @embedFile("host_events.py"), &.{ "managed", spec }));
    try ready.poll(a, r, &report.state, .host_events_ready, ready.active_ms, try common.python(a, @embedFile("host_events.py"), &.{ "ready", spec }), ready.ready);
}
pub fn finalize(a: std.mem.Allocator, r: remote.Remote, report: *model.Report) !void {
    report.component = .host_events;
    _ = try report.call(r, .finalize, try remote.shell(a, &.{ "rm", "-f", pending }));
}
