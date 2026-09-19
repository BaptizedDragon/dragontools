//! Local, bounded credential storage. Never follows a link in a managed path.
const std = @import("std");
const Metadata = extern struct { uid: u64, gid: u64, mode: u64, nlink: u64 };
extern "c" fn dragontools_file_metadata(fd: c_int, out: *Metadata) c_int;
const j = @import("json.zig");
const pki = @import("../pki/pki.zig");
pub const Files = std.StringHashMapUnmanaged([]const u8);
pub const Owner = struct { uid: std.posix.uid_t, gid: std.posix.gid_t };
pub const marker = "DragonTools agent mTLS v1\n";
pub const client_marker = "DragonTools host-local client identity v1\n";
pub const etc = "/etc/dragontools";
pub const base = etc ++ "/ingestion";
pub const state = "/var/lib/dragontools";
pub const canonical = etc ++ "/monitoring-client";
pub const secrets = [_][]const u8{ "ca.crt", "client.crt", "client.key" };
pub const client_files = secrets ++ [_][]const u8{"identity.json"};
pub const limit = 393216;
pub fn item(values: Files, name: []const u8) ![]const u8 {
    return values.get(name) orelse error.CredentialStateRefused;
}
pub fn equal(left: Files, right: Files) bool {
    if (left.count() != right.count()) return false;
    var it = left.iterator();
    while (it.next()) |entry| if (!std.mem.eql(u8, entry.value_ptr.*, right.get(entry.key_ptr.*) orelse return false)) return false;
    return true;
}
pub fn matches(values: Files, name: []const u8, data: []const u8) bool {
    return std.mem.eql(u8, data, values.get(name) orelse return false);
}
pub fn selected(a: std.mem.Allocator, values: Files, names: []const []const u8) !Files {
    var result: Files = .empty;
    for (names) |name| if (values.get(name)) |data| try result.put(a, name, data);
    return result;
}
pub fn keys(values: Files, names: []const []const u8) !void {
    try j.require(values.count() == names.len);
    for (names) |name| try j.require(values.contains(name));
}
pub fn copy(a: std.mem.Allocator, values: Files) !Files {
    var result: Files = .empty;
    var it = values.iterator();
    while (it.next()) |entry| try result.put(a, entry.key_ptr.*, entry.value_ptr.*);
    return result;
}
pub const Store = struct {
    a: std.mem.Allocator,
    io: std.Io,
    // Production uses /. Tests inject an isolated root; no CLI path override.
    root: std.Io.Dir,
    root_owner: Owner = .{ .uid = 0, .gid = 0 },
    // Test-injected interruption boundaries; production never sets this hook.
    fault_context: ?*anyopaque = null,
    fault: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!void = null,
    pub fn checkpoint(self: Store, event: []const u8, pathname: []const u8) anyerror!void {
        if (self.fault) |inject| try inject(self.fault_context, event, pathname);
    }
    pub fn path(self: Store, dir: []const u8, name: []const u8) ![]const u8 {
        try j.require(name.len > 0 and std.mem.indexOfScalar(u8, name, '/') == null and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."));
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ dir, name });
    }
    fn allowed(pathname: []const u8) !void {
        try j.require(std.mem.eql(u8, pathname, etc) or std.mem.startsWith(u8, pathname, etc ++ "/") or std.mem.eql(u8, pathname, state) or std.mem.startsWith(u8, pathname, state ++ "/"));
        try j.require(pathname.len < 4096 and std.mem.indexOfScalar(u8, pathname, 0) == null);
        var parts = std.mem.splitScalar(u8, pathname[1..], '/');
        while (parts.next()) |part| try j.require(part.len != 0 and !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, ".."));
    }
    fn walk(self: Store, pathname: []const u8) !std.Io.Dir {
        var current = try self.root.openDir(self.io, ".", .{ .iterate = true });
        errdefer current.close(self.io);
        var parts = std.mem.splitScalar(u8, pathname[1..], '/');
        while (parts.next()) |part| {
            if ((try current.statFile(self.io, part, .{ .follow_symlinks = false })).kind == .sym_link) return error.UnexpectedManagedSymlink;
            const next = try current.openDir(self.io, part, .{ .iterate = true, .follow_symlinks = false });
            current.close(self.io);
            current = next;
            var st: Metadata = undefined;
            try j.require(dragontools_file_metadata(current.handle, &st) == 0 and st.uid == self.root_owner.uid and st.mode & 0o022 == 0);
        }
        return current;
    }
    fn parent(self: Store, pathname: []const u8) !std.Io.Dir {
        try allowed(pathname);
        return self.walk(std.fs.path.dirname(pathname) orelse return error.CredentialStateRefused);
    }
    fn metadata(fd: std.posix.fd_t, owner: Owner, mode: ?u16, kind: u32) !void {
        var st: Metadata = undefined;
        try j.require(dragontools_file_metadata(fd, &st) == 0);
        try j.require(st.uid == owner.uid and st.gid == owner.gid and st.mode & std.posix.S.IFMT == kind);
        if (mode) |wanted| try j.require(st.mode & 0o7777 == wanted);
        if (kind == std.posix.S.IFREG) try j.require(st.nlink == 1);
    }
    fn syncDir(self: Store, dir: std.Io.Dir) !void {
        try (std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } }).sync(self.io);
    }
    pub fn sync(self: Store, pathname: []const u8) !void {
        try allowed(pathname);
        const dir = try self.walk(pathname);
        defer dir.close(self.io);
        try self.syncDir(dir);
    }
    pub fn exists(self: Store, pathname: []const u8) !bool {
        const dir = self.parent(pathname) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close(self.io);
        _ = dir.statFile(self.io, std.fs.path.basename(pathname), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
    pub fn directory(self: Store, pathname: []const u8, owner: Owner, mode: u16, create: bool) !bool {
        const dir = try self.parent(pathname);
        defer dir.close(self.io);
        const name = std.fs.path.basename(pathname);
        var changed = false;
        if (dir.statFile(self.io, name, .{ .follow_symlinks = false })) |st| {
            if (st.kind == .sym_link) return error.UnexpectedManagedSymlink;
        } else |err| if (err != error.FileNotFound) return err;
        const child = dir.openDir(self.io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound or !create) return err;
            try dir.createDir(self.io, name, .fromMode(0o700));
            changed = true;
            break :blk try dir.openDir(self.io, name, .{ .iterate = true, .follow_symlinks = false });
        };
        defer child.close(self.io);
        if (changed) {
            try child.setOwner(self.io, owner.uid, owner.gid);
            try child.setPermissions(self.io, .fromMode(mode));
            try self.syncDir(child);
            try self.syncDir(dir);
        }
        try metadata(child.handle, owner, mode, std.posix.S.IFDIR);
        return changed;
    }
    pub fn registry(self: Store, group: std.posix.gid_t, reconcile: bool) !bool {
        return self.registryInner(group, reconcile) catch error.RegistryPermissions;
    }
    fn registryInner(self: Store, group: std.posix.gid_t, reconcile: bool) !bool {
        _ = try self.directory(etc, self.root_owner, 0o755, false);
        _ = try self.directory(base, self.root_owner, 0o755, false);
        const dir = try self.walk(base);
        defer dir.close(self.io);
        var changed = false;
        const child = dir.openDir(self.io, "registry", .{ .iterate = true, .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound or !reconcile) return err;
            try dir.createDir(self.io, "registry", .fromMode(0o700));
            changed = true;
            break :blk try dir.openDir(self.io, "registry", .{ .iterate = true, .follow_symlinks = false });
        };
        defer child.close(self.io);
        if (changed) try child.setOwner(self.io, self.root_owner.uid, group);
        try metadata(child.handle, .{ .uid = self.root_owner.uid, .gid = group }, null, std.posix.S.IFDIR);
        const st = try child.stat(self.io);
        if (st.permissions.toMode() & 0o7777 != 0o750) {
            // Only the known previous 0700 generation may be migrated.
            try j.require(reconcile and st.permissions.toMode() & 0o7777 == 0o700);
            try child.setPermissions(self.io, .fromMode(0o750));
            try self.syncDir(child);
            changed = true;
        }
        if (changed) try self.syncDir(dir);
        return changed;
    }
    pub fn names(self: Store, pathname: []const u8) ![]const []const u8 {
        try allowed(pathname);
        const dir = try self.walk(pathname);
        defer dir.close(self.io);
        var result: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            try j.require(result.items.len < 4096);
            try result.append(self.a, try self.a.dupe(u8, entry.name));
        }
        return result.toOwnedSlice(self.a);
    }
    pub fn read(self: Store, pathname: []const u8, owner: Owner, mode: u16, max: usize) ![]const u8 {
        const dir = try self.parent(pathname);
        defer dir.close(self.io);
        // Refuse FIFOs/devices before opening; opening a FIFO could otherwise
        // block forever. Ancestors are root-owned and not publicly writable.
        const before = try dir.statFile(self.io, std.fs.path.basename(pathname), .{ .follow_symlinks = false });
        if (before.kind == .sym_link) return error.UnexpectedManagedSymlink;
        try j.require(before.kind == .file);
        const file = try dir.openFile(self.io, std.fs.path.basename(pathname), .{ .follow_symlinks = false, .allow_directory = false });
        defer file.close(self.io);
        try metadata(file.handle, owner, mode, std.posix.S.IFREG);
        const st = try file.stat(self.io);
        try j.require(st.size <= max);
        const data = try self.a.alloc(u8, @intCast(st.size + 1));
        const n = try file.readPositionalAll(self.io, data, 0);
        try j.require(n == st.size);
        return data[0..n];
    }
    pub fn write(self: Store, pathname: []const u8, data: []const u8, owner: Owner, mode: u16) !void {
        try j.require(data.len <= limit);
        const dir = try self.parent(pathname);
        defer dir.close(self.io);
        const file = try dir.createFile(self.io, std.fs.path.basename(pathname), .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        try file.writePositionalAll(self.io, data, 0);
        try file.setOwner(self.io, owner.uid, owner.gid);
        try file.setPermissions(self.io, .fromMode(mode));
        try file.sync(self.io);
        try self.syncDir(dir);
    }
    pub fn temporary(self: Store, parent_dir: []const u8, prefix: []const u8, directory_value: bool) ![]const u8 {
        var random: [16]u8 = undefined;
        try pki.crypto.random(&random);
        const name = try std.fmt.allocPrint(self.a, ".{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
        const pathname = try self.path(parent_dir, name);
        if (directory_value) _ = try self.directory(pathname, self.root_owner, 0o700, true);
        return pathname;
    }
    pub fn rename(self: Store, from: []const u8, to: []const u8, replace: bool) !void {
        const source = try self.parent(from);
        defer source.close(self.io);
        const destination = try self.parent(to);
        defer destination.close(self.io);
        // Directory publication runs under the helper's operation lock. Zig's
        // renamePreserve fallback uses hard links, which cannot move directories.
        if (!replace and try self.exists(to)) return error.PathAlreadyExists;
        try self.checkpoint("before_publish", to);
        try source.rename(std.fs.path.basename(from), destination, std.fs.path.basename(to), self.io);
        try self.syncDir(destination);
        try self.syncDir(source);
        try self.checkpoint("after_publish", to);
    }
    pub fn atomic(self: Store, pathname: []const u8, data: []const u8, owner: Owner, mode: u16, staging_parent: []const u8) !bool {
        if (try self.exists(pathname)) {
            if (std.mem.eql(u8, data, try self.read(pathname, owner, mode, limit))) return false;
        }
        const stage = try self.temporary(staging_parent, "credential", false);
        defer self.unlink(stage) catch {};
        try self.write(stage, data, owner, mode);
        try self.rename(stage, pathname, true);
        return true;
    }
    pub fn unlink(self: Store, pathname: []const u8) !void {
        try self.checkpoint("before_unlink", pathname);
        const dir = try self.parent(pathname);
        defer dir.close(self.io);
        try dir.deleteFile(self.io, std.fs.path.basename(pathname));
        try self.syncDir(dir);
    }
    pub fn removeEmpty(self: Store, pathname: []const u8) !void {
        const dir = try self.parent(pathname);
        defer dir.close(self.io);
        try dir.deleteDir(self.io, std.fs.path.basename(pathname));
        try self.syncDir(dir);
    }
    pub fn mark(self: Store, name: []const u8) !void {
        try j.require(j.contains(&.{ "caddy", "vector", "vmagent" }, name));
        const pathname = try std.fmt.allocPrint(self.a, state ++ "/{s}-restart-required", .{name});
        if (try self.exists(pathname)) _ = try self.read(pathname, self.root_owner, 0o600, 64) else try self.write(pathname, "", self.root_owner, 0o600);
    }
    pub fn readFiles(self: Store, pathname: []const u8, names_value: []const []const u8, owner: Owner) !Files {
        var result: Files = .empty;
        for (names_value) |name| {
            const filename = try self.path(pathname, name);
            if (try self.exists(filename)) try result.put(self.a, name, try self.read(filename, owner, 0o400, limit));
        }
        return result;
    }
    pub fn managed(self: Store, pathname: []const u8, owner: Owner, mode: u16, names_value: []const []const u8, content: []const u8, exact: bool) !Files {
        _ = try self.directory(pathname, .{ .uid = self.root_owner.uid, .gid = owner.gid }, mode, false);
        const entries = try self.names(pathname);
        for (entries) |name| if (!std.mem.eql(u8, name, ".dragontools-managed") and !j.contains(names_value, name)) return error.UnexpectedManagedFile;
        if (exact) try j.require(entries.len == names_value.len + 1);
        try j.require(std.mem.eql(u8, try self.read(try self.path(pathname, ".dragontools-managed"), self.root_owner, 0o400, 128), content));
        const result = try self.readFiles(pathname, names_value, owner);
        if (exact) try keys(result, names_value);
        return result;
    }
    pub fn createBundle(self: Store, pathname: []const u8, owner: Owner, mode: u16, values: Files, content: []const u8) !void {
        const stage = try self.temporary(std.fs.path.dirname(pathname).?, "bundle", true);
        var published = false;
        defer if (!published) {
            var it = values.keyIterator();
            while (it.next()) |name| self.unlink(self.path(stage, name.*) catch continue) catch {};
            self.unlink(self.path(stage, ".dragontools-managed") catch stage) catch {};
            self.removeEmpty(stage) catch {};
        };
        try self.write(try self.path(stage, ".dragontools-managed"), content, self.root_owner, 0o400);
        var it = values.iterator();
        while (it.next()) |entry| try self.write(try self.path(stage, entry.key_ptr.*), entry.value_ptr.*, owner, 0o400);
        const dir = try self.walk(stage);
        defer dir.close(self.io);
        try dir.setOwner(self.io, self.root_owner.uid, owner.gid);
        try dir.setPermissions(self.io, .fromMode(mode));
        try self.syncDir(dir);
        try self.rename(stage, pathname, false);
        published = true;
    }
    pub fn stagedFile(self: Store, pathname: []const u8, owner: Owner) ![]const u8 {
        const parent_dir = try self.parent(pathname);
        defer parent_dir.close(self.io);
        const st = try parent_dir.statFile(self.io, std.fs.path.basename(pathname), .{ .follow_symlinks = false });
        if (st.kind == .sym_link) return error.UnexpectedManagedSymlink;
        const mode: u16 = @intCast(st.permissions.toMode() & 0o7777);
        try j.require(mode == 0o400 or mode == 0o600);
        if (mode == 0o600) {
            // write() may stop before or after chown, before its final chmod.
            return self.read(pathname, self.root_owner, mode, limit) catch |err| {
                if (err != error.CredentialStateRefused) return err;
                return self.read(pathname, owner, mode, limit);
            };
        }
        return self.read(pathname, owner, mode, limit);
    }
    /// Only station CA/server candidates use this recovery path. Validate every
    /// entry before unlinking any: private generated name, exact marker/prefix,
    /// no links, known files and metadata from interrupted createBundle writes.
    pub fn discardBundle(self: Store, pathname: []const u8, owner: Owner, mode: u16, names_value: []const []const u8) !void {
        const dir = try self.walk(pathname);
        defer dir.close(self.io);
        var st: Metadata = undefined;
        try j.require(dragontools_file_metadata(dir.handle, &st) == 0);
        try j.require(st.uid == self.root_owner.uid and
            (st.gid == self.root_owner.gid and st.mode & 0o7777 == 0o700 or st.gid == owner.gid and (st.mode & 0o7777 == 0o700 or st.mode & 0o7777 == mode)));
        const entries = try self.names(pathname);
        if (entries.len != 0) {
            const marker_path = try self.path(pathname, ".dragontools-managed");
            const marker_stat = dir.statFile(self.io, ".dragontools-managed", .{ .follow_symlinks = false }) catch return error.UnexpectedManagedFile;
            if (marker_stat.kind == .sym_link) return error.UnexpectedManagedSymlink;
            const marker_mode: u16 = @intCast(marker_stat.permissions.toMode() & 0o7777);
            try j.require(marker_mode == 0o400 or marker_mode == 0o600);
            const value = try self.read(marker_path, self.root_owner, marker_mode, marker.len);
            if (marker_mode == 0o400) try j.require(std.mem.eql(u8, value, marker)) else try j.require(std.mem.startsWith(u8, marker, value));
            // Marker is completed before any bundle contents are created.
            if (!std.mem.eql(u8, value, marker)) try j.require(entries.len == 1);
        }
        for (entries) |name| {
            if (std.mem.eql(u8, name, ".dragontools-managed")) continue;
            if (!j.contains(names_value, name)) return error.UnexpectedManagedFile;
            _ = try self.stagedFile(try self.path(pathname, name), owner);
        }
        for (entries) |name| if (!std.mem.eql(u8, name, ".dragontools-managed")) try self.unlink(try self.path(pathname, name));
        if (entries.len != 0) try self.unlink(try self.path(pathname, ".dragontools-managed"));
        try self.removeEmpty(pathname);
    }
};
