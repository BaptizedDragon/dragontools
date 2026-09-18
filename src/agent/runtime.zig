const std = @import("std");
const s = @import("state.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
    @cInclude("unistd.h");
});
pub fn protect() !void {
    const limit: c.struct_rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    try s.j.require(c.setrlimit(c.RLIMIT_CORE, &limit) == 0);
    _ = c.umask(0o077);
}
fn owner(name: [:0]const u8, required: bool) !s.f.Owner {
    if (c.getpwnam(name)) |entry| return .{ .uid = entry.*.pw_uid, .gid = entry.*.pw_gid };
    if (required) return error.CredentialAccountMissing;
    return .{ .uid = std.math.maxInt(std.posix.uid_t), .gid = std.math.maxInt(std.posix.gid_t) };
}
pub const Runtime = struct {
    a: std.mem.Allocator,
    io: std.Io,
    pub fn context(self: *Runtime, root: std.Io.Dir, station: bool) !s.Context {
        try s.j.require(c.geteuid() == 0);
        return .{ .store = .{ .a = self.a, .io = self.io, .root = root }, .now = std.Io.Clock.real.now(self.io).toSeconds(), .ingestion = try owner("dt-ingest", station), .vector = try owner("dt-vector", false), .vmagent = try owner("dt-vmagent", false), .service_context = self, .service_fn = service };
    }
    fn service(raw: ?*anyopaque, verb: []const u8, kind: []const u8) !bool {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        try s.j.require(s.j.contains(&.{ "is-active", "stop", "start" }, verb) and s.j.contains(&.{ "vector", "vmagent" }, kind));
        const unit = try std.fmt.allocPrint(self.a, "dragontools-{s}.service", .{kind});
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } };
        const result = try std.process.run(self.a, self.io, .{ .argv = &.{ "/usr/bin/systemctl", verb, unit }, .stdout_limit = .limited(1024), .stderr_limit = .limited(4096), .timeout = timeout });
        defer std.crypto.secureZero(u8, result.stderr);
        try s.j.require(result.term == .exited);
        const code = result.term.exited;
        if (std.mem.eql(u8, verb, "is-active")) {
            const output = std.mem.trim(u8, result.stdout, "\r\n \t");
            if (s.j.contains(&.{ "active", "activating", "reloading", "deactivating" }, output)) {
                try s.j.require(code == 0);
                return true;
            }
            try s.j.require((code == 3 or code == 4) and s.j.contains(&.{ "inactive", "failed", "unknown" }, output));
            return false;
        }
        try s.j.require(code == 0);
        return false;
    }
};
pub fn lock(io: std.Io, root: std.Io.Dir) !std.Io.Dir {
    // Advisory lock on the existing managed directory: read-only verification
    // creates no lock file and alters no credential metadata. No unbounded wait.
    const etc = try root.openDir(io, "etc", .{ .follow_symlinks = false });
    defer etc.close(io);
    const dir = try etc.openDir(io, "dragontools", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    try s.j.require(c.flock(dir.handle, c.LOCK_EX | c.LOCK_NB) == 0);
    return dir;
}
