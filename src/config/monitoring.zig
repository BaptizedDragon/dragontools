//! A deliberately narrow TOML v1 document: connection alias and secret references.
//! No resolution, interpolation, include files or remote I/O.
const std = @import("std");
const probes = @import("../monitoring/probes.zig");
const references = @import("../secrets/reference.zig");
pub const max_bytes = 64 * 1024;
pub const default_path = "./station.toml";

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    ssh_host: ?[]const u8 = null,
    ingress_hostname: ?[]const u8 = null,
    grafana_user_op: ?[]const u8 = null,
    grafana_password_op: ?[]const u8 = null,
    probes: []const probes.Probe = &.{},
    telegram_bot_token_op: ?[]const u8 = null,
    telegram_chat_id_op: ?[]const u8 = null,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

const Section = enum { root, connection, station, ingress, grafana, telegram, probe };

const ProbeTable = struct { name: ?[]const u8 = null, url: ?[]const u8 = null };

/// Single-line basic/literal TOML strings, with basic escapes. Other TOML forms
/// (other arrays/tables, dotted/quoted keys and multiline strings) are rejected.
const Line = struct {
    rest: []const u8,

    fn space(self: *Line) void {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
    }

    fn take(self: *Line, byte: u8) !void {
        self.space();
        if (self.rest.len == 0 or self.rest[0] != byte) return error.InvalidMonitoringConfig;
        self.rest = self.rest[1..];
    }

    fn key(self: *Line) ![]const u8 {
        self.space();
        var length: usize = 0;
        while (length < self.rest.len and (std.ascii.isAlphanumeric(self.rest[length]) or self.rest[length] == '_' or self.rest[length] == '-')) : (length += 1) {}
        if (length == 0) return error.InvalidMonitoringConfig;
        const result = self.rest[0..length];
        self.rest = self.rest[length..];
        return result;
    }

    fn end(self: *Line) !void {
        self.space();
        if (self.rest.len != 0 and self.rest[0] != '#') return error.InvalidMonitoringConfig;
    }

    fn string(self: *Line, a: std.mem.Allocator) ![]const u8 {
        self.space();
        if (self.rest.len == 0 or (self.rest[0] != '"' and self.rest[0] != '\'')) return error.InvalidMonitoringConfig;
        const quote = self.rest[0];
        self.rest = self.rest[1..];
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(a);
        while (self.rest.len > 0) {
            const byte = self.rest[0];
            self.rest = self.rest[1..];
            if (byte == quote) return value.toOwnedSlice(a);
            if (byte < 0x20 and byte != '\t' or byte == 0x7f) return error.InvalidMonitoringConfig;
            if (byte != '\\' or quote == '\'') {
                try value.append(a, byte);
                continue;
            }
            if (self.rest.len == 0) return error.InvalidMonitoringConfig;
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
                    if (self.rest.len < digits) return error.InvalidMonitoringConfig;
                    for (self.rest[0..digits]) |digit| if (!std.ascii.isHex(digit)) return error.InvalidMonitoringConfig;
                    const cp = std.fmt.parseInt(u21, self.rest[0..digits], 16) catch return error.InvalidMonitoringConfig;
                    self.rest = self.rest[digits..];
                    var bytes: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(cp, &bytes) catch return error.InvalidMonitoringConfig;
                    try value.appendSlice(a, bytes[0..length]);
                },
                else => return error.InvalidMonitoringConfig,
            }
        }
        return error.InvalidMonitoringConfig;
    }

    fn reference(self: *Line, a: std.mem.Allocator) ![]const u8 {
        try self.take('{');
        if (!std.mem.eql(u8, try self.key(), "op")) return error.UnsupportedConfigSecretSource;
        try self.take('=');
        const value = try self.string(a);
        try self.take('}');
        return value;
    }
};

