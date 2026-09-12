#!/usr/bin/env bash
set -euo pipefail
# ROADMAP EXAMPLE: currently fails NotImplemented before SSH.
APP_HOST="app01.example.com"
STATION_IP="10.0.0.20"
SERVICE="orderflow.service"
./zig-out/bin/dragontool monitoring agents install --host "$APP_HOST" \
  --station-ip "$STATION_IP" --service "$SERVICE"
