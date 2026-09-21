//! Strict application-repository monitoring.toml v1. Parsing is local and owns
//! all decoded strings. It never resolves secrets, contacts SSH or searches paths.
const std = @import("std");
const probe_policy = @import("../monitoring/probes.zig");
const targets = @import("../monitoring/agents/targets.zig");
pub const max_bytes = 64 * 1024;
pub const max_items = 64;
pub const default_path = "./monitoring.toml";
pub const Identity = struct { name: []const u8, environment: []const u8 };
pub const HttpMetrics = struct {
    requests_total: ?[]const u8 = null,
    duration_histogram: ?[]const u8 = null,
    status_label: ?[]const u8 = null,
    route_label: ?[]const u8 = null,
};
pub const Service = struct { name: []const u8, systemd: []const u8, logs: bool = false, metrics_url: ?[]const u8 = null, http: ?HttpMetrics = null };
pub const Probe = probe_policy.Probe;
pub const Source = enum { logs, probe };
pub const Severity = enum { warning, critical };
pub const Alert = struct {
    name: []const u8,
    source: Source,
    severity: Severity,
    service: ?[]const u8 = null,
    level: ?[]const u8 = null,
    window: ?[]const u8 = null,
    threshold: ?u64 = null,
    probe: ?[]const u8 = null,
    for_duration: ?[]const u8 = null,
};
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    application: Identity,
    target_ssh_host: []const u8,
    station_ssh_host: []const u8,
    station_hostname: []const u8,
    services: []const Service = &.{},
    probes: []const Probe = &.{},
    alerts: []const Alert = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};
