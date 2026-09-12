//! Optional secret source. Never invoke op until a protected consumer is ready.
pub fn resolve() error{NotImplemented}!void {
    // TODO: capture op read into Secret, suppress/redact stderr, wipe on all exits.
    // Private keys should use a temporary isolated ssh-agent via stdin, not argv.
    return error.NotImplemented;
}
