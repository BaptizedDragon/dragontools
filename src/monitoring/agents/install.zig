//! Roadmap: Vector logs, vmagent metrics, OTel traces, node_exporter host metrics.
const remote = @import("../../system/remote.zig");
pub fn install(_: remote.Remote, _: []const []const u8) error{NotImplemented}!void {
    // TODO: validate selected units, bound journald, verify remote signal arrival.
    return error.NotImplemented;
}
