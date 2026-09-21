const std = @import("std");
const common = @import("common.zig");
pub fn command(a: std.mem.Allocator, install: bool) ![]const u8 {
    return common.python(a, @embedFile("journald.py"), &.{if (install) "install" else "verify"});
}
test "journal bounds retain strict limits and detect later administrator overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = @embedFile("journald.py") ++
        \\
        \\limits=desired(10*1024**3, 1024**3)
        \\assert limits['SystemMaxUse']==512*1024**2
        \\assert limits['RuntimeMaxUse']==1024**3*2//100
        \\assert desired(1024**4,1024**4)['SystemMaxUse']==1024**3
        \\assert desired(1024**4,1024**4)['RuntimeMaxUse']==256*1024**2
        \\actual=effective('[Journal]\nSystemMaxUse=64M\nRuntimeMaxUse=4M\nMaxRetentionSec=1day\n')
        \\assert bounded(actual, limits)
        \\assert effective(render(actual,limits))==actual
        \\assert duration('7day')==604800 and duration('1h 30min')==5400
        \\assert not bounded(effective('[Journal]\nSystemMaxUse=0\n'),limits)
        \\text='# '+PATH+'\n[Journal]\nSystemMaxUse=1G\n# /etc/systemd/journald.conf.d/99-admin.conf\n[Journal]\nSystemMaxUse=4G\n'
        \\assert not bounded(effective(text,render({},limits)),limits)
    ;
    // Run pure helpers only; __name__ intentionally excludes the host entrypoint.
    const wrapped = try std.fmt.allocPrint(a, "__name__='fixture'\n{s}", .{script});
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "-c", wrapped } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
