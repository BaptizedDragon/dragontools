//! No firewall writes in this milestone. Ingestion must remain loopback-only.
pub fn apply() error{NotImplemented}!void {
    // TODO: inspect SSH_CONNECTION; validate admin membership; schedule rollback;
    // own a dedicated nftables table; reconnect before canceling rollback.
    return error.NotImplemented;
}
