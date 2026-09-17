//! Pure, bounded monitored-host selection validation. Never resolves DNS or secrets.
const std = @import("std");

pub const max_targets = 64;
pub const max_services = 64;
pub const max_name_bytes = 63;
pub const max_url_bytes = 2048;
pub const Target = struct { name: []const u8, url: []const u8 };

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes or !std.ascii.isAlphanumeric(name[0])) return error.InvalidMetricsTargetName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidMetricsTargetName;
}

fn privateIp4(bytes: [4]u8) bool {
    return bytes[0] == 127 or bytes[0] == 10 or
        (bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) or
        (bytes[0] == 192 and bytes[1] == 168) or
        (bytes[0] == 169 and bytes[1] == 254);
}

/// Only literal private/local addresses or localhost are accepted. DNS names
/// could resolve publicly or change after validation; no DNS lookup is trusted.
pub fn parsedUrl(value: []const u8) !std.Uri {
    if (value.len == 0 or value.len > max_url_bytes) return error.InvalidMetricsTargetUrl;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte <= 32 or byte >= 127 or std.mem.indexOfScalar(u8, "\\<>\"{}|^`?#", byte) != null) return error.InvalidMetricsTargetUrl;
        if (byte == '%') {
            if (index + 2 >= value.len or !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return error.InvalidMetricsTargetUrl;
            const decoded = std.fmt.parseInt(u8, value[index + 1 ..][0..2], 16) catch return error.InvalidMetricsTargetUrl;
            if (decoded < 32 or decoded == 127) return error.InvalidMetricsTargetUrl;
            index += 2;
        }
    }
    const uri = std.Uri.parse(value) catch return error.InvalidMetricsTargetUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidMetricsTargetUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidMetricsTargetUrl;
    if (uri.port != null and uri.port.? == 0) return error.InvalidMetricsTargetUrl;
    const authority_start = uri.scheme.len + 3;
    if (value.len < authority_start or !std.mem.eql(u8, value[uri.scheme.len..][0..3], "://")) return error.InvalidMetricsTargetUrl;
    const authority_end = std.mem.indexOfScalarPos(u8, value, authority_start, '/') orelse value.len;
    if (value[authority_end - 1] == ':') return error.InvalidMetricsTargetUrl;
    var host = switch (uri.host.?) {
        .raw, .percent_encoded => |text| text,
    };
    if (std.mem.indexOfScalar(u8, host, '%') != null) return error.InvalidMetricsTargetUrl;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return uri;
    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) host = host[1 .. host.len - 1];
    const address = std.Io.net.IpAddress.parse(host, 0) catch return error.InvalidMetricsTargetUrl;
    const allowed = switch (address) {
        .ip4 => |ip4| privateIp4(ip4.bytes),
        .ip6 => |ip6| blk: {
            if (std.Io.net.Ip4Address.fromIp6(ip6)) |ip4| break :blk privateIp4(ip4.bytes);
            break :blk std.mem.eql(u8, &ip6.bytes, &std.Io.net.Ip6Address.loopback(0).bytes) or
                (ip6.bytes[0] & 0xfe == 0xfc) or
                (ip6.bytes[0] == 0xfe and ip6.bytes[1] & 0xc0 == 0x80);
        },
    };
    if (!allowed) return error.InvalidMetricsTargetUrl;
    return uri;
}

/// Returned slices borrow the input; only the first '=' separates the name.
pub fn parseOne(value: []const u8) !Target {
    const separator = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidMetricsTarget;
    const target: Target = .{ .name = value[0..separator], .url = value[separator + 1 ..] };
    try validateName(target.name);
    _ = try parsedUrl(target.url);
    return target;
}

pub fn validate(values: []const Target) !void {
    if (values.len > max_targets) return error.TooManyMetricsTargets;
    for (values, 0..) |target, index| {
        try validateName(target.name);
        _ = try parsedUrl(target.url);
        for (values[0..index]) |other| if (std.mem.eql(u8, target.name, other.name)) return error.DuplicateMetricsTargetName;
    }
}

pub fn validateService(value: []const u8) !void {
    if (value.len <= ".service".len or value.len > 253 or !std.ascii.isAlphanumeric(value[0]) or !std.mem.endsWith(u8, value, ".service")) return error.InvalidService;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_.@:-", byte) == null) return error.InvalidService;
}

