//! Read-only deterministic verification followed by bounded startup readiness checks.
const std = @import("std");
const remote = @import("../system/remote.zig");
const workflow = @import("install.zig");
const host = @import("../system/host.zig");
const bb = @import("../components/blackbox_exporter.zig");
const readiness = @import("readiness.zig");

pub const managed_state =
    \\expected=$1; unit=$2; version=$3; config=$4
    \\check_property() {
    \\  actual=$(systemctl show -p "$1" --value dragontools-blackbox-exporter.service)
    \\  test "$actual" = "$2"
    \\}
    \\check_property FragmentPath /etc/systemd/system/dragontools-blackbox-exporter.service
    \\check_property LoadState loaded
    \\check_property UnitFileState enabled
    \\check_property NeedDaemonReload no
    \\check_property DropInPaths ""
    \\test ! -L /etc/systemd/system/dragontools-blackbox-exporter.service
    \\test -f /etc/systemd/system/dragontools-blackbox-exporter.service
    \\test "$(stat -c '%u:%g:%a' /etc/systemd/system/dragontools-blackbox-exporter.service)" = 0:0:644
    \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-blackbox-exporter.service
    \\check_property User dt-blackbox
    \\check_property Group dt-blackbox
    \\check_property ProtectSystem strict
    \\for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do
    \\  check_property "$property" yes
    \\done
    \\check_property CapabilityBoundingSet ""
    \\check_property AmbientCapabilities ""
    \\check_property ReadWritePaths ""
    \\families=$(systemctl show -p RestrictAddressFamilies --value dragontools-blackbox-exporter.service)
    \\test "$(printf '%s\n' "$families" | tr ' ' '\n' | sort | tr '\n' ' ')" = 'AF_INET AF_INET6 AF_UNIX '
    \\for dir in /opt/dragontools /opt/dragontools/components /opt/dragontools/components/blackbox-exporter "/opt/dragontools/components/blackbox-exporter/$version" /var/lib/dragontools; do
    \\  test ! -L "$dir" && test -d "$dir"
    \\  test "$(stat -c '%u:%g:%a' "$dir")" = 0:0:755
    \\done
    \\test ! -L /var/lib/dragontools/blackbox-exporter && test -d /var/lib/dragontools/blackbox-exporter
    \\test "$(stat -c '%U:%G:%a' /var/lib/dragontools/blackbox-exporter)" = dt-blackbox:dt-blackbox:750
    \\for dir in /etc/dragontools /etc/dragontools/blackbox-exporter; do
    \\  test ! -L "$dir" && test -d "$dir"
    \\  test "$(stat -c '%u:%g:%a' "$dir")" = 0:0:755
    \\done
    \\test ! -L /etc/dragontools/blackbox-exporter/blackbox.yml
    \\test -f /etc/dragontools/blackbox-exporter/blackbox.yml
    \\test "$(stat -c '%u:%g:%a' /etc/dragontools/blackbox-exporter/blackbox.yml)" = 0:0:644
    \\printf '%s' "$config" | cmp -s - /etc/dragontools/blackbox-exporter/blackbox.yml
    \\test "$(getent passwd dt-blackbox | cut -d: -f7)" = /usr/sbin/nologin
    \\test "$(getent passwd dt-blackbox | cut -d: -f6)" = /var/lib/dragontools/blackbox-exporter
    \\test "$(id -u dt-blackbox)" -ne 0
    \\test "$(id -gn dt-blackbox)" = dt-blackbox
    \\test "$(readlink /opt/dragontools/components/blackbox-exporter/current)" = "$version"
    \\test ! -L "/opt/dragontools/components/blackbox-exporter/$version/blackbox_exporter"
    \\test -f "/opt/dragontools/components/blackbox-exporter/$version/blackbox_exporter"
    \\test "$(stat -c '%u:%g:%a' "/opt/dragontools/components/blackbox-exporter/$version/blackbox_exporter")" = 0:0:755
    \\printf '%s  %s\n' "$expected" /opt/dragontools/components/blackbox-exporter/current/blackbox_exporter | sha256sum --check --status
;

