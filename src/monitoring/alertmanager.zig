//! Concrete local Alertmanager; only notifyTest intentionally publishes an alert.
const std = @import("std");
const remote = @import("../system/remote.zig");
const host = @import("../system/host.zig");
const workflow = @import("install.zig");
const files = @import("../system/files.zig");
const component = @import("../components/alertmanager.zig");
const readiness = @import("readiness.zig");
pub const config_path = "/etc/dragontools/alertmanager/alertmanager.yml";
pub const unit_path = "/etc/systemd/system/dragontools-alertmanager.service";
pub const executable = component.root ++ "/current/alertmanager";
pub const secret_helper = @embedFile("alertmanager_secrets.py");
pub const api_helper = @embedFile("alertmanager_runtime.py");
pub const disabled_config =
    \\# Managed by DragonTools
    \\global:
    \\  resolve_timeout: 5m
    \\route:
    \\  receiver: discard
    \\  group_by: [alertname, source, probe, target]
    \\  group_wait: 30s
    \\  group_interval: 5m
    \\  repeat_interval: 4h
    \\receivers:
    \\  - name: discard
    \\
;
pub const enabled_config =
    \\# Managed by DragonTools
    \\global:
    \\  resolve_timeout: 5m
    \\route:
    \\  receiver: discard
    \\  group_by: [alertname, source, probe, target]
    \\  group_wait: 30s
    \\  group_interval: 5m
    \\  repeat_interval: 4h
    \\  routes:
    \\    - receiver: telegram
    \\      matchers: ['severity=~"warning|critical"']
    \\receivers:
    \\  - name: discard
    \\  - name: telegram
    \\    telegram_configs:
    \\      - bot_token_file: /etc/dragontools/alertmanager/secrets/telegram-bot-token
    \\        chat_id_file: /etc/dragontools/alertmanager/secrets/telegram-chat-id
    \\        send_resolved: true
    \\        parse_mode: ''
    \\        message: '{{ .Status }}: {{ range .Alerts }}{{ .Labels.alertname }} {{ .Annotations.summary }} {{ .Annotations.description }}{{ "\n" }}{{ end }}'
    \\
;
pub const unit_text =
    \\# Managed by DragonTools
    \\[Unit]
    \\Description=DragonTools Alertmanager
    \\After=network.target
    \\
    \\[Service]
    \\User=dt-alertmanager
    \\Group=dt-alertmanager
    \\ExecStart=/opt/dragontools/components/alertmanager/current/alertmanager --config.file=/etc/dragontools/alertmanager/alertmanager.yml --storage.path=/var/lib/dragontools/alertmanager --web.listen-address=127.0.0.1:9093 --cluster.listen-address= --log.level=info
    \\Restart=on-failure
    \\RestartSec=5s
    \\TimeoutStopSec=60s
    \\NoNewPrivileges=yes
    \\PrivateTmp=yes
    \\PrivateDevices=yes
    \\ProtectHome=yes
    \\ProtectSystem=strict
    \\ProtectKernelTunables=yes
    \\ProtectKernelModules=yes
    \\ProtectControlGroups=yes
    \\RestrictSUIDSGID=yes
    \\LockPersonality=yes
    \\CapabilityBoundingSet=
    \\AmbientCapabilities=
    \\RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
    \\ReadWritePaths=/var/lib/dragontools/alertmanager
    \\UMask=0027
    \\# Native Telegram transport errors may contain the token-bearing request URL.
    \\StandardOutput=null
    \\StandardError=null
    \\
    \\[Install]
    \\WantedBy=multi-user.target
    \\
