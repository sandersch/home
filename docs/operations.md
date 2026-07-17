# Operations

Ongoing concerns: backups, monitoring/alerting, UPS, resource tuning, AI-session
practices, and deferred work. Built out in [Phase 5](./build-plan.md#phase-5--observability--expansion-).

## Backups

Three categories of data, three different needs:

| What | Mechanism | Destination | Cadence |
|---|---|---|---|
| age private key + bootstrap secrets | manual | password manager | once |
| GitOps repo (all manifests) | git | GitHub | every commit |
| App state (`/opt`, incl. SQLite DBs) | Restic CronJob | NAS now; Backblaze B2 next | nightly / weekly |
| Frigate recordings | — (not backed up) | NAS is the store | — |
| Media library | NAS-level (your call) | — | — |

What is **already covered** and needs no backup job: cluster/GitOps config (it's in
git — rebuild = reinstall k3s + re-bootstrap Flux), and recordings/media (regenerable
or the NAS is already the system of record). The job below exists for **app state on
the non-redundant local NVMe**.

### Restic CronJob (runs in-cluster)

Restic runs as a Kubernetes **CronJob** (chosen over a host systemd timer to keep it
in git and visible to monitoring). The Phase 5 backup-first implementation mounts
`/opt` read-only and writes to a dedicated NAS export at `/mnt/backups`, with the
Restic repository at `/mnt/backups/opt` from the host's point of view
(`/repo/nas/opt` in the pod). Backblaze B2 is intentionally the next backup phase,
after the NAS repo and restore drill are proven. B2 was chosen over Cloudflare R2:
cheaper per-GB storage (~$6/TB vs ~$15/TB), and egress is irrelevant for an
infrequently-restored backup. Switching providers later is a backend URL change —
Restic supports B2/S3/R2/Wasabi natively, and rclone covers the rest.

```bash
restic -r /mnt/backups/opt backup /data/opt   # local copy
restic -r b2:bucket/opt    backup /data/opt   # future offsite copy
```

Required hardening on the CronJob so a failure is **loud**, not silently missing:
```yaml
spec:
  failedJobsHistoryLimit: 3
  successfulJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0              # fail fast, no silent retries
      activeDeadlineSeconds: 3600  # kill a hung run after 1h
```
Plus the Alertmanager rule on failed jobs once monitoring lands. Credentials
(`RESTIC_PASSWORD`, `HOME_ASSISTANT_TOKEN`, `ROMM_DB_PASSWORD`, and later B2 keys) are
SOPS-encrypted Secrets. **`restic init` runs once** per repo before the first backup via
`runbooks/phase5/03-init-restic-nas-repo.sh`.

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
| Home Assistant | call its **REST API** `homeassistant.backup` (not raw sqlite3) | HA manages its own WAL |
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

Stack: **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager) + **Loki/Promtail**
for logs + **nut-exporter** for UPS metrics. Alerts route to **ntfy** (self-hosted)
for phone push.

### Alerts to define

| Alert | Trigger | Why it matters |
|---|---|---|
| NVMe usage > 80% | `/opt` (or any local mount) filling | single non-redundant disk; running out is disruptive |
| NFS mount lost | NAS mount unhealthy | Plex **and** Frigate both depend on it |
| Gluetun pod restart | VPN container restarted | tunnel likely dropped; kill switch engaged |
| UPS on battery | NUT input-power loss | power event; act before clean shutdown |
| Pod crash loop | repeated restarts, any namespace | catch failures early |
| Restic backup failed | CronJob job failure | a broken backup must not hide for weeks |

### ntfy and the node-down gap

ntfy is a tiny self-hosted pub/sub push service: Alertmanager POSTs to a topic, the
phone app subscribed to that topic gets a notification. Free, self-hosted, no
third-party dependency. Chosen over Pushover (paid, third-party), Discord (channel, not
real push), and email (slow, ignorable).

**Caveat — chicken-and-egg:** a self-hosted alerter can't notify you about *its own*
node going down. App-level alerts (disk, crashloops, VPN, backups) work fine because
the node is still up. For true node-down/total-failure, either accept the gap (a
single-node failure is self-evident fast — Plex stops working) or point **only** the
UPS/node-health alerts at the hosted `ntfy.sh` as an off-node fallback. Default:
self-host everything, accept the gap.

## UPS / NUT

NUT runs as a **host systemd service** (configured in
[Phase 0.5](./build-plan.md#phase-0--os-baseline-)), before k3s, so a clean shutdown
fires even if the cluster is degraded. The **nut-exporter** pod scrapes it into
Prometheus for the Grafana dashboard and the "UPS on battery" alert — so a power event
is visible even when the node rides it out and you weren't watching.

## Resource tuning

The [allocation table](./architecture.md#resource-allocation) values are conservative
starting points. After ~1 week of real data:

- In Grafana, compare actual CPU/memory per workload against its requests/limits.
- Raise requests where a pod is consistently throttled; lower limits where headroom is
  wasted. Each change is a one-line manifest edit Flux reconciles.
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

> **Camera switch isolation (Catalyst 3850)** was previously listed here as a deferred
> TODO. It is now a **Phase 1 blocker** — see [build-plan.md → 1.1b](./build-plan.md#phase-1--networking-isolation-).
> No camera is connected until the host nftables rules *and* switch protected ports are
> both in place and verified.

Accepted constraints (not gaps): no staging environment (changes go to the one
cluster — mitigated by btrfs snapshots + `flux suspend`); cert renewal depends on the
external DNS provider's API (90-day certs make a brief outage non-fatal); no k3s etcd
snapshots — the entire cluster state lives in git, and a full re-bootstrap from
scratch takes ~30 min; the only out-of-git state is the `sops-age` key, which is
backed up to a password manager.
