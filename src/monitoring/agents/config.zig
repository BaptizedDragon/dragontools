//! Deterministic, bounded agent configuration. Secret contents never enter renderers.
const std = @import("std");
const targets = @import("targets.zig");
const model = @import("model.zig");
pub const vector_buffer_bytes: u64 = 268435488; // Vector disk buffer minimum, per sink.
pub const vmagent_queue_bytes: u64 = 1073741824;
pub const metadata_interval_secs = 30;

fn string(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}
fn sortedServices(services: []const []const u8, storage: *[targets.max_services][]const u8) []const []const u8 {
    @memcpy(storage[0..services.len], services);
    std.mem.sort([]const u8, storage[0..services.len], {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    return storage[0..services.len];
}

pub fn renderVector(a: std.mem.Allocator, host_id: []const u8, station_hostname: []const u8, services: []const []const u8) ![]const u8 {
    return vectorConfig(a, host_id, station_hostname, services, &.{});
}
pub fn renderVectorRegistration(a: std.mem.Allocator, registration: model.Registration) ![]const u8 {
    const apps = try orderedApplications(a, registration.applications);
    defer freeApplications(a, apps);
    return vectorConfig(a, registration.host, registration.station, registration.services, apps);
}
fn orderedApplications(a: std.mem.Allocator, values: []const model.ApplicationScope) ![]model.ApplicationScope {
    const result = try a.alloc(model.ApplicationScope, values.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |app| a.free(app.services);
        a.free(result);
    }
    for (values, result) |value, *copy| {
        try value.validate();
        copy.* = value;
        const services = try a.dupe(model.AppService, value.services);
        copy.services = services;
        count += 1;
        std.mem.sort(model.AppService, services, {}, struct {
            fn less(_: void, lhs: model.AppService, rhs: model.AppService) bool {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.less);
    }
    std.mem.sort(model.ApplicationScope, result, {}, struct {
        fn less(_: void, lhs: model.ApplicationScope, rhs: model.ApplicationScope) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.less);
    return result;
}
fn freeApplications(a: std.mem.Allocator, values: []model.ApplicationScope) void {
    for (values) |app| a.free(app.services);
    a.free(values);
}
fn vectorConfig(a: std.mem.Allocator, host_id: []const u8, station_hostname: []const u8, services: []const []const u8, applications: []const model.ApplicationScope) ![]const u8 {
    try targets.validateServices(services);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    var storage: [targets.max_services][]const u8 = undefined;
    const ordered = sortedServices(services, &storage);
    // Immutable image filesystems commonly report 100% usage by design. Keep
    // ordinary filesystems even when systemd protects their mounts read-only.
    try w.writeAll("# Managed by DragonTools\ndata_dir: /var/lib/dragontools/vector\napi:\n  enabled: false\nsources:\n  host:\n    type: host_metrics\n    namespace: host\n    collectors: [cpu, memory, filesystem, disk, network]\n    filesystem:\n      filesystems:\n        excludes: [squashfs, iso9660]\n    scrape_interval_secs: 15\n  internal:\n    type: internal_metrics\n    scrape_interval_secs: 15\n");
    try w.writeAll("  maintenance_exec:\n    type: exec\n    command: [/opt/dragontools/agent/current/dragontool-agent, maintenance, metrics]\n    mode: scheduled\n    scheduled:\n      exec_interval_secs: 60\n    clear_environment: true\n    include_stderr: false\n    maximum_buffer_size_bytes: 4096\n    decoding:\n      codec: json\n");
    try w.writeAll("  host_events_journal:\n    type: journald\n    current_boot_only: false\n    since_now: false\n    include_units: [dragontools-host-events.service]\n  host_events_metadata:\n    type: demo_logs\n    format: shuffle\n    interval: 30\n    lines: ['{\"event\":\"host_stream_ready\",\"message\":\"DragonTools host event stream metadata\"}']\n");
    if (ordered.len != 0) {
        try w.writeAll("  journal:\n    type: journald\n    current_boot_only: false\n    since_now: true\n    include_units:\n");
        for (ordered) |service| {
            try w.writeAll("      - ");
            try string(w, service);
            try w.writeByte('\n');
        }
    }
    // One native source per service emits one distinct metadata record at startup
    // and every 30 seconds. Quiet services remain verifiable without fake errors,
    // application traffic, journal writes, or installer-triggered events on rerun.
    for (ordered, 0..) |service, i| {
        try w.print("  stream_{d}:\n    type: demo_logs\n    format: shuffle\n    interval: {d}\n    lines:\n      - ", .{ i, metadata_interval_secs });
        const metadata = try std.json.Stringify.valueAlloc(a, .{ .service = service, .type = "dragontools_stream", .level = "info", .event = "stream_ready", .message = "DragonTools agent stream metadata" }, .{});
        defer a.free(metadata);
        try string(w, metadata);
        try w.writeByte('\n');
    }
    try w.writeAll("transforms:\n  maintenance:\n    type: log_to_metric\n    inputs: [maintenance_exec]\n    metrics:\n");
    inline for (@import("../../maintenance/main.zig").gauges) |name| try w.writeAll("      - type: gauge\n        field: dragontool_host_" ++ name ++ "\n");
    try w.writeAll("      - type: gauge\n        field: dragontool_host_package_metadata_fresh\n      - type: gauge\n        field: dragontool_agent_version_info\n        tags:\n          version: '{{ version }}'\n");
    if (applications.len == 0) {
        try metricTransform(w, "metrics_identity", host_id, null);
    } else {
        for (applications, 0..) |app, i| {
            const name = try std.fmt.allocPrint(a, "metrics_identity_{d}", .{i});
            defer a.free(name);
            try metricTransform(w, name, host_id, app);
        }
    }
    if (ordered.len != 0) {
        try w.writeAll("  logs_identity:\n    type: remap\n    inputs: [journal]\n    drop_on_abort: true\n    source: |\n");
        var normalization = std.mem.splitScalar(u8, @embedFile("logs.vrl"), '\n');
        while (normalization.next()) |line| {
            if (line.len != 0) try w.print("      {s}\n", .{line});
        }
        try w.writeAll("      .host = ");
        try string(w, host_id);
        try w.writeAll("\n      .service = unit\n      .type = \"application\"\n");
        try logApplicationIdentity(w, applications, "unit");
        try w.writeAll("  stream_identity:\n    type: remap\n    inputs: [");
        for (ordered, 0..) |_, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("stream_{d}", .{i});
        }
        try w.writeAll("]\n    source: |\n      . = parse_json!(string!(.message))\n      .host = ");
        try string(w, host_id);
        try w.writeAll("\n      .timestamp = now()\n");
        try logApplicationIdentity(w, applications, ".service");
    }
    try w.writeAll("  host_events_identity:\n    type: remap\n    inputs: [host_events_journal, host_events_metadata]\n    drop_on_abort: true\n    source: |\n");
    var host_events_source = std.mem.splitScalar(u8, @embedFile("host_events.vrl"), '\n');
    while (host_events_source.next()) |line| if (line.len != 0) {
        try w.print("      {s}\n", .{line});
    };
    try w.writeAll("      .host = ");
    try string(w, host_id);
    try w.writeByte('\n');
    try w.writeAll("sinks:\n  metrics:\n    type: prometheus_remote_write\n    inputs: [");
    if (applications.len == 0) {
        try w.writeAll("metrics_identity");
    } else {
        for (applications, 0..) |_, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("metrics_identity_{d}", .{i});
        }
    }
    try w.writeAll("]\n    endpoint: ");
    const metrics_url = try std.fmt.allocPrint(a, "https://{s}:9443/api/v1/write", .{station_hostname});
    defer a.free(metrics_url);
    try string(w, metrics_url);
    try w.writeByte('\n');
    try sinkPolicy(w);
    {
        try w.writeAll("  logs:\n    type: http\n    inputs: [host_events_identity");
        if (ordered.len != 0) try w.writeAll(", logs_identity, stream_identity");
        try w.writeAll("]\n    uri: ");
        const logs_url = try std.fmt.allocPrint(a, "https://{s}:9444/insert/jsonline", .{station_hostname});
        defer a.free(logs_url);
        try string(w, logs_url);
        try w.writeAll("\n    method: post\n    compression: none\n    encoding:\n      codec: json\n    framing:\n      method: newline_delimited\n");
        try sinkPolicy(w);
    }
    try w.writeAll("  telemetry:\n    type: prometheus_exporter\n    inputs: [internal]\n    address: 127.0.0.1:8686\n");
    return out.toOwnedSlice();
}

fn metricTransform(w: *std.Io.Writer, name: []const u8, host: []const u8, app: ?model.ApplicationScope) !void {
    try w.print("  {s}:\n    type: remap\n    inputs: [host, internal, maintenance]\n    source: |\n      .tags.host = ", .{name});
    try string(w, host);
    try w.writeAll("\n      .tags.agent = \"vector\"\n");
    if (app) |scope| {
        try w.writeAll("      .tags.application = ");
        try string(w, scope.name);
        try w.writeAll("\n      .tags.environment = ");
        try string(w, scope.environment);
        try w.writeByte('\n');
    }
}
fn logApplicationIdentity(w: *std.Io.Writer, apps: []const model.ApplicationScope, unit: []const u8) !void {
    if (apps.len == 0) return;
    try w.print("      selected_unit = {s}\n", .{unit});
    for (apps) |app| for (app.services) |service| {
        if (!service.logs) continue;
        try w.writeAll("      if selected_unit == ");
        try string(w, service.systemd);
        try w.writeAll(" {\n        .application = ");
        try string(w, app.name);
        try w.writeAll("\n        .environment = ");
        try string(w, app.environment);
        try w.writeAll("\n        .service = ");
        try string(w, service.name);
        try w.writeAll("\n        .journal_unit = ");
        try string(w, service.systemd);
        try w.writeAll("\n      }\n");
    };
}

fn sinkPolicy(w: *std.Io.Writer) !void {
    try w.print("    buffer:\n      type: disk\n      max_size: {d}\n      when_full: block\n", .{vector_buffer_bytes});
    try w.writeAll("    acknowledgements:\n      enabled: true\n    healthcheck:\n      enabled: false\n    batch:\n      max_bytes: 1048576\n      timeout_secs: 1\n    request:\n      timeout_secs: 10\n      retry_initial_backoff_secs: 1\n      retry_max_duration_secs: 30\n    tls:\n      ca_file: /etc/dragontools/vector/ca.crt\n      crt_file: /etc/dragontools/vector/client.crt\n      key_file: /etc/dragontools/vector/client.key\n      verify_certificate: true\n      verify_hostname: true\n");
}

pub fn renderVmagent(a: std.mem.Allocator, host_id: []const u8, _: []const u8, values: []const targets.Target) ![]const u8 {
    try targets.validate(values);
    if (values.len == 0) return error.NoMetricsTargets;
    var sorted: [targets.max_targets]targets.Target = undefined;
    @memcpy(sorted[0..values.len], values);
    std.mem.sort(targets.Target, sorted[0..values.len], {}, struct {
        fn less(_: void, lhs: targets.Target, rhs: targets.Target) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.less);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("# Managed by DragonTools\nglobal:\n  scrape_interval: 15s\n  scrape_timeout: 5s\nscrape_configs:\n  - job_name: dragontools-vmagent\n    honor_labels: false\n    follow_redirects: false\n    static_configs:\n      - targets: ['127.0.0.1:8429']\n");
    try identityRelabel(w, host_id, null);
    for (sorted[0..values.len]) |target| {
        const uri = try targets.parsedUrl(target.url);
        const authority_start = uri.scheme.len + 3;
        const authority_end = std.mem.indexOfScalarPos(u8, target.url, authority_start, '/') orelse target.url.len;
        const path = if (authority_end == target.url.len) "/" else target.url[authority_end..];
        try w.writeAll("  - job_name: ");
        const job = try std.fmt.allocPrint(a, "dragontools-app-{s}", .{target.name});
        defer a.free(job);
        try string(w, job);
        try w.writeAll("\n    honor_labels: false\n    follow_redirects: false\n    scheme: ");
        try string(w, if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else "http");
        try w.writeAll("\n    metrics_path: ");
        try string(w, path);
        try w.writeAll("\n    static_configs:\n      - targets: [");
        try string(w, target.url[authority_start..authority_end]);
        try w.writeAll("]\n");
        try identityRelabel(w, host_id, target.name);
    }
    return out.toOwnedSlice();
}

pub fn renderVmagentRegistration(a: std.mem.Allocator, registration: model.Registration) ![]const u8 {
    if (registration.applications.len == 0) return renderVmagent(a, registration.host, registration.station, registration.metrics_targets);
    if (registration.metricsCount() == 0) return error.NoMetricsTargets;
    const apps = try orderedApplications(a, registration.applications);
    defer freeApplications(a, apps);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("# Managed by DragonTools\nglobal:\n  scrape_interval: 15s\n  scrape_timeout: 5s\nscrape_configs:\n  - job_name: dragontools-vmagent\n    honor_labels: false\n    follow_redirects: false\n    static_configs:\n      - targets: ['127.0.0.1:8429']\n");
    try identityRelabel(w, registration.host, null);
    for (apps) |app| for (app.services) |service| {
        const url = service.metrics_url orelse continue;
        const uri = try targets.parsedUrl(url);
        const start = uri.scheme.len + 3;
        const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
        try w.writeAll("  - job_name: ");
        // JSON-encoded length-prefixed identity is unambiguous even when names
        // themselves contain the separators used by human-readable job names.
        const job = try std.fmt.allocPrint(a, "dragontools-app-{d}-{s}-{d}-{s}", .{ app.name.len, app.name, service.name.len, service.name });
        defer a.free(job);
        try string(w, job);
        try w.writeAll("\n    honor_labels: false\n    follow_redirects: false\n    scheme: ");
        try string(w, if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else "http");
        try w.writeAll("\n    metrics_path: ");
        try string(w, if (end == url.len) "/" else url[end..]);
        try w.writeAll("\n    static_configs:\n      - targets: [");
        try string(w, url[start..end]);
        try w.writeAll("]\n");
        for ([_][]const u8{ "relabel_configs", "metric_relabel_configs" }) |key| {
            try w.print("    {s}:\n", .{key});
            const names = [_][]const u8{ "host", "agent", "application", "environment", "service" };
            const values = [_][]const u8{ registration.host, "vmagent", app.name, app.environment, service.name };
            for (names, values) |name, value| {
                try w.print("      - target_label: {s}\n        replacement: ", .{name});
                try string(w, value);
                try w.writeByte('\n');
            }
        }
    };
    return out.toOwnedSlice();
}

fn identityRelabel(w: *std.Io.Writer, host_id: []const u8, app: ?[]const u8) !void {
    // Target relabeling also labels automatically generated up/scrape_* samples.
    // Metric relabeling then overwrites identities supplied by application data.
    for ([_][]const u8{ "relabel_configs", "metric_relabel_configs" }) |key| {
        try w.print("    {s}:\n      - target_label: host\n        replacement: ", .{key});
        try string(w, host_id);
        try w.writeAll("\n      - target_label: agent\n        replacement: vmagent\n");
        if (app) |name| {
            try w.writeAll("      - target_label: app\n        replacement: ");
            try string(w, name);
            try w.writeByte('\n');
        }
    }
}

pub fn vectorArguments(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8, "--config /etc/dragontools/vector/vector.yaml");
}
pub fn vmagentArguments(a: std.mem.Allocator, station_hostname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "-httpListenAddr=127.0.0.1:8429 -promscrape.config=/etc/dragontools/vmagent/prometheus.yml -remoteWrite.url=https://{s}:9443/api/v1/write -remoteWrite.tlsCAFile=/etc/dragontools/vmagent/ca.crt -remoteWrite.tlsCertFile=/etc/dragontools/vmagent/client.crt -remoteWrite.tlsKeyFile=/etc/dragontools/vmagent/client.key -remoteWrite.tmpDataPath=/var/lib/dragontools/vmagent -remoteWrite.maxDiskUsagePerURL=1GiB -remoteWrite.forcePromProto=true", .{station_hostname});
}

test "Vector selects only explicit journal services with trusted identity and bounded mTLS forwarding" {
    const a = std.testing.allocator;
    const config = try renderVector(a, "app-host", "monitor.example", &.{ "orderflow.service", "doers.service" });
    defer a.free(config);
    for ([_][]const u8{ "include_units:", "\"orderflow.service\"", "\"doers.service\"", ".host = \"app-host\"", ".service = unit", "api:\n  enabled: false", "when_full: block", "max_size: 268435488", "retry_initial_backoff_secs: 1", "retry_max_duration_secs: 30", "verify_hostname: true", "verify_certificate: true", "compression: none", "type: internal_metrics", "collectors: [cpu, memory, filesystem, disk, network]", "address: 127.0.0.1:8686", "interval: 30", "dragontools_stream" }) |needle| try std.testing.expect(std.mem.indexOf(u8, config, needle) != null);
    for ([_][]const u8{ "demo: error", "0.0.0.0", "bearer", "password", "source: |\n      . = parsed" }) |needle| try std.testing.expect(std.mem.indexOf(u8, config, needle) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, config, "type: exec"));
    try std.testing.expect(std.mem.indexOf(u8, config, "command: [/opt/dragontools/agent/current/dragontool-agent, maintenance, metrics]") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "include_stderr: false") != null);
    const reversed = try renderVector(a, "app-host", "monitor.example", &.{ "doers.service", "orderflow.service" });
    defer a.free(reversed);
    try std.testing.expectEqualStrings(config, reversed);
    try std.testing.expectError(error.DuplicateService, renderVector(a, "app", "monitor", &.{ "one.service", "one.service" }));
    try std.testing.expectError(error.InvalidService, renderVector(a, "app", "monitor", &.{"*.service"}));
    const no_logs = try renderVector(a, "app-host", "monitor", &.{});
    defer a.free(no_logs);
    try std.testing.expect(std.mem.indexOf(u8, no_logs, "  journal:") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_logs, "host_events_metadata:") != null);
}