;
pub const account =
    \\set -eu
    \\for dir in /etc/dragontools /etc/dragontools/alertmanager /var/lib/dragontools/alertmanager; do
    \\  test ! -L "$dir" || exit 43
    \\  test ! -e "$dir" || test -d "$dir" || exit 40
    \\done
    \\test ! -L /etc/dragontools/alertmanager/secrets || exit 43
    \\for file in /etc/systemd/system/dragontools-alertmanager.service /etc/dragontools/alertmanager/alertmanager.yml; do
    \\  test ! -L "$file" || exit 43
    \\  if test -e "$file"; then test -f "$file" && grep -qx '# Managed by DragonTools' "$file" || exit 40; fi
    \\done
    \\test -z "$(systemctl show -p DropInPaths --value dragontools-alertmanager.service)" || exit 42
    \\if getent passwd dt-alertmanager >/dev/null; then
    \\  test "$(getent passwd dt-alertmanager | cut -d: -f7)" = /usr/sbin/nologin || exit 41
    \\  test "$(getent passwd dt-alertmanager | cut -d: -f6)" = /var/lib/dragontools/alertmanager || exit 41
    \\  test "$(id -u dt-alertmanager)" -ne 0 || exit 41
    \\  test "$(id -gn dt-alertmanager)" = dt-alertmanager || exit 41
    \\  printf unchanged
    \\else
    \\  getent group dt-alertmanager >/dev/null && exit 41
    \\  useradd --system --user-group --home-dir /var/lib/dragontools/alertmanager --no-create-home --shell /usr/sbin/nologin dt-alertmanager
    \\  printf changed
    \\fi
;
pub const directories =
    \\set -eu
    \\changed=0
    \\for dir in /etc/dragontools /etc/dragontools/alertmanager; do
    \\  test ! -L "$dir" || exit 43
    \\  if test -e "$dir"; then
    \\    test -d "$dir" || exit 40
    \\    if test "$(stat -c '%u:%g:%a' "$dir")" != 0:0:755; then chown root:root "$dir"; chmod 755 "$dir"; changed=1; fi
    \\  else install -d -o root -g root -m 755 "$dir"; changed=1; fi
    \\done
    \\dir=/var/lib/dragontools/alertmanager
    \\test ! -L "$dir" || exit 43
    \\if test -e "$dir"; then
    \\  test -d "$dir" || exit 40
    \\  if test "$(stat -c '%U:%G:%a' "$dir")" != dt-alertmanager:dt-alertmanager:750; then chown dt-alertmanager:dt-alertmanager "$dir"; chmod 750 "$dir"; changed=1; fi
    \\else install -d -o dt-alertmanager -g dt-alertmanager -m 750 "$dir"; changed=1; fi
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;
fn apiCommand(a: std.mem.Allocator, mode: []const u8) ![]const u8 {
    return remote.shell(a, &.{ "python3", "-I", "-B", "-c", api_helper, mode, disabled_config, enabled_config });
}
pub fn install(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch) !void {
    if (report.telegram_configured != (report.telegram_credentials != null)) return error.TelegramSecretTransportRequired;
    _ = try report.call(r, .user, account);
    _ = try report.call(r, .directories, directories);
    const binary = try component.binaryCommand(a, arch);
    defer a.free(binary);
    _ = try report.call(r, .binary, binary);
    const config = try files.writeCommand(a, config_path, if (report.telegram_credentials != null) enabled_config else disabled_config, component.pending);
    defer a.free(config);
    _ = try report.call(r, .config, config);
    const unit = try files.writeCommand(a, unit_path, unit_text, component.pending);
    defer a.free(unit);
    _ = try report.call(r, .unit, unit);
    if (report.telegram_credentials) |payload| {
        report.phase = .credentials;
        const command = try remote.shell(a, &.{ "python3", "-I", "-B", "-c", secret_helper, "install" });
        defer a.free(command);
        const result = try r.runSecret(.credentials, command, payload, 60_000);
        if (result.code == 86) return error.TelegramSecretPublicationFailed;
        if (result.code == 0 and !std.mem.eql(u8, result.output, "changed") and !std.mem.eql(u8, result.output, "unchanged")) return error.TelegramSecretPublicationFailed;
        _ = try report.accept(result);
    }
    _ = try report.call(r, .config, "runuser --user dt-alertmanager -- /opt/dragontools/components/alertmanager/current/amtool check-config /etc/dragontools/alertmanager/alertmanager.yml >/dev/null 2>&1");
    _ = try report.call(r, .activate, workflow.activation("alertmanager"));
    try health(a, r, report, arch);
    _ = try report.call(r, .finalize, "rm -f /var/lib/dragontools/alertmanager-restart-required");
}