const Section = enum { root, application, target, station, service, logs, metrics, http, traces, probe, alert };
const ServiceTable = struct {
    name: ?[]const u8 = null,
    systemd: ?[]const u8 = null,
    logs: ?bool = null,
    metrics_url: ?[]const u8 = null,
    traces: ?bool = null,
    logs_seen: bool = false,
    metrics_seen: bool = false,
    http: HttpMetrics = .{},
    http_seen: bool = false,
    traces_seen: bool = false,
};
const ProbeTable = struct { name: ?[]const u8 = null, url: ?[]const u8 = null };
const AlertTable = struct {
    name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    severity: ?[]const u8 = null,
    service: ?[]const u8 = null,
    level: ?[]const u8 = null,
    window: ?[]const u8 = null,
    threshold: ?u64 = null,
    probe: ?[]const u8 = null,
    for_duration: ?[]const u8 = null,
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 63 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}
pub fn metricIdentifier(value: []const u8, label: bool) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value, 0..) |byte, i| {
        if (!std.ascii.isAlphabetic(byte) and byte != '_' and !(byte == ':' and !label) and !(i > 0 and std.ascii.isDigit(byte))) return false;
    }
    return !std.mem.startsWith(u8, value, "__");
}
pub fn validateIdentity(identity: Identity) !void {
    if (!identifier(identity.name)) return error.InvalidApplicationName;
    if (!identifier(identity.environment)) return error.InvalidApplicationEnvironment;
}
fn validateAlias(value: []const u8) !void {
    if (value.len == 0 or value.len > 253 or !std.ascii.isAlphanumeric(value[0])) return error.InvalidSshHost;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_.-:", byte) == null) return error.InvalidSshHost;
}
pub fn validateStationHostname(value: []const u8) !void {
    if (value.len == 0 or value.len > 253) return error.InvalidStationHostname;
    var labels = std.mem.splitScalar(u8, value, '.');
    var only_digits = true;
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidStationHostname;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidStationHostname;
            if (!std.ascii.isDigit(byte)) only_digits = false;
        }
    }
    // Reject IP literals and ambiguous numeric address spellings. Single-label
    // DNS names remain valid when explicitly supplied by the operator.
    if (only_digits) return error.InvalidStationHostname;
}
pub fn durationSeconds(value: []const u8) !u32 {
    if (value.len < 2 or value.len > 6 or value[0] == '0') return error.InvalidAlertDuration;
    const multiplier: u32 = switch (value[value.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return error.InvalidAlertDuration,
    };
    for (value[0 .. value.len - 1]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAlertDuration;
    const quantity = std.fmt.parseInt(u32, value[0 .. value.len - 1], 10) catch return error.InvalidAlertDuration;
    if (quantity == 0 or quantity > 86400 / multiplier) return error.InvalidAlertDuration;
    return quantity * multiplier;
}
fn putString(target: *?[]const u8, line: *Line, a: std.mem.Allocator) !void {
    if (target.* != null) return error.DuplicateApplicationConfigKey;
    target.* = try line.string(a);
}
fn namedLess(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn less(_: void, left: T, right: T) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.less;
}
const Line = struct {
    rest: []const u8,

    fn space(self: *Line) void {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
    }

    fn take(self: *Line, byte: u8) !void {
        self.space();
        if (self.rest.len == 0 or self.rest[0] != byte) return error.InvalidApplicationConfig;
        self.rest = self.rest[1..];
    }

    fn key(self: *Line) ![]const u8 {
        self.space();
        var length: usize = 0;
        while (length < self.rest.len and (std.ascii.isAlphanumeric(self.rest[length]) or self.rest[length] == '_' or self.rest[length] == '-')) : (length += 1) {}
        if (length == 0) return error.InvalidApplicationConfig;
        const result = self.rest[0..length];
        self.rest = self.rest[length..];
        return result;
    }

    fn end(self: *Line) !void {
        self.space();
        if (self.rest.len != 0 and self.rest[0] != '#') return error.InvalidApplicationConfig;
    }

    fn string(self: *Line, a: std.mem.Allocator) ![]const u8 {
        self.space();
        if (self.rest.len == 0 or (self.rest[0] != '"' and self.rest[0] != '\'')) return error.InvalidApplicationConfig;
        const quote = self.rest[0];
        self.rest = self.rest[1..];
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(a);
        while (self.rest.len > 0) {
            const byte = self.rest[0];
            self.rest = self.rest[1..];
            if (byte == quote) return value.toOwnedSlice(a);
            if (byte < 0x20 and byte != '\t' or byte == 0x7f) return error.InvalidApplicationConfig;
            if (byte != '\\' or quote == '\'') {
                try value.append(a, byte);
                continue;
            }
            if (self.rest.len == 0) return error.InvalidApplicationConfig;
            const escaped = self.rest[0];
            self.rest = self.rest[1..];
            switch (escaped) {
                '"', '\\' => try value.append(a, escaped),
                'b' => try value.append(a, '\x08'),
                't' => try value.append(a, '\t'),
                'n' => try value.append(a, '\n'),
                'f' => try value.append(a, '\x0c'),
                'r' => try value.append(a, '\r'),
                'u', 'U' => {
                    const digits: usize = if (escaped == 'u') 4 else 8;
                    if (self.rest.len < digits) return error.InvalidApplicationConfig;
                    for (self.rest[0..digits]) |digit| if (!std.ascii.isHex(digit)) return error.InvalidApplicationConfig;
                    const cp = std.fmt.parseInt(u21, self.rest[0..digits], 16) catch return error.InvalidApplicationConfig;
                    self.rest = self.rest[digits..];
                    var bytes: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(cp, &bytes) catch return error.InvalidApplicationConfig;
                    try value.appendSlice(a, bytes[0..length]);
                },
                else => return error.InvalidApplicationConfig,
            }
        }
        return error.InvalidApplicationConfig;
    }

    fn boolean(self: *Line) !bool {
        const value = try self.atom();
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return error.InvalidApplicationConfig;
    }

    fn atom(self: *Line) ![]const u8 {
        self.space();
        const end_index = std.mem.indexOfAny(u8, self.rest, " \t#") orelse self.rest.len;
        if (end_index == 0) return error.InvalidApplicationConfig;
        const value = self.rest[0..end_index];
        self.rest = self.rest[end_index..];
        return value;
    }
};

pub fn parse(a: std.mem.Allocator, contents: []const u8) !Config {
    if (contents.len > max_bytes) return error.ApplicationConfigTooLarge;
    if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidApplicationConfig;
    for (contents, 0..) |byte, index| if (byte == '\r' and (index + 1 == contents.len or contents[index + 1] != '\n')) return error.InvalidApplicationConfig;
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const storage = arena.allocator();
    var section: Section = .root;
    var version_seen = false;
    var application_seen = false;
    var target_seen = false;
    var station_seen = false;
    var name: ?[]const u8 = null;
    var environment: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var station: ?[]const u8 = null;
    var station_hostname: ?[]const u8 = null;
    var service_tables: std.ArrayList(ServiceTable) = .empty;
    var probe_tables: std.ArrayList(ProbeTable) = .empty;
    var alert_tables: std.ArrayList(AlertTable) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const value = std.mem.trimEnd(u8, raw, "\r");
        for (value) |byte| if (byte < 0x20 and byte != '\t' or byte == 0x7f) return error.InvalidApplicationConfig;
        var line: Line = .{ .rest = value };
        line.space();
        if (line.rest.len == 0 or line.rest[0] == '#') continue;
        if (line.rest[0] == '[') {
            try line.take('[');
            if (line.rest.len > 0 and line.rest[0] == '[') {
                try line.take('[');
                const table = try line.key();
                try line.take(']');
                try line.take(']');
                try line.end();
                if (eq(table, "service")) {
                    if (service_tables.items.len == max_items) return error.TooManyServices;
                    try service_tables.append(storage, .{});
                    section = .service;
                } else if (eq(table, "probe")) {
                    if (probe_tables.items.len == max_items) return error.TooManyProbes;
                    try probe_tables.append(storage, .{});
                    section = .probe;
                } else if (eq(table, "alert")) {
                    if (alert_tables.items.len == max_items) return error.TooManyAlerts;
                    try alert_tables.append(storage, .{});
                    section = .alert;
                } else return error.UnknownApplicationConfigKey;
                continue;
            }
            const table = try line.key();
            if (eq(table, "service")) {
                try line.take('.');
                const child = try line.key();
                if (service_tables.items.len == 0) return error.MissingApplicationService;
                const current = &service_tables.items[service_tables.items.len - 1];
                line.space();
                const http = eq(child, "metrics") and std.mem.startsWith(u8, line.rest, ".");
                if (http) {
                    try line.take('.');
                    if (!eq(try line.key(), "http")) return error.UnknownApplicationConfigKey;
                }
                const seen = if (http) &current.http_seen else if (eq(child, "logs")) &current.logs_seen else if (eq(child, "metrics")) &current.metrics_seen else if (eq(child, "traces")) &current.traces_seen else return error.UnknownApplicationConfigKey;
                if (seen.*) return error.DuplicateApplicationConfigKey;
                seen.* = true;
                section = if (http) .http else if (eq(child, "logs")) .logs else if (eq(child, "metrics")) .metrics else .traces;
            } else {
                const seen = if (eq(table, "application")) &application_seen else if (eq(table, "target")) &target_seen else if (eq(table, "station")) &station_seen else return error.UnknownApplicationConfigKey;
                if (seen.*) return error.DuplicateApplicationConfigKey;
                seen.* = true;
                section = if (eq(table, "application")) .application else if (eq(table, "target")) .target else .station;
            }
            try line.take(']');
            try line.end();
            continue;
        }
        const key = try line.key();
        try line.take('=');
        switch (section) {
            .root => {
                if (!eq(key, "version")) return error.UnknownApplicationConfigKey;
                if (version_seen) return error.DuplicateApplicationConfigKey;
                version_seen = true;
                if (!eq(try line.atom(), "1")) return error.UnsupportedApplicationConfigVersion;
            },
            .application => try putString(if (eq(key, "name")) &name else if (eq(key, "environment")) &environment else return error.UnknownApplicationConfigKey, &line, storage),
            .target, .station => {
                if (section == .station and eq(key, "hostname")) {
                    try putString(&station_hostname, &line, storage);
                } else {
                    if (!eq(key, "ssh_host")) return error.UnknownApplicationConfigKey;
                    try putString(if (section == .target) &target else &station, &line, storage);
                }
            },
            .service => {
                const current = &service_tables.items[service_tables.items.len - 1];
                try putString(if (eq(key, "name")) &current.name else if (eq(key, "systemd")) &current.systemd else return error.UnknownApplicationConfigKey, &line, storage);
            },
            .logs, .traces => {
                if (!eq(key, "enabled")) return error.UnknownApplicationConfigKey;
                const current = &service_tables.items[service_tables.items.len - 1];
                const destination = if (section == .logs) &current.logs else &current.traces;
                if (destination.* != null) return error.DuplicateApplicationConfigKey;
                destination.* = try line.boolean();
                if (section == .traces and destination.*.?) return error.ApplicationTracesUnsupported;
            },
            .metrics => {
                if (!eq(key, "url")) return error.UnknownApplicationConfigKey;
                try putString(&service_tables.items[service_tables.items.len - 1].metrics_url, &line, storage);
            },
            .http => {
                const current = &service_tables.items[service_tables.items.len - 1].http;
                const dest = if (eq(key, "requests_total")) &current.requests_total else if (eq(key, "duration_histogram")) &current.duration_histogram else if (eq(key, "status_label")) &current.status_label else if (eq(key, "route_label")) &current.route_label else return error.UnknownApplicationConfigKey;
                try putString(dest, &line, storage);
                if (!metricIdentifier(dest.*.?, eq(key, "status_label") or eq(key, "route_label"))) return error.InvalidHttpMetricIdentifier;
            },
            .probe => {
                const current = &probe_tables.items[probe_tables.items.len - 1];
                try putString(if (eq(key, "name")) &current.name else if (eq(key, "url")) &current.url else return error.UnknownApplicationConfigKey, &line, storage);
            },
            .alert => {
                const current = &alert_tables.items[alert_tables.items.len - 1];
                if (eq(key, "threshold")) {
                    if (current.threshold != null) return error.DuplicateApplicationConfigKey;
                    const integer = try line.atom();
                    if (integer.len == 0 or (integer.len > 1 and integer[0] == '0')) return error.InvalidAlertThreshold;
                    for (integer) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAlertThreshold;
                    current.threshold = std.fmt.parseInt(u64, integer, 10) catch return error.InvalidAlertThreshold;
                    if (current.threshold.? == 0 or current.threshold.? > 1_000_000_000) return error.InvalidAlertThreshold;
                } else {
                    const destination = if (eq(key, "name")) &current.name else if (eq(key, "source")) &current.source else if (eq(key, "severity")) &current.severity else if (eq(key, "service")) &current.service else if (eq(key, "level")) &current.level else if (eq(key, "window")) &current.window else if (eq(key, "probe")) &current.probe else if (eq(key, "for")) &current.for_duration else return error.UnknownApplicationConfigKey;
                    try putString(destination, &line, storage);
                }
            },
        }
        try line.end();
    }
    if (!version_seen) return error.MissingApplicationConfigVersion;
    var result: Config = .{
        .arena = undefined,
        .application = .{ .name = name orelse return error.MissingApplicationName, .environment = environment orelse return error.MissingApplicationEnvironment },
        .target_ssh_host = target orelse return error.MissingApplicationTarget,
        .station_ssh_host = station orelse return error.MissingApplicationStation,
        .station_hostname = station_hostname orelse return error.MissingStationHostname,
    };
    try validateIdentity(result.application);
    try validateAlias(result.target_ssh_host);
    try validateAlias(result.station_ssh_host);
    try validateStationHostname(result.station_hostname);
    const services = try storage.alloc(Service, service_tables.items.len);
    for (service_tables.items, services, 0..) |table, *service, index| {
        service.* = .{ .name = table.name orelse return error.MissingApplicationServiceName, .systemd = table.systemd orelse return error.MissingApplicationServiceUnit, .logs = table.logs orelse false, .metrics_url = table.metrics_url };
        if (table.http_seen) {
            if (table.metrics_url == null or (table.http.requests_total == null and table.http.duration_histogram == null) or ((table.http.status_label != null or table.http.route_label != null) and table.http.requests_total == null)) return error.InvalidHttpMetricMapping;
            service.http = table.http;
        }
        if (!identifier(service.name)) return error.InvalidApplicationServiceName;
        try targets.validateService(service.systemd);
        if ((table.logs_seen and table.logs == null) or (table.traces_seen and table.traces == null) or (table.metrics_seen and table.metrics_url == null)) return error.MissingApplicationSignalField;
        if (service.metrics_url) |url| {
            _ = try targets.parsedUrl(url);
            service.metrics_url = try probe_policy.normalizeUrl(storage, url);
        }
        for (services[0..index]) |other| {
            if (eq(service.name, other.name)) return error.DuplicateApplicationServiceName;
            if (eq(service.systemd, other.systemd)) return error.DuplicateService;
        }
    }
    const configured_probes = try storage.alloc(Probe, probe_tables.items.len);
    for (probe_tables.items, configured_probes) |table, *probe| {
        probe.* = .{ .name = table.name orelse return error.MissingProbeName, .url = try probe_policy.normalizeUrl(storage, table.url orelse return error.MissingProbeUrl) };
    }
    try probe_policy.validate(configured_probes);
    const alerts = try storage.alloc(Alert, alert_tables.items.len);
    for (alert_tables.items, alerts, 0..) |table, *alert, index| {
        const source_value = table.source orelse return error.MissingAlertSource;
        if (eq(source_value, "metrics")) return error.ApplicationMetricsAlertsUnsupported;
        const source = std.meta.stringToEnum(Source, source_value) orelse return error.InvalidAlertSource;
        alert.* = .{
            .name = table.name orelse return error.MissingAlertName,
            .source = source,
            .severity = std.meta.stringToEnum(Severity, table.severity orelse return error.MissingAlertSeverity) orelse return error.InvalidAlertSeverity,
            .service = table.service,
            .level = table.level,
            .window = table.window,
            .threshold = table.threshold,
            .probe = table.probe,
            .for_duration = table.for_duration,
        };
        if (!identifier(alert.name)) return error.InvalidAlertName;
        for (alerts[0..index]) |other| if (eq(alert.name, other.name)) return error.DuplicateAlertName;
        switch (source) {
            .logs => {
                if (alert.probe != null or alert.for_duration != null) return error.InvalidAlertFields;
                const level = alert.level orelse return error.MissingLogAlertField;
                var valid_level = false;
                for ([_][]const u8{ "debug", "info", "warn", "warning", "error", "critical", "fatal" }) |allowed| if (eq(level, allowed)) {
                    valid_level = true;
                };
                if (!valid_level) return error.InvalidLogAlertLevel;
                _ = try durationSeconds(alert.window orelse return error.MissingLogAlertField);
                if (alert.threshold == null) return error.MissingLogAlertField;
                var matched = false;
                for (services) |service| {
                    if (alert.service) |wanted| {
                        if (!eq(wanted, service.name)) continue;
                    }
                    if (!service.logs) {
                        if (alert.service != null) return error.LogAlertServiceDisabled;
                        continue;
                    }
                    matched = true;
                }
                if (!matched) return error.LogAlertServiceRequired;
            },
            .probe => {
                if (alert.service != null or alert.level != null or alert.window != null or alert.threshold != null) return error.InvalidAlertFields;
                const probe_name = alert.probe orelse return error.MissingProbeAlertField;
                if (alert.for_duration) |duration| _ = try durationSeconds(duration);
                var matched = false;
                for (configured_probes) |probe| if (eq(probe_name, probe.name)) {
                    matched = true;
                };
                if (!matched) return error.UnknownAlertProbe;
                for (alerts[0..index]) |other| if (other.source == .probe and eq(other.probe.?, probe_name)) return error.DuplicateProbeAlert;
            },
        }
    }
    std.mem.sort(Service, services, {}, namedLess(Service));
    std.mem.sort(Probe, configured_probes, {}, namedLess(Probe));
    std.mem.sort(Alert, alerts, {}, namedLess(Alert));
    result.services = services;
    result.probes = configured_probes;
    result.alerts = alerts;
    // Arena allocator state can grow while the owned arrays are constructed.
    // Transfer its final state only after the last allocation.
    result.arena = arena;
    return result;
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const dir = std.Io.Dir.cwd();
    const metadata = dir.statFile(io, path, .{}) catch return error.UnableToReadApplicationConfig;
    if (metadata.kind != .file) return error.InvalidApplicationConfigFile;
    if (metadata.size > max_bytes) return error.ApplicationConfigTooLarge;
    const contents = dir.readFileAlloc(io, path, a, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ApplicationConfigTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnableToReadApplicationConfig,
    };
    defer a.free(contents);
    return parse(a, contents);
}

pub const example =
    \\version = 1
    \\[application]
    \\name = 'doers'
    \\environment = 'production'
    \\[target]
    \\ssh_host = 'softwarelanding'
    \\[station]
    \\ssh_host = 'monitoring'
    \\hostname='monitoring.baptizeddragon.com'
;
const logged_service =
    \\[[service]]
    \\name = 'doers'
    \\systemd = 'doers.service'
    \\[service.logs]
    \\enabled = true
;
const sample_probe =
    \\[[probe]]
    \\name = 'website'
    \\url = 'HTTPS://EXAMPLE.COM:443/healthz'
;
const log_alert =
    \\[[alert]]
    \\name = 'HighErrorRate'
    \\source = 'logs'
    \\severity = 'warning'
    \\service = 'doers'
    \\level = 'error'
    \\window = '5m'
    \\threshold = 10
;
const probe_alert =
    \\[[alert]]
    \\name = 'WebsiteDown'
    \\source = 'probe'
    \\severity = 'critical'
    \\probe = 'website'
    \\for = '2m'
;

fn rejection(expected: anyerror, suffix: []const u8) !void {
    const input = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n", .{ example, suffix });
    defer std.testing.allocator.free(input);
    try std.testing.expectError(expected, parse(std.testing.allocator, input));
}

test "application v1 parses explicit identities signals and bounded structured alerts" {
    var config = try parse(std.testing.allocator, example ++ "\n" ++ logged_service ++ "\n[service.metrics]\nurl='http://127.0.0.1:16005/metrics'\n[service.traces]\nenabled=false\n" ++ sample_probe ++ "\n" ++ log_alert ++ "\n" ++ probe_alert);
    defer config.deinit();
    try std.testing.expectEqualStrings("doers", config.application.name);
    try std.testing.expectEqualStrings("production", config.application.environment);
    try std.testing.expectEqualStrings("softwarelanding", config.target_ssh_host);
    try std.testing.expectEqualStrings("monitoring", config.station_ssh_host);
    try std.testing.expectEqualStrings("monitoring.baptizeddragon.com", config.station_hostname);
    try std.testing.expect(config.services[0].logs);
    try std.testing.expectEqualStrings("http://127.0.0.1:16005/metrics", config.services[0].metrics_url.?);
    try std.testing.expectEqualStrings("https://example.com/healthz", config.probes[0].url);
    try std.testing.expectEqual(@as(u64, 10), config.alerts[0].threshold.?);
    try std.testing.expectEqual(Source.probe, config.alerts[1].source);
    var host_only = try parse(std.testing.allocator, example);
    defer host_only.deinit();
    try std.testing.expectEqual(@as(usize, 0), host_only.services.len);
    var default_signals = try parse(std.testing.allocator, example ++ "\n[[service]]\nname='app'\nsystemd='app.service'");
    defer default_signals.deinit();
    try std.testing.expect(!default_signals.services[0].logs);
    try std.testing.expect(default_signals.services[0].metrics_url == null);
}

test "application station hostname is required DNS-only and independent of SSH alias" {
    const prefix = "version=1\n[application]\nname='app'\nenvironment='prod'\n[target]\nssh_host='app'\n[station]\nssh_host='admin-alias'\n";
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingStationHostname, parse(a, prefix));
    try std.testing.expectError(error.UnknownApplicationConfigKey, parse(a, prefix ++ "hostnmae='station.example'"));
    try std.testing.expectError(error.DuplicateApplicationConfigKey, parse(a, prefix ++ "hostname='one.example'\nhostname='two.example'"));
    for ([_][]const u8{ "", "https://station.example", "station.example:9443", "station.example/path", "station example", " station", "station\t", "-station.example", "station-.example", "station..example", "station.example.", ".station", "station_example", "127.0.0.1", "2001:db8::1", "[::1]", "2130706433", "*.example" }) |hostname| {
        const input = try std.fmt.allocPrint(a, "{s}hostname='{s}'", .{ prefix, hostname });
        defer a.free(input);
        try std.testing.expectError(error.InvalidStationHostname, parse(a, input));
    }
    try std.testing.expectError(error.InvalidStationHostname, validateStationHostname(&(@as([64]u8, @splat('a')))));
    try std.testing.expectError(error.InvalidStationHostname, validateStationHostname(&(@as([254]u8, @splat('a')))));
    for ([_][]const u8{ "monitoring", "monitoring.baptizeddragon.com", "Monitoring.Example", "a-1.example", "xn--bcher-kva.example" }) |hostname| {
        const input = try std.fmt.allocPrint(a, "{s}hostname='{s}'", .{ prefix, hostname });
        defer a.free(input);
        var value = try parse(a, input);
        defer value.deinit();
        try std.testing.expectEqualStrings("admin-alias", value.station_ssh_host);
        try std.testing.expectEqualStrings(hostname, value.station_hostname);
    }
}

