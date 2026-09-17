//! Narrow, controller-local external HTTP probe policy. No secret resolution or I/O.
const std = @import("std");

pub const max_probes = 64;
pub const max_name_bytes = 63;
pub const max_url_bytes = 2048;
pub const job = "dragontools-blackbox";
pub const scrape_path = "/etc/dragontools/victoriametrics/prometheus.yml";
pub const reload_pending = "/var/lib/dragontools/victoriametrics-scrape-reload-required";
pub const Probe = struct { name: []const u8, url: []const u8 };

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes or !std.ascii.isAlphanumeric(name[0])) return error.InvalidProbeName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidProbeName;
}

fn parsedUrl(value: []const u8) !std.Uri {
    if (value.len == 0 or value.len > max_url_bytes) return error.InvalidProbeUrl;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        // URLs are ASCII with explicit percent encoding. In particular, query
        // strings, fragments and credentials cannot become persistent labels.
        if (byte <= 32 or byte >= 127 or std.mem.indexOfScalar(u8, "\\<>\"{}|^`?#", byte) != null) return error.InvalidProbeUrl;
        if (byte == '%') {
            if (index + 2 >= value.len or !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return error.InvalidProbeUrl;
            const decoded = std.fmt.parseInt(u8, value[index + 1 ..][0..2], 16) catch return error.InvalidProbeUrl;
            if (decoded < 32 or decoded == 127) return error.InvalidProbeUrl;
            index += 2;
        }
    }
    const uri = std.Uri.parse(value) catch return error.InvalidProbeUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidProbeUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidProbeUrl;
    if (uri.port != null and uri.port.? == 0) return error.InvalidProbeUrl;
    const host = switch (uri.host.?) {
        .raw, .percent_encoded => |s| s,
    };
    // Percent escapes in the authority obscure its identity and are unnecessary
    // for ordinary DNS, IPv4 and bracketed IPv6 targets.
    if (std.mem.indexOfScalar(u8, host, '%') != null) return error.InvalidProbeUrl;
    const authority_start = uri.scheme.len + 3;
    if (value.len < authority_start or !std.mem.eql(u8, value[uri.scheme.len..][0..3], "://")) return error.InvalidProbeUrl;
    const authority_end = std.mem.indexOfScalarPos(u8, value, authority_start, '/') orelse value.len;
    if (value[authority_end - 1] == ':') return error.InvalidProbeUrl;
    return uri;
}

/// Normalize only identity-neutral spelling: scheme/DNS case, default ports and
/// the empty path. Preserve path bytes and percent escapes because servers may
/// distinguish them. Returned storage belongs to the caller.
pub fn normalizeUrl(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var uri = try parsedUrl(value);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else "http";
    const host = switch (uri.host.?) {
        .raw, .percent_encoded => |s| s,
    };
    const lower = try std.ascii.allocLowerString(a, host);
    defer a.free(lower);
    uri.host = .{ .percent_encoded = lower };
    if (uri.port) |port| if ((port == 80 and std.mem.eql(u8, uri.scheme, "http")) or (port == 443 and std.mem.eql(u8, uri.scheme, "https"))) {
        uri.port = null;
    };
    const normalized = try std.fmt.allocPrint(a, "{f}", .{uri});
    errdefer a.free(normalized);
    if (normalized.len > max_url_bytes) return error.InvalidProbeUrl;
    return normalized;
}

pub fn validate(probes: []const Probe) !void {
    if (probes.len > max_probes) return error.TooManyProbes;
    for (probes, 0..) |probe, index| {
        try validateName(probe.name);
        _ = try parsedUrl(probe.url);
        for (probes[0..index]) |other| if (std.mem.eql(u8, probe.name, other.name)) return error.DuplicateProbeName;
    }
}

fn yamlString(w: *std.Io.Writer, value: []const u8) !void {
    // JSON strings are valid YAML and avoid doubling a long quoted URL before
    // transport encoding. Valid probe URLs contain no raw double quote/backslash.
    if (std.mem.indexOfScalar(u8, value, '\'') != null) return std.json.Stringify.value(value, .{}, w);
    try w.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try w.writeByte('\'');
        try w.writeByte(byte);
    }
    try w.writeByte('\'');
}

