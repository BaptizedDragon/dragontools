pub const Mode = enum { manual_dns01, cloudflare_dns01 };
pub fn provision(_: Mode) error{NotImplemented}!void {
    // TODO: real ACME DNS-01 proof, propagation check, credential-backed renewal.
    return error.NotImplemented;
}