test "application schema rejects unknown duplicate keys and absent or invalid identity version" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "version=2", "version=01", "version=1.0", "version='1'" }) |input| try std.testing.expectError(error.UnsupportedApplicationConfigVersion, parse(a, input));
    try std.testing.expectError(error.MissingApplicationConfigVersion, parse(a, "[application]\nname='app'"));
    try std.testing.expectError(error.MissingApplicationEnvironment, parse(a, "version=1\n[application]\nname='app'"));
    try std.testing.expectError(error.DuplicateApplicationConfigKey, parse(a, "version=1\nversion=1"));
    try rejection(error.UnknownApplicationConfigKey, "[grafana]\npassword='never-a-secret'");
    try rejection(error.UnknownApplicationConfigKey, "unexpected=true");
    try rejection(error.UnknownApplicationConfigKey, "[[service]]\nname='x'\nsystemd='x.service'\nlabel='x'");
    try rejection(error.DuplicateApplicationConfigKey, "[application]");
    try rejection(error.DuplicateApplicationConfigKey, "ssh_host='other'");
    for ([_][]const u8{ "../app", "app/name", "app name", "", "-app", "app.name" }) |value| {
        const input = try std.fmt.allocPrint(a, "version=1\n[application]\nname='{s}'\nenvironment='prod'\n[target]\nssh_host='app'\n[station]\nssh_host='station'\nhostname='station.example'", .{value});
        defer a.free(input);
        try std.testing.expectError(error.InvalidApplicationName, parse(a, input));
    }
    try std.testing.expectError(error.InvalidApplicationEnvironment, validateIdentity(.{ .name = "app", .environment = "../prod" }));
    try std.testing.expectError(error.InvalidApplicationName, validateIdentity(.{ .name = &(@as([64]u8, @splat('a'))), .environment = "prod" }));
}

