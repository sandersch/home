# Phase 5 - backups and observability

Scripts for the backup and first observability slices of
[build-plan.md Phase 5](../../docs/build-plan.md#phase-5--observability--expansion-).

## Order

Run these after Phase 4 is validated and the direct-attached backup filesystem is
available as `/dev/mapper/hoardvg-backuplv` at `/mnt/backups`.

| Script | Purpose |
|---|---|
| `00-preflight.sh` | Validate Phase 5 backup/monitoring manifests, including dormant or active Pushover invariants |
| `01-backups-mount.sh` | Add `/mnt/backups` to `/etc/fstab`, verify its exact UUID/device mapping, and test UID 65534 write access |
| `02-encrypt-restic-secret.sh` | Create the SOPS-encrypted `monitoring/restic-nas` Secret |
| `03-init-restic-nas-repo.sh` | Initialize `/mnt/backups/opt` as a Restic repo |
| `04-run-manual-backup.sh` | Run one backup immediately from the CronJob |
| `05-validate-restore.sh` | Restore and validate every required export from the latest direct-array snapshot, including a temporary RomM import |
| `06-encrypt-restic-b2-secret.sh` | Generate the independent SOPS-encrypted B2 repository Secret |
| `07-init-restic-b2-repo.sh` | Reconcile monitoring and initialize the B2 repository idempotently |
| `08-run-manual-b2-backup.sh` | Run the weekly B2 CronJob manually |
| `09-validate-b2-restore.sh` | Restore and validate every required export from B2, including a temporary RomM import, without the local backup volume |
| `10-setup-deadmanssnitch.sh` | SOPS-encrypt the external heartbeat URL and activate Alertmanager Watchdog routing |
| `11-setup-pushover.sh` | SOPS-encrypt Pushover keys and atomically activate actionable phone notifications |
| `12-test-pushover.sh` | Inject and resolve synthetic warning/critical alerts through Alertmanager |
| `13-validate-nut-exporter.sh` | Validate UPS telemetry, Prometheus/Grafana integration, and optionally run the physical mains-loss alert drill |
| `14-audit-resources.sh` | Audit current reservations and historical CPU, throttling, memory, and OOM metrics |
| `15-validate-zigbee2mqtt-monitoring.sh` | Validate Zigbee2MQTT's critical ingress/coordinator probes, MQTT exporter, Prometheus metrics, and alerts |

Both repositories have passed initialization, manual backup, and representative restore
validation. The nightly local and first naturally scheduled weekly B2 backups both
completed successfully on 2026-07-19. Required-export contract version 1 passed fresh
attended local and B2 backup/restore drills on 2026-08-16. The local restore validated
snapshot `c0c28acd`; the local-volume-independent B2 restore validated snapshot
`8e27e272`. Each drill checked all eight mandatory SQLite exports, a readable Home
Assistant archive, and a RomM dump imported as 22 healthy tables.

The shared backup workflow excludes `/data/opt/.snapshots` from both SQLite discovery
and Restic input. Local btrfs snapshots remain available for same-device rollback but
are not recursively embedded in the independent local or B2 recovery points.

Backup-contract version 2 makes both Plex library databases and the primary Frigate,
Home Assistant, Prowlarr, Radarr, Sonarr, and Seerr databases mandatory. Each must be
exported during the current Job and pass SQLite validation. A newly created, readable Home Assistant
managed backup and a `mariadb-check`-validated RomM logical dump are also mandatory.
The Job stops before Restic if any required artifact is missing, stale, or invalid.
Optional discovered log/history/cache databases do not block the recovery point.
Contract version 2 also requires a current-job SQLite online backup of
`/var/lib/rancher/k3s/server/db/state.db`. It must pass full integrity, contain the
`kine` and `sqlite_sequence` tables, and have at least one `kine` row. The CronJobs
mount only the database directory read-only; the server token remains exclusively in
the external password manager and is never included in scheduled snapshots.

Both restore-validation scripts select the latest snapshot for their own target tag,
require the exact current contract and inventory, validate every required SQLite file
and the independently extracted k3s artifact,
read the Home Assistant tar archive, and import the RomM dump into a temporary MariaDB
sidecar followed by `mariadb-check`.

The initial observability stack passed live validation on 2026-07-20. Prometheus,
Grafana, Alertmanager, blackbox probes, Flux metrics, and rules were healthy, and the
Alertmanager Watchdog reached a healthy Dead Man's Snitch check. The Pushover route was
then activated and its synthetic warning/critical firing and resolved notifications
were delivered successfully to the iPhone.

The nut-exporter, CP1500 dashboard, and `UPSOnBattery` rule passed live validation on
2026-07-25. The operator-gated physical mains-loss drill confirmed the on-battery
transition, critical Pushover firing notification, return to online state, alert
resolution, and quiet recovery notification.

Zigbee2MQTT's critical HTTPS probe, coordinator TCP probe, and MQTT-native
bridge-health monitoring passed live validation on 2026-08-16. The exporter endpoint
reported retained online state, an active MQTT connection, and current one-minute
health data; Prometheus had one healthy exporter target, both blackbox paths
succeeded, and the five-minute bridge-health and shared three-minute endpoint rules
were healthy with no active Zigbee2MQTT alert.

## Zigbee2MQTT monitoring validation

Use a kubeconfig context allowed to port-forward in both `zigbee2mqtt` and
`monitoring`, then run:

```bash
./runbooks/phase5/15-validate-zigbee2mqtt-monitoring.sh
```

The helper verifies the rendered safety invariants and both critical-priority
Deployments, reads the exporter endpoint, and queries Prometheus for exactly one
healthy scrape target. It requires the retained bridge state to be online,
Zigbee2MQTT's MQTT client to be connected, health data to be newer than three
minutes, and the critical HTTPS blackbox probe to be successful. It also confirms
that the SLZB coordinator's critical TCP probe succeeds and that both
`Zigbee2MQTTBridgeUnhealthy` and its shared `CriticalEndpointDown` rule are loaded
with the expected delays and evaluate without errors or an active coordinator alert.

This gate is non-disruptive: it does not change retained MQTT state, restart a
workload, or inject an alert. Notification delivery is covered independently by
`12-test-pushover.sh`, so a routine validation does not need to falsify bridge state
or interrupt home automation.

## Resource audit

Run the audit with a kubeconfig context allowed to port-forward to Prometheus. Keep
captured reports outside git:

```bash
./runbooks/phase5/14-audit-resources.sh \
  > /tmp/resource-audit-$(date +%F).tsv
```

`RESOURCE_AUDIT_WINDOW` defaults to `14d`; `RESOURCE_AUDIT_LOCAL_PORT` defaults to
`19090`. The report is stable TSV with one row per currently Running/Pending
container and a `__TOTAL__` row per namespace. It covers `media`, `frigate`,
`home-assistant`, and `mqtt`, and includes current CPU/memory requests and limits,
5-minute CPU p95/max, aggregate CFS throttling percentage, working-set memory
p95/max, and cgroup OOM events. Status goes to stderr so stdout can be redirected or
piped safely.

The helper exits nonzero for invalid overrides, an unavailable port-forward or
metric, a failed Prometheus response, or any tracked container that cannot be joined
across the required metrics. Thresholds are deliberately observational. The
unchanged-cluster baseline captured on 2026-08-13 included:

```text
NAMESPACE  CONTAINER  CPU_REQUEST_CORES  CPU_LIMIT_CORES  MEMORY_REQUEST_MIB  MEMORY_LIMIT_MIB
media      __TOTAL__  3.6                16.75            4032                11008
```

After the media tuning rollout, current reservations/limits should read:

```text
NAMESPACE  CONTAINER  CPU_REQUEST_CORES  CPU_LIMIT_CORES  MEMORY_REQUEST_MIB  MEMORY_LIMIT_MIB
media      __TOTAL__  1.775              17.25            4320                11776
```

After seven complete days, capture the observation report with:

```bash
RESOURCE_AUDIT_WINDOW=7d ./runbooks/phase5/14-audit-resources.sh \
  > /tmp/resource-audit-7d-$(date +%F).tsv
```

Require zero OOM events or resource-related restarts, memory maximum below 85% of
each media container's limit, aggregate throttling below 5% per media container, and
no Plex, download/import, Seerr, or RomM regression before closing the gate.

## UPS telemetry and alert drill

The nut-exporter manifests use anonymous read-only access to the host NUT server at
`10.137.20.5:3493`, UPS name `cp1500`. No Kubernetes Secret is required. After the
manifests are committed and pushed, switch explicitly to an admin kubeconfig context,
reconcile the configs slice, and run the non-disruptive checks:

```bash
flux reconcile kustomization monitoring-configs --with-source
./runbooks/phase5/13-validate-nut-exporter.sh
```

The helper verifies the hardened Deployment and rendered invariants, checks the live
exporter metrics, confirms the Prometheus target and `UPSOnBattery` rule are healthy,
and authenticates to Grafana with the deployed `grafana-admin` Secret to verify
dashboard provisioning. It does not print the decoded Grafana credentials; access to
that Secret is one reason this runbook requires an admin kubeconfig context.

The physical drill is opt-in and must be run with an operator present:

```bash
NUT_POWER_DRILL=1 ./runbooks/phase5/13-validate-nut-exporter.sh
```

Follow the prompts to disconnect only the UPS mains input while leaving the protected
load attached, confirm the high-priority Pushover alert after `OB=1` has persisted for
one minute, then restore mains. The helper verifies Prometheus returns to `OB=0` and
the alert resolves. Confirm the quiet recovery notification arrives within the
inherited five-minute Alertmanager group interval and Dead Man's Snitch stays healthy.
If the script is interrupted after the drill begins, restore mains before doing
anything else.

## External monitoring heartbeat

The current Prometheus `Watchdog` Snitch is active and healthy with a 10-minute Basic
interval. For a rebuild or check-in URL rotation, create or update the Snitch in the
existing Dead Man's Snitch account. Keep the 10-minute interval because Alertmanager
checks in every 5 minutes; the wider service interval leaves room for scheduling and
network jitter. Then run:

```bash
./runbooks/phase5/10-setup-deadmanssnitch.sh
```

The script prompts without echoing the unique `https://nosnch.in/...` URL (or accepts
it from `DEADMANS_SNITCH_URL`), writes plaintext only in a temporary directory,
creates `infrastructure/monitoring/configs/deadmanssnitch/deadmanssnitch.sops.yaml`,
and adds the complete component to `monitoring-configs`. Commit those changes before
reconciling:

```bash
flux reconcile kustomization monitoring-configs --with-source
```

Confirm that `Watchdog` is firing in Alertmanager and that the Snitch becomes healthy
again.
This tests the Prometheus → Alertmanager → external-network path end to end. Dead Man's
Snitch remains separate from Pushover so loss of the node, monitoring stack, DNS, or
outbound path is still detected when no actionable phone notification can be sent.

## Actionable Pushover notifications

The Pushover component is active and passed its initial firing/resolution drill on
2026-07-20. The following setup procedure is for a rebuild or credential rotation.

Install and purchase Pushover on the one recipient iPhone, then register one Pushover
application named `Homelab Alertmanager`. Store the account's individual user key and
the application's API token in the password manager. Pushover is hosted and adds no
cluster workload; its iOS/iPadOS license is a one-time purchase and the service allows
10,000 application messages per month. See [Pushover pricing](https://pushover.net/pricing).

Create or rotate its encrypted Secret with silent prompts, or provide both values
through the environment:

```bash
export PUSHOVER_USER_KEY=...
export PUSHOVER_API_TOKEN=...
./runbooks/phase5/11-setup-pushover.sh
```

On reruns, omitted values are recovered from the existing encrypted Secret and
preserved. Plaintext exists only in a mode-0700 directory under `/tmp`; the helper
encrypts before writing the Secret into the repo, validates the complete render, and
adds `pushover` to `monitoring-configs` last. Commit the encrypted Secret, component
kustomizations, and manifest changes, then reconcile only the configs slice:

```bash
flux reconcile kustomization monitoring-configs --with-source
flux get kustomization monitoring-configs
kubectl -n monitoring logs statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  -c alertmanager --since=10m
```

Only `severity=warning|critical` reaches Pushover, and `Watchdog` is explicitly
excluded. Warning firing notifications use priority `0`, critical firing notifications
use priority `1` (high priority without emergency acknowledgement retries), and both
resolve at quiet priority `-1`. The route keeps the 30-second group wait and 12-hour
repeat interval and links to `https://grafana.worm.run`.

After first activation, every credential rotation, and periodic monitoring drills, run:

```bash
./runbooks/phase5/12-test-pushover.sh
```

The helper opens a local port-forward, injects short-lived synthetic warning and
critical alerts through Alertmanager, then resolves them. Confirm ordinary/high firing
notifications and quiet recovery notifications arrive on the iPhone, the critical
notification does not demand acknowledgement or repeat, `Watchdog` never appears in
Pushover, and the account-side Dead Man's Snitch remains healthy. Recovery delivery
inherits Alertmanager's five-minute group interval, so the full drill takes about six
minutes.

## Secret generation

Create a long-lived Home Assistant token dedicated to backups, then run:

```bash
export HOME_ASSISTANT_TOKEN=...
./runbooks/phase5/02-encrypt-restic-secret.sh
```

`RESTIC_PASSWORD` is generated when omitted only if there is no existing Restic Secret;
on reruns, the existing value is preserved so the initialized Restic repository stays
readable. `HOME_ASSISTANT_TOKEN` is also preserved on reruns when omitted.
`ROMM_DB_PASSWORD` is read from the existing SOPS-encrypted RomM Secret's
`MARIADB_PASSWORD` key when omitted, because that is the password MariaDB uses for the
`romm` database user. The script warns if RomM's app-facing `DB_PASSWD` value differs
from `MARIADB_PASSWORD`.

The script writes plaintext only under a temporary directory, encrypts the Secret to
`infrastructure/monitoring/restic-nas.sops.yaml`, and adds it to the monitoring
kustomization.

If a manual backup fails with `mariadb-dump: Got error: 1045` for
`romm@<pod-ip>`, regenerate `infrastructure/monitoring/restic-nas.sops.yaml` with
this script, commit/reconcile `monitoring`, and rerun `04-run-manual-backup.sh`.

## Image

The backup CronJobs and recovery helpers use the same immutable custom image reference.
Its canonical tag is in `containers/restic-backup/VERSION`, and the base image is
pinned by exact tag and digest in the Containerfile. Pull requests build without
publishing. To release a reviewed revision, bump the version/revision, manually run
the `restic-backup-image` workflow on that reviewed branch, and copy the reported
publisher digest into every CronJob and recovery helper before merge. The workflow
refuses to overwrite an existing GHCR tag, and the image-policy CI check rejects tag,
digest, or version-file drift.

## Backblaze B2 offsite repository

Provision B2 before running script 06:

1. Create a dedicated private bucket with default server-side encryption enabled.
   Leave Object Lock disabled; once enabled it cannot be disabled, and a lock would
   prevent scheduled `forget --prune` from deleting expired Restic data.
2. Set the bucket lifecycle to **Keep only the latest version of each object**. B2
   buckets are versioned, and Restic's S3 backend otherwise leaves hidden older
   versions consuming storage.
3. Create a non-expiring application key restricted to this bucket with **Read and
   Write** access and **Allow List All Bucket Names** enabled. The latter is required
   for S3-compatible clients using a bucket-restricted key.
4. Record the bucket name, S3 endpoint, key ID, application key, and the Restic
   password generated in the next step in the password manager.

Generate the Secret with the values from Backblaze:

```bash
export B2_BUCKET=...
export B2_ENDPOINT=https://s3.us-west-004.backblazeb2.com
export B2_KEY_ID=...
export B2_APPLICATION_KEY=...
./runbooks/phase5/06-encrypt-restic-b2-secret.sh
```

The script writes plaintext only inside a temporary directory. It creates
`RESTIC_REPOSITORY=s3:<endpoint>/<bucket>/opt`, generates a distinct repository
password when one is not supplied, preserves every existing value on reruns, and adds
the encrypted Secret to the monitoring kustomization. The weekly job reads the
existing local-repository Secret (`restic-nas`, retained as a legacy name) for the Home Assistant token and RomM password instead of
duplicating them.

Commit the encrypted Secret, reconcile and validate while the CronJob is suspended:

```bash
./runbooks/phase5/07-init-restic-b2-repo.sh
./runbooks/phase5/08-run-manual-b2-backup.sh
./runbooks/phase5/09-validate-b2-restore.sh
```

Only after all three succeed, ensure `suspend: false` in
`infrastructure/monitoring/restic-b2-cronjob.yaml`, commit, and reconcile monitoring.
The offsite schedule is Sunday at 04:30 America/Chicago, with 8 weekly and 12 monthly
snapshots and no daily tier.

References: [Restic's Backblaze guidance](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#backblaze-b2),
[Backblaze lifecycle rules](https://www.backblaze.com/docs/en/cloud-storage-lifecycle-rules),
and [S3-compatible application keys](https://www.backblaze.com/docs/cloud-storage-s3-compatible-app-keys).
