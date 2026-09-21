//! Wipe arena backing storage before releasing it, including abandoned keys.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const SecureAllocator = struct {
    child: Allocator,
    pub fn allocator(self: *SecureAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *SecureAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *SecureAllocator = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, bytes);
        self.child.rawFree(bytes, alignment, ret);
    }
};
