#!/usr/bin/env bash
set -euo pipefail
# ROADMAP EXAMPLE: currently fails NotImplemented on the first host before SSH.
APP_HOSTS=("app01.example.com" "app02.example.com")
STATION_IP="10.0.0.20"
SERVICES=("orderflow.service" "whoami.service")
for host in "${APP_HOSTS[@]}"; do
  args=()
  for service in "${SERVICES[@]}"; do args+=(--service "$service"); done
  ./zig-out/bin/dragontool monitoring agents install --host "$host" \
    --station-ip "$STATION_IP" "${args[@]}"
done
