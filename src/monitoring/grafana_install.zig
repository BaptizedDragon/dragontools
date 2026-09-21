//! Concrete fourth-component workflow. It never activates another service.
const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const workflow = @import("install.zig");
const grafana = @import("../components/grafana.zig");
const config = @import("../components/grafana_config.zig");
const unit = @import("../components/grafana_unit.zig");
const files = @import("../system/files.zig");

// Refuse foreign configuration before creating the account or changing metadata.
// Python is limited to standard-library artifact/SQLite inspection; credentials
// are never passed through these helpers or through the ordinary file writer.
pub const preflight =
    \\set -eu
    \\for tool in python3 runuser; do command -v "$tool" >/dev/null || exit 12; done
    \\python3 -I -B -c 'import sqlite3, hashlib, tarfile, ctypes' || exit 12
    \\unit=/etc/systemd/system/dragontools-grafana.service
    \\pending=/var/lib/dragontools/grafana-restart-required
    \\test ! -L "$unit" && test ! -L "$pending" || exit 43
    \\if test -e "$unit"; then test -f "$unit" && grep -qx '# Managed by DragonTools' "$unit" || exit 40; fi
    \\if test -e "$pending"; then test -f "$pending" && test "$(stat -c '%u:%g' "$pending")" = 0:0 || exit 40; fi
    \\dropins=$(systemctl show -p DropInPaths --value dragontools-grafana.service)
    \\test -z "$dropins" || exit 42
    \\for dir in /etc/dragontools /etc/dragontools/grafana /etc/dragontools/grafana/provisioning /etc/dragontools/grafana/provisioning/datasources /etc/dragontools/grafana/provisioning/dashboards /var/lib/dragontools/grafana; do
    \\  test ! -L "$dir" || exit 43
    \\  test ! -e "$dir" || test -d "$dir" || exit 40
    \\done
    \\for path in /etc/dragontools/grafana/grafana.ini /etc/dragontools/grafana/provisioning/datasources/dragontools.yaml; do
    \\  test ! -L "$path" || exit 43
    \\  if test -e "$path"; then test -f "$path" && grep -qx '# Managed by DragonTools' "$path" || exit 40; fi
    \\done
    \\# Only the selected deterministic provisioning is loaded. Preserve and
    \\# refuse unknown files instead of replacing an administrator's setup.
    \\for dir in /etc/dragontools/grafana /etc/dragontools/grafana/provisioning /etc/dragontools/grafana/provisioning/datasources /etc/dragontools/grafana/provisioning/dashboards; do
    \\  test -d "$dir" || continue
    \\  for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    \\    if test ! -e "$path" && test ! -L "$path"; then continue; fi
    \\    case "$path" in
    \\      /etc/dragontools/grafana/grafana.ini|/etc/dragontools/grafana/provisioning|/etc/dragontools/grafana/provisioning/datasources|/etc/dragontools/grafana/provisioning/dashboards|/etc/dragontools/grafana/provisioning/datasources/dragontools.yaml|/etc/dragontools/grafana/provisioning/dashboards/dragontools.yaml|/etc/dragontools/grafana/provisioning/dashboards/dragontools.yaml.next) ;;
    \\      /etc/dragontools/grafana/grafana.ini.??????|/etc/dragontools/grafana/provisioning/datasources/dragontools.yaml.??????)
    \\        # Interrupted adjacent writer files are never loaded, adopted or purged.
    \\        suffix=${path##*.}
    \\        test "${#suffix}" = 6 || exit 40
    \\        case "$suffix" in *[!A-Za-z0-9]*) exit 40 ;; esac
    \\        test ! -L "$path" && test -f "$path" && test "$(stat -c '%u:%g' "$path")" = 0:0 || exit 40 ;;
    \\      *) exit 40 ;;
    \\    esac
    \\  done
    \\done
    \\# Never adopt an existing database without our managed configuration.
    \\if test -d /var/lib/dragontools/grafana && test ! -f /etc/dragontools/grafana/grafana.ini; then
    \\  for path in /var/lib/dragontools/grafana/* /var/lib/dragontools/grafana/.[!.]* /var/lib/dragontools/grafana/..?*; do
    \\    if test -e "$path" || test -L "$path"; then exit 40; fi
    \\  done
    \\fi
;

pub const account =
    \\set -eu
    \\if getent passwd dt-grafana >/dev/null; then
    \\  test "$(getent passwd dt-grafana | cut -d: -f7)" = /usr/sbin/nologin || exit 41
    \\  test "$(getent passwd dt-grafana | cut -d: -f6)" = /var/lib/dragontools/grafana || exit 41
    \\  test "$(id -u dt-grafana)" -ne 0 || exit 41
    \\  test "$(id -gn dt-grafana)" = dt-grafana || exit 41
    \\  printf unchanged
    \\else
    \\  getent group dt-grafana >/dev/null && exit 41
    \\  useradd --system --user-group --home-dir /var/lib/dragontools/grafana --no-create-home --shell /usr/sbin/nologin dt-grafana
    \\  printf changed
    \\fi
;

pub const directories =
    \\set -eu
    \\changed=0
    \\for dir in /etc/dragontools /etc/dragontools/grafana /etc/dragontools/grafana/provisioning /etc/dragontools/grafana/provisioning/datasources /etc/dragontools/grafana/provisioning/dashboards; do
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
    \\dir=/var/lib/dragontools/grafana
    \\test ! -L "$dir" || exit 43
    \\if test -e "$dir"; then
    \\  test -d "$dir" || exit 40
    \\  if test "$(stat -c '%u:%g' "$dir")" != "$(id -u dt-grafana):$(id -g dt-grafana)"; then chown dt-grafana:dt-grafana "$dir"; changed=1; fi
    \\  if test "$(stat -c '%a' "$dir")" != 750; then chmod 750 "$dir"; changed=1; fi
    \\else
    \\  install -d -o dt-grafana -g dt-grafana -m 750 "$dir"
    \\  changed=1
    \\fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;

pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch) !void {
    _ = try report.call(r, .user, preflight ++ "\n" ++ account);
    _ = try report.call(r, .directories, directories);
    _ = try report.call(r, .binary, try grafana.binaryCommand(a, arch));
    // Establish managed configuration before creating plugin state in the data
    // directory, so a failed download/publication can pass preflight on retry.
    _ = try report.call(r, .config, try files.writeCommand(a, config.ini_path, config.ini, grafana.pending));
    report.emit(.plugin_inspecting);
    const plugin_result = try report.call(r, .plugin, try @import("../components/grafana_victorialogs_plugin.zig").installCommand(a));
    report.emit(if (std.mem.eql(u8, plugin_result, "changed")) .plugin_installed else .plugin_current);
    const provisioning_result = try report.call(r, .provisioning, try files.writeCommand(a, config.datasources_path, config.datasources, grafana.pending));
    report.emit(if (std.mem.eql(u8, provisioning_result, "changed")) .datasources_updated else .datasources_current);
    if (report.station_enabled) try @import("dashboards/main.zig").station(a, r, report, true);
    _ = try report.call(r, .unit, try files.writeCommand(a, unit.unit_path, try unit.render(a), grafana.pending));
    try @import("grafana_credentials.zig").bootstrap(a, r, report);
    _ = try report.call(r, .activate, workflow.activate_grafana);
    try @import("grafana_verify.zig").health(a, r, report, arch);
    try @import("grafana_credentials.zig").reconcile(a, r, report);
    try @import("grafana_credentials.zig").verifyLogs(a, r, report);
    report.emit(if (report.logs_query_verified) .logs_query_verified else .logs_query_unchecked);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/grafana-restart-required");
}

test {
    _ = @import("grafana_install_tests.zig");
}
