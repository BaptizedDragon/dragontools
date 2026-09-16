//! Roadmap: Vector journal logs/host metrics, vmagent application metrics, OTel traces.
//! Host metric names and systemd service-state monitoring remain deferred.
const remote = @import("../../system/remote.zig");
pub fn status(_: remote.Remote, _: []const []const u8) error{NotImplemented}!void {
    // TODO: validate selected units, bound journald, verify remote signal arrival.
    return error.NotImplemented;
}
