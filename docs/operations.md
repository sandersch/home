# Operations

Ongoing concerns: backups, monitoring/alerting, UPS, resource tuning, AI-session
practices, and deferred work. Built out in [Phase 5](./build-plan.md#phase-5--observability--expansion-).

## Backups

Three categories of data, three different needs:

| What | Mechanism | Destination | Cadence |
|---|---|---|---|
| age private key + bootstrap secrets | manual | password manager | once |
| GitOps repo (all manifests) | git | GitHub | every commit |
| App state (`/opt`, incl. SQLite DBs) | independent Restic CronJobs | NAS + Backblaze B2 | nightly + weekly |
| Frigate recordings | — (not backed up) | NAS is the store | — |
| Media library | NAS-level (your call) | — | — |

What is **already covered** and needs no backup job: cluster/GitOps config (it's in
git — rebuild = reinstall k3s + re-bootstrap Flux), and recordings/media (regenerable
or the NAS is already the system of record). The job below exists for **app state on
the non-redundant local NVMe**.

### Restic CronJob (runs in-cluster)

Restic runs as Kubernetes **CronJobs** (chosen over host systemd timers to keep them in
git and visible to monitoring). The Phase 5 implementation mounts `/opt` read-only and
creates independent snapshots in two repositories. The nightly NAS job writes to
`/mnt/backups/opt` on the host (`/repo/nas/opt` in the pod) and keeps 14 daily, 8
weekly, and 12 monthly snapshots. The Sunday 04:30 America/Chicago job writes directly
to Backblaze's S3-compatible API and keeps 8 weekly and 12 monthly snapshots. Both run
the same SQLite, Home Assistant, and RomM hot-backup workflow, but the B2 job and its
restore validation have no NAS volume dependency.

Validation status: initialization, manual backups, repository checks, and representative
restore drills passed for both repositories. The nightly NAS and first naturally
scheduled weekly B2 backups both completed successfully on 2026-07-19.

```bash
restic -r /mnt/backups/opt backup /data/opt
restic -r s3:https://s3.<region>.backblazeb2.com/<bucket>/opt backup /data/opt
```

Required hardening on the CronJob so a failure is **loud**, not silently missing:
```yaml
spec:
  failedJobsHistoryLimit: 3
  successfulJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0              # fail fast, no silent retries
      activeDeadlineSeconds: 3600  # NAS: kill a hung run after 1h; B2 uses 6h
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
recovery commands are in [`runbooks/phase5/README.md`](../runbooks/phase5/README.md).

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
| Home Assistant | call its **REST API** `backup.create_automatic` (not raw sqlite3) | HA manages its own WAL |
| Frigate | `sqlite3 .backup` | small; already in `/opt` scope |
| Radarr/Sonarr/Prowlarr | `sqlite3 .backup` | low-risk but be consistent |
| Seerr | `sqlite3 .backup` | lightweight; loss = re-sync/rescan |
| RomM | `mariadb-dump` from the MariaDB sidecar | lightweight; loss = re-sync/rescan |
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

## Monitoring & alerting

Phase one is deliberately metrics-first:

- **kube-prometheus-stack** provides Prometheus, Grafana, Alertmanager, node-exporter,
  kube-state-metrics, the Prometheus Operator, and the upstream Kubernetes rules and
  dashboards. The chart is pinned, CRDs are upgraded through Flux, and k3s-only
  nonexistent control-plane scrape targets are disabled.
- **prometheus-blackbox-exporter** checks the authenticated/user-facing ingress path
  for Home Assistant, Frigate, Plex, Seerr, and RomM, plus the internal MQTT TCP path.
  These probes exercise DNS, ingress, TLS, Services, and applications instead of only
  observing that pods exist.
- **nut-exporter** anonymously polls the host NUT server for the `cp1500` UPS. Its
  ServiceMonitor records charge, runtime, voltage, load, and status every 30 seconds;
  a repo-owned Grafana dashboard uses only telemetry exposed by this CyberPower model.
- A Flux `PodMonitor` exposes GitOps controller health. Local rules cover blackbox
  failures and certificate expiry, `/opt`, NFS, Gluetun restarts, and Restic failures,
  suspension, and overdue schedules; upstream rules cover Kubernetes crash loops and
  resource failures.
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
resolution, and quiet recovery notification.

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
| Critical/standard endpoint down | blackbox HTTPS or MQTT TCP probe fails beyond its tier window | committed |
| Ingress certificate expiring | blackbox sees fewer than 14 days remaining | committed |
| NVMe usage > 80% | `/opt` filling | committed |
| NFS mount lost/error | expected host NFS mount disappears or reports a device error | committed |
| Gluetun pod restart | VPN container restarted in the last 15 minutes | committed |
| Pod crash loop | repeated restarts, any namespace | upstream kube-prometheus rule |
| Restic backup failed | CronJob job failure | committed |
| Restic backup overdue/suspended | no success within 30 hours (NAS) or 8 days (B2), or schedule suspended | committed |
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

## Resource tuning

The [allocation table](./architecture.md#resource-allocation) values are conservative
starting points. After ~1 week of real data:

- In Grafana, compare actual CPU/memory per workload against its requests/limits.
- Raise CPU limits when a pod is throttled; raise requests when sustained usage needs a
  larger guaranteed share. Lower consistently over-provisioned requests to release
  scheduler reservation, while keeping memory limits safely above observed peaks.
- Re-check after adding Immich — its ML container is the one likely to shift the memory
  picture.
- Only if Frigate detection latency suffers under load: consider the static
  CPU-manager policy to pin it to P-cores. Don't do this preemptively.

## AI-session practices

This repo is operated alongside an AI coding session. See the
[working agreements in AGENTS.md](../AGENTS.md#working-agreements-for-an-ai-session) for
the guardrails (read-only default, `flux suspend` before manifest surgery, btrfs
snapshot before risky changes, never commit plaintext secrets, no speculative
destructive commands). Operationally useful surfaces to expose to the session:

- **kubeconfig** at `~/.kube/config`; keep a read-only context as default and an admin
  context for deliberate changes. Optionally a scoped `ServiceAccount` + RBAC for
  programmatic access that's easy to rotate and audit.
- **k3s API on the Tailnet** (`:6443`) so the laptop can reconcile remotely.
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

| Item | When to do it |
|---|---|
| **Second node** | Only on a *measured* need: HA must survive main-node maintenance, or Frigate outgrows the Coral/CPU budget. Repo layout already supports it via `nodeSelector`/affinity. |
| **Tailscale Funnel for Plex** | If sharing with non-Tailnet users / casting to uncontrolled client devices becomes a real need. Cleaner than Plex native remote access. |
| **Immich** | When ready — coordinate the initial import in a quiet window, watch memory. Originals on NAS, thumbs/ML on `/opt/immich`. |

> **Camera switch isolation (Catalyst 3850)** was previously listed here as deferred
> work. It became a Phase 1 blocker and was satisfied before the deployed camera went
> live: protected ports and the host nftables path were verified during Phase 4. Repeat
> the camera-specific isolation checks whenever another camera is provisioned; see
> [build-plan.md → 1.1b](./build-plan.md#phase-1--networking-isolation-).

Accepted constraints (not gaps): no staging environment (changes go to the one
cluster — mitigated by btrfs snapshots + `flux suspend`); cert renewal depends on the
external DNS provider's API (90-day certs make a brief outage non-fatal); no k3s etcd
snapshots — the entire cluster state lives in git, and a full re-bootstrap from
scratch takes ~30 min; the only out-of-git state is the `sops-age` key, which is
backed up to a password manager.