pub fn parse(a: std.mem.Allocator, contents: []const u8) !Config {
    if (contents.len > max_bytes) return error.MonitoringConfigTooLarge;
    if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidMonitoringConfig;
    for (contents, 0..) |byte, index| if (byte == '\r' and (index + 1 == contents.len or contents[index + 1] != '\n')) return error.InvalidMonitoringConfig;
    var config: Config = .{ .arena = .init(a) };
    errdefer config.deinit();
    const storage = config.arena.allocator();
    var section: Section = .root;
    var version_seen = false;
    var connection_seen = false;
    var ingress_seen = false;
    var station_seen = false;
    var station_hostname: ?[]const u8 = null;
    var legacy_hostname: ?[]const u8 = null;
    var grafana_seen = false;
    var telegram_seen = false;
    var probe_tables: std.ArrayList(ProbeTable) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const value = std.mem.trimEnd(u8, raw, "\r");
        // Only CRLF is a TOML newline; embedded controls are never comments.
        for (value) |byte| if (byte < 0x20 and byte != '\t' or byte == 0x7f) return error.InvalidMonitoringConfig;
        var line: Line = .{ .rest = value };
        line.space();
        if (line.rest.len == 0 or line.rest[0] == '#') continue;
        if (line.rest[0] == '[') {
            try line.take('[');
            if (line.rest.len > 0 and line.rest[0] == '[') {
                try line.take('[');
                if (!std.mem.eql(u8, try line.key(), "probe")) return error.InvalidMonitoringConfig;
                try line.take(']');
                try line.take(']');
                try line.end();
                if (probe_tables.items.len >= probes.max_probes) return error.TooManyProbes;
                try probe_tables.append(storage, .{});
                section = .probe;
                continue;
            }
            const table = try line.key();
            try line.take(']');
            try line.end();
            if (std.mem.eql(u8, table, "connection")) {
                if (connection_seen) return error.DuplicateMonitoringConfigKey;
                connection_seen = true;
                section = .connection;
            } else if (std.mem.eql(u8, table, "station")) {
                if (station_seen) return error.DuplicateMonitoringConfigKey;
                station_seen = true;
                section = .station;
            } else if (std.mem.eql(u8, table, "ingress")) {
                if (ingress_seen) return error.DuplicateMonitoringConfigKey;
                ingress_seen = true;
                section = .ingress;
            } else if (std.mem.eql(u8, table, "grafana")) {
                if (grafana_seen) return error.DuplicateMonitoringConfigKey;
                grafana_seen = true;
                section = .grafana;
            } else if (std.mem.eql(u8, table, "telegram")) {
                if (telegram_seen) return error.DuplicateMonitoringConfigKey;
                telegram_seen = true;
                section = .telegram;
            } else return error.UnknownMonitoringConfigKey;
            continue;
        }
        const key = try line.key();
        try line.take('=');
        switch (section) {
            .root => {
                if (!std.mem.eql(u8, key, "version")) return error.UnknownMonitoringConfigKey;
                if (version_seen) return error.DuplicateMonitoringConfigKey;
                version_seen = true;
                line.space();
                if (line.rest.len == 0 or line.rest[0] != '1') return error.UnsupportedMonitoringConfigVersion;
                line.rest = line.rest[1..];
            },
            .connection => {
                if (!std.mem.eql(u8, key, "ssh_host")) return error.UnknownMonitoringConfigKey;
                if (config.ssh_host != null) return error.DuplicateMonitoringConfigKey;
                config.ssh_host = try line.string(storage);
            },
            .station, .ingress => {
                if (!std.mem.eql(u8, key, "hostname")) return error.UnknownMonitoringConfigKey;
                const target = if (section == .station) &station_hostname else &legacy_hostname;
                if (target.* != null) return error.DuplicateMonitoringConfigKey;
                target.* = try line.string(storage);
                try @import("application.zig").validateStationHostname(target.*.?);
            },
            .grafana => {
                const target = if (std.mem.eql(u8, key, "username")) &config.grafana_user_op else if (std.mem.eql(u8, key, "password")) &config.grafana_password_op else return error.UnknownMonitoringConfigKey;
                if (target.* != null) return error.DuplicateMonitoringConfigKey;
                target.* = try line.reference(storage);
            },
            .telegram => {
                const target = if (std.mem.eql(u8, key, "bot_token")) &config.telegram_bot_token_op else if (std.mem.eql(u8, key, "chat_id")) &config.telegram_chat_id_op else return error.UnknownMonitoringConfigKey;
                if (target.* != null) return error.DuplicateMonitoringConfigKey;
                target.* = try line.reference(storage);
                _ = try references.parseOnePassword(target.*.?);
            },
            .probe => {
                const current = &probe_tables.items[probe_tables.items.len - 1];
                const target = if (std.mem.eql(u8, key, "name")) &current.name else if (std.mem.eql(u8, key, "url")) &current.url else return error.UnknownMonitoringConfigKey;
                if (target.* != null) return error.DuplicateMonitoringConfigKey;
                target.* = try line.string(storage);
            },
        }
        try line.end();
    }
    if (!version_seen) return error.MissingMonitoringConfigVersion;
    if (station_hostname) |canonical| if (legacy_hostname) |legacy| {
        if (!std.mem.eql(u8, canonical, legacy)) return error.ConflictingStationHostname;
    };
    config.ingress_hostname = station_hostname orelse legacy_hostname;
    if (telegram_seen and (config.telegram_bot_token_op == null or config.telegram_chat_id_op == null)) return error.TelegramCredentialReferencesRequired;
    const configured = try storage.alloc(probes.Probe, probe_tables.items.len);
    for (probe_tables.items, configured) |table, *probe| {
        probe.name = table.name orelse return error.MissingProbeName;
        probe.url = try probes.normalizeUrl(storage, table.url orelse return error.MissingProbeUrl);
    }
    try probes.validate(configured);
    config.probes = configured;
    return config;
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    return loadFrom(a, io, .cwd(), path);
}
pub fn loadDefault(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?Config {
    // Only absence is optional. A present invalid/unreadable file fails closed.
    _ = dir.statFile(io, default_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.UnableToReadMonitoringConfig,
    };
    return try loadFrom(a, io, dir, default_path);
}
pub fn loadFrom(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Config {
    const metadata = dir.statFile(io, path, .{}) catch return error.UnableToReadMonitoringConfig;
    if (metadata.kind != .file) return error.InvalidMonitoringConfigFile;
    if (metadata.size > max_bytes) return error.MonitoringConfigTooLarge;
    const contents = dir.readFileAlloc(io, path, a, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.MonitoringConfigTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnableToReadMonitoringConfig,
    };
    defer a.free(contents);
    return parse(a, contents);
}

test "monitoring config accepts only explicit v1 values and reference tables" {
    var config = try parse(std.testing.allocator,
        \\# Controller-only secret references.
        \\version = 1
        \\[connection] # OpenSSH alias
        \\ssh_host = "monitoring"
        \\[grafana]
        \\username = { op = 'op://Example/Grafana/username' }
        \\password = { op = "op://Example/Grafana/pass\\word#field" } # literal comment marker
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("monitoring", config.ssh_host.?);
    try std.testing.expectEqualStrings("op://Example/Grafana/username", config.grafana_user_op.?);
    try std.testing.expectEqualStrings("op://Example/Grafana/pass\\word#field", config.grafana_password_op.?);
}

test "monitoring config rejects literal secrets unknown duplicate and unsupported TOML" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidMonitoringConfig, parse(a, "version = 1\n[grafana]\npassword = \"never-report-this-value\"\n"));
    try std.testing.expectError(error.UnknownMonitoringConfigKey, parse(a, "version = 1\n[connection]\nhost = \"example\""));
    try std.testing.expectError(error.UnknownMonitoringConfigKey, parse(a, "version = 1\n[metrics]\n"));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version = 1\nversion = 1"));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version = 1\n[grafana]\n[grafana]"));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version = 1\n[connection]\nssh_host = 'a'\nssh_host = 'b'"));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version = 1\n[grafana]\nusername = { op = 'a' }\nusername = { op = 'b' }"));
    try std.testing.expectError(error.UnsupportedConfigSecretSource, parse(a, "version = 1\n[grafana]\npassword = { env = 'PASSWORD' }"));
    try std.testing.expectError(error.UnsupportedMonitoringConfigVersion, parse(a, "version = 2"));
    try std.testing.expectError(error.MissingMonitoringConfigVersion, parse(a, "[connection]\nssh_host = 'a'"));
    for ([_][]const u8{ "version = 1.0", "version = 1\nconnection.ssh_host = 'a'", "version = 1\n[[connection]]", "version = 1\n[grafana]\npassword = { op = 'a', op = 'b' }", "version = 1\n[connection]\nssh_host = '''multiline'''", "version = 1\n[connection]\nssh_host = \"bad\\q\"", "version = 1\x00", "version = 1\n#\x1b", "version = 1\r", "version = 1\r\r\n" }) |input| {
        try std.testing.expectError(error.InvalidMonitoringConfig, parse(a, input));
    }
}

