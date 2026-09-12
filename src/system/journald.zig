//! Planned agent policy; not applied until conflict inspection and verification exist.
pub const managed_path = "/etc/systemd/journald.conf.d/90-dragontools.conf";
pub const proposed_dropin =
    \\[Journal]
    \\SystemMaxUse=512M
    \\SystemKeepFree=1G
    \\RuntimeMaxUse=128M
    \\RuntimeKeepFree=256M
;
