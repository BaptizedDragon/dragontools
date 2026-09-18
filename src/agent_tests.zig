const std = @import("std");
const state = @import("agent/state.zig");
const station = @import("agent/station.zig");
const client = @import("agent/client.zig");
const client_store = @import("agent/client_store.zig");
const j = state.j;
const f = state.f;
const pki = state.pki;
const host = "dt-0123456789abcdef0123456789abcdef";
const Services = struct {
    active: [2]bool = .{ false, false },
    mutations: usize = 0,
    fn call(raw: ?*anyopaque, verb: []const u8, kind: []const u8) !bool {
        const self: *Services = @ptrCast(@alignCast(raw.?));
        const index: usize = if (std.mem.eql(u8, kind, "vector")) 0 else 1;
        if (std.mem.eql(u8, verb, "is-active")) return self.active[index];
        self.mutations += 1;
        self.active[index] = std.mem.eql(u8, verb, "start");
        return false;
    }
};
const Fixture = struct {
    temp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    services: Services = .{},
    fn init() !Fixture {
        var result: Fixture = .{ .temp = std.testing.tmpDir(.{}), .arena = .init(std.testing.allocator) };
        errdefer result.deinit();
        const io = std.testing.io;
        for ([_][]const u8{ "etc/dragontools/ingestion", "var/lib/dragontools", "etc/dragontools/vector", "etc/dragontools/vmagent" }) |path| try result.temp.dir.createDirPath(io, path);
        return result;
    }
    fn context(self: *Fixture) state.Context {
        const owner: f.Owner = .{ .uid = std.c.getuid(), .gid = std.c.getgid() };
        return .{ .store = .{ .a = self.arena.allocator(), .io = std.testing.io, .root = self.temp.dir, .root_owner = owner }, .now = 1770000000, .ingestion = owner, .vector = owner, .vmagent = owner, .service_context = &self.services, .service_fn = Services.call };
    }
    fn deinit(self: *Fixture) void {
        self.temp.cleanup();
        self.arena.deinit();
    }
};
fn registration(a: std.mem.Allocator) !j.Value {
    return j.parse(a, "{\"version\":1,\"host\":\"" ++ host ++ "\",\"station\":\"station.example\",\"services\":[\"one.service\"],\"metrics_targets\":[]}", 4096);
}
test "native station bootstraps empty parents migrates registry and preserves exact valid PKI" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const ctx = fixture.context();
    const value = try registration(ctx.store.a);
    for ([_][]const u8{ "pki", "clients", "registry" }) |name| _ = try ctx.store.directory(try ctx.store.path(f.base, name), ctx.store.root_owner, 0o700, true);
    try std.testing.expect(try station.ensure(ctx, value));
    try std.testing.expect(!try ctx.store.registry(ctx.ingestion.gid, false));
    const root = try station.loadCa(ctx);
    const server = try ctx.store.read(f.base ++ "/server/server.crt", ctx.ingestion, 0o400, 16384);
    try std.testing.expect(!try station.ensure(ctx, value));
    const repeated = try station.loadCa(ctx);
    try std.testing.expect(f.equal(root, repeated));
    try std.testing.expectEqualStrings(server, try ctx.store.read(f.base ++ "/server/server.crt", ctx.ingestion, 0o400, 16384));
    try std.testing.expectEqual(@as(usize, 0), (try ctx.store.names(f.base ++ "/clients")).len);
    const inspection = try station.inspect(ctx, host, "station.example");
    try std.testing.expect(try j.get(inspection, "certificate_sha256") == .null);
    try std.testing.expect(std.mem.indexOf(u8, try j.encoded(ctx.store.a, inspection), "PRIVATE KEY") == null);
}
test "native station resumable public CSR signing finalization and unchanged registration" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const ctx = fixture.context();
    const value = try registration(ctx.store.a);
    _ = try station.ensure(ctx, value);
    var key = try pki.Key.generate();
    defer key.deinit();
    const csr = try pki.createClientCsr(ctx.store.a, &key, host);
    const response = try station.stage(ctx, value, csr);
    const fresh_csr = try pki.createClientCsr(ctx.store.a, &key, host);
    const repeat = try station.stage(ctx, value, fresh_csr);
    try std.testing.expect(try j.equal(ctx.store.a, response, repeat));
    try std.testing.expectError(error.CredentialStateRefused, station.verify(ctx, value));
    const fp = try j.field(response, "certificate_sha256");
    try std.testing.expect(try station.finalize(ctx, host, fp));
    try station.verify(ctx, value);
    try std.testing.expect(!try station.finalize(ctx, host, fp));
    try std.testing.expect(!try station.ensure(ctx, value));
    try std.testing.expect(!try station.stageRegistration(ctx, value));
    try std.testing.expect(try j.equal(ctx.store.a, response, try station.stage(ctx, value, fresh_csr)));
    try std.testing.expect(!try ctx.store.exists(f.base ++ "/clients/" ++ host));
}
test {
    _ = @import("pki/pki.zig");
    _ = @import("maintenance/main.zig");
}
fn enroll(station_ctx: state.Context, app_ctx: state.Context) !j.Value {
    const value = try registration(station_ctx.store.a);
    _ = try station.ensure(station_ctx, value);
    const inspection = try station.inspect(station_ctx, host, "station.example");
    const prepared = try client.prepare(app_ctx, host, "station.example", inspection);
    const response = try station.stage(station_ctx, value, try j.field(prepared, "csr"));
    _ = try client.stage(app_ctx, response);
    _ = try client.install(app_ctx, "vector", host, "station.example");
    _ = try client.install(app_ctx, "vmagent", host, "station.example");
    _ = try station.finalize(station_ctx, host, try j.field(response, "certificate_sha256"));
    _ = try client.commit(app_ctx, host, "station.example");
    return response;
}
test "native host enrollment keeps keys local and repeated complete rollout is no-op" {
    var station_fixture = try Fixture.init();
    defer station_fixture.deinit();
    var app_fixture = try Fixture.init();
    defer app_fixture.deinit();
    const sc = station_fixture.context();
    const ac = app_fixture.context();
    const response = try enroll(sc, ac);
    try client.verify(ac, "vector", host, "station.example");
    try client.verify(ac, "vmagent", host, "station.example");
    try std.testing.expect(!try ac.store.exists(f.base ++ "/pki/ca/ca.key"));
    try std.testing.expect(!try sc.store.exists(f.canonical ++ "/client.key"));
    try std.testing.expect(!try sc.store.exists(f.base ++ "/clients/" ++ host));
    const key = try ac.store.read(f.canonical ++ "/client.key", ac.store.root_owner, 0o400, 4096);
    const public = try j.encoded(sc.store.a, response);
    try std.testing.expect(std.mem.indexOf(u8, public, "PRIVATE KEY") == null and std.mem.indexOf(u8, public, key) == null);
    const again = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    try std.testing.expectEqualStrings("unchanged", try j.field(again, "action"));
    try std.testing.expect(try j.get(again, "csr") == .null);
    try std.testing.expect(!try client.install(ac, "vector", host, "station.example"));
    try std.testing.expect(!try client.install(ac, "vmagent", host, "station.example"));
    try std.testing.expect(!try client.commit(ac, host, "station.example"));
    try std.testing.expectEqual(@as(usize, 0), app_fixture.services.mutations);
}
test "native host same-key renewal supports rollback resume and final no-op" {
    var station_fixture = try Fixture.init();
    defer station_fixture.deinit();
    var app_fixture = try Fixture.init();
    defer app_fixture.deinit();
    var sc = station_fixture.context();
    var ac = app_fixture.context();
    const original = try enroll(sc, ac);
    const original_key = try ac.store.read(f.canonical ++ "/client.key", ac.store.root_owner, 0o400, 4096);
    const original_consumer = (try client_store.agentState(ac, "vector")).?;
    sc.now += 340 * 86400;
    ac.now = sc.now;
    const value = try registration(sc.store.a);
    _ = try station.ensure(sc, value);
    const prepared = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    try std.testing.expectEqualStrings("renew", try j.field(prepared, "action"));
    try std.testing.expectEqualStrings(original_key, try ac.store.read(client_store.pending_path ++ "/client.key", ac.store.root_owner, 0o400, 4096));
    const renewed = try station.stage(sc, value, try j.field(prepared, "csr"));
    try std.testing.expect(!try j.equal(sc.store.a, original, renewed));
    _ = try client.stage(ac, renewed);
    app_fixture.services.active = .{ true, true };
    _ = try client.install(ac, "vector", host, "station.example");
    try std.testing.expect(try client.rollback(ac, host, "station.example"));
    try std.testing.expect(f.equal(original_consumer, (try client_store.agentState(ac, "vector")).?));
    try std.testing.expect(app_fixture.services.active[0]);
    _ = try client.install(ac, "vector", host, "station.example");
    _ = try client.install(ac, "vmagent", host, "station.example");
    _ = try station.finalize(sc, host, try j.field(renewed, "certificate_sha256"));
    _ = try client.commit(ac, host, "station.example");
    try client.verify(ac, "vector", host, "station.example");
    try std.testing.expectEqualStrings(original_key, try ac.store.read(f.canonical ++ "/client.key", ac.store.root_owner, 0o400, 4096));
    try std.testing.expect(!try client.install(ac, "vector", host, "station.example"));
}
test "native host recovers a proven local key and reenrolls only when all copies are missing" {
    var station_fixture = try Fixture.init();
    defer station_fixture.deinit();
    var app_fixture = try Fixture.init();
    defer app_fixture.deinit();
    const sc = station_fixture.context();
    const ac = app_fixture.context();
    _ = try enroll(sc, ac);
    const original = try ac.store.read(f.canonical ++ "/client.key", ac.store.root_owner, 0o400, 4096);
    try ac.store.unlink(f.canonical ++ "/client.key");
    const restored = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    try std.testing.expectEqualStrings("unchanged", try j.field(restored, "action"));
    try std.testing.expect(try j.flag(try j.get(restored, "recovered_key")));
    try std.testing.expectEqualStrings(original, try ac.store.read(f.canonical ++ "/client.key", ac.store.root_owner, 0o400, 4096));
    for ([_][]const u8{ f.canonical ++ "/client.key", f.etc ++ "/vector/client.key", f.etc ++ "/vmagent/client.key" }) |path| try ac.store.unlink(path);
    const prepared = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    try std.testing.expectEqualStrings("reenroll", try j.field(prepared, "action"));
    const response = try station.stage(sc, try registration(sc.store.a), try j.field(prepared, "csr"));
    _ = try client.stage(ac, response);
    _ = try client.install(ac, "vector", host, "station.example");
    _ = try client.install(ac, "vmagent", host, "station.example");
    _ = try station.finalize(sc, host, try j.field(response, "certificate_sha256"));
    _ = try client.commit(ac, host, "station.example");
    try std.testing.expect(!std.mem.eql(u8, original, try ac.store.read(f.canonical ++ "/client.key", ac.store.root_owner, 0o400, 4096)));
}