test "vmagent scrapes only explicit applications plus itself and cannot accept forged host identity" {
    const a = std.testing.allocator;
    const values = [_]targets.Target{ .{ .name = "second", .url = "https://10.0.0.2/custom" }, .{ .name = "first", .url = "http://127.0.0.1:16000/metrics" } };
    const config = try renderVmagent(a, "app-host", "monitor", &values);
    defer a.free(config);
    for ([_][]const u8{ "dragontools-app-first", "dragontools-app-second", "dragontools-vmagent", "follow_redirects: false", "honor_labels: false", "metric_relabel_configs:", "replacement: \"app-host\"", "replacement: vmagent", "metrics_path: \"/custom\"", "targets: [\"127.0.0.1:16000\"]" }) |needle| try std.testing.expect(std.mem.indexOf(u8, config, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "discovery") == null);
    const reversed = try renderVmagent(a, "app-host", "monitor", &.{ values[1], values[0] });
    defer a.free(reversed);
    try std.testing.expectEqualStrings(config, reversed);
    try std.testing.expectError(error.NoMetricsTargets, renderVmagent(a, "app-host", "monitor", &.{}));
}

test "application hostname renders deterministic TLS destinations with strict validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = try @import("../../config/application.zig").parse(a, @import("../../config/application.zig").example);
    defer app.deinit();
    const vector = try renderVector(a, "host", app.station_hostname, &.{"app.service"});
    const arguments = try vmagentArguments(a, app.station_hostname);
    for ([_][]const u8{ vector, arguments }) |output| {
        try std.testing.expect(std.mem.indexOf(u8, output, "https://monitoring.baptizeddragon.com:9443/") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "https://monitoring:9443") == null);
    }
    try std.testing.expectEqualStrings(vector, try renderVector(a, "host", app.station_hostname, &.{"app.service"}));
    try std.testing.expectEqualStrings(arguments, try vmagentArguments(a, app.station_hostname));
    try std.testing.expect(std.mem.indexOf(u8, vector, "verify_certificate: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, vector, "verify_hostname: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, arguments, "-remoteWrite.tlsCAFile=") != null);
    try std.testing.expect(std.mem.indexOf(u8, arguments, "tlsInsecureSkipVerify") == null);
}