test "application services probes and traces fail closed" {
    try rejection(error.DuplicateApplicationServiceName, logged_service ++ "\n[[service]]\nname='doers'\nsystemd='other.service'");
    try rejection(error.DuplicateService, logged_service ++ "\n[[service]]\nname='other'\nsystemd='doers.service'");
    try rejection(error.InvalidService, "[[service]]\nname='doers'\nsystemd='*.service'");
    try rejection(error.InvalidService, "[[service]]\nname='doers'\nsystemd='app.socket'");
    try rejection(error.DuplicateApplicationConfigKey, logged_service ++ "\n[service.logs]\nenabled=false");
    try rejection(error.MissingApplicationSignalField, logged_service ++ "\n[service.metrics]");
    try rejection(error.ApplicationTracesUnsupported, logged_service ++ "\n[service.traces]\nenabled=true");
    try rejection(error.InvalidMetricsTargetUrl, logged_service ++ "\n[service.metrics]\nurl='https://public.example/metrics'");
    try rejection(error.DuplicateProbeName, sample_probe ++ "\n" ++ sample_probe);
    for ([_][]const u8{ "ftp://example.com", "https://user:password@example.com", "https://example.com/?token=x" }) |url| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "[[probe]]\nname='web'\nurl='{s}'", .{url});
        defer std.testing.allocator.free(input);
        try rejection(error.InvalidProbeUrl, input);
    }
}

