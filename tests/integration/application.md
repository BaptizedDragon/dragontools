# Application contract: two-host Ubuntu gate

**Disposable-host integration not run.** Local schema/ownership tests and native
process fixtures do not establish SSH/systemd deployment, actual journald capture,
outage recovery or notification delivery.

Use disposable Ubuntu 24.04/26.04 station and application hosts with verified
OpenSSH aliases `replace-me-monitoring` and `replace-me-application`, root or
noninteractive sudo, normal prerequisites and synchronized clocks. Install the
central station with its separate `station.toml`. Allow application-to-station TCP
9443 in the operator-managed firewall; keep raw storage/admin ports private.
Prepare canonical `app.service` with structured journal logs, a private Prometheus
endpoint exposing a real application metric, and a reachable HTTP health URL.
The Doers example is illustrative, not production discovery.

Put the public application contract in a disposable repo as `monitoring.toml`.
Replace its aliases, unit and endpoints, and require explicit app/environment.
Never copy station credential references into it. Use the same release/source-built
executable and native SSH authentication throughout:

```bash
dragontool monitoring apply --plan
dragontool monitoring apply
dragontool monitoring app-verify
dragontool monitoring app-status
dragontool monitoring apply
```

1. Confirm plan makes no SSH connection. Expected first apply includes
   `host metrics flowing`, `selected service logs flowing (quiet-service metadata included)`,
   `application metrics flowing`, `probes registered: 1` and
   `application alerts loaded`. Second apply must include `No changes required.`
   Record PIDs/start timestamps, cert/config hashes and pending markers before and
   after; unchanged apply must not restart services or rewrite credentials.
2. Query stored VM host/app metrics and VL selected streams. Check trusted
   application/environment/host/service against conflicting fixture input fields.
   Confirm unselected units are absent and filesystem free/used/inode plus
   CPU/memory metrics match the pinned contract. Quiet metadata is distinctly
   typed, never a synthetic error. Inspect bounded disk buffers and effective
   journald limits; stricter administrator limits remain unchanged.
3. Check loaded app probe definitions, one default/overridden alert per probe,
   app log group and shared host rules. Inspect labels and policy thresholds.
   Apply while the HTTP target is down: fresh `probe_success=0` with a working
   scraper/evaluator must still pass installation.
4. Stop only the disposable sample service. Observe 30-second probes, stored
   failure, the configured two-minute hold, and firing alert via vmalert and
   Alertmanager APIs. Restore promptly, then observe successful probes and alert
   resolution. API state does not prove human Telegram delivery. Do not run
   notify-test implicitly.
5. Change only an alert threshold: only its app rule/manifest and evaluator may
   change. Add a probe: only that app's station documents and affected consumers
   activate. Change a metrics endpoint: vmagent may restart, but Vector and
   unrelated rule files remain unchanged. Remove an alert and confirm its loaded
   rule disappears while manual files are preserved.
6. Apply a second repository on the same target. Reapply the first and confirm the
   second's station files, target manifest and signals remain intact. Conflicting
   unit ownership, namespace rebinding and edited/unmanaged app files must fail
   before target mutation. Keep manual rules, Grafana assets and central secrets
   as byte-for-byte sentinels.
7. Perform the [agent outage/recovery checks](README.md#monitored-host-logsmetrics-two-host-ubuntu-gate).
   Also interrupt application publication and station reload/restart. Rerun must
   recover, verify, finalize, then become a no-op. Read-only commands must never
   clear pending intent. Record bounded-buffer behavior during the outage.
8. Missing config, unknown keys, invalid URLs and traces=true must fail before
   SSH. A host-only config installs no unnecessary vmagent. Removing one app's
   last metrics target must retain other apps' targets.

Retain sanitized versions, timestamps, hashes, runtime properties, telemetry
identities, alert transitions and no-op evidence. Never retain credentials.
Test amd64 and arm64 hosts separately; cross-compilation is not runtime validation.

## Host-local PKI migration and renewal gate

Use the same two disposable hosts and aliases. These are required deployment
checks, not results established by the local crypto/process fixtures:

1. After apply, inspect ownership/mode and **public** certificate metadata only.
   The app owns `/etc/dragontools/monitoring-client/client.key` and its local
   service copies. The station owns only CA/server private keys: require no
   `clients/<host>/client.key`. Inspect CN, URI SAN, clientAuth and certificate
   validity without printing any key. All applications on one machine use the
   same machine identity and station registry permissions.
2. Verify actual host/app metrics and selected logs traverse mTLS, then record
   public cert fingerprints, file mtimes and service PIDs around an unchanged
   apply. Require `No changes required.`, no new CSR/signature, and stable
   Vector/vmagent/ingestion identities.
3. With fixture-only short-lived client certificates, simulate at most 30 days
   remaining. Apply must retain the client public key, replace its certificate,
   restart only actual credential consumers, verify fresh telemetry, finalize
   registry/local state, and become a no-op on rerun. Read-only app-verify must
   never renew. Independently shorten only the server certificate: its public
   key stays the same and only ingestion restarts.
4. Use a prior-version **disposable** installation with station-generated client
   credentials. Require a new host-generated key, old working credentials
   retained until the candidate path verifies, and station key unlink only after
   successful telemetry/finalization. Test signing failure and interruption
   before/after consumer publication and either host's finalization. Rerun must
   recover without restoring an identity already revoked on the station.
5. Reject malformed/wrong-host/CA/serverAuth CSRs and CA-signed but unregistered
   clients. Verify strict server hostname validation, pending lease expiry,
   and read-only failure for expired credentials. Near-expiry CA must report
   maintenance and preserve the existing CA; no automatic rollover is allowed.
6. Block DNS/TCP independently and inspect only semantic diagnostics. Expect
   `dns_unresolved`/`tcp_unreachable` and the explicit DNS/provider-firewall
   guidance. Wrong station hostname and unregistered client must produce
   `server_tls_invalid`/`client_certificate_rejected`, with no raw stderr.

Keep private fixture credentials on their owning disposable hosts. Inspect public
keys/fingerprints rather than transferring private keys for comparison. Normal
unlink does not demonstrate physical-media erasure. Destroy disposable resources
when finished. **Disposable-host integration not run.**
