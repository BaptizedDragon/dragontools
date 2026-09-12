#!/usr/bin/env bash
set -euo pipefail
: "${VM_HOST:?Set VM_HOST to a disposable Ubuntu VM}"
VM_USER="${VM_USER:-root}"
TOOL="${TOOL:-./zig-out/bin/dragontool}"
state() {
  ssh -F /dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes -l "$VM_USER" -- "$VM_HOST" \
    'systemctl show dragontools-victoriametrics.service -p MainPID -p ExecMainStartTimestampMonotonic'
}
"$TOOL" monitoring install --host "$VM_HOST" --user "$VM_USER"
"$TOOL" monitoring verify --host "$VM_HOST" --user "$VM_USER"
before="$(state)"
output="$("$TOOL" monitoring install --host "$VM_HOST" --user "$VM_USER")"
printf '%s\n' "$output"
[[ "$output" == *"No changes required."* ]]
[[ "$before" == "$(state)" ]]
"$TOOL" monitoring verify --host "$VM_HOST" --user "$VM_USER"
printf '%s\n' 'PASS: second run kept the same running process.'
