#!/usr/bin/env bash
set -euo pipefail
MONITOR_HOST="monitor.example.com"
SSH_USER="root"
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --user "$SSH_USER"
./zig-out/bin/dragontool monitoring verify --host "$MONITOR_HOST" --user "$SSH_USER"