pub const runtime_guard =
    \\expected=$1
    \\# A missing listener is temporary; a public or extra listener is never retried.
    \\listeners=$(ss -H -ltnp 'sport = :9115')
    \\if test -n "$listeners"; then
    \\  if printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:9115[[:space:]]' >/dev/null; then exit 1; fi
    \\fi
    \\pid=$(systemctl show -p MainPID --value dragontools-blackbox-exporter.service)
    \\case "$pid" in ''|*[!0-9]*) exit 1;; 0) exit 75;; esac
    \\test -d "/proc/$pid" || exit 75
    \\test "$(stat -c '%U:%G' "/proc/$pid")" = dt-blackbox:dt-blackbox
    \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
    \\expected_args=$(printf '%s\n' /opt/dragontools/components/blackbox-exporter/current/blackbox_exporter --config.file=/etc/dragontools/blackbox-exporter/blackbox.yml --web.listen-address=127.0.0.1:9115 --history.limit=0 --log.prober=error)
    \\test "$actual_args" = "$expected_args"
    \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
    \\all_listeners=$(ss -H -ltnp)
    \\owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid," || :)
    \\if test -n "$owned"; then
    \\  if printf '%s\n' "$owned" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:9115[[:space:]]' >/dev/null; then exit 1; fi
    \\fi
    \\if test -n "$listeners"; then
    \\  printf '%s\n' "$listeners" | grep -F "pid=$pid," >/dev/null || exit 1
    \\fi
;

pub const listener_ready =
    \\test -n "$listeners" || exit 75
    \\systemctl is-active --quiet dragontools-blackbox-exporter.service || exit 75
;

pub fn runtimeCommand(a: std.mem.Allocator, arch: host.Arch, check: readiness.Check, tail: []const u8) ![]const u8 {
    const script = try std.fmt.allocPrint(a, "{s}\n{s}", .{ runtime_guard, tail });
    defer a.free(script);
    const label = try std.fmt.allocPrint(a, "dragontools-blackbox-exporter-{s}", .{@tagName(check)});
    defer a.free(label);
    return remote.shell(a, &.{ "sh", "-eu", "-c", script, label, bb.artifact(arch).binary_sha256 });
}

/// Verify the mechanism only: this does not issue an external target probe and
/// never requires monitored applications to be healthy.
pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch) !void {
    const managed = try remote.shell(a, &.{ "sh", "-eu", "-c", managed_state, "dragontools-blackbox-exporter-managed_state", bb.artifact(arch).binary_sha256, bb.unit, bb.version, bb.config });
    defer a.free(managed);
    _ = try readiness.deterministic(a, r, report, .managed_state, managed);
    const active = try runtimeCommand(a, arch, .service_active, "systemctl is-active --quiet dragontools-blackbox-exporter.service || exit 75");
    defer a.free(active);
    try readiness.poll(a, r, report, .service_active, readiness.active_ms, active, readiness.ready);
    const http = try runtimeCommand(a, arch, .http_ready, listener_ready ++ "\n" ++
        "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 4096 http://127.0.0.1:9115/-/healthy || exit 75");
    defer a.free(http);
    try readiness.poll(a, r, report, .http_ready, readiness.http_ms, http, validateHealth);
    const loaded_config = try runtimeCommand(a, arch, .provisioning_ready, listener_ready ++ "\n" ++
        "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 16384 http://127.0.0.1:9115/config || exit 75");
    defer a.free(loaded_config);
    try readiness.poll(a, r, report, .provisioning_ready, readiness.http_ms, loaded_config, validateLoadedConfig);
    const metrics = try runtimeCommand(a, arch, .storage_ready, listener_ready ++ "\n" ++
        "curl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 1048576 http://127.0.0.1:9115/metrics || exit 75");
    defer a.free(metrics);
    try readiness.poll(a, r, report, .storage_ready, readiness.telemetry_ms, metrics, validateMetrics);
}

fn validateHealth(_: std.mem.Allocator, output: []const u8) !void {
    if (!std.mem.eql(u8, output, "Healthy")) return error.InvalidBlackboxHealth;
}

