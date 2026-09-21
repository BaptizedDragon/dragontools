//! Two-host convergence with public enrollment data and host-local private keys.
const std = @import("std");
const remote = @import("../../system/remote.zig");
const host = @import("../../system/host.zig");
const files = @import("../../system/files.zig");
const model = @import("model.zig");
const common = @import("common.zig");
const verify = @import("verify.zig");
const ingress = @import("ingestion.zig");
pub const Report = model.Report;
pub const Registration = model.Registration;
pub const prerequisites =
    \\set -eu
    \\for tool in python3 journalctl systemd-analyze runuser sort; do command -v "$tool" >/dev/null || exit 12; done
    \\getent group systemd-journal >/dev/null || exit 12
;
pub const station_preflight =
    \\set -eu
    \\command -v python3 >/dev/null || exit 12
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
    report.component = .application_host;
    try @import("helper.zig").ensure(a, app, report, app_machine.arch);
    report.component = .station;
    report.state.ingress_hostname = registration.station;
    report.state.check = .station_ingress_required;
    try @import("helper.zig").verify(a, station, report, station_machine.arch);
    report.component = .ingestion;
    try @import("../ingress.zig").verifyBase(a, station, &report.state, station_machine.arch);
    _ = try @import("../readiness.zig").deterministic(a, station, &report.state, .station_ingress_required, "test ! -e /var/lib/dragontools/caddy-restart-required && test ! -L /var/lib/dragontools/caddy-restart-required && test ! -e /var/lib/dragontools/ingress-auth-restart-required && test ! -L /var/lib/dragontools/ingress-auth-restart-required");
    _ = try report.call(station, .credentials, try ingress.ensureCommand(a, registration.host, registration.station, try registration.json(a)));

    report.component = .journald;
    // The dedicated helper inspects effective values, retains stricter limits,
    // and rejects later conflicting drop-ins before publication.
    _ = try report.call(app, .directories, try parentDirectories(a));
    _ = try report.call(app, .config, try @import("journald.zig").command(a, true));
    // The station must be reachable and its listener verified before generating
    // any local candidate. Only bounded public material crosses these calls.
    report.component = .ingestion;
    const inspection = try report.call(station, .status, try ingress.inspectCommand(a, registration.host, registration.station));
    const inspected = try ingress.parseInspection(a, inspection, registration.host, registration.station);
    report.component = .application_host;
    if (inspected.legacy_active and !inspected.legacy_expired and inspected.pending_certificate_sha256 == null) {
        // Prove the existing credential actually authenticates before generating
        // a replacement; cryptographic parsing alone does not prove enrollment.
        // A staged migration already passed this check. Its consumers may now
        // use the candidate, whose rollout lease must be refreshed before probing.
        try verify.enrollmentEndpoints(a, app, report, registration, "vector");
    }
    const prepared = try ingress.parsePrepared(a, try report.call(app, .credentials, try ingress.prepareClientCommand(a, registration.host, registration.station, inspection)));
    if (prepared.recovered_key) _ = try report.state.accept(.{ .code = 0, .output = "changed" });
    var fingerprint = prepared.certificate_sha256;
    if (prepared.csr) |csr| {
        report.component = .ingestion;
        const bundle = try report.call(station, .credentials, try ingress.stageCommand(a, registration.host, registration.station, try registration.json(a), csr));
        fingerprint = try ingress.publicBundleFingerprint(a, bundle);
        report.component = .application_host;
        _ = try report.call(app, .credentials, try ingress.stageClientCommand(a, bundle));
        // Prove the candidate before stopping a working consumer. The old active
        // registration remains valid throughout the explicit rollover lease.
        try verify.enrollmentEndpoints(a, app, report, registration, "pending");
    } else {
        report.component = .ingestion;
        _ = try report.call(station, .credentials, try ingress.reconcileCommand(a, registration.host, registration.station, try registration.json(a)));
    }
    convergeAgents(a, app, station, report, registration, app_machine.arch) catch |err| {
        const old_still_active = if (prepared.certificate_sha256) |old|
            if (inspected.certificate_sha256) |active| std.mem.eql(u8, old, active) else false
        else
            false;
        if ((prepared.action == .migrate or prepared.action == .renew) and old_still_active) {
            const failed_component = report.component;
            const failed_phase = report.state.phase;
            const failed_check = report.state.check;
            const rollback_command = try ingress.finishClientCommand(a, registration.host, registration.station, false);
            const rollback = app.run(.credentials, rollback_command) catch {
                report.state.beginRequest(rollback_command);
                report.component = .application_host;
                report.state.check = .credential_recovery;
                return error.ClientCredentialRecoveryRequired;
            };
            if (rollback.code != 0) {
                report.state.beginRequest(rollback_command);
                report.state.captureAgentFailure(rollback);
                report.component = .application_host;
                report.state.check = .credential_recovery;
                return error.ClientCredentialRecoveryRequired;
            }
            report.component = failed_component;
            report.state.phase = failed_phase;
            report.state.check = failed_check;
        }
        return err;
    };
    // Do not rollback after an uncertain station-finalize response: the station
    // may have committed. Keep the working candidate and backups for inspection
    // and idempotent recovery on the next apply.
    report.component = .ingestion;
    _ = try report.call(station, .finalize, try ingress.finalizeCommand(a, registration.host, fingerprint.?));
    report.component = .application_host;
    _ = try report.call(app, .finalize, try ingress.finishClientCommand(a, registration.host, registration.station, true));
    report.enrollment = prepared.action;
    report.component = .ingestion;
    _ = try report.call(station, .health, try ingress.verifyStationCommand(a, registration.host, registration.station, try registration.json(a)));
    report.component = .host_rules;
    // Both packs are fixed; this does not rewrite native scraper targets or any
    // station URLs. The metrics evaluator owns its independent restart intent.
    if (registration.applications.len == 0) try @import("../vmalert.zig").install(a, station, &report.state, station_machine.arch, .metrics);
}
fn convergeAgents(a: std.mem.Allocator, app: remote.Remote, station: remote.Remote, report: *Report, registration: Registration, arch: host.Arch) !void {
    report.component = .vector;
    try prepare(a, app, report, registration, arch, .vector);
    report.configured = true;
    try @import("host_events.zig").install(a, app, report, arch);
    report.component = .vector;
    try verify.service(a, app, report, registration, arch, .vector);
    // Station ingress is finalized by station install, independently of apps.
    try verify.signals(a, app, station, report, registration, "host");
    if (registration.applications.len > 0) try verify.signals(a, app, station, report, registration, "service");
    try verify.signals(a, app, station, report, registration, "events");
    try verify.signals(a, app, station, report, registration, "logs");
    report.component = .vector;
    try verify.service(a, app, report, registration, arch, .vector);
    _ = try report.call(app, .finalize, try common.finalize(a, .vector));
    try @import("host_events.zig").verify(a, app, report, arch);
    try @import("host_events.zig").finalize(a, app, report);
    if (registration.metricsCount() > 0) {
        report.component = .vmagent;
        try prepare(a, app, report, registration, arch, .vmagent);
        try verify.service(a, app, report, registration, arch, .vmagent);
        try verify.signals(a, app, station, report, registration, "app");
        report.component = .vmagent;
        try verify.service(a, app, report, registration, arch, .vmagent);
        _ = try report.call(app, .finalize, try common.finalize(a, .vmagent));
        report.vmagent_installed = true;
    } else {
        report.component = .vmagent;
        _ = try report.call(app, .activate, stop_unused_vmagent);
    }
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
fn prepare(a: std.mem.Allocator, app: remote.Remote, report: *Report, registration: Registration, arch: host.Arch, kind: common.Kind) !void {
    _ = try report.call(app, .user, try common.preflight(a, kind));
    _ = try report.call(app, .directories, try common.directories(a, kind));
    _ = try report.call(app, .binary, if (kind == .vector) try @import("../../components/vector.zig").binaryCommand(a, arch) else try @import("../../components/vmagent.zig").binaryCommand(a, arch));
    _ = try report.call(app, .credentials, try ingress.installCredentialsCommand(a, if (kind == .vector) .vector else .vmagent, registration.host, registration.station));
    const config = try verify.configFile(a, kind, registration);
    _ = try report.call(app, .config, if (kind == .vector)
        try @import("vector_config.zig").writeCommand(a, config.content)
    else
        try files.writeCommand(a, config.path, config.content, try common.marker(a, kind)));
    // Vector candidates validate before publication. This additional read-only
    // validation also checks unchanged files before any pending activation.
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