test "application alerts require structured valid fields and references" {
    try rejection(error.InvalidAlertSource, "[[alert]]\nname='A'\nsource='sql'\nseverity='warning'");
    try rejection(error.ApplicationMetricsAlertsUnsupported, "[[alert]]\nname='A'\nsource='metrics'\nseverity='warning'");
    try rejection(error.MissingAlertSource, "[[alert]]\nname='A'");
    try rejection(error.MissingAlertSeverity, "[[alert]]\nname='A'\nsource='logs'");
    try rejection(error.MissingLogAlertField, "[[alert]]\nname='A'\nsource='logs'\nseverity='warning'");
    try rejection(error.InvalidAlertSeverity, "[[alert]]\nname='A'\nsource='logs'\nseverity='urgent'");
    try rejection(error.InvalidAlertThreshold, "[[alert]]\nthreshold=0");
    try rejection(error.InvalidAlertThreshold, "[[alert]]\nthreshold=-1");
    try rejection(error.InvalidAlertThreshold, "[[alert]]\nthreshold=1000000001");
    try rejection(error.LogAlertServiceRequired, log_alert);
    try rejection(error.LogAlertServiceDisabled, "[[service]]\nname='doers'\nsystemd='doers.service'\n" ++ log_alert);
    try rejection(error.DuplicateAlertName, logged_service ++ "\n" ++ log_alert ++ "\n" ++ log_alert);
    try rejection(error.UnknownAlertProbe, probe_alert);
    var default_probe_hold = try parse(std.testing.allocator, example ++ "\n" ++ sample_probe ++ "\n[[alert]]\nname='Down'\nsource='probe'\nprobe='website'\nseverity='critical'");
    defer default_probe_hold.deinit();
    try std.testing.expect(default_probe_hold.alerts[0].for_duration == null);
    try rejection(error.DuplicateProbeAlert, sample_probe ++ "\n" ++ probe_alert ++ "\n[[alert]]\nname='OtherDown'\nsource='probe'\nseverity='warning'\nprobe='website'\nfor='3m'");
    try rejection(error.InvalidAlertFields, sample_probe ++ "\n" ++ probe_alert ++ "\nlevel='error'");
    try rejection(error.UnknownApplicationConfigKey, logged_service ++ "\n" ++ log_alert ++ "\nexpr='arbitrary expression'");
    for ([_][]const u8{ "", "0s", "-1m", "01m", "1w", "25h", "2d", "1.5h", "1m30s", "1m;id" }) |value| try std.testing.expectError(error.InvalidAlertDuration, durationSeconds(value));
    try std.testing.expectEqual(@as(u32, 86400), try durationSeconds("1d"));
    try std.testing.expectEqual(@as(u32, 60), try durationSeconds("1m"));
}