/// VM v1.151.0's native Prometheus scraper stores these samples directly. Probe
/// identities are static; the only exporter label retained is its fixed phase.
pub fn renderScrape(a: std.mem.Allocator, probes: []const Probe) ![]const u8 {
    try validate(probes);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("# Managed by DragonTools\nglobal:\n  scrape_interval: 30s\n  scrape_timeout: 5s\n");
    if (probes.len == 0) {
        try w.writeAll("scrape_configs: []\n");
        return out.toOwnedSlice();
    }
    try w.writeAll("scrape_configs:\n  - job_name: " ++ job ++ "\n    metrics_path: /probe\n    params:\n      module: [http_2xx]\n    static_configs:\n");
    // Config table ordering must not create deployment changes.
    var sorted: [max_probes]Probe = undefined;
    @memcpy(sorted[0..probes.len], probes);
    std.mem.sort(Probe, sorted[0..probes.len], {}, struct {
        fn less(_: void, lhs: Probe, rhs: Probe) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.less);
    for (sorted[0..probes.len]) |probe| {
        const url = try normalizeUrl(a, probe.url);
        defer a.free(url);
        try w.writeAll("      - targets: [");
        try yamlString(w, url);
        try w.writeAll("]\n        labels:\n          __scrape_interval__: 30s\n          __scrape_timeout__: 5s\n          probe: ");
        try yamlString(w, probe.name);
        try w.writeByte('\n');
    }
    try w.writeAll(
        "    relabel_configs:\n" ++
            "      - source_labels: [__address__]\n        target_label: __param_target\n" ++
            "      - source_labels: [__param_target]\n        target_label: target\n" ++
            "      - source_labels: [probe]\n        target_label: instance\n" ++
            "      - target_label: __address__\n        replacement: 127.0.0.1:9115\n" ++
            "    metric_relabel_configs:\n" ++
            "      - source_labels: [__name__]\n        regex: 'probe_success|probe_duration_seconds|probe_dns_lookup_time_seconds|probe_http_duration_seconds|probe_http_status_code|probe_http_ssl|probe_ssl_earliest_cert_expiry|probe_http_redirects|probe_ip_protocol'\n        action: keep\n" ++
            "      - regex: '__name__|job|instance|probe|target|phase'\n        action: labelkeep\n",
    );
    return out.toOwnedSlice();
}

/// One stable rule selects the owned job. Target changes need only scrape reload,
/// and a down application produces an alert without invalidating station health.
pub fn renderRules(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8,
        \\# Managed by DragonTools
        \\groups:
        \\  - name: dragontools-probes
        \\    type: prometheus
        \\    interval: 30s
        \\    rules:
        \\      - alert: ServiceProbeFailed
        \\        expr: probe_success{job="dragontools-blackbox"} == 0
        \\        for: 2m
        \\        labels:
        \\          severity: critical
        \\          source: blackbox
        \\        annotations:
        \\          summary: 'HTTP probe {{ $labels.probe }} is failing'
        \\          description: 'Target {{ $labels.target }} has failed HTTP/HTTPS availability checks for two minutes.'
        \\
    );
}

test "probe URLs have normalized bounded HTTP identities without credentials or queries" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "HTTPS://EXAMPLE.COM:443", "http://Example.COM:80/healthz", "https://[::1]:9443/health" }, [_][]const u8{ "https://example.com/", "http://example.com/healthz", "https://[::1]:9443/health" }) |input, expected| {
        const actual = try normalizeUrl(a, input);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    for ([_][]const u8{ "", "ftp://example.com/", "http:example.com", "http:///health", "http://user:password@example.com/", "http://example.com/?key=secret", "https://example.com/#secret", "http://example.com/line\n", "http://example.com/%0A", "http://example.com/%", "http://example.com:0/", "http://example.com:99999/", "http://example.com:/", "http://example.com\\@other/", "http://exa%6dple.com/" }) |input| try std.testing.expectError(error.InvalidProbeUrl, normalizeUrl(a, input));
    for ([_][]const u8{ "", "bad name", "-leading", "injected\nlabel", "a.b" }) |name| try std.testing.expectError(error.InvalidProbeName, validateName(name));
    try std.testing.expectError(error.InvalidProbeName, validateName(&(@as([64]u8, @splat('a')))));
    try std.testing.expectError(error.InvalidProbeUrl, normalizeUrl(a, &(@as([2049]u8, @splat('a')))));
}

test "probe validation rejects duplicate names and excessive configured cardinality" {
    try std.testing.expectError(error.DuplicateProbeName, validate(&.{ .{ .name = "one", .url = "https://one.example/" }, .{ .name = "one", .url = "https://two.example/" } }));
    const too_many: [max_probes + 1]Probe = @splat(.{ .name = "one", .url = "https://example.com/" });
    try std.testing.expectError(error.TooManyProbes, validate(&too_many));
}

test "scrape rendering is deterministic bounded and uses owned loopback HTTP module" {
    const a = std.testing.allocator;
    const values = [_]Probe{ .{ .name = "beta", .url = "HTTPS://B.EXAMPLE:443" }, .{ .name = "alpha", .url = "https://a.example/health's" } };
    const first = try renderScrape(a, &values);
    defer a.free(first);
    const reordered = [_]Probe{ values[1], values[0] };
    const second = try renderScrape(a, &reordered);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    for ([_][]const u8{ "scrape_interval: 30s", "scrape_timeout: 5s", "metrics_path: /probe", "module: [http_2xx]", "replacement: 127.0.0.1:9115", "target_label: __param_target", "target_label: target", "source_labels: [probe]", "'https://b.example/'", "\"https://a.example/health's\"", "'__name__|job|instance|probe|target|phase'", "probe_http_duration_seconds" }) |needle| try std.testing.expect(std.mem.indexOf(u8, first, needle) != null);
    for ([_][]const u8{ "insecure_skip_verify", "noStaleMarkers", "authorization", "node_exporter" }) |needle| try std.testing.expect(std.mem.indexOf(u8, first, needle) == null);
    const empty = try renderScrape(a, &.{});
    defer a.free(empty);
    try std.testing.expect(std.mem.endsWith(u8, empty, "scrape_configs: []\n"));
}

test "availability rule delays failed probes for two minutes without latency alerts" {
    const a = std.testing.allocator;
    const rules = try renderRules(a);
    defer a.free(rules);
    for ([_][]const u8{ "ServiceProbeFailed", "probe_success{job=\"dragontools-blackbox\"} == 0", "for: 2m", "severity: critical", "source: blackbox", "$labels.probe", "$labels.target" }) |needle| try std.testing.expect(std.mem.indexOf(u8, rules, needle) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rules, "- alert:"));
    try std.testing.expect(std.mem.indexOf(u8, rules, "latency") == null);
}
