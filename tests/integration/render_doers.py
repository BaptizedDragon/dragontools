"""Render the committed Doers reference through production Zig parsers/renderers.

Local files only. No SSH, secret lookup, DNS, or production endpoint requests.
Usage: python3 -I -B tests/integration/render_doers.py /tmp/doers-fixture
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = r'''
const std = @import("std");
const application = @import("config/application.zig");
const config = @import("monitoring/agents/config.zig");
const model = @import("monitoring/agents/model.zig");
fn write(init: std.process.Init, directory: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ directory, name });
    const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, bytes);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.OutputDirectoryRequired;
    var value = try application.load(a, init.io, "examples/doers-monitoring.toml");
    defer value.deinit();
    const services = try a.alloc(model.AppService, value.services.len);
    var units: std.ArrayList([]const u8) = .empty;
    for (value.services, services) |service, *selected| {
        selected.* = .{ .name = service.name, .systemd = service.systemd, .logs = service.logs, .metrics_url = service.metrics_url };
        if (service.logs) try units.append(a, service.systemd);
    }
    const registration: model.Registration = .{ .host = "dt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .station = value.station_hostname,
        .services = units.items, .metrics_targets = &.{}, .applications = &.{.{ .name = value.application.name, .environment = value.application.environment, .services = services }} };
    try write(init, args[1], "doers-registration.json", try registration.json(a));
    try write(init, args[1], "doers-vector.yaml", try config.renderVectorRegistration(a, registration));
    try write(init, args[1], "doers-prometheus.yml", try config.renderVmagentRegistration(a, registration));
    try write(init, args[1], "doers-station.json", try std.json.Stringify.valueAlloc(a, .{
        .application = value.application.name, .environment = value.application.environment, .host = registration.host,
        .services = value.services, .probes = value.probes, .alerts = value.alerts,
    }, .{}));
    try write(init, args[1], "doers-transport.json", try std.json.Stringify.valueAlloc(a, .{
        .target_ssh_host = value.target_ssh_host, .station_ssh_host = value.station_ssh_host, .station_hostname = value.station_hostname,
    }, .{}));
    try write(init, args[1], "blackbox.yml", @import("components/blackbox_exporter.zig").config);
    try write(init, args[1], "base-logs.rules.yml", try @import("monitoring/vmalert.zig").rules(a, .logs));
    try write(init, args[1], "base-metrics.rules.yml", try @import("monitoring/vmalert.zig").rules(a, .metrics));
}
'''


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.zig', prefix='.doers-fixture-', dir=ROOT / 'src', delete=False) as source:
        source.write(SOURCE)
    try:
        subprocess.run(['zig', 'run', source.name, '--', str(output)], cwd=ROOT, check=True)
    finally:
        Path(source.name).unlink()
    print('PASS: Doers reference parsed and rendered through production code (no network).')


if __name__ == '__main__':
    main()