const managed_script =
    \\expected=$1; amtool=$2; unit=$3; version=$4
    \\check_property() { test "$(systemctl show -p "$1" --value dragontools-alertmanager.service)" = "$2"; }
    \\check_property FragmentPath /etc/systemd/system/dragontools-alertmanager.service
    \\check_property LoadState loaded
    \\check_property UnitFileState enabled
    \\check_property NeedDaemonReload no
    \\check_property DropInPaths ""
    \\check_property Environment ""
    \\check_property EnvironmentFiles ""
    \\check_property User dt-alertmanager
    \\check_property Group dt-alertmanager
    \\check_property ProtectSystem strict
    \\check_property StandardOutput null
    \\check_property StandardError null
    \\check_property CapabilityBoundingSet ""
    \\check_property AmbientCapabilities ""
    \\check_property ReadWritePaths /var/lib/dragontools/alertmanager
    \\families=$(systemctl show -p RestrictAddressFamilies --value dragontools-alertmanager.service)
    \\test "$(printf '%s\n' "$families" | tr ' ' '\n' | sort | tr '\n' ' ')" = 'AF_INET AF_INET6 AF_UNIX '
    \\test "$(getent passwd dt-alertmanager | cut -d: -f7)" = /usr/sbin/nologin
    \\test "$(getent passwd dt-alertmanager | cut -d: -f6)" = /var/lib/dragontools/alertmanager
    \\test "$(id -u dt-alertmanager)" -ne 0
    \\test "$(id -gn dt-alertmanager)" = dt-alertmanager
    \\for property in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules ProtectControlGroups RestrictSUIDSGID LockPersonality; do check_property "$property" yes; done
    \\for dir in /opt/dragontools /opt/dragontools/components /opt/dragontools/components/alertmanager "/opt/dragontools/components/alertmanager/$version" /etc/dragontools /etc/dragontools/alertmanager /var/lib/dragontools; do
    \\  test ! -L "$dir" && test -d "$dir"
    \\  test "$(stat -c '%u:%g:%a' "$dir")" = 0:0:755
    \\done
    \\test ! -L /var/lib/dragontools/alertmanager
    \\test "$(stat -c '%U:%G:%a' /var/lib/dragontools/alertmanager)" = dt-alertmanager:dt-alertmanager:750
    \\test "$(readlink /opt/dragontools/components/alertmanager/current)" = "$version"
    \\for binary in alertmanager amtool; do
    \\  path="/opt/dragontools/components/alertmanager/$version/$binary"
    \\  test ! -L "$path" && test -f "$path"
    \\  test "$(stat -c '%u:%g:%a:%h' "$path")" = 0:0:755:1
    \\done
    \\printf '%s  %s\n' "$expected" /opt/dragontools/components/alertmanager/current/alertmanager "$amtool" /opt/dragontools/components/alertmanager/current/amtool | sha256sum --check --status
    \\test ! -L /etc/systemd/system/dragontools-alertmanager.service
    \\test "$(stat -c '%u:%g:%a' /etc/systemd/system/dragontools-alertmanager.service)" = 0:0:644
    \\printf '%s' "$unit" | cmp -s - /etc/systemd/system/dragontools-alertmanager.service
    \\runuser --user dt-alertmanager -- /opt/dragontools/components/alertmanager/current/amtool check-config /etc/dragontools/alertmanager/alertmanager.yml >/dev/null 2>&1