const Fault = struct {
    event: []const u8,
    path: []const u8,
    fired: bool = false,
    failure: anyerror = error.InjectedInterruption,
    fn inject(raw: ?*anyopaque, event: []const u8, path: []const u8) !void {
        const self: *Fault = @ptrCast(@alignCast(raw.?));
        if (!self.fired and std.mem.eql(u8, event, self.event) and std.mem.eql(u8, path, self.path)) {
            self.fired = true;
            return self.failure;
        }
    }
    fn context(self: *Fault, ctx: state.Context) state.Context {
        var result = ctx;
        result.store.fault_context = self;
        result.store.fault = inject;
        return result;
    }
};
fn prepareStage(sc: state.Context, ac: state.Context, endpoint: []const u8) !j.Value {
    var value = try registration(sc.store.a);
    try value.object.put(sc.store.a, "station", j.string(endpoint));
    _ = try station.ensure(sc, value);
    const prepared = try client.prepare(ac, host, endpoint, try station.inspect(sc, host, endpoint));
    const response = try station.stage(sc, value, try j.field(prepared, "csr"));
    _ = try client.stage(ac, response);
    return response;
}
fn finish(sc: state.Context, ac: state.Context, response: j.Value, endpoint: []const u8) !void {
    _ = try station.finalize(sc, host, try j.field(response, "certificate_sha256"));
    _ = try client.commit(ac, host, endpoint);
}
fn bytes(ctx: state.Context, path: []const u8) ![]const u8 {
    return ctx.store.read(path, ctx.store.root_owner, 0o400, f.limit);
}
test "native failed CA validation and private publication leave clean bootstrap parents" {
    for ([_][]const u8{ "validate_ca", "before_publish" }) |event| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const ctx = fixture.context();
        const value = try registration(ctx.store.a);
        var fault: Fault = .{ .event = event, .path = f.base ++ "/pki/ca" };
        try std.testing.expectError(error.InjectedInterruption, station.ensure(fault.context(ctx), value));
        try std.testing.expect(fault.fired);
        try std.testing.expectEqual(@as(usize, 0), (try ctx.store.names(f.base ++ "/pki")).len);
        try std.testing.expect(try station.ensure(ctx, value));
        try std.testing.expect(!try station.ensure(ctx, value));
    }
}
test "native CA corruption missing roots and near-expiry require repair without rotation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context();
    const value = try registration(ctx.store.a);
    _ = try station.ensure(ctx, value);
    const root = try station.loadCa(ctx);
    ctx.now += 3300 * 86400;
    try std.testing.expectError(error.CaMaintenanceRequired, station.ensure(ctx, value));
    try std.testing.expect(f.equal(root, try station.loadCa(ctx)));
    ctx.now -= 3300 * 86400;
    _ = try ctx.store.atomic(f.base ++ "/pki/ca/ca.crt", "broken certificate", ctx.store.root_owner, 0o400, f.base ++ "/pki");
    if (station.ensure(ctx, value)) |_| return error.ExpectedFailure else |_| {}
    try std.testing.expectEqualStrings("broken certificate", try bytes(ctx, f.base ++ "/pki/ca/ca.crt"));
    try ctx.store.rename(f.base ++ "/pki/ca", f.base ++ "/pki/saved-ca", false);
    try std.testing.expectError(error.CaMaintenanceRequired, station.ensure(ctx, value));
    try std.testing.expect(!try ctx.store.exists(f.base ++ "/pki/ca"));
}
test "native registry read-only metadata rejection and owned directory migration" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const ctx = fixture.context();
    const value = try registration(ctx.store.a);
    _ = try station.ensure(ctx, value);
    const dir = try fixture.temp.dir.openDir(std.testing.io, "etc/dragontools/ingestion/registry", .{});
    defer dir.close(std.testing.io);
    try dir.setPermissions(std.testing.io, .fromMode(0o700));
    try std.testing.expectError(error.RegistryPermissions, ctx.store.registry(ctx.ingestion.gid, false));
    try std.testing.expectEqual(@as(u32, 0o700), (try dir.stat(std.testing.io)).permissions.toMode() & 0o7777);
    try std.testing.expectError(error.RegistryPermissions, ctx.store.registry(ctx.ingestion.gid + 1, true));
    var wrong_owner = ctx.store;
    wrong_owner.root_owner.uid += 1;
    try std.testing.expectError(error.RegistryPermissions, wrong_owner.registry(ctx.ingestion.gid, true));
    try std.testing.expect(try ctx.store.registry(ctx.ingestion.gid, true));
    try std.testing.expect(!try ctx.store.registry(ctx.ingestion.gid, true));
    try std.testing.expect(!try station.ensure(ctx, value));
    try std.testing.expectError(error.CredentialStateRefused, ctx.store.directory("/tmp/registry", ctx.store.root_owner, 0o750, true));
}
test "native registry refuses files and symlink escape without modifying targets" {
    for ([_]bool{ false, true }) |link| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const ctx = fixture.context();
        if (link) {
            try fixture.temp.dir.createDir(std.testing.io, "outside", .fromMode(0o700));
            try fixture.temp.dir.symLink(std.testing.io, "../../../outside", "etc/dragontools/ingestion/registry", .{ .is_directory = true });
        } else try ctx.store.write(f.base ++ "/registry", "untouched", ctx.store.root_owner, 0o400);
        try std.testing.expectError(error.RegistryPermissions, station.ensure(ctx, try registration(ctx.store.a)));
        if (!link) try std.testing.expectEqualStrings("untouched", try bytes(ctx, f.base ++ "/registry"));
    }
}
test "native hostname change keeps CA server key client identity and registration finalization no-op" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    const sc = sf.context();
    const ac = af.context();
    _ = try enroll(sc, ac);
    const ca = try station.loadCa(sc);
    const server_key = try bytes(sc, f.base ++ "/server/server.key");
    const client_key = try bytes(ac, f.canonical ++ "/client.key");
    var value = try registration(sc.store.a);
    try value.object.put(sc.store.a, "station", j.string("new.example"));
    var fault: Fault = .{ .event = "after_publish", .path = f.base ++ "/server/server.crt" };
    try std.testing.expectError(error.InjectedInterruption, station.ensure(fault.context(sc), value));
    const cert = try bytes(sc, f.base ++ "/server/server.crt");
    try std.testing.expect(!try station.ensure(sc, value));
    try std.testing.expectEqualStrings(cert, try bytes(sc, f.base ++ "/server/server.crt"));
    try std.testing.expectEqualStrings(server_key, try bytes(sc, f.base ++ "/server/server.key"));
    try std.testing.expect(f.equal(ca, try station.loadCa(sc)));
    _ = try station.verifyServer(sc, "station.example", false);
    _ = try station.verifyServer(sc, "new.example", false);
    const prepared = try client.prepare(ac, host, "new.example", try station.inspect(sc, host, "new.example"));
    try std.testing.expectEqualStrings("unchanged", try j.field(prepared, "action"));
    try std.testing.expect(!try client.install(ac, "vector", host, "new.example"));
    try std.testing.expectEqualStrings(client_key, try bytes(ac, f.canonical ++ "/client.key"));
    try std.testing.expect(try station.stageRegistration(sc, value));
    _ = try station.finalize(sc, host, try j.field(prepared, "certificate_sha256"));
    try station.verify(sc, value);
    try std.testing.expect(!try station.stageRegistration(sc, value));
}
test "native rollout recovers interrupted consumer canonical publication and cleanup" {
    for ([_][]const u8{ f.etc ++ "/vector/client.crt", f.canonical ++ "/ca.crt", f.canonical ++ "/.completed" }) |path| {
        var sf = try Fixture.init();
        defer sf.deinit();
        var af = try Fixture.init();
        defer af.deinit();
        const sc = sf.context();
        const ac = af.context();
        const response = try prepareStage(sc, ac, "station.example");
        var fault: Fault = .{ .event = "after_publish", .path = path };
        if (std.mem.indexOf(u8, path, "/vector/") != null) {
            try std.testing.expectError(error.InjectedInterruption, client.install(fault.context(ac), "vector", host, "station.example"));
            try std.testing.expect(try client.install(ac, "vector", host, "station.example"));
        } else _ = try client.install(ac, "vector", host, "station.example");
        _ = try station.finalize(sc, host, try j.field(response, "certificate_sha256"));
        if (!fault.fired) try std.testing.expectError(error.InjectedInterruption, client.commit(fault.context(ac), host, "station.example"));
        if (std.mem.endsWith(u8, path, "/.completed")) try ac.store.unlink(f.canonical ++ "/.completed/request.csr");
        _ = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
        _ = try client.commit(ac, host, "station.example");
        try client.verify(ac, "vector", host, "station.example");
        try std.testing.expect(!try client.commit(ac, host, "station.example"));
        try std.testing.expect(!try client.install(ac, "vector", host, "station.example"));
    }
}
test "native renewal resumes after a long interrupted completed-generation cleanup" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    var sc = sf.context();
    var ac = af.context();
    const response = try prepareStage(sc, ac, "station.example");
    _ = try client.install(ac, "vector", host, "station.example");
    _ = try station.finalize(sc, host, try j.field(response, "certificate_sha256"));
    var fault: Fault = .{ .event = "after_publish", .path = f.canonical ++ "/.completed" };
    try std.testing.expectError(error.InjectedInterruption, client.commit(fault.context(ac), host, "station.example"));
    try ac.store.unlink(f.canonical ++ "/.completed/request.csr");
    const key = try bytes(ac, f.canonical ++ "/client.key");
    sc.now += 340 * 86400;
    ac.now = sc.now;
    const value = try registration(sc.store.a);
    _ = try station.ensure(sc, value);
    const prepared = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    try std.testing.expectEqualStrings("renew", try j.field(prepared, "action"));
    try std.testing.expect(!try ac.store.exists(f.canonical ++ "/.completed"));
    const renewed = try station.stage(sc, value, try j.field(prepared, "csr"));
    _ = try client.stage(ac, renewed);
    _ = try client.install(ac, "vector", host, "station.example");
    _ = try station.finalize(sc, host, try j.field(renewed, "certificate_sha256"));
    _ = try client.commit(ac, host, "station.example");
    try client.verify(ac, "vector", host, "station.example");
    try std.testing.expectEqualStrings(key, try bytes(ac, f.canonical ++ "/client.key"));
    try std.testing.expect(!try client.install(ac, "vector", host, "station.example"));
    try std.testing.expect(!try client.commit(ac, host, "station.example"));
}
test "native expired managed identity renews same key and disabled consumer rejoins historical generation" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    var sc = sf.context();
    var ac = af.context();
    const first = try enroll(sc, ac);
    const key = try bytes(ac, f.canonical ++ "/client.key");
    sc.now += 367 * 86400;
    ac.now = sc.now;
    if (client.verify(ac, "vector", host, "station.example")) |_| return error.ExpectedFailure else |_| {}
    const response = try prepareStage(sc, ac, "station.example");
    _ = try client.install(ac, "vector", host, "station.example");
    try finish(sc, ac, response, "station.example");
    try std.testing.expectEqualStrings(try j.field(first, "client.crt"), try bytes(ac, f.etc ++ "/vmagent/client.crt"));
    try std.testing.expectEqualStrings(key, try bytes(ac, f.canonical ++ "/client.key"));
    try std.testing.expect(try client.install(ac, "vmagent", host, "station.example"));
    try client.verify(ac, "vmagent", host, "station.example");
    try std.testing.expect(!try client.install(ac, "vmagent", host, "station.example"));
}
test "native pending lease expiration and reissue after failed public publication retain same key" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    var sc = sf.context();
    var ac = af.context();
    const first = try prepareStage(sc, ac, "station.example");
    const key = try bytes(ac, client_store.pending_path ++ "/client.key");
    sc.now += 86401;
    ac.now = sc.now;
    try std.testing.expectError(error.CredentialStateRefused, station.finalize(sc, host, try j.field(first, "certificate_sha256")));
    sc.now += 370 * 86400;
    ac.now = sc.now;
    _ = try station.ensure(sc, try registration(sc.store.a));
    const prepared = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    const second = try station.stage(sc, try registration(sc.store.a), try j.field(prepared, "csr"));
    var fault: Fault = .{ .event = "after_publish", .path = client_store.pending_path ++ "/client.crt" };
    try std.testing.expectError(error.InjectedInterruption, client.stage(fault.context(ac), second));
    _ = try client.stage(ac, second);
    try std.testing.expectEqualStrings(key, try bytes(ac, client_store.pending_path ++ "/client.key"));
    _ = try client.install(ac, "vector", host, "station.example");
    try finish(sc, ac, second, "station.example");
    try std.testing.expectEqualStrings("unchanged", try j.field(try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example")), "action"));
}

fn installConsumerFixture(ctx: state.Context, kind: []const u8, values: f.Files) !void {
    const path = try ctx.store.path(f.etc, kind);
    try ctx.store.write(try ctx.store.path(path, ".dragontools-credentials"), f.marker, ctx.store.root_owner, 0o400);
    try ctx.store.write(try ctx.store.path(path, ".agent-identity"), try client_store.consumerIdentity(ctx, host, "station.example"), ctx.store.root_owner, 0o400);
    for (f.secrets) |name| try ctx.store.write(try ctx.store.path(path, name), try f.item(values, name), try ctx.account(kind), 0o400);
}
fn legacyFixture(sc: state.Context, ac: state.Context) !f.Files {
    const value = try registration(sc.store.a);
    _ = try station.ensure(sc, value);
    const ca = try station.loadCa(sc);
    var ca_key = try pki.Key.parse(sc.store.a, try f.item(ca, "ca.key"));
    defer ca_key.deinit();
    var key = try pki.Key.generate();
    defer key.deinit();
    const cert = try @import("pki/test_support.zig").certificate(sc.store.a, &key, &ca_key, host, .legacy, sc.now);
    var values: f.Files = .empty;
    try values.put(sc.store.a, "client.key", try key.privatePem(sc.store.a));
    try values.put(sc.store.a, "client.crt", cert);
    try sc.store.createBundle(f.base ++ "/clients/" ++ host, sc.store.root_owner, 0o700, values, f.marker);
    var active = try j.copy(sc.store.a, value);
    try active.object.put(sc.store.a, "certificate_sha256", j.string(try sc.fingerprint(cert)));
    _ = try station.saveRegistry(sc, host, active);
    try values.put(sc.store.a, "ca.crt", try f.item(ca, "ca.crt"));
    for (client_store.kinds) |kind| try installConsumerFixture(ac, kind, values);
    return values;
}
test "native legacy migration signing failure bad response rollback and interrupted unlink preserve locality" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    const sc = sf.context();
    const ac = af.context();
    const old = try legacyFixture(sc, ac);
    const prepared = try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example"));
    try std.testing.expectEqualStrings("migrate", try j.field(prepared, "action"));
    try std.testing.expect(!std.mem.eql(u8, try f.item(old, "client.key"), try bytes(ac, client_store.pending_path ++ "/client.key")));
    if (station.stage(sc, try registration(sc.store.a), "malformed public CSR")) |_| return error.ExpectedFailure else |_| {}
    try std.testing.expectEqualStrings(try f.item(old, "client.key"), try bytes(ac, f.etc ++ "/vector/client.key"));
    const response = try station.stage(sc, try registration(sc.store.a), try j.field(prepared, "csr"));
    var bad = try j.copy(sc.store.a, response);
    try bad.object.put(sc.store.a, "client.crt", try j.get(response, "ca.crt"));
    if (client.stage(ac, bad)) |_| return error.ExpectedFailure else |_| {}
    try std.testing.expect(!try client.rollback(ac, host, "station.example"));
    _ = try client.stage(ac, response);
    af.services.active = .{ true, true };
    _ = try client.install(ac, "vector", host, "station.example");
    try std.testing.expect(try client.rollback(ac, host, "station.example"));
    try std.testing.expectEqualStrings(try f.item(old, "client.key"), try bytes(ac, f.etc ++ "/vector/client.key"));
    try std.testing.expect(af.services.active[0]);
    _ = try client.install(ac, "vector", host, "station.example");
    var fault: Fault = .{ .event = "before_unlink", .path = f.base ++ "/clients/" ++ host ++ "/client.key" };
    try std.testing.expectError(error.InjectedInterruption, station.finalize(fault.context(sc), host, try j.field(response, "certificate_sha256")));
    try std.testing.expect(try sc.store.exists(fault.path));
    try std.testing.expect(try j.equal(sc.store.a, response, try station.stage(sc, try registration(sc.store.a), try j.field(prepared, "csr"))));
    try finish(sc, ac, response, "station.example");
    try std.testing.expect(!try sc.store.exists(fault.path));
    try std.testing.expectEqualStrings(try f.item(old, "client.key"), try bytes(ac, f.etc ++ "/vmagent/client.key"));
    _ = try client.install(ac, "vmagent", host, "station.example");
    try client.verify(ac, "vmagent", host, "station.example");
    try std.testing.expect(!try client.install(ac, "vmagent", host, "station.example"));
}
test "native expired legacy credentials migrate and retain working material until commit" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    var sc = sf.context();
    var ac = af.context();
    const old = try legacyFixture(sc, ac);
    sc.now += 367 * 86400;
    ac.now = sc.now;
    _ = try station.ensure(sc, try registration(sc.store.a));
    const inspection = try station.inspect(sc, host, "station.example");
    try std.testing.expect(try j.flag(try j.get(inspection, "legacy_expired")));
    if (client.verify(ac, "vector", host, "station.example")) |_| return error.ExpectedFailure else |_| {}
    const response = try prepareStage(sc, ac, "station.example");
    try std.testing.expectEqualStrings(try f.item(old, "client.key"), try bytes(ac, f.etc ++ "/vector/client.key"));
    _ = try client.install(ac, "vector", host, "station.example");
    _ = try client.install(ac, "vmagent", host, "station.example");
    try finish(sc, ac, response, "station.example");
    try client.verify(ac, "vector", host, "station.example");
}
test "native backend accepts existing OpenSSL station and host bundles byte-for-byte with no restart" {
    var sf = try Fixture.init();
    defer sf.deinit();
    var af = try Fixture.init();
    defer af.deinit();
    var sc = sf.context();
    var ac = af.context();
    var ca = try pki.Certificate.parse(sc.store.a, @embedFile("pki/fixtures/openssl-ca.crt"));
    defer ca.deinit();
    sc.now = try ca.validFrom() + 120;
    ac.now = sc.now;
    const value = try registration(sc.store.a);
    _ = try station.ensure(sc, value);
    inline for (.{ "ca.crt", "ca.key" }) |name| _ = try sc.store.atomic(f.base ++ "/pki/ca/" ++ name, @embedFile("pki/fixtures/openssl-" ++ name), sc.store.root_owner, 0o400, f.base ++ "/pki");
    inline for (.{ "server.crt", "server.key" }) |name| _ = try sc.store.atomic(f.base ++ "/server/" ++ name, @embedFile("pki/fixtures/openssl-" ++ name), sc.ingestion, 0o400, f.base);
    _ = try sc.store.atomic(f.base ++ "/server/ca.crt", @embedFile("pki/fixtures/openssl-ca.crt"), sc.ingestion, 0o400, f.base);
    var values: f.Files = .empty;
    inline for (.{ "ca.crt", "client.crt", "client.key" }) |name| try values.put(ac.store.a, name, @embedFile("pki/fixtures/openssl-" ++ name));
    const cert = try f.item(values, "client.crt");
    try values.put(ac.store.a, "identity.json", try client_store.identity(ac, host, "station.example", cert, try j.object(ac.store.a, &.{})));
    try client_store.create(ac, f.canonical, values);
    for (client_store.kinds) |kind| try installConsumerFixture(ac, kind, values);
    var active = try j.copy(sc.store.a, value);
    try active.object.put(sc.store.a, "certificate_sha256", j.string(try sc.fingerprint(cert)));
    try active.object.put(sc.store.a, "certificate_pem", j.string(cert));
    try active.object.put(sc.store.a, "certificate_identity", j.string(try pki.profile.identity(sc.store.a, host)));
    _ = try station.saveRegistry(sc, host, active);
    try sc.store.unlink(f.state ++ "/ingestion-restart-required");
    try std.testing.expect(!try station.ensure(sc, value));
    try station.verify(sc, value);
    try std.testing.expectEqualStrings("unchanged", try j.field(try client.prepare(ac, host, "station.example", try station.inspect(sc, host, "station.example")), "action"));
    for (client_store.kinds) |kind| try std.testing.expect(!try client.install(ac, kind, host, "station.example"));
    try std.testing.expect(!try client.commit(ac, host, "station.example"));
    try std.testing.expectEqualStrings(@embedFile("pki/fixtures/openssl-ca.crt"), try bytes(sc, f.base ++ "/pki/ca/ca.crt"));
    try std.testing.expectEqualStrings(@embedFile("pki/fixtures/openssl-server.crt"), try bytes(sc, f.base ++ "/server/server.crt"));
    try std.testing.expect(f.equal(values, (try client_store.inspectRoot(ac, host, "station.example", false)).?));
    try std.testing.expect(!try sc.store.exists(f.state ++ "/ingestion-restart-required"));
    try std.testing.expectEqual(@as(usize, 0), af.services.mutations);
}