test "monitoring config decodes basic unicode and rejects malformed encoding or oversize" {
    var config = try parse(std.testing.allocator, "version = 1\r\n[grafana]\r\nusername = { op = \"op://Vault/Grafana/na\\u006de\" }\r\n");
    defer config.deinit();
    try std.testing.expectEqualStrings("op://Vault/Grafana/name", config.grafana_user_op.?);
    try std.testing.expectError(error.InvalidMonitoringConfig, parse(std.testing.allocator, "version = 1\n#\xff"));
    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.MonitoringConfigTooLarge, parse(std.testing.allocator, oversized));
}

test "explicit config loading accepts relative paths and bounds file contents" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/monitoring config.toml", .{tmp.sub_path});
    defer a.free(file_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "monitoring config.toml", .data = "version = 1\n[connection]\nssh_host = 'monitoring'\n" });
    var config = try load(a, io, file_path);
    defer config.deinit();
    try std.testing.expectEqualStrings("monitoring", config.ssh_host.?);
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "monitoring config.toml", .data = oversized });
    try std.testing.expectError(error.MonitoringConfigTooLarge, load(a, io, file_path));
    const directory_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(directory_path);
    try std.testing.expectError(error.InvalidMonitoringConfigFile, load(a, io, directory_path));
    try tmp.dir.deleteFile(io, "monitoring config.toml");
    try std.testing.expectError(error.UnableToReadMonitoringConfig, load(a, io, file_path));
}

