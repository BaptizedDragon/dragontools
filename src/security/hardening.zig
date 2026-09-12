pub const victoria_metrics =
    \\NoNewPrivileges=yes
    \\PrivateTmp=yes
    \\ProtectHome=yes
    \\ProtectSystem=strict
    \\ProtectKernelTunables=yes
    \\ProtectKernelModules=yes
    \\ProtectControlGroups=yes
    \\RestrictSUIDSGID=yes
    \\CapabilityBoundingSet=
    \\RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
    \\ReadWritePaths=/var/lib/dragontools/victoriametrics
    \\TasksMax=512
    \\UMask=0027
    \\LogRateLimitIntervalSec=30s
    \\LogRateLimitBurst=1000
;
