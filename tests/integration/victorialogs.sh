#!/usr/bin/env bash
# Opt-in lifecycle checks for a disposable supported Ubuntu VM. Never use production.
set -euo pipefail
: "${VM_HOST:?Set VM_HOST to a disposable Ubuntu VM}"
VM_USER="${VM_USER:-root}"
TOOL="${TOOL:-./zig-out/bin/dragontool}"

# All remote scripts below are fixed test code. Host/user values are argv only.
remote_root() {
  ssh -F /dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes \
    -o ConnectTimeout=10 -o ConnectionAttempts=1 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    -l "$VM_USER" -- "$VM_HOST" \
    'if [ "$(id -u)" -eq 0 ]; then exec sh -s; else exec sudo -n sh -s; fi' 2>/dev/null
}

metrics_state() {
  remote_root <<'REMOTE'
set -eu
systemctl show dragontools-victoriametrics.service -p MainPID -p ExecMainStartTimestampMonotonic
REMOTE
}

logs_state() {
  remote_root <<'REMOTE'
set -eu
systemctl show dragontools-victorialogs.service -p MainPID -p ExecMainStartTimestampMonotonic
REMOTE
}

check_runtime() {
  remote_root <<'REMOTE'
set -eu
for component in victoriametrics victorialogs; do
  systemctl is-active --quiet "dragontools-$component.service"
  systemctl is-enabled --quiet "dragontools-$component.service"
done
for port in 8428 9428; do
  listeners=$(ss -H -ltn "sport = :$port")
  [ "$(printf '%s\n' "$listeners" | wc -l)" -eq 1 ]
  # ss -H -ltn has State, Recv-Q, Send-Q, Local Address, Peer Address columns.
  set -f
  set -- $listeners
  [ "${4:-}" = "127.0.0.1:$port" ]
  curl --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 10 \
    "http://127.0.0.1:$port/health" >/dev/null
done
metrics=$(curl --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 10 \
  http://127.0.0.1:9428/metrics)
samples=$(printf '%s\n' "$metrics" | grep '^vl_storage_is_read_only')
[ "$samples" = 'vl_storage_is_read_only{path="/var/lib/dragontools/victorialogs"} 0' ]
unit=/etc/systemd/system/dragontools-victorialogs.service
grep -Fq -- '-retentionPeriod=100y' "$unit"
grep -Fq -- '-retention.maxDiskUsagePercent=75' "$unit"
if grep -Fq -- '-retention.maxDiskSpaceUsageBytes' "$unit"; then exit 1; fi
running=$(systemctl show dragontools-victorialogs.service --property=ExecStart --value)
printf '%s\n' "$running" | grep -Fq -- '-retentionPeriod=100y'
printf '%s\n' "$running" | grep -Fq -- '-retention.maxDiskUsagePercent=75'
grep -Fq -- '-retentionPeriod=90d' /etc/systemd/system/dragontools-victoriametrics.service
[ ! -e /var/lib/dragontools/victoriametrics-restart-required ]
[ ! -e /var/lib/dragontools/victorialogs-restart-required ]
REMOTE
}

install() {
  "$TOOL" monitoring install --host "$VM_HOST" --user "$VM_USER"
}

verify() {
  "$TOOL" monitoring verify --host "$VM_HOST" --user "$VM_USER"
  check_runtime
}

assert_noop() {
  local vm_before vl_before output
  vm_before="$(metrics_state)"
  vl_before="$(logs_state)"
  output="$(install)"
  printf '%s\n' "$output"
  [[ "$output" == *"No changes required."* ]]
  [[ "$vm_before" == "$(metrics_state)" ]]
  [[ "$vl_before" == "$(logs_state)" ]]
  verify
}

trap 'printf "%s\n" "FAIL: disposable-VM integration stopped; inspect the managed services before rerunning." >&2' ERR
install
verify
assert_noop
printf '%s\n' 'PASS: both components are healthy; second install kept both running processes.'

# A harmless managed-unit comment simulates drift without altering service flags.
# Install must repair the unit and restart only VictoriaLogs, then become a no-op.
vm_before="$(metrics_state)"
vl_before="$(logs_state)"
remote_root <<'REMOTE'
set -eu
unit=/etc/systemd/system/dragontools-victorialogs.service
[ -f "$unit" ]
[ ! -L "$unit" ]
grep -Fq '# Managed by DragonTools' "$unit"
printf '\n# DragonTools disposable integration repair probe\n' >> "$unit"
REMOTE
install
verify
[[ "$vm_before" == "$(metrics_state)" ]]
[[ "$vl_before" != "$(logs_state)" ]]
assert_noop
printf '%s\n' 'PASS: VictoriaLogs unit repair restarted only VictoriaLogs and converged to no changes.'

# Simulate persisted restart intent after an interrupted deployment. No live
# process is interrupted or executable corrupted by this recovery check.
vm_before="$(metrics_state)"
vl_before="$(logs_state)"
remote_root <<'REMOTE'
set -eu
marker=/var/lib/dragontools/victorialogs-restart-required
[ ! -e "$marker" ]
[ ! -L "$marker" ]
(umask 077; set -C; : > "$marker")
chown root:root "$marker"
chmod 0600 "$marker"
REMOTE
install
verify
[[ "$vm_before" == "$(metrics_state)" ]]
[[ "$vl_before" != "$(logs_state)" ]]
assert_noop
printf '%s\n' 'PASS: persisted VictoriaLogs restart intent recovered without restarting VictoriaMetrics.'