test "Vector excludes only immutable image filesystems and retains protected root mounts" {
    const a = std.testing.allocator;
    const config = try renderVector(a, "app-host", "monitor.example", &.{"application.service"});
    defer a.free(config);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, config, "filesystem:\n      filesystems:\n        excludes: [squashfs, iso9660]\n"));
    for ([_][]const u8{ "readonly", "read_only", "mountpoints:", "ext4", "xfs", "btrfs", "overlay" }) |unexpected| try std.testing.expect(std.mem.indexOf(u8, config, unexpected) == null);
}

test "application agents merge scopes with trusted labels and metrics-only edits isolate vmagent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = model.ApplicationScope{ .name = "doers", .environment = "production", .services = &.{.{ .name = "web", .systemd = "doers.service", .logs = true, .metrics_url = "http://127.0.0.1:16005/metrics" }} };
    const second = model.ApplicationScope{ .name = "orderflow", .environment = "staging", .services = &.{.{ .name = "web", .systemd = "orderflow.service", .metrics_url = "http://127.0.0.1:16006/metrics" }} };
    const registration = model.Registration{ .host = "dt-0123456789abcdef0123456789abcdef", .station = "station.example", .services = &.{"doers.service"}, .metrics_targets = &.{}, .applications = &.{ first, second } };
    const vector = try renderVectorRegistration(a, registration);
    for ([_][]const u8{ ".application = \"doers\"", ".environment = \"production\"", ".service = \"web\"", ".journal_unit = \"doers.service\"", ".tags.application = \"doers\"", ".tags.application = \"orderflow\"", ".tags.environment = \"staging\"" }) |needle| try std.testing.expect(std.mem.indexOf(u8, vector, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, vector, "orderflow.service") == null);
    const vmagent = try renderVmagentRegistration(a, registration);
    for ([_][]const u8{ "dragontools-app-5-doers-3-web", "dragontools-app-9-orderflow-3-web", "target_label: application", "target_label: environment", "target_label: service", "metric_relabel_configs:", "follow_redirects: false" }) |needle| try std.testing.expect(std.mem.indexOf(u8, vmagent, needle) != null);
    var reversed = registration;
    reversed.applications = &.{ second, first };
    try std.testing.expectEqualStrings(vector, try renderVectorRegistration(a, reversed));
    try std.testing.expectEqualStrings(vmagent, try renderVmagentRegistration(a, reversed));
    var changed = registration;
    var service = first.services[0];
    service.metrics_url = "http://127.0.0.1:17005/metrics";
    var scope = first;
    scope.services = &.{service};
    changed.applications = &.{ scope, second };
    try std.testing.expectEqualStrings(vector, try renderVectorRegistration(a, changed));
    try std.testing.expect(!std.mem.eql(u8, vmagent, try renderVmagentRegistration(a, changed)));
    changed.services = &.{};
    changed.applications = &.{.{ .name = "hostonly", .environment = "production", .services = &.{} }};
    const host_only = try renderVectorRegistration(a, changed);
    try std.testing.expect(std.mem.indexOf(u8, host_only, "type: host_metrics") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_only, "  journal:") == null);
    try std.testing.expect(std.mem.indexOf(u8, host_only, "host_events_metadata:") != null);
    try std.testing.expectEqual(@as(usize, 0), changed.metricsCount());
    try std.testing.expectError(error.NoMetricsTargets, renderVmagentRegistration(a, changed));
}

test "Vector and vmagent use separate fixed metrics and log ports with no trace edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try renderVector(a, "host", "station.example", &.{"app.service"});
    const arguments = try vmagentArguments(a, "station.example");
    try std.testing.expect(std.mem.indexOf(u8, config, "https://station.example:9443/api/v1/write") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "https://station.example:9444/insert/jsonline") != null);
    try std.testing.expect(std.mem.indexOf(u8, arguments, "https://station.example:9443/api/v1/write") != null);
    for ([_][]const u8{ config, arguments }) |value| {
        for ([_][]const u8{ ":9443/insert", ":9444/api/v1/write", ":9445", "ingestion.service" }) |wrong| try std.testing.expect(std.mem.indexOf(u8, value, wrong) == null);
    }
}
