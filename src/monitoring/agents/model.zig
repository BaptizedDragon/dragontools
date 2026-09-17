const std = @import("std");
const targets = @import("targets.zig");
const remote = @import("../../system/remote.zig");
pub const Component = enum { application_host, station, ingestion, journald, vector, vmagent, signals, host_rules };
pub const Report = struct {
    component: Component = .application_host,
    state: @import("../install.zig").Report = .{},
    configured: bool = false,
    enrollment: @import("ingestion.zig").Action = .unchanged,
    application: ?[]const u8 = null,
    vmagent_installed: bool = false,
    pub fn enrollmentSummary(self: Report) []const u8 {
        return switch (self.enrollment) {
            .unchanged => "",
            .enroll => "local client identity enrolled\nmTLS verified\n",
            .reenroll => "local client identity re-enrolled\nmTLS verified\n",
            .renew => "local client certificate renewed\nmTLS verified\n",
            .migrate => "legacy certificate detected\nlocal client identity enrolled\nmTLS verified\n",
        };
    }
    pub fn call(self: *Report, r: remote.Remote, op: remote.Operation, command: []const u8) ![]const u8 {
        return self.state.call(r, op, command);
    }
};
pub const AppService = struct { name: []const u8, systemd: []const u8, logs: bool = false, metrics_url: ?[]const u8 = null };
pub const ApplicationScope = struct {
    name: []const u8,
    environment: []const u8,
    services: []const AppService,
    pub fn validate(self: ApplicationScope) !void {
        try targets.validateName(self.name);
        try targets.validateName(self.environment);
        if (self.services.len > 64) return error.InvalidAgentRegistration;
        for (self.services, 0..) |service, index| {
            try targets.validateName(service.name);
            try targets.validateService(service.systemd);
            if (service.metrics_url) |url| _ = try targets.parsedUrl(url);
            for (self.services[0..index]) |other| if (std.mem.eql(u8, service.name, other.name) or std.mem.eql(u8, service.systemd, other.systemd)) return error.InvalidAgentRegistration;
        }
    }
};
pub const Registration = struct {
    version: u8 = 1,
    host: []const u8,
    station: []const u8,
    services: []const []const u8,
    metrics_targets: []const targets.Target,
    applications: []const ApplicationScope = &.{},

    pub fn metricsCount(self: Registration) usize {
        var count = self.metrics_targets.len;
        for (self.applications) |app| for (app.services) |service| {
            if (service.metrics_url != null) count += 1;
        };
        return count;
    }

    pub fn selected(self: Registration, name: ?[]const u8) Registration {
        const wanted = name orelse return self;
        for (self.applications, 0..) |app, i| if (std.mem.eql(u8, app.name, wanted)) {
            var result = self;
            result.applications = self.applications[i .. i + 1];
            return result;
        };
        return self;
    }
    pub fn json(self: Registration, a: std.mem.Allocator) ![]const u8 {
        if (self.applications.len == 0) return std.json.Stringify.valueAlloc(a, .{ .version = self.version, .host = self.host, .station = self.station, .services = self.services, .metrics_targets = self.metrics_targets }, .{});
        return std.json.Stringify.valueAlloc(a, self, .{});
    }
    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Registration {
        if (bytes.len > 196608) return error.InvalidAgentRegistration;
        const parsed = try std.json.parseFromSlice(Registration, a, bytes, .{ .allocate = .alloc_always });
        const value = parsed.value;
        if (value.version != 1 or !validHostId(value.host)) return error.InvalidAgentRegistration;
        try validateEndpoint(value.station);
        try targets.validateServices(value.services);
        if (value.services.len == 0 and value.applications.len == 0) return error.InvalidAgentRegistration;
        if (value.applications.len > 32 or (value.applications.len != 0 and value.metrics_targets.len != 0)) return error.InvalidAgentRegistration;
        var total: usize = 0;
        for (value.applications, 0..) |app, index| {
            try app.validate();
            total += app.services.len;
            for (value.applications[0..index]) |other| if (std.mem.eql(u8, app.name, other.name)) return error.InvalidAgentRegistration;
        }
        if (total > 64) return error.InvalidAgentRegistration;
        if (value.applications.len != 0) {
            var logs: usize = 0;
            for (value.applications, 0..) |app, index| {
                for (app.services) |service| {
                    for (value.applications[0..index]) |other| for (other.services) |other_service| {
                        if (std.mem.eql(u8, service.systemd, other_service.systemd)) return error.InvalidAgentRegistration;
                    };
                    if (service.logs) {
                        logs += 1;
                        var found = false;
                        for (value.services) |selected_unit| if (std.mem.eql(u8, selected_unit, service.systemd)) {
                            found = true;
                        };
                        if (!found) return error.InvalidAgentRegistration;
                    }
                }
            }
            if (logs != value.services.len) return error.InvalidAgentRegistration;
        }
        try targets.validate(value.metrics_targets);
        try targets.validateSelectionSize(value.services, value.metrics_targets);
        return value;
    }
};
pub fn validateEndpoint(value: []const u8) !void {
    if (value.len == 0 or value.len > 253 or value[0] == '-' or value[0] == '.') return error.InvalidStationEndpoint;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return error.InvalidStationEndpoint;
}
pub fn validHostId(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "dt-") or value.len != 35) return false;
    for (value[3..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}
pub fn hostId(a: std.mem.Allocator, output: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, output, "\n");
    const id = try std.fmt.allocPrint(a, "dt-{s}", .{value});
    if (!validHostId(id) or std.mem.eql(u8, value, "00000000000000000000000000000000")) return error.InvalidMachineIdentity;
    return id;
}
test "agent registration uses stable machine identity and bounded public data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try hostId(a, "0123456789abcdef0123456789abcdef\n");
    try std.testing.expect(validHostId(id));
    try std.testing.expectError(error.InvalidMachineIdentity, hostId(a, "../../bad"));
    try std.testing.expectError(error.InvalidStationEndpoint, validateEndpoint("https://station:9443"));
    const value: Registration = .{ .host = id, .station = "monitoring.example.com", .services = &.{"app.service"}, .metrics_targets = &.{} };
    const parsed = try Registration.parse(a, try value.json(a));
    try std.testing.expectEqualStrings(value.host, parsed.host);
}
