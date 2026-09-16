#!/usr/bin/env bash
set -euo pipefail
# Installs VictoriaMetrics, VictoriaLogs, and VictoriaTraces with private listeners.
MONITOR_HOST="monitor.example.com"
SSH_USER="root"
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --user "$SSH_USER"
./zig-out/bin/dragontool monitoring verify --host "$MONITOR_HOST" --user "$SSH_USER"
./zig-out/bin/dragontool monitoring status --host "$MONITOR_HOST" --user "$SSH_USER"
# Safe rerun: healthy unchanged services keep their processes.
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --user "$SSH_USER"
