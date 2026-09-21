#!/usr/bin/env bash
set -euo pipefail
MONITOR_HOST="monitor.example.com"
# Use the actual socket configured by 1Password on your controller.
SSH_SOCK="$HOME/.1password/agent.sock"
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" --ssh-sock "$SSH_SOCK"
# Private-key op:// resolution is not yet implemented; socket authentication works.