pub fn validateServices(values: []const []const u8) !void {
    if (values.len > max_services) return error.TooManyServices;
    for (values, 0..) |value, index| {
        try validateService(value);
        for (values[0..index]) |other| if (std.mem.eql(u8, value, other)) return error.DuplicateService;
    }
}

/// Keep generated registration within a 64 KiB transfer budget. Reserve fixed
/// JSON fields, maximum endpoint/host identity and per-item syntax before SSH.
pub fn validateSelectionSize(services: []const []const u8, values: []const Target) !void {
    var size: usize = 1024;
    for (services) |value| size += value.len + 3;
    for (values) |target| size += target.name.len + target.url.len + 32;
    if (size > 65536) return error.AgentSelectionsTooLarge;
}

test "metrics targets accept only named bounded local or private HTTP endpoints" {
    for ([_][]const u8{ "app=http://127.0.0.1:16000/metrics", "app=https://localhost/metrics", "app=http://10.0.0.5/metrics", "app=https://172.16.0.1/metrics", "app=http://192.168.1.1/metrics", "app=http://169.254.1.1/metrics", "app=http://[::1]:9090/metrics", "app=https://[fd12::1]/metrics", "app=http://[fe80::1]/metrics", "app=http://[::ffff:127.0.0.1]/metrics" }) |value| {
        const parsed = try parseOne(value);
        try std.testing.expectEqualStrings("app", parsed.name);
    }
    for ([_][]const u8{ "http://example.com/", "http://public.example/", "http://8.8.8.8/", "http://172.32.0.1/", "http://[2001:db8::1]/", "http://[::ffff:8.8.8.8]/", "http://0.0.0.0/", "http://[::]/", "http://127.1/", "http://127.000.0.1/", "ftp://127.0.0.1/", "http://user:secret@127.0.0.1/", "http://127.0.0.1/?secret=x", "http://127.0.0.1/#x", "http://127.0.0.1:0/", "http://127.0.0.1:99999/", "http://127.0.0.1:/", "http://127.0.0.1/%0A", "http://127.0.0.1/\n", "http://local%68ost/", "http://[fe80::1%25eth0]/" }) |value| try std.testing.expectError(error.InvalidMetricsTargetUrl, parsedUrl(value));
    for ([_][]const u8{ "", "-name", "name space", "name.dot", "name=other" }) |value| try std.testing.expectError(error.InvalidMetricsTargetName, validateName(value));
    try std.testing.expectError(error.InvalidMetricsTargetName, validateName(&(@as([64]u8, @splat('a')))));
    try std.testing.expectError(error.InvalidMetricsTargetUrl, parsedUrl(&(@as([2049]u8, @splat('a')))));
    try std.testing.expectError(error.InvalidMetricsTarget, parseOne("http://127.0.0.1/metrics"));
}

test "agent selections reject duplicate and excessive names and invalid units" {
    try validateServices(&.{ "one.service", "app@blue.service" });
    try std.testing.expectError(error.DuplicateService, validateServices(&.{ "one.service", "one.service" }));
    for ([_][]const u8{ "", ".service", "one", "*.service", "../one.service", "one;id.service", "one.service\n" }) |value| try std.testing.expectError(error.InvalidService, validateService(value));
    const too_many_services: [max_services + 1][]const u8 = @splat("one.service");
    try std.testing.expectError(error.TooManyServices, validateServices(&too_many_services));
    try std.testing.expectError(error.DuplicateMetricsTargetName, validate(&.{ .{ .name = "app", .url = "http://127.0.0.1/a" }, .{ .name = "app", .url = "http://127.0.0.1/b" } }));
    const too_many_targets: [max_targets + 1]Target = @splat(.{ .name = "app", .url = "http://127.0.0.1/metrics" });
    try std.testing.expectError(error.TooManyMetricsTargets, validate(&too_many_targets));
    const long_url: [2048]u8 = @splat('a');
    const oversized: [max_targets]Target = @splat(.{ .name = "app", .url = &long_url });
    try std.testing.expectError(error.AgentSelectionsTooLarge, validateSelectionSize(&.{}, &oversized));
}
