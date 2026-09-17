//! Two-host convergence with independent restart intent and protected mTLS I/O.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const host = @import("../../system/host.zig");
const files = @import("../../system/files.zig");
const model = @import("model.zig");
const common = @import("common.zig");
const verify = @import("verify.zig");
const ingress = @import("ingestion.zig");
const Secret = @import("../../secrets/secret.zig").Secret;
pub const Report = model.Report;
pub const Registration = model.Registration;
pub const prerequisites =
    \\set -eu
    \\for tool in python3 openssl journalctl systemd-analyze runuser sort; do command -v "$tool" >/dev/null || exit 12; done
    \\getent group systemd-journal >/dev/null || exit 12
;
pub const station_preflight =
    \\set -eu
    \\for tool in python3 openssl; do command -v "$tool" >/dev/null || exit 12; done
    \\for pair in victoriametrics:8428 victorialogs:9428; do
    \\  name=${pair%:*}; port=${pair#*:}
    \\  systemctl is-active --quiet dragontools-$name.service
    \\  listeners=$(ss -H -ltnp "sport = :$port")
    \\  test -n "$listeners"
    \\  if printf '%s\n' "$listeners" | grep -Ev "[[:space:]]127[.]0[.]0[.]1:$port[[:space:]]" >/dev/null; then exit 1; fi
    \\done
    \\test -f /etc/systemd/system/dragontools-vmalert-metrics.service
    \\grep -qx '# Managed by DragonTools' /etc/systemd/system/dragontools-vmalert-metrics.service
;

pub fn identify(a: std.mem.Allocator, app: remote.Remote, report: *Report) ![]const u8 {
    report.component = .application_host;
    return model.hostId(a, try report.call(app, .detect, "cat /etc/machine-id"));
}

pub fn install(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, report: *Report, registration: Registration) !void {
    report.component = .application_host;
    const app_machine = try host.parse(try report.call(app, .detect, host.detect_command));
    _ = try report.call(app, .detect, prerequisites);
    for (registration.services) |service| _ = try report.call(app, .service_exists, try common.selectedService(a, service));
    report.component = .station;
    const station_machine = try host.parse(try report.call(station, .detect, host.detect_command));
    _ = try report.call(station, .health, station_preflight);

    // Safe preregistration before agent startup. No station backend, Grafana,
    // Alertmanager, firewall, or preexisting agent is restarted here.
    report.component = .ingestion;
    _ = try report.call(station, .user, try common.preflight(a, .ingestion));
    _ = try report.call(station, .directories, try common.directories(a, .ingestion));
    _ = try report.call(station, .credentials, try ingress.ensureCommand(a, registration.host, registration.station, try registration.json(a)));
    _ = try report.call(station, .directories, "set -eu\npath=/opt/dragontools/ingestion\ntest ! -L \"$path\" || exit 43\nif test -e \"$path\"; then test -d \"$path\" && test \"$(stat -c '%u:%g:%a' \"$path\")\" = 0:0:755 || exit 40; printf unchanged; else install -d -o root -g root -m 755 \"$path\"; printf changed; fi");
    _ = try report.call(station, .config, try files.writeCommand(a, ingress.executable, ingress.program, ingress.marker));
    _ = try report.call(station, .unit, try files.writeCommand(a, try common.unitPath(a, .ingestion), try common.unit(a, .ingestion, try verify.commandLine(a, .ingestion, registration)), ingress.marker));
    _ = try report.call(station, .activate, common.activation(.ingestion));
    try verify.service(a, station, report, registration, station_machine.arch, .ingestion);
    _ = try report.call(station, .health, try ingress.verifyStationCommand(a, registration.host, registration.station, try registration.json(a)));

    report.component = .journald;
    // The dedicated helper inspects effective values, retains stricter limits,
    // and rejects later conflicting drop-ins before publication.
    _ = try report.call(app, .directories, try parentDirectories(a));
    _ = try report.call(app, .config, try @import("journald.zig").command(a, true));
    report.state.phase = .credentials;
    const credentials = try station.readSecret(try ingress.exportCommand(a, registration.host), 30_000);
    defer credentials.deinit();
    report.component = .vector;
    try prepare(a, app, report, registration, app_machine.arch, .vector, credentials);
    report.configured = true;
    try verify.service(a, app, report, registration, app_machine.arch, .vector);
    // Once the authenticated end-to-end path works the gateway is independently
    // finalized. Later vmagent failures never dirty a verified Vector or gateway.
    _ = try report.call(station, .finalize, try common.finalize(a, .ingestion));
    try verify.signals(a, app, station, report, registration, "host");
    try verify.signals(a, app, station, report, registration, "logs");
    report.component = .vector;
    try verify.service(a, app, report, registration, app_machine.arch, .vector);
    _ = try report.call(app, .finalize, try common.finalize(a, .vector));
    if (registration.metricsCount() > 0) {
        report.component = .vmagent;
        try prepare(a, app, report, registration, app_machine.arch, .vmagent, credentials);
        try verify.service(a, app, report, registration, app_machine.arch, .vmagent);
        try verify.signals(a, app, station, report, registration, "app");
        report.component = .vmagent;
        try verify.service(a, app, report, registration, app_machine.arch, .vmagent);
        _ = try report.call(app, .finalize, try common.finalize(a, .vmagent));
        report.vmagent_installed = true;
    } else {
        report.component = .vmagent;
        _ = try report.call(app, .activate, stop_unused_vmagent);
    }
    report.component = .host_rules;
    // Both packs are fixed; this does not rewrite native scraper targets or any
    // station URLs. The metrics evaluator owns its independent restart intent.
    if (registration.applications.len == 0) try @import("../vmalert.zig").install(a, station, &report.state, station_machine.arch, .metrics);
}
pub fn parentDirectories(a: std.mem.Allocator) ![]const u8 {
    return remote.shell(a, &.{
        "sh",                        "-eu", "-c",
        \\changed=0
        \\for path in /var/lib/dragontools /etc/dragontools; do
        \\  test ! -L "$path" || exit 43
        \\  if test -e "$path"; then test -d "$path" && test "$(stat -c '%u:%g:%a' "$path")" = 0:0:755 || exit 40;
        \\  else install -d -o root -g root -m 755 "$path"; changed=1; fi
        \\done
        \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
        ,
        "dragontools-agent-parents",
    });
}
fn prepare(a: std.mem.Allocator, app: remote.Remote, report: *Report, registration: Registration, arch: host.Arch, kind: common.Kind, secret: *const Secret) !void {
    _ = try report.call(app, .user, try common.preflight(a, kind));
    _ = try report.call(app, .directories, try common.directories(a, kind));
    _ = try report.call(app, .binary, if (kind == .vector) try @import("../../components/vector.zig").binaryCommand(a, arch) else try @import("../../components/vmagent.zig").binaryCommand(a, arch));
    report.state.phase = .credentials;
    _ = try report.state.accept(try app.runSecret(.credentials, try ingress.installCredentialsCommand(a, if (kind == .vector) .vector else .vmagent), secret, 30_000));
    const config = try verify.configFile(a, kind, registration);
    _ = try report.call(app, .config, try files.writeCommand(a, config.path, config.content, try common.marker(a, kind)));
    // Native validation is read-only and precedes activation. Published config
    // and its intent remain recoverable on a syntax/environment failure.
    _ = try report.call(app, .config, if (kind == .vector)
        "runuser -u dt-vector -- /opt/dragontools/components/vector/current/vector validate --no-environment --skip-healthchecks /etc/dragontools/vector/vector.yaml >/dev/null 2>&1"
    else
        "runuser -u dt-vmagent -- /opt/dragontools/components/vmagent/current/vmagent-prod -dryRun -promscrape.config=/etc/dragontools/vmagent/prometheus.yml >/dev/null 2>&1");
    _ = try report.call(app, .unit, try files.writeCommand(a, try common.unitPath(a, kind), try common.unit(a, kind, try verify.commandLine(a, kind, registration)), try common.marker(a, kind)));
    _ = try report.call(app, .activate, common.activation(kind));
}
pub const stop_unused_vmagent =
    \\set -eu
    \\path=/etc/systemd/system/dragontools-vmagent.service
    \\test ! -L "$path" || exit 43
    \\if test ! -e "$path"; then printf unchanged; exit 0; fi
    \\test -f "$path" && test "$(stat -c '%u:%g' "$path")" = 0:0 || exit 40
    \\grep -qx '# Managed by DragonTools' "$path" || exit 40
    \\test -z "$(systemctl show -p DropInPaths --value dragontools-vmagent.service)" || exit 42
    \\changed=0
    \\if systemctl is-active --quiet dragontools-vmagent.service; then systemctl stop dragontools-vmagent.service; changed=1; fi
    \\enabled=$(systemctl is-enabled dragontools-vmagent.service) || :
    \\case "$enabled" in enabled|enabled-runtime) systemctl disable dragontools-vmagent.service >/dev/null 2>&1; changed=1;; disabled) ;; *) exit 1;; esac
    \\if test "$changed" = 1; then printf changed; else printf unchanged; fi
;