// /config is YAML marshalled by the pinned exporter, rather than caller-supplied
// YAML. Accept only its concrete scalar/map shape and reviewed zero-value defaults
// for unused protocol blocks. Never add a general configuration language here.
pub fn validateLoadedConfig(a: std.mem.Allocator, output: []const u8) !void {
    const Field = struct { path: []const u8, value: []const u8, required: bool = true };
    const fields = [_]Field{
        .{ .path = "modules", .value = "" },
        .{ .path = "modules.http_2xx", .value = "" },
        .{ .path = "modules.http_2xx.prober", .value = "http" },
        .{ .path = "modules.http_2xx.timeout", .value = "5s" },
        .{ .path = "modules.http_2xx.http", .value = "" },
        .{ .path = "modules.http_2xx.http.method", .value = "GET" },
        .{ .path = "modules.http_2xx.http.preferred_ip_protocol", .value = "ip4" },
        .{ .path = "modules.http_2xx.http.ip_protocol_fallback", .value = "true" },
        .{ .path = "modules.http_2xx.http.follow_redirects", .value = "true" },
        .{ .path = "modules.http_2xx.http.enable_http2", .value = "false" },
        .{ .path = "modules.http_2xx.http.tls_config", .value = "", .required = false },
        .{ .path = "modules.http_2xx.http.tls_config.insecure_skip_verify", .value = "false", .required = false },
        .{ .path = "modules.http_2xx.tcp", .value = "", .required = false },
        .{ .path = "modules.http_2xx.tcp.ip_protocol_fallback", .value = "true", .required = false },
        .{ .path = "modules.http_2xx.icmp", .value = "", .required = false },
        .{ .path = "modules.http_2xx.icmp.ip_protocol_fallback", .value = "true", .required = false },
        .{ .path = "modules.http_2xx.icmp.ttl", .value = "64", .required = false },
        .{ .path = "modules.http_2xx.dns", .value = "", .required = false },
        .{ .path = "modules.http_2xx.dns.ip_protocol_fallback", .value = "true", .required = false },
        .{ .path = "modules.http_2xx.dns.recursion_desired", .value = "true", .required = false },
    };
    if (output.len > 16384) return error.InvalidBlackboxConfig;
    var seen = [_]bool{false} ** fields.len;
    var keys: [8][]const u8 = undefined;
    var indents: [8]usize = undefined;
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const text = std.mem.trimStart(u8, line, " ");
        const indent = line.len - text.len;
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidBlackboxConfig;
        const key = text[0..colon];
        const value = std.mem.trim(u8, text[colon + 1 ..], " ");
        while (depth > 0 and indent <= indents[depth - 1]) depth -= 1;
        if ((depth == 0 and indent != 0) or depth == keys.len) return error.InvalidBlackboxConfig;
        keys[depth] = key;
        const path = try std.mem.join(a, ".", keys[0 .. depth + 1]);
        defer a.free(path);
        var matched = false;
        for (fields, 0..) |field, i| {
            if (!std.mem.eql(u8, field.path, path)) continue;
            if (seen[i] or !std.mem.eql(u8, field.value, value)) return error.InvalidBlackboxConfig;
            seen[i] = true;
            matched = true;
            break;
        }
        if (!matched) return error.InvalidBlackboxConfig;
        if (value.len == 0) {
            indents[depth] = indent;
            depth += 1;
        }
    }
    for (fields, seen) |field, found| if (field.required and !found) return error.InvalidBlackboxConfig;
}

// The exact self-observation contract comes from v0.28.0 main.go/config/config.go.
// Missing initial metrics may settle; a failed configuration reload or wrong
// exporter identity is deterministic, and no target health enters this check.
pub fn validateMetrics(_: std.mem.Allocator, output: []const u8) !void {
    var version_found = false;
    var reload_found = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.lastIndexOfAny(u8, line, " \t") orelse return error.InvalidBlackboxMetrics;
        const value = std.mem.trim(u8, line[split + 1 ..], " \t");
        _ = std.fmt.parseFloat(f64, value) catch return error.InvalidBlackboxMetrics;
        if (std.mem.startsWith(u8, line, "blackbox_exporter_build_info{")) {
            if (version_found or !std.mem.endsWith(u8, line[0..split], "}") or !std.mem.eql(u8, value, "1")) return error.InvalidBlackboxMetrics;
            if (std.mem.indexOf(u8, line[0..split], "version=\"" ++ bb.version ++ "\"") == null) return error.InvalidBlackboxMetrics;
            version_found = true;
        } else if (std.mem.eql(u8, line[0..split], "blackbox_exporter_config_last_reload_successful")) {
            if (reload_found or !std.mem.eql(u8, value, "1")) return error.InvalidBlackboxMetrics;
            reload_found = true;
        }
    }
    if (!version_found or !reload_found) return error.NotReady;
}