;
pub const runtime_guard =
    \\expected=$1
    \\listeners=$(ss -H -ltnp 'sport = :9093')
    \\if test -n "$listeners" && printf '%s\n' "$listeners" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:9093[[:space:]]' >/dev/null; then exit 1; fi
    \\pid=$(systemctl show -p MainPID --value dragontools-alertmanager.service)
    \\case "$pid" in ''|*[!0-9]*) exit 1;; 0) exit 75;; esac
    \\test -d "/proc/$pid" || exit 75
    \\test "$(stat -c '%U:%G' "/proc/$pid")" = dt-alertmanager:dt-alertmanager
    \\actual_args=$(tr '\000' '\n' < "/proc/$pid/cmdline")
    \\expected_args=$(printf '%s\n' /opt/dragontools/components/alertmanager/current/alertmanager --config.file=/etc/dragontools/alertmanager/alertmanager.yml --storage.path=/var/lib/dragontools/alertmanager --web.listen-address=127.0.0.1:9093 --cluster.listen-address= --log.level=info)
    \\test "$actual_args" = "$expected_args"
    \\printf '%s  %s\n' "$expected" "/proc/$pid/exe" | sha256sum --check --status
    \\all_listeners=$(ss -H -ltnp)
    \\owned=$(printf '%s\n' "$all_listeners" | grep -F "pid=$pid," || :)
    \\if test -n "$owned" && printf '%s\n' "$owned" | grep -Ev '[[:space:]]127[.]0[.]0[.]1:9093[[:space:]]' >/dev/null; then exit 1; fi
    \\udp=$(ss -H -lunp)
    \\if printf '%s\n' "$udp" | grep -F "pid=$pid," >/dev/null; then exit 1; fi
    \\if test -n "$listeners" && printf '%s\n' "$listeners" | grep -v -F "pid=$pid," >/dev/null; then exit 1; fi
;
pub fn health(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report, arch: host.Arch) !void {
    const pin = component.artifact(arch);
    const policy = try remote.shell(a, &.{ "sh", "-eu", "-c", managed_script, "dragontools-alertmanager-managed_state", pin.binary_sha256, pin.amtool_sha256, unit_text, component.version });
    defer a.free(policy);
    _ = try readiness.deterministic(a, r, report, .managed_state, policy);
    const check = try apiCommand(a, "check");
    defer a.free(check);
    const mode = try readiness.deterministic(a, r, report, .managed_state, check);
    if (!std.mem.eql(u8, mode, if (report.telegram_configured) "enabled" else "disabled")) return error.TelegramConfigurationMismatch;
    if (std.mem.eql(u8, mode, "enabled")) {
        const secrets = try remote.shell(a, &.{ "python3", "-I", "-B", "-c", secret_helper, "verify" });
        defer a.free(secrets);
        _ = try readiness.deterministic(a, r, report, .managed_state, secrets);
    } else if (!std.mem.eql(u8, mode, "disabled")) return error.InvalidAlertmanagerConfig;
    const active = try remote.shell(a, &.{ "sh", "-eu", "-c", runtime_guard ++ "\nsystemctl is-active --quiet dragontools-alertmanager.service || exit 75\n", "dragontools-alertmanager-service_active", pin.binary_sha256 });
    defer a.free(active);
    try readiness.poll(a, r, report, .service_active, readiness.active_ms, active, readiness.ready);
    const http = try remote.shell(a, &.{ "sh", "-eu", "-c", runtime_guard ++ "\ntest -n \"$listeners\" || exit 75\ncurl --disable --noproxy '*' --fail --silent --connect-timeout 3 --max-time 5 http://127.0.0.1:9093/-/ready >/dev/null || exit 75\n", "dragontools-alertmanager-http_ready", pin.binary_sha256 });
    defer a.free(http);
    try readiness.poll(a, r, report, .http_ready, readiness.http_ms, http, readiness.ready);
    const api = try apiCommand(a, "health");
    defer a.free(api);
    const guarded = try std.fmt.allocPrint(a, "{s}\n{s}", .{ runtime_guard, api });
    defer a.free(guarded);
    const backend = try remote.shell(a, &.{ "sh", "-eu", "-c", guarded, "dragontools-alertmanager-backend_ready", pin.binary_sha256 });
    defer a.free(backend);
    try readiness.poll(a, r, report, .backend_ready, readiness.http_ms, backend, readiness.ready);
}
pub fn notifyTest(a: std.mem.Allocator, r: remote.Remote, report: *workflow.Report) !void {
    report.component = .alertmanager;
    if (!report.telegram_configured) return error.TelegramConfigurationRequired;
    const detected = try report.call(r, .detect, host.detect_command);
    try health(a, r, report, (try host.parse(detected)).arch);
    const command = try apiCommand(a, "notify");
    defer a.free(command);
    _ = try report.call(r, .notify_test, command);
}
test {
    _ = @import("alertmanager_tests.zig");
}