const diagnostics = @import("agent/diagnostics.zig");
fn ensureFailure(ctx: state.Context, value: j.Value, stage: *diagnostics.Stage) !struct { err: anyerror } {
    var tracked = ctx;
    tracked.diagnostic_stage = stage;
    if (station.ensure(tracked, value)) |_| return error.ExpectedFailure else |err| return .{ .err = err };
}
test "native bootstrap diagnostics identify CA and server failures without changing recovery" {
    const Case = struct { event: []const u8, path: []const u8, stage: diagnostics.Stage, reason: diagnostics.AgentError, ca_published: bool = false };
    const ca_path = f.base ++ "/pki/ca";
    const server_path = f.base ++ "/server";
    for ([_]Case{
        .{ .event = "generate_ca_key", .path = ca_path, .stage = .ca_key_generation, .reason = .CryptoKeyGenerationFailed },
        .{ .event = "generate_ca_certificate", .path = ca_path, .stage = .ca_certificate_generation, .reason = .CertificateGenerationFailed },
        .{ .event = "validate_ca", .path = ca_path, .stage = .ca_certificate_validation, .reason = .CertificateValidationFailed },
        .{ .event = "before_publish", .path = ca_path, .stage = .ca_publication, .reason = .FilesystemStateRefused },
        .{ .event = "generate_server_key", .path = server_path, .stage = .server_key_generation, .reason = .CryptoKeyGenerationFailed, .ca_published = true },
        .{ .event = "generate_server_certificate", .path = server_path, .stage = .server_certificate_generation, .reason = .CertificateGenerationFailed, .ca_published = true },
        .{ .event = "validate_server", .path = server_path, .stage = .server_certificate_validation, .reason = .CertificateValidationFailed, .ca_published = true },
        .{ .event = "before_publish", .path = server_path, .stage = .server_publication, .reason = .FilesystemStateRefused, .ca_published = true },
    }) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const ctx = fixture.context();
        // Exact production failure state: only the three managed empty parents.
        for ([_][]const u8{ "pki", "clients" }) |name| _ = try ctx.store.directory(try ctx.store.path(f.base, name), ctx.store.root_owner, 0o700, true);
        _ = try ctx.store.registry(ctx.ingestion.gid, true);
        const value = try registration(ctx.store.a);
        var fault: Fault = .{ .event = case.event, .path = case.path, .failure = error.InvalidPki };
        var stage: diagnostics.Stage = .request;
        const err = (try ensureFailure(fault.context(ctx), value, &stage)).err;
        try std.testing.expect(fault.fired);
        try std.testing.expectEqual(@as(u8, 86), @import("agent/protocol.zig").exitCode(err));
        const diagnostic = diagnostics.failure(stage, err);
        try std.testing.expectEqual(case.stage, diagnostic.stage);
        try std.testing.expectEqual(case.reason, diagnostic.reason);
        var buffer: [diagnostics.limit]u8 = undefined;
        const output = diagnostic.render(&buffer);
        try std.testing.expectEqual(diagnostic, diagnostics.parse(output).?);
        try std.testing.expect(std.mem.indexOf(u8, output, "PRIVATE KEY") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, f.base) == null);
        try std.testing.expect(!try ctx.store.exists(server_path));
        const saved_ca: ?f.Files = if (case.ca_published) try station.loadCa(ctx) else null;
        if (saved_ca == null) try std.testing.expectEqual(@as(usize, 0), (try ctx.store.names(f.base ++ "/pki")).len);
        try std.testing.expect(try station.ensure(ctx, value));
        try std.testing.expect(!try station.ensure(ctx, value));
        if (saved_ca) |root| try std.testing.expect(f.equal(root, try station.loadCa(ctx)));
    }
}
test "native CA validation diagnostic never echoes key bytes or replaces invalid CA" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const ctx = fixture.context();
    const value = try registration(ctx.store.a);
    _ = try station.ensure(ctx, value);
    const key = try bytes(ctx, f.base ++ "/pki/ca/ca.key");
    // Malformed certificate deliberately contains actual private material.
    _ = try ctx.store.atomic(f.base ++ "/pki/ca/ca.crt", key, ctx.store.root_owner, 0o400, f.base ++ "/pki");
    var stage: diagnostics.Stage = .request;
    const err = (try ensureFailure(ctx, value, &stage)).err;
    var buffer: [diagnostics.limit]u8 = undefined;
    const output = diagnostics.failure(stage, err).render(&buffer);
    try std.testing.expectEqualStrings("AgentStage: ca_certificate_validation\nAgentError: CertificateValidationFailed\n", output);
    try std.testing.expect(std.mem.indexOf(u8, output, key) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PRIVATE KEY") == null);
    try std.testing.expectEqualStrings(key, try bytes(ctx, f.base ++ "/pki/ca/ca.crt"));
    try std.testing.expectEqualStrings(key, try bytes(ctx, f.base ++ "/pki/ca/ca.key"));
}
test "native managed directory refusal and registry permissions keep distinct diagnostics and exit codes" {
    for ([_]bool{ false, true }) |registry| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const ctx = fixture.context();
        const path = if (registry) f.base ++ "/registry" else f.base ++ "/pki";
        try ctx.store.write(path, "private-sentinel", ctx.store.root_owner, 0o400);
        var stage: diagnostics.Stage = .request;
        const err = (try ensureFailure(ctx, try registration(ctx.store.a), &stage)).err;
        try std.testing.expectEqual(@as(u8, if (registry) 89 else 86), @import("agent/protocol.zig").exitCode(err));
        const diagnostic = diagnostics.failure(stage, err);
        try std.testing.expectEqual(if (registry) diagnostics.Stage.registry_prepare else .managed_directories, diagnostic.stage);
        try std.testing.expectEqual(if (registry) diagnostics.AgentError.RegistryPermissions else .FilesystemStateRefused, diagnostic.reason);
        try std.testing.expectEqualStrings("private-sentinel", try bytes(ctx, path));
    }
}
test "native CA maintenance retains exit 87 and existing root with diagnostics enabled" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var ctx = fixture.context();
    const value = try registration(ctx.store.a);
    _ = try station.ensure(ctx, value);
    const root = try station.loadCa(ctx);
    ctx.now += 3300 * 86400;
    var stage: diagnostics.Stage = .request;
    const err = (try ensureFailure(ctx, value, &stage)).err;
    try std.testing.expectEqual(error.CaMaintenanceRequired, err);
    try std.testing.expectEqual(@as(u8, 87), @import("agent/protocol.zig").exitCode(err));
    try std.testing.expectEqual(diagnostics.AgentError.CaMaintenanceRequired, diagnostics.failure(stage, err).reason);
    try std.testing.expect(f.equal(root, try station.loadCa(ctx)));
}