test "monitoring config parses HTTP probe tables and paired Telegram secret references locally" {
    var config = try parse(std.testing.allocator,
        \\version = 1
        \\[[probe]]
        \\name = 'software-landing'
        \\url = 'HTTPS://SOFTWARE.EXAMPLE:443/healthz'
        \\[telegram]
        \\bot_token = { op = 'op://Example/DragonTools/telegram-bot-token' }
        \\chat_id = { op = 'op://Example/DragonTools/telegram-chat-id' }
        \\[[probe]] # Another table after a normal section.
        \\url = 'http://orderflow.example:8080/healthz'
        \\name = 'orderflow'
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 2), config.probes.len);
    try std.testing.expectEqualStrings("software-landing", config.probes[0].name);
    try std.testing.expectEqualStrings("https://software.example/healthz", config.probes[0].url);
    try std.testing.expectEqualStrings("orderflow", config.probes[1].name);
    try std.testing.expectEqualStrings("op://Example/DragonTools/telegram-bot-token", config.telegram_bot_token_op.?);
    try std.testing.expectEqualStrings("op://Example/DragonTools/telegram-chat-id", config.telegram_chat_id_op.?);
}

test "probe config rejects incomplete duplicate unsafe and unsupported definitions" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingProbeName, parse(a, "version=1\n[[probe]]\nurl='https://example.com'"));
    try std.testing.expectError(error.MissingProbeUrl, parse(a, "version=1\n[[probe]]\nname='example'"));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version=1\n[[probe]]\nname='a'\nname='b'"));
    try std.testing.expectError(error.DuplicateProbeName, parse(a, "version=1\n[[probe]]\nname='a'\nurl='https://a.example'\n[[probe]]\nname='a'\nurl='https://b.example'"));
    try std.testing.expectError(error.InvalidProbeName, parse(a, "version=1\n[[probe]]\nname=''\nurl='https://example.com'"));
    try std.testing.expectError(error.InvalidProbeUrl, parse(a, "version=1\n[[probe]]\nname='a'\nurl='ftp://example.com'"));
    for ([_][]const u8{ "labels={service='other'}", "module='tcp_connect'", "headers='Authorization'", "method='POST'" }) |setting| {
        const input = try std.fmt.allocPrint(a, "version=1\n[[probe]]\nname='a'\nurl='https://a.example/'\n{s}", .{setting});
        defer a.free(input);
        try std.testing.expectError(error.UnknownMonitoringConfigKey, parse(a, input));
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("version=1\n");
    for (0..probes.max_probes + 1) |index| try out.writer.print("[[probe]]\nname='probe-{d}'\nurl='https://example.com/'\n", .{index});
    try std.testing.expectError(error.TooManyProbes, parse(a, out.written()));
}

