"""Render native application fixtures through the real Zig configuration functions.

Usage: python3 tests/integration/render_agent_apps.py /tmp/dragontools-ingestion-fixture
No hosts, secrets or network are accessed. Zig 0.16.0 is required for this developer fixture.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = r'''
const std = @import("std");
const config = @import("monitoring/agents/config.zig");
const model = @import("monitoring/agents/model.zig");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.OutputDirectoryRequired;
    const value: model.Registration = .{ .host = "dt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .station = "localhost", .services = &.{ "doers.service", "orderflow.service" }, .metrics_targets = &.{}, .applications = &.{
        .{ .name = "doers", .environment = "production", .services = &.{ .{ .name = "web", .systemd = "doers.service", .logs = true, .metrics_url = "http://127.0.0.1:16000/metrics" } } },
        .{ .name = "hostonly", .environment = "production", .services = &.{} },
        .{ .name = "orderflow", .environment = "staging", .services = &.{ .{ .name = "web", .systemd = "orderflow.service", .logs = true, .metrics_url = "http://127.0.0.1:16000/metrics" } } },
    } };
    const names = [_][]const u8{ "apps-vector.yaml", "apps-prometheus.yml", "apps-registration.json" };
    const contents = [_][]const u8{ try config.renderVectorRegistration(a, value), try config.renderVmagentRegistration(a, value), try value.json(a) };
    for (names, contents) |name, content| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], name });
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, content);
    }
}
'''

def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    # The temporary package root is within src so its imports use exactly the
    # production package boundary; it is always removed, including failures.
    with tempfile.NamedTemporaryFile(mode='w', suffix='.zig', prefix='.agent-fixture-', dir=ROOT / 'src', delete=False) as source:
        source.write(SOURCE)
    try:
        subprocess.run(['zig', 'run', source.name, '--', str(output)], cwd=ROOT, check=True)
    finally:
        Path(source.name).unlink()
    print('Rendered application agent fixtures with production Zig renderers.')

if __name__ == '__main__':
    main()