test "application parsing sorts object names deterministically and owns decoded strings" {
    const a = std.testing.allocator;
    const one = "[[service]]\nname='a'\nsystemd='a.service'\n[service.metrics]\nurl='HTTP://LOCALHOST:80/metrics'\n";
    const two = "[[service]]\nname='z'\nsystemd='z.service'\n";
    var first = try parse(a, example ++ "\n" ++ two ++ one);
    defer first.deinit();
    var second = try parse(a, example ++ "\n" ++ one ++ two);
    defer second.deinit();
    try std.testing.expectEqualStrings("a", first.services[0].name);
    try std.testing.expectEqualStrings("http://localhost/metrics", first.services[0].metrics_url.?);
    for (first.services, second.services) |left, right| {
        try std.testing.expectEqualStrings(left.name, right.name);
        try std.testing.expectEqualStrings(left.systemd, right.systemd);
    }
    try std.testing.expectError(error.InvalidApplicationConfig, parse(a, example ++ "\n#\xff"));
    try std.testing.expectError(error.InvalidApplicationConfig, parse(a, example ++ "\r"));
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.ApplicationConfigTooLarge, parse(a, oversized));
    for ([_][]const u8{ "service", "probe", "alert" }, [_]anyerror{ error.TooManyServices, error.TooManyProbes, error.TooManyAlerts }) |table, expected| {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try out.writer.print("{s}\n", .{example});
        for (0..max_items + 1) |_| try out.writer.print("[[{s}]]\n", .{table});
        try std.testing.expectError(expected, parse(a, out.written()));
    }
}