test "Telegram config rejects missing malformed plaintext and unsupported secret sources" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TelegramCredentialReferencesRequired, parse(a, "version=1\n[telegram]"));
    try std.testing.expectError(error.TelegramCredentialReferencesRequired, parse(a, "version=1\n[telegram]\nbot_token={op='op://v/i/token'}"));
    try std.testing.expectError(error.InvalidMonitoringConfig, parse(a, "version=1\n[telegram]\nbot_token='plaintext'"));
    try std.testing.expectError(error.InvalidMonitoringConfig, parse(a, "version=1\n[telegram]\nchat_id=12345"));
    try std.testing.expectError(error.InvalidSecretReference, parse(a, "version=1\n[telegram]\nbot_token={op='not-a-reference'}"));
    try std.testing.expectError(error.UnsupportedConfigSecretSource, parse(a, "version=1\n[telegram]\nbot_token={env='TOKEN'}"));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version=1\n[telegram]\n[telegram]"));
    try std.testing.expectError(error.UnknownMonitoringConfigKey, parse(a, "version=1\n[telegram]\ntoken={op='op://v/i/token'}"));
}

test "station hostname canonical v1 setting and compatible legacy alias" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "[station]\nhostname='monitoring.baptizeddragon.com'\n",
        "[ingress]\nhostname='monitoring.baptizeddragon.com'\n",
        "[station]\nhostname='monitoring.baptizeddragon.com'\n[ingress]\nhostname='monitoring.baptizeddragon.com'\n",
    }) |tables| {
        const text = try std.fmt.allocPrint(a, "version=1\n{s}", .{tables});
        defer a.free(text);
        var value = try parse(a, text);
        defer value.deinit();
        try std.testing.expectEqualStrings("monitoring.baptizeddragon.com", value.ingress_hostname.?);
    }
    for ([_][]const u8{ "https://station.example", "station.example:9443", "station.example/path", "127.0.0.1" }) |hostname| {
        const text = try std.fmt.allocPrint(a, "version=1\n[station]\nhostname='{s}'\n", .{hostname});
        defer a.free(text);
        try std.testing.expectError(error.InvalidStationHostname, parse(a, text));
    }
    for ([_][]const u8{
        "version=1\n[station]\nhostname='one.example'\n[ingress]\nhostname='two.example'\n",
        "version=1\n[ingress]\nhostname='one.example'\n[station]\nhostname='two.example'\n",
    }) |text| try std.testing.expectError(error.ConflictingStationHostname, parse(a, text));
    try std.testing.expectError(error.DuplicateMonitoringConfigKey, parse(a, "version=1\n[station]\nhostname='one.example'\nhostname='one.example'\n"));
}
