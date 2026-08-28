# Operations

Ongoing concerns: backups, monitoring/alerting, UPS, resource tuning, AI-session
practices, and deferred work. Built out in [Phase 5](./build-plan.md#phase-5--observability--expansion-).

## Backups

Several categories of data have different protection needs:

| What | Mechanism | Destination | Cadence |
|---|---|---|---|
| selected bootstrap/host/device/service secrets | manual | external password manager | on creation/rotation |
| GitOps repo (all manifests) | git | GitHub | every commit |
| App state (`/opt`, incl. SQLite DBs) | independent Restic CronJobs | direct backup LV + Backblaze B2 | nightly + weekly |
| k3s SQLite datastore | online SQLite backup inside the same Restic CronJobs | direct backup LV + Backblaze B2 | nightly + weekly |
| Frigate recordings | — (not backed up) | direct bulk array | — |
| Media library | — (not backed up) | direct bulk array | — |

What is **already covered** and needs no backup job: cluster/GitOps config (it's in
git — rebuild = reinstall k3s + re-bootstrap Flux), and recordings/media (regenerable
or the bulk array is already the system of record). The job below exists for **app state on
the non-redundant local NVMe**.

### Restic CronJob (runs in-cluster)

Restic runs as Kubernetes **CronJobs** (chosen over host systemd timers to keep them in
git and visible to monitoring). The Phase 5 implementation mounts `/opt` read-only and
creates independent snapshots in two repositories. The nightly local job writes to
`/mnt/backups/opt` on the host (`/repo/nas/opt` in the pod) and keeps 14 daily, 8
weekly, and 12 monthly snapshots. The Sunday 04:30 America/Chicago job writes directly
to Backblaze's S3-compatible API and keeps 8 weekly and 12 monthly snapshots. Both run
the same application SQLite, k3s SQLite, Home Assistant, and RomM hot-backup workflow, but the B2 job and its
restore validation have no local backup-volume dependency.

Both targets exclude `/data/opt/.snapshots`. Those same-device btrfs snapshots are
local rollback aids, not independent backup inputs; nesting them in Restic duplicates
historical trees and database discovery work. The current `/opt` tree and all
application-aware hot dumps remain covered.

Validation status: initialization, manual backups, repository checks, and representative
restore drills passed for both repositories. The nightly local and first naturally
scheduled weekly B2 backups both completed successfully on 2026-07-19. Contract
version 2 passed fresh attended local and B2 backup/restore drills on 2026-08-22.
Local snapshot
`731326fa530f2c54686210a360ee4dc30833a418d145e95b39de591ead8cdca0`
validated 2,445 k3s `kine` rows; local-volume-independent B2 snapshot
`fe10c1ffa810ab7d5af75a52fd1f5b69315a3411e96e5deab93363406baea166`
validated 2,815. Both passed full k3s SQLite integrity/schema checks, all eight
required application SQLite exports, a readable Home Assistant archive, a 32-table
RomM import/check, and an explicit scan proving no server-token artifact was present.

```bash
restic -r /mnt/backups/opt backup \
  --exclude /data/opt/.snapshots /data/opt /work/hot-dumps
restic -r s3:https://s3.<region>.backblazeb2.com/<bucket>/opt backup \
  --exclude /data/opt/.snapshots /data/opt /work/hot-dumps
```

Required hardening on the CronJob so a failure is **loud**, not silently missing:
```yaml
spec:
  failedJobsHistoryLimit: 3
  successfulJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0              # fail fast, no silent retries
      activeDeadlineSeconds: 3600  # local repository: kill a hung run after 1h; B2 uses 6h
```
The committed Alertmanager rules cover failed, overdue, and accidentally suspended
backup jobs once the observability slice is reconciled. Credentials
(`RESTIC_PASSWORD`, `HOME_ASSISTANT_TOKEN`, `ROMM_DB_PASSWORD`, and B2 S3 keys) are
SOPS-encrypted Secrets. **`restic init` runs once** per repo before the first backup via
`runbooks/phase5/03-init-restic-nas-repo.sh` and
`runbooks/phase5/07-init-restic-b2-repo.sh`.

The B2 bucket is private, has default server-side encryption enabled, has Object Lock
disabled so pruning works, and uses the lifecycle rule that keeps only the latest
object version. Its non-expiring application key is bucket-scoped Read and Write with
List All Bucket Names enabled for S3 compatibility. The cluster therefore holds delete
authority for automatic pruning; hardened offline deletion is deferred. Setup and
representative restore-drill commands are in
[`runbooks/phase5/README.md`](../runbooks/phase5/README.md). A real fresh-system
restore uses the guarded, executable
[`runbooks/disaster-recovery/`](../runbooks/disaster-recovery/) procedure; the restore
drills do not populate `/opt`.

### SQLite hot backups (pre-hook)

Several apps use SQLite; copying a live DB file can capture a mid-write (corrupt)
state. Before Restic snapshots, dump each DB safely with the online-backup API. The
stock `restic/restic` image lacks the helper tools, so the repo builds
`ghcr.io/sandersch/restic-backup:0.19.0-1` from `containers/restic-backup/` with
`sqlite`, `mariadb-client`, `curl`, and `jq`. The CronJob runs the dump commands before
backing up `/opt`.

| App | Treatment | Notes |
|---|---|---|
| Plex | `sqlite3 .backup` of both `library.db` + `library.blobs.db` | precious; days to rebuild; validate with schema reads because Plex can define a custom SQLite tokenizer |
| Home Assistant | `sqlite3 .backup` of `home-assistant_v2.db` plus REST API `backup.create_automatic` | require both a direct-restore DB and one new readable managed archive |
| Frigate | `sqlite3 .backup` of `frigate.db` | required; small and quick to validate |
| Radarr/Sonarr/Prowlarr | `sqlite3 .backup` of each primary application DB | all three are required; log DBs are optional |
| Seerr | `sqlite3 .backup` of `db.sqlite3` | required |
| RomM | `mariadb-check` followed by `mariadb-dump --single-transaction` | require a nonempty logical dump containing application tables |
| SABnzbd | none | queue/history are throwaway |
| qBittorrent | none | queue/history are throwaway; credentials live in password manager |

HA's dump is triggered over its API from inside the cluster using a long-lived token
(SOPS secret), e.g. POST to
`http://home-assistant.home-assistant.svc.cluster.local:8123/api/services/backup/create_automatic`.
RomM's MariaDB sidecar is exposed only inside the cluster as
`romm-mariadb.media.svc.cluster.local:3306` for the backup job. The backup Secret's
`ROMM_DB_PASSWORD` must match the RomM Secret's `MARIADB_PASSWORD`; if a manual backup
fails with MariaDB error 1045, rerun
`runbooks/phase5/02-encrypt-restic-secret.sh` and reconcile `monitoring`.
Before Restic starts, the shared script enforces backup-contract version 2. Both Plex
databases plus the primary Frigate, Home Assistant, Prowlarr, Radarr, Sonarr, and Seerr
databases must exist, must have been exported during the current Job, and must pass
their applicable SQLite validation. The new Home Assistant archive must pass `tar -tf`; RomM must pass
`mariadb-check`, and its completed logical dump must contain tables. Missing, stale, or
invalid required output aborts the Job before `restic backup`, so it cannot create a
successful-looking but full-recovery-ineligible snapshot. Other discovered SQLite log,
history, or cache databases remain optional best-effort additions.

The same contract requires a transactionally consistent online backup of the live
`/var/lib/rancher/k3s/server/db/state.db`. Both CronJobs are pinned to `minis` and
mount only the `server/db` directory read-only; they never mount `server/token`.
The script uses SQLite's `.backup` API with a 60-second busy timeout, validates the
temporary file with `PRAGMA integrity_check`, requires the `kine` and
`sqlite_sequence` tables and at least one `kine` row, and only then renames it to
`/work/hot-dumps/k3s/state.db.sqlite-backup`. Any missing, stale, or invalid k3s
artifact stops the Job before Restic runs. The pods run as root solely to traverse
the host's mode-`0700` database directory; service-account token mounting is disabled,
the default capability set is dropped and only `DAC_OVERRIDE` is added back for the
mixed-ownership read-only sources and UID-65534-owned NAS repository, privilege
escalation and privileged mode are disabled, and the root filesystem remains read-only.

The snapshot carries the contract version, exact required SQLite inventory, and export
completion timestamp. Local and B2 representative restore validation restores every
required artifact, checks every required SQLite export, validates the Home Assistant
archive, imports the RomM dump into a temporary MariaDB instance, and runs
`mariadb-check`. Full disaster recovery rejects a snapshot whose contract version or
inventory differs from the current required set before copying anything into `/opt`.
They validate the k3s artifact independently as well. Full recovery retains that
artifact in its root-only staging tree but never copies it into `/opt` and never
replaces the active datastore automatically.

### Optional emergency k3s datastore recovery

GitOps clean rebuild remains the default recovery model. Use the contract-v2 k3s
artifact only as an attended, operator-only same-cluster recovery source, following
the [k3s datastore backup and restore model](https://docs.k3s.io/datastore/backup-restore).
The database and server token must come from the same cluster state; the authoritative
token remains in the external password manager and is never present in Restic.

1. Select a validated contract-v2 snapshot and restore only
   `/work/hot-dumps/k3s/state.db.sqlite-backup` into a root-owned mode-`0700` staging
   directory. Repeat `PRAGMA integrity_check`, require both `kine` and
   `sqlite_sequence`, and require at least one `kine` row.
2. Retrieve the matching `/var/lib/rancher/k3s/server/token` value from the external
   password manager without placing it in the repository, shell history, logs, or the
   Restic staging tree.
3. Stop k3s with `sudo systemctl stop k3s` and confirm it is inactive.
4. Move `/var/lib/rancher/k3s/server/db` to a timestamped, root-only rollback path on
   the same filesystem. Do not delete it.
5. Create a fresh root-owned mode-`0700` `server/db`, install the validated artifact
   as mode-`0600` `server/db/state.db`, and confirm no `state.db-wal` or
   `state.db-shm` file exists in the new directory.
6. Preserve the existing matching `server/token`, or restore the retrieved matching
   token as root-owned mode `0600` before startup. Never substitute a token from a
   different cluster state.
7. Start k3s, then run `runbooks/phase2/06-validate-bootstrap.sh`,
   `runbooks/phase3/00-preflight.sh`, `runbooks/phase3/03-validation-gate.sh`, and
   representative Phase 4 workload validators. Retain the rollback directory until
   the cluster, Flux, monitoring, and representative workloads have remained healthy.

This procedure is intentionally not called by the default disaster-recovery runner.

## Monitoring & alerting

Phase one is deliberately metrics-first:

- **kube-prometheus-stack** provides Prometheus, Grafana, Alertmanager, node-exporter,
  kube-state-metrics, the Prometheus Operator, and the upstream Kubernetes rules and
  dashboards. The chart is pinned, CRDs are upgraded through Flux, and k3s-only
  nonexistent control-plane scrape targets are disabled.
- **prometheus-blackbox-exporter** checks the authenticated/user-facing ingress path
  for Home Assistant, Frigate, Zigbee2MQTT, Plex, Seerr, and RomM, plus the internal
  MQTT broker and SLZB-MRW10U Zigbee coordinator TCP paths. These probes exercise DNS,
  ingress, TLS, Services, applications, and the coordinator network socket instead of
  only observing that pods exist. Zigbee2MQTT is in the critical tier, so both its
  HTTPS path and coordinator socket are checked every 30 seconds and alert after three
  minutes of continuous failure.
- A dedicated **MQTT exporter** subscribes only to Zigbee2MQTT's retained bridge state
  and one-minute health topic. Prometheus alerts when the bridge reports offline, its
  own MQTT client reports disconnected, or health publication is missing or more
  than five minutes old. This distinguishes an available frontend from a broken
  Zigbee2MQTT-to-broker application path; the separate coordinator TCP probe covers
  SLZB name resolution, routing, appliance availability, and the radio socket.
- **nut-exporter** anonymously polls the host NUT server for the `cp1500` UPS. Its
  ServiceMonitor records charge, runtime, voltage, load, and status every 30 seconds;
  a repo-owned Grafana dashboard uses only telemetry exposed by this CyberPower model.
- A Flux `PodMonitor` exposes GitOps controller health. Local rules cover blackbox
  failures and certificate expiry, `/opt`, exact direct bulk-storage mounts,
  filesystem errors, stalled md checks, Gluetun restarts, and Restic failures,
  suspension, and overdue schedules; upstream rules cover degraded/failing RAID,
  Kubernetes crash loops, and resource failures.
- The upstream always-firing `Watchdog` alert checks in with **Dead Man's Snitch** via
  Alertmanager every five minutes. The URL is a SOPS Secret. This is the required
  off-node signal: if the node, Prometheus, Alertmanager, DNS, or outbound path fails,
  the hosted service notices the missing heartbeat.
- Hosted **Pushover** is the active actionable phone-notification destination. It
  routes only `severity=warning|critical`, explicitly excludes `Watchdog`, and reads
  its recipient/application keys from a SOPS-encrypted Secret. This adds no cluster
  workload or same-node notification dependency.

The initial metrics and alert pipeline passed live validation on 2026-07-20. All four
monitoring Flux Kustomizations and the kube-prometheus-stack HelmRelease were ready;
all 24 active scrape targets (including four Flux controllers) and all six blackbox
probes were healthy; 229 rules in 33 groups loaded without evaluation errors; Grafana's
HTTPS ingress reached its login page with valid TLS; and `Watchdog` was the only firing
alert. Alertmanager loaded the Dead Man's Snitch route, delivered its webhook without
failures, and the account-side Snitch became healthy. The Pushover component was then
activated and reconciled; synthetic warning and critical firing notifications and
their resolved notifications reached the iPhone. The nut-exporter workload, dashboard,
and critical on-battery rule were added to git on 2026-07-22 and passed live validation
on 2026-07-25. The controlled physical mains-loss drill confirmed the on-battery
transition, critical Pushover firing notification, return to online state, alert
resolution, and quiet recovery notification. The Zigbee2MQTT critical HTTPS and SLZB
coordinator TCP probes plus the MQTT-native bridge-health path passed live validation
on 2026-08-16. Prometheus had one healthy exporter target, reported retained online
state, an active MQTT connection, and health data newer than three minutes, saw both
blackbox paths succeed, and evaluated the bridge-health and shared endpoint rules
without errors or an active Zigbee2MQTT alert.

Grafana is exposed at `https://grafana.worm.run`; its `admin` password is generated
once and stored only in `infrastructure/monitoring/base/grafana-admin.sops.yaml`. Read
it locally when needed (the decrypted `data` value is base64-encoded):

```bash
sops --decrypt infrastructure/monitoring/base/grafana-admin.sops.yaml \
  | yq -r '.data["admin-password"]' | base64 --decode
```

**Optional phase two:** add **Loki with Grafana Alloy** only if cross-pod log search is
worth its storage and memory cost. Kubernetes logs remain the phase-one fallback;
hosted Pushover handles actionable phone push and the external dead-man independently
detects monitoring-path failure. If centralized logs are added, Promtail is not an
option: it reached
[end of life in March 2026](https://grafana.com/docs/loki/latest/send-data/promtail/),
and its functionality moved to Grafana Alloy.

### Alert coverage

| Alert | Trigger | State |
|---|---|---|
| Critical/standard endpoint down | blackbox HTTPS, MQTT TCP, or Zigbee coordinator TCP probe fails beyond its tier window | deployed; coordinator TCP live-validated 2026-08-16 |
| Zigbee2MQTT bridge unhealthy | retained state is offline, MQTT is disconnected, or one-minute health data is missing/stale | deployed and live-validated 2026-08-16 |
| Ingress certificate expiring | blackbox sees fewer than 14 days remaining | committed |
| NVMe usage > 80% | `/opt` filling | committed |
| Bulk-storage mount lost/error | an expected `hoardvg` ext4 mount disappears, maps incorrectly, or reports a device error | committed |
| RAID degraded/disk failure | md array is degraded or reports failed component disks | upstream kube-prometheus rule |
| RAID check stalled | active md3 consistency check makes no block progress for 45 minutes | committed |
| Gluetun pod restart | VPN container restarted in the last 15 minutes | committed |
| Pod crash loop | repeated restarts, any namespace | upstream kube-prometheus rule |
| Restic backup failed | CronJob job failure | committed |
| Restic backup overdue/suspended | no success within 30 hours (local) or 8 days (B2), or schedule suspended | committed |
| Actionable warning/critical alert | Alertmanager sends firing and resolved notifications to Pushover | deployed and live-validated 2026-07-20 |
| Monitoring pipeline absent | Dead Man's Snitch misses the Alertmanager Watchdog | deployed and live-validated; external check healthy 2026-07-20 |
| UPS on battery | `cp1500` reports `OB=1` for one minute | deployed and live-validated; mains-loss/Pushover drill passed 2026-07-25 |

### External dead-man and actionable notification routing

The Prometheus Watchdog Snitch is active with a 10-minute Basic interval and was
confirmed healthy on 2026-07-20. For a rebuild or check-in URL rotation, create or
update the Snitch in the existing account and run:

```bash
./runbooks/phase5/10-setup-deadmanssnitch.sh
```

The helper prompts without echo, validates the `https://nosnch.in/...` URL, creates a
SOPS-encrypted Secret, and activates the matching `AlertmanagerConfig`. Reconcile
`monitoring-configs`, confirm `Watchdog` is firing in Alertmanager, and confirm the
Snitch turns healthy again. Do not put the unique check-in URL in Helm values or
plaintext git history.

Pushover handles the separate actionable path without weakening this heartbeat. It is
active and passed a synthetic warning/critical firing and resolution drill on
2026-07-20. For a rebuild or credential rotation, use the existing Pushover application
named `Homelab Alertmanager`, update the password manager, then run:

```bash
./runbooks/phase5/11-setup-pushover.sh
```

The helper accepts `PUSHOVER_USER_KEY` and `PUSHOVER_API_TOKEN` or prompts without
echo, preserves omitted existing values during rotation, uses temporary plaintext
files only, and activates the component after its SOPS Secret and full render validate.
Commit the result and reconcile only `monitoring-configs`. Warning firing alerts use
normal priority `0`; critical firing alerts use high priority `1`, which bypasses quiet
hours without emergency acknowledgement retries; resolved alerts use quiet priority
`-1`. All messages show state, severity, alert name, summary, description, available
namespace/instance context, and a Grafana link. `Watchdog` is explicitly excluded.

After initial activation, each credential rotation, and periodic monitoring drills,
run `runbooks/phase5/12-test-pushover.sh`. Confirm the warning, critical, and quiet
recovery notifications; confirm the critical alert does not request acknowledgement;
confirm no `Watchdog` notification appears; and confirm Dead Man's Snitch remains
healthy. Keep the Snitch and Pushover tests together: Pushover delivers symptoms while
the independent heartbeat detects loss of the entire local monitoring path.

## UPS / NUT

NUT runs as a **host systemd service** (configured in
[Phase 0.5](./build-plan.md#phase-0--os-baseline-)), before k3s, so a clean shutdown
fires even if the cluster is degraded. The repo-managed **nut-exporter** pod polls it
for Prometheus and the `UPS / NUT — CP1500` Grafana dashboard. If the `OB` flag remains
set for one minute, `UPSOnBattery` fires at critical severity through the existing
Pushover route; recovery is sent quietly when mains returns. Existing kube-prometheus
`TargetDown` coverage reports exporter or NUT connectivity loss separately.

The full UPS monitoring path passed live validation on 2026-07-25. The automated
checks confirmed exporter telemetry, a healthy Prometheus target and rule, and Grafana
dashboard provisioning. During the operator-gated drill, disconnecting the UPS mains
input changed Prometheus to `OB=1`, fired `UPSOnBattery` and its critical Pushover
notification, and left the protected load running. Restoring mains returned the UPS
to online state, resolved the alert, and delivered the quiet recovery notification.

### UPS telemetry fan-out (one upsd, many read-only clients)

Both monitoring consumers poll the **same host `upsd`** directly — never one through
the other (routing UPS state via HA or Prometheus would couple the power-loss alert to
that intermediary's health, exactly what the alert exists to catch):

- **Home Assistant** — native NUT integration (UI-managed, lives on the HA PVC per
  repo convention) pointing at `10.137.20.5:3493`, UPS `cp1500`.
- **Prometheus** — the nut-exporter pod polling the same server/UPS.

Host-side plumbing (canonical copies in `host/minis/etc/`):

- `nut/upsd.conf` adds `LISTEN 10.137.20.5 3493` alongside loopback so pods can
  reach it. Reads are anonymous — NUT auth is only needed for commands and the
  `upsmon` role — which is acceptable because…
- `nftables.conf` (`ups_access` table) pins TCP 3493 to loopback + the k3s pod CIDR
  (`10.42.0.0/16`) and drops everything else, keeping the LAN and camera segment out.
- `systemd/system/nut-server.service.d/10-wait-online.conf` orders `nut-server` after
  `network-online.target` so the non-loopback bind can't race address assignment at
  boot (a lost race would leave telemetry silently blind while loopback/upsmon still
  worked).

This host plumbing was applied and re-verified on 2026-07-21: `nut-server` and
`nftables` were active, both listener addresses were present, and
`upsc cp1500@10.137.20.5` returned live telemetry. After future host changes, repeat
`ss -ltn | grep 3493` and `upsc cp1500@10.137.20.5`; host-local traffic arrives via
`lo`, which the nftables table accepts.

After committing and pushing the monitoring manifests, reconcile and run the
automated validation with an admin kubeconfig context:

```bash
flux reconcile kustomization monitoring-configs --with-source
./runbooks/phase5/13-validate-nut-exporter.sh
```

The helper validates the exporter endpoint, current online status, Prometheus target
and rule health, and Grafana dashboard provisioning without changing UPS state. For
the final end-to-end acceptance test, have an operator present and run
`NUT_POWER_DRILL=1 ./runbooks/phase5/13-validate-nut-exporter.sh`. The helper requires
confirmation before and after manually disconnecting **only the UPS mains input**, and
checks the transition to `OB=1`, the firing critical alert, return to online state,
and resolution. Confirm the critical firing and quiet recovery notifications on the
iPhone and that Dead Man's Snitch remains healthy.

## Direct-attached bulk storage

The canonical mdadm identity, filesystem automounts, and md check schedule live under
`host/minis/etc/`. The RAID6 array must assemble as `/dev/md3` with 13 active members,
two spares, and no degraded members. The four workload mountpoints must resolve to the
exact `hoardvg` mapper and ext4 UUID recorded in `host/minis/etc/fstab`; a directory on
the root filesystem is not a valid fallback.

The first-Sunday check starts at 10:00 local time. Ubuntu's stock mdcheck service runs
for up to six hours; an unfinished check records continuation state under
`/var/lib/mdcheck/` and retries daily at 10:00. Service drop-ins set the per-array
`sync_speed_max` to `50000` KiB/s while either service runs, then restore `system` so
a rebuild or recovery is not left throttled. Inspect the live posture with:

```bash
cat /proc/mdstat
cat /sys/block/md3/md/{array_state,sync_action,degraded}
cat /sys/block/md3/md/sync_speed_max
systemctl list-timers mdcheck_start.timer mdcheck_continue.timer
systemctl show mdcheck_start.service mdcheck_continue.service -p DropInPaths
```

At idle, `sync_speed_max` displays the current system value followed by `(system)`;
during a scheduled check it must display `50000`. The first direct-array check on
2026-08-10/11 completed with `mismatch_cnt=0` but saturated the active members and
blocked Frigate filesystem tasks for 122–245 seconds. The cap was installed on
2026-08-13; its attended workload-impact validation is intentionally deferred to the
next check window.

The upstream `NodeRAIDDegraded` and `NodeRAIDDiskFailure` rules cover array/device
failure. Repo-owned `BulkStorageMountSetIncomplete` and
`BulkStorageFilesystemDeviceError` rules cover the exact direct mount layer;
`RaidCheckStalled` warns when an active check has made no synced-block progress for
45 minutes. Treat HBA resets, I/O errors, a nonzero degraded count, or an unexpected
resync/recovery as immediate investigation conditions.

## Resource tuning

`runbooks/phase5/14-audit-resources.sh` is the repeatable audit path. It opens a
temporary Prometheus port-forward and emits TSV for currently Running/Pending
containers in `media`, `frigate`, `home-assistant`, and `mqtt`. Current requests and
limits come from kube-state-metrics joined to Running/Pending pod phases, preventing
retained Failed/Succeeded pods from inflating reservation totals. Historical columns
use 5-minute CPU rates, CFS throttled/total periods, memory working set, and cgroup
OOM counters over `RESOURCE_AUDIT_WINDOW` (default `14d`). Reports belong under
`/tmp` or another path outside git.

The pre-change 14-day baseline captured on 2026-08-13 showed zero OOM events. Media
reserved `3.6` CPU cores and `4032Mi`; the sustained memory working sets justified a
small reservation increase while the low CPU usage justified releasing scheduler
reservations. Key container observations were:

| Container | CPU 5m p95 / max | Throttling | Memory p95 / max |
|---|---:|---:|---:|
| Plex | 1.005579 / 3.838676 cores | 0.058% | 1174.969 / 3241.359Mi |
| Gluetun | 0.000265 / 0.000949 cores | 0% | 56.289 / 70.281Mi |
| SABnzbd | 0.000355 / 0.111655 cores | 0% | 227.441 / 409.008Mi |
| qBittorrent | 0.000396 / 0.001674 cores | 0% | 50.898 / 50.902Mi |
| Prowlarr | 0.001189 / 0.032714 cores | 0.006% | 224.921 / 228.980Mi |
| Radarr | 0.002070 / 0.102894 cores | 0.147% | 333.785 / 347.715Mi |
| Sonarr | 0.002191 / 0.072910 cores | 0.143% | 445.282 / 500.883Mi |
| Seerr | 0.001496 / 0.039060 cores | 10.263% | 419.543 / 641.602Mi |
| RomM | 0.001970 / 0.082399 cores | 0.024% | 280.102 / 280.539Mi |
| MariaDB | 0.002081 / 0.007546 cores | 0.029% | 165.793 / 168.188Mi |
| Valkey | 0.001783 / 0.006310 cores | 0.008% | 27.383 / 27.828Mi |

The resulting media allocation reserves `1.775` CPU cores and `4320Mi`. It was
deployed on 2026-08-13 and passed the seven-complete-day audit gate on 2026-08-22.
The closeout reproduced the exact reservation totals, recorded zero OOM events and no
resource-related restarts, kept every memory maximum below 85% of its limit, and kept
every container below 5% throttling without user-visible regression. Seerr was closest
to the throttling threshold at `4.264%`; that passes the gate, but should be watched in
later audits before considering any limit change.

For future tuning:

- In Grafana, compare actual CPU/memory per workload against its requests/limits.
- Raise CPU limits when a pod is throttled; raise requests when sustained usage needs a
  larger scheduler reservation and contention weight. Lower consistently
  over-provisioned requests to release scheduler reservation, while keeping memory
  limits safely above observed peaks.
- Re-check after adding Immich — its ML container is the one likely to shift the memory
  picture.
- Only if Frigate detection latency suffers under load: evaluate exclusive CPU
  placement. That requires changing Frigate to Guaranteed QoS with an equal integer
  CPU request/limit, enabling static CPU Manager, and adding host-level CPU-set/topology
  controls for the intended P-cores; static CPU Manager alone does not choose P-cores.
  Don't do this preemptively.

## AI-session practices

This repo is operated alongside an AI coding session. See the
[working agreements in AGENTS.md](../AGENTS.md#working-agreements-for-an-ai-session) for
the guardrails (read-only default, `flux suspend` before manifest surgery, btrfs
snapshot before risky changes, never commit plaintext secrets, no speculative
destructive commands). Operationally useful surfaces to expose to the session:

- **kubeconfig** at `~/.kube/config`; keep a read-only context as default and an admin
  context for deliberate changes. Optionally a scoped `ServiceAccount` + RBAC for
  programmatic access that's easy to rotate and audit.
- **Tailnet application access** through the in-cluster Tailscale Operator Connector,
  which advertises only `10.137.20.10/32` for ingress and `10.137.20.1/32` for split
  DNS. The administrative kubeconfig targets the node API on the LAN; the Connector
  does not advertise the node address or require host-level `tailscaled`.
- **Prometheus HTTP API** (`/api/v1/query`) — far more useful than scraping logs for
  "correlate a Frigate detection spike with NVMe I/O wait" type questions.
- **Frigate API** (`/api/...`) and **Home Assistant API** (long-lived token) for
  app-level introspection.
- A `~/.homelab-env` sourced from `.bashrc` holding the handy tokens/URLs (these are
  *also* SOPS secrets in-cluster; the env file is just for the shell, never committed).

`flux reconcile kustomization apps --with-source` gives a tight edit→apply loop instead
of waiting for the default interval.

## Follow-ups

Deferred deliberately; revisit when the trigger condition is met.

The former VLAN 10 NTP follow-up was deployed and live-validated on 2026-08-27:
the bastion serves only `10.137.10.9:123/udp` to VLAN 10 and synchronizes
upstream through VLAN 30. `ntp.service.mgmt.matrix`, DHCP option 42, and the
Catalyst static client were enabled only after the attended local and client
health gates passed. The retired Morpheus name, advertisement, and firewall
exception remain absent.

| Item | When to do it |
|---|---|
| **Bulk-storage backup plan** | Replace the current ad hoc external-drive copies with a documented, repeatable backup policy for irreplaceable content on `/mnt/media` (including personal pictures), `/mnt/games`, and any other selected bulk-array paths. Define the destination, cadence, retention, monitoring, and representative restore drills; until then, do not describe the RAID array itself as a backup. |
| **Move SLZB-MRW10U to IoT VLAN 60** | The dual-radio coordinator currently resides on Trusted/VLAN 30. Follow the ordered migration checklist in [network.md](./network.md#network-step-1-unifi-dream-machine-configuration): record its current IP/MAC, assign a stable VLAN 60 address, stage the narrow `minis` TCP `6638`/`7638` allow, preserve `slzb-mrw10u.iot.matrix`, and rerun the Z-Wave, Zigbee, and monitoring validators. mDNS reflection is neither enabled nor required for this fixed DNS/TCP path. |
| **Selected NFS exports from `minis`** | When a real remote consumer appears, export only `/mnt/media` and `/mnt/games` from `minis` with an explicit client/access policy. Nothing exports bulk storage over NFS today. Keep `/mnt/frigate` local-only; do not export `/mnt/backups` without a concrete use. |
| **Second node** | Only on a *measured* need: HA must survive main-node maintenance, or Frigate outgrows the Coral/CPU budget. Repo layout already supports it via `nodeSelector`/affinity. |
| **Tailscale Funnel for Plex** | Evaluate only if sharing with non-Tailnet users or casting to uncontrolled clients becomes a real need. Funnel is still beta and subject to Tailscale's non-configurable bandwidth limits, so validate sustained Plex throughput and target-client compatibility before choosing it over another narrowly scoped remote-access design. |
| **Immich** | When ready — coordinate the initial import in a quiet window, watch memory. Originals on the direct bulk array, thumbs/ML on `/opt/immich`. |

> **Camera switch isolation (Catalyst 3850)** was previously listed here as deferred
> work. It became a Phase 1 blocker and was satisfied before the deployed camera went
> live: protected ports and the host nftables path were verified during Phase 4. Repeat
> the camera-specific isolation checks whenever another camera is provisioned; see
> [build-plan.md → 1.1b](./build-plan.md#phase-1--networking-isolation-).

Accepted constraints (not gaps): no staging environment (changes go to the one
cluster—mitigated by btrfs snapshots + `flux suspend`); cert renewal depends on the
external DNS provider's API (90-day certs make a brief outage non-fatal). Git remains
the cluster rebuild source of truth. The scheduled k3s SQLite artifact is an optional
emergency same-cluster recovery source, not the default rebuild path; the
version-management workflow also adds a short-lived, access-controlled datastore
checkpoint before k3s upgrades. Application state is protected separately by Restic.
Selected secrets are also saved
in the external password manager as an independent recovery source; the `sops-age`
private key and values redacted from canonical host or device configuration remain
outside git. A rebuild therefore requires the git repository, Restic where state is
needed, and the relevant password-manager entries.
