#!/usr/bin/env bash
set -euo pipefail
# Installs VictoriaMetrics, VictoriaLogs, VictoriaTraces, and Grafana with private listeners.
MONITOR_HOST="monitor.example.com"
SSH_USER="root"
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --user "$SSH_USER"
./zig-out/bin/dragontool monitoring verify --host "$MONITOR_HOST" --user "$SSH_USER"
./zig-out/bin/dragontool monitoring status --host "$MONITOR_HOST" --user "$SSH_USER"
# Safe rerun: healthy unchanged services keep their processes.
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --user "$SSH_USER"
# Open Grafana through a separate SSH session; change the initial admin password.
# Match the direct root/default-agent connection above. No firewall changes needed.
# ssh -o StrictHostKeyChecking=yes -L 127.0.0.1:3000:127.0.0.1:3000 "$SSH_USER@$MONITOR_HOST"
# Then open http://127.0.0.1:3000 on the controller.