test "application config loading requires one bounded regular file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/monitoring.toml", .{tmp.sub_path});
    defer a.free(path);
    try std.testing.expectError(error.UnableToReadApplicationConfig, load(a, io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "monitoring.toml", .data = example });
    var loaded = try load(a, io, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("doers", loaded.application.name);
    const dir_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(dir_path);
    try std.testing.expectError(error.InvalidApplicationConfigFile, load(a, io, dir_path));
}

test "application maximum object counts remain bounded and free all arena storage" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.print("{s}\n", .{example});
    for (0..max_items) |index| try out.writer.print("[[service]]\nname='app{d}'\nsystemd='app{d}.service'\n[service.logs]\nenabled=true\n[service.metrics]\nurl='http://127.0.0.1:{d}/metrics'\n", .{ index, index, 9000 + index });
    for (0..max_items) |index| try out.writer.print("[[probe]]\nname='web{d}'\nurl='https://example.com/{d}'\n[[alert]]\nname='Down{d}'\nsource='probe'\nprobe='web{d}'\nseverity='critical'\n", .{ index, index, index, index });
    var config = try parse(a, out.written());
    defer config.deinit();
    try std.testing.expectEqual(max_items, config.services.len);
    try std.testing.expectEqual(max_items, config.probes.len);
    try std.testing.expectEqual(max_items, config.alerts.len);
}

test "HTTP dashboard mapping validates identifiers independently of agent configuration" {
    const base = example ++ "\n" ++ logged_service ++ "\n[service.metrics]\nurl='http://127.0.0.1:16005/metrics'\n[service.metrics.http]\n";
    var parsed = try parse(std.testing.allocator, base ++ "requests_total='doers_http_requests_total'\nduration_histogram='doers_http_request_duration_seconds'\nstatus_label='status_class'\nroute_label='route'\n");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("doers_http_requests_total", parsed.services[0].http.?.requests_total.?);
    for ([_][]const u8{ "x{job='other'}", "sum(x)", "x[5m]", "1metric", "__name__", "a b" }) |bad| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "{s}requests_total=\"{s}\"\n", .{ base, bad });
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidHttpMetricIdentifier, parse(std.testing.allocator, text));
    }
    try std.testing.expectError(error.InvalidHttpMetricMapping, parse(std.testing.allocator, base ++ "route_label='route'"));
    try std.testing.expectError(error.InvalidHttpMetricIdentifier, parse(std.testing.allocator, base ++ "requests_total='requests_total'\nstatus_label='bad:label'"));
}
