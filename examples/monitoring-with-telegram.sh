#!/usr/bin/env bash
set -euo pipefail
# ROADMAP EXAMPLE: currently fails NotImplemented before SSH; no token is read.
MONITOR_HOST="monitor.example.com"
TELEGRAM_TOKEN_OP="op://Monitoring/Telegram/token"
TELEGRAM_CHANNEL_ID="-1001234567890"
./zig-out/bin/dragontool monitoring install --host "$MONITOR_HOST" \
  --telegram-bot-token-op "$TELEGRAM_TOKEN_OP" --telegram-channel-id "$TELEGRAM_CHANNEL_ID"