pub const preflight =
    \\set -eu
    \\command -v sort >/dev/null || exit 12
    \\for path in /etc/systemd/system/dragontools-blackbox-exporter.service /etc/dragontools/blackbox-exporter/blackbox.yml; do
    \\  test ! -L "$path" || exit 43
    \\  if test -e "$path"; then test -f "$path" && grep -qx '# Managed by DragonTools' "$path" || exit 40; fi
    \\done
    \\test -z "$(systemctl show -p DropInPaths --value dragontools-blackbox-exporter.service)" || exit 42
    \\pending=/var/lib/dragontools/blackbox-exporter-restart-required
    \\test ! -L "$pending" || exit 43
    \\if test -e "$pending"; then test -f "$pending" && test "$(stat -c '%u:%g' "$pending")" = 0:0 || exit 40; fi
    \\for dir in /opt/dragontools /opt/dragontools/components /opt/dragontools/components/blackbox-exporter /var/lib/dragontools /var/lib/dragontools/blackbox-exporter /etc/dragontools /etc/dragontools/blackbox-exporter; do
    \\  test ! -L "$dir" || exit 43
    \\  test ! -e "$dir" || test -d "$dir" || exit 40
    \\done
;

pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch) !void {
    _ = try report.call(r, .user, preflight ++ "\n" ++ account);
    _ = try report.call(r, .directories, directories);
    const binary = try bb.binaryCommand(a, arch);
    defer a.free(binary);
    _ = try report.call(r, .binary, binary);
    const config = try @import("../system/files.zig").writeCommand(a, bb.config_path, bb.config, bb.pending);
    defer a.free(config);
    _ = try report.call(r, .config, config);
    const unit = try @import("../system/files.zig").writeCommand(a, bb.unit_path, bb.unit, bb.pending);
    defer a.free(unit);
    _ = try report.call(r, .unit, unit);
    _ = try report.call(r, .activate, activate);
    try health(a, r, report, arch);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/blackbox-exporter-restart-required");
}

pub const account =
    \\set -eu
    \\if getent passwd dt-blackbox >/dev/null; then
    \\  test "$(getent passwd dt-blackbox | cut -d: -f7)" = /usr/sbin/nologin || exit 41
    \\  test "$(getent passwd dt-blackbox | cut -d: -f6)" = /var/lib/dragontools/blackbox-exporter || exit 41
    \\  test "$(id -u dt-blackbox)" -ne 0 || exit 41
    \\  test "$(id -gn dt-blackbox)" = dt-blackbox || exit 41
    \\  printf unchanged
    \\else
    \\  getent group dt-blackbox >/dev/null && exit 41
    \\  useradd --system --user-group --home-dir /var/lib/dragontools/blackbox-exporter --no-create-home --shell /usr/sbin/nologin dt-blackbox
    \\  printf changed
    \\fi
;

pub const directories =
    \\set -eu
    \\changed=0
    \\for dir in /opt/dragontools /opt/dragontools/components /var/lib/dragontools /etc/dragontools /etc/dragontools/blackbox-exporter; do
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
    \\dir=/var/lib/dragontools/blackbox-exporter
    \\test ! -L "$dir" || exit 43
    \\if test -e "$dir"; then
    \\  test -d "$dir" || exit 40
    \\  if test "$(stat -c '%u:%g' "$dir")" != "$(id -u dt-blackbox):$(id -g dt-blackbox)"; then chown dt-blackbox:dt-blackbox "$dir"; changed=1; fi
    \\  if test "$(stat -c '%a' "$dir")" != 750; then chmod 750 "$dir"; changed=1; fi
    \\else
    \\  install -d -o dt-blackbox -g dt-blackbox -m 750 "$dir"
    \\  changed=1
    \\fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;

pub const activate =
    \\set -eu
    \\unit=dragontools-blackbox-exporter.service; pending=/var/lib/dragontools/blackbox-exporter-restart-required
    \\changed=0
    \\test ! -L "$pending" || exit 43
    \\if test -e "$pending"; then test -f "$pending" && test "$(stat -c '%u:%g' "$pending")" = 0:0 || exit 40; fi
    \\enabled_now=0
    \\enabled_state=$(systemctl is-enabled "$unit") || { test "$enabled_state" = disabled || exit 1; }
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
;

test {
    _ = @import("blackbox_tests.zig");
}
