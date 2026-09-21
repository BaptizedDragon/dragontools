#!/usr/bin/env bash
set -euo pipefail
# Copy examples/monitoring.toml to monitoring.toml, replace its SSH alias/probe
# URLs/references, and uncomment [telegram] with both SecretRefs before running.
# The local op CLI resolves configured values; the host needs no op installation.
# Install enables real rule notifications but does not send a synthetic test.
MONITORING_CONFIG="monitoring.toml"
./zig-out/bin/dragontool monitoring install --config "$MONITORING_CONFIG" --plan
./zig-out/bin/dragontool monitoring install --config "$MONITORING_CONFIG"
./zig-out/bin/dragontool monitoring verify --config "$MONITORING_CONFIG"
./zig-out/bin/dragontool monitoring status --config "$MONITORING_CONFIG"
# Deliberate unchanged rerun: no service restart or secret rewrite is expected.
./zig-out/bin/dragontool monitoring install --config "$MONITORING_CONFIG"
# Send only when the configured chat is intended to receive a test notification:
# ./zig-out/bin/dragontool monitoring notify-test --config "$MONITORING_CONFIG"
