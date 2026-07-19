# homelab

Managed with **k3s + Flux CD**; secrets encrypted in-repo with **SOPS + age**.

> **Status: active build.** Most of Phases 0-4 and the backup-first slice of Phase 5
> are implemented in repo: host config, runbooks, Flux bootstrap output,
> infrastructure controllers/configs, and the core media/Frigate app manifests are present. See
> [`docs/build-plan.md`](./docs/build-plan.md#implementation-status) for what remains.

## Stack at a glance

- **Platform:** Ubuntu 24.04 LTS · k3s · Flux CD · MetalLB · ingress-nginx · cert-manager
- **Access:** LAN + Tailnet only (nothing public) · `*.worm.run` via router wildcard DNS
- **Current workload manifests:** Plex (Quick Sync), Frigate (Coral),
  Radarr/Sonarr/Prowlarr/SABnzbd/qBittorrent behind Mullvad/Gluetun, Seerr, RomM,
  Home Assistant, and Mosquitto
- **Backups:** nightly NAS Restic plus an independent weekly Backblaze B2 copy;
  manual backup/restore validation has passed for both repositories
- **Still planned:** Prometheus/Grafana/Alertmanager, Loki with Grafana Alloy,
  ntfy push alerts, and deferred apps

## Layout

```
AGENTS.md          project context, decisions, conventions (start here)
docs/              architecture, build plan, migration runbook, operations
runbooks/          executable host/app phase runbooks
host/minis/        canonical host-level config copied by the runbooks
clusters/minis/    Flux entrypoint (flux-system + Kustomizations)
infrastructure/    controllers, cluster configs, Phase 5 backups/monitoring
apps/              media, frigate, home-assistant, mqtt
```

## Docs

| Doc | Contents |
|---|---|
| [AGENTS.md](./AGENTS.md) | Orientation, decision log, repo conventions, working agreements |
| [docs/architecture.md](./docs/architecture.md) | Hardware, storage, networking, access, resource strategy |
| [docs/build-plan.md](./docs/build-plan.md) | Phased build (0→5), validation gate, YAML patterns |
| [docs/migration-runbook.md](./docs/migration-runbook.md) | Migrating Plex + *arr data, cutover, rollback |
| [docs/operations.md](./docs/operations.md) | Backups, monitoring/alerting, tuning, follow-ups |

## Conventions (short version)

Declarative platform and workload changes after the initial bootstrap are git commits.
Home Assistant is the explicit exception: its integrations, automations, HACS, and
other UI-managed configuration live on the backed-up Home Assistant PVC. Every
workload sets resource requests/limits and a priority class. App state goes on local
NVMe via the `local-nvme` StorageClass; bulk data lives on the NAS. Secrets are
SOPS-encrypted before commit — the repo is private. Full detail in
[AGENTS.md](./AGENTS.md).
