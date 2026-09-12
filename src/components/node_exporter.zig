//! Roadmap only: no installation or success reporting yet.
const remote = @import("../system/remote.zig");
pub fn install(_: remote.Remote) error{NotImplemented}!void {
    // TODO: pin/verify artifacts, render compatible config/hardening, verify signal flow.
    return error.NotImplemented;
}
