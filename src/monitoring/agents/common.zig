//! Concrete shared lifecycle fragments for the agents, Caddy and private ingress authorization.
const std = @import("std");
const remote = @import("../../system/remote.zig");
pub const Kind = enum { vector, vmagent, ingestion, caddy };
pub fn owner(kind: Kind) []const u8 {
    return if (kind == .caddy) "dt-caddy" else if (kind == .ingestion) "dt-ingest" else if (kind == .vector) "dt-vector" else "dt-vmagent";
}
pub fn serviceName(kind: Kind) []const u8 {
    return if (kind == .ingestion) "ingress-auth" else @tagName(kind);
}
pub fn marker(a: std.mem.Allocator, kind: Kind) ![]const u8 {
    return std.fmt.allocPrint(a, "/var/lib/dragontools/{s}-restart-required", .{serviceName(kind)});
}
pub fn unitPath(a: std.mem.Allocator, kind: Kind) ![]const u8 {
    return std.fmt.allocPrint(a, "/etc/systemd/system/dragontools-{s}.service", .{serviceName(kind)});
}
pub fn preflight(a: std.mem.Allocator, kind: Kind) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                        "-eu",             "-c",
        \\name=$1; user=$2; home=$3
        \\unit=/etc/systemd/system/dragontools-$name.service
        \\test -z "$(systemctl show -p DropInPaths --value dragontools-$name.service)" || exit 42
        \\for path in "$unit" /var/lib/dragontools/$name-restart-required; do
        \\  test ! -L "$path" || exit 43
        \\  if test -e "$path"; then test -f "$path" && test "$(stat -c '%h:%u:%g' "$path")" = 1:0:0 || exit 40; fi
        \\done
        \\if test -f "$unit"; then grep -qx '# Managed by DragonTools' "$unit" || exit 40; fi
        \\if getent passwd "$user" >/dev/null; then
        \\  test "$(getent passwd "$user" | cut -d: -f7)" = /usr/sbin/nologin || exit 41
        \\  test "$(getent passwd "$user" | cut -d: -f6)" = /var/lib/dragontools/$home || exit 41
        \\  test "$(id -u "$user")" -ne 0 && test "$(id -gn "$user")" = "$user" || exit 41
        \\  for group in $(id -nG "$user"); do
        \\    if test "$group" != "$user"; then test "$name:$group" = vector:systemd-journal || exit 41; fi
        \\  done
        \\  printf unchanged
        \\else
        \\  getent group "$user" >/dev/null && exit 41
        \\  useradd --system --user-group --home-dir /var/lib/dragontools/$home --no-create-home --shell /usr/sbin/nologin "$user"
        \\  printf changed
        \\fi
        ,
        "dragontools-agent-account", serviceName(kind), owner(kind),
        @tagName(kind),
    });
}
pub fn directories(a: std.mem.Allocator, kind: Kind) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                            "-eu",          "-c",
        \\name=$1; owner=$2; changed=0
        \\for dir in /opt/dragontools /opt/dragontools/components /var/lib/dragontools /etc/dragontools /etc/dragontools/$name /var/lib/dragontools/$name; do
        \\  user=root; mode=755
        \\  if test "$dir" = /var/lib/dragontools/$name; then user=$owner; mode=750; fi
        \\  test ! -L "$dir" || exit 43
        \\  if test -e "$dir"; then
        \\    test -d "$dir" || exit 40
        \\    if test "$(stat -c '%U:%G' "$dir")" != "$user:$user"; then chown "$user:$user" "$dir"; changed=1; fi
        \\    if test "$(stat -c '%a' "$dir")" != "$mode"; then chmod "$mode" "$dir"; changed=1; fi
        \\  else install -d -o "$user" -g "$user" -m "$mode" "$dir"; changed=1; fi
        \\done
        \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
        ,
        "dragontools-agent-directories", @tagName(kind), owner(kind),
    });
}
pub fn unit(a: std.mem.Allocator, kind: Kind, executable: []const u8) ![]const u8 {
    if (kind == .ingestion) return a.dupe(u8, @import("ingress_units.zig").auth);
    if (kind == .caddy) return a.dupe(u8, @import("ingress_units.zig").caddy);
    return std.fmt.allocPrint(a, "# Managed by DragonTools\n[Unit]\nDescription=DragonTools {s}\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nUser={s}\nGroup={s}\n{s}ExecStart={s}\nRestart=on-failure\nRestartSec=5s\nTimeoutStopSec=60s\nNoNewPrivileges=yes\nPrivateTmp=yes\nPrivateDevices=yes\nProtectHome=yes\nProtectSystem=strict\nProtectKernelTunables=yes\nProtectKernelModules=yes\nProtectControlGroups=yes\nRestrictSUIDSGID=yes\nLockPersonality=yes\nCapabilityBoundingSet=\nAmbientCapabilities=\nRestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\nReadWritePaths={s}\nUMask=0077\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n", .{ @tagName(kind), owner(kind), owner(kind), if (kind == .vector) "SupplementaryGroups=systemd-journal\n" else "", executable, if (kind == .ingestion) "" else if (kind == .vector) "/var/lib/dragontools/vector" else "/var/lib/dragontools/vmagent" });
}
pub fn activation(kind: Kind) []const u8 {
    return switch (kind) {
        .vector => @import("../install.zig").activation("vector"),
        .vmagent => @import("../install.zig").activation("vmagent"),
        .ingestion => @import("../install.zig").activation("ingress-auth"),
        .caddy => @import("../install.zig").activation("caddy"),
    };
}
pub fn finalize(a: std.mem.Allocator, kind: Kind) ![]const u8 {
    return remote.shell(a, &.{ "rm", "-f", try marker(a, kind) });
}
pub fn selectedService(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                           "-eu", "-c",
        \\test "$(systemctl show --property=LoadState --value -- "$1")" = loaded
        \\test "$(systemctl show --property=Id --value -- "$1")" = "$1"
        \\test -z "$(systemctl show --property=LogNamespace --value -- "$1")"
        ,
        "dragontools-selected-journal", name,
    });
}
pub fn python(a: std.mem.Allocator, program: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "python3", "-I", "-B", "-c", program });
    try argv.appendSlice(a, args);
    return remote.shell(a, argv.items);
}
