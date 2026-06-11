# homelab

Managed with **k3s + Flux CD**; secrets encrypted in-repo with **SOPS + age**.

> **Status: pre-build.** This repo currently holds planning docs only — see
> [`docs/build-plan.md`](./docs/build-plan.md) for the path from bare metal to running.

## Stack at a glance

- **Platform:** Ubuntu 26.04 · k3s · Flux CD · MetalLB · ingress-nginx · cert-manager
- **Access:** LAN + Tailnet only (nothing public) · `*.worm.run` via router wildcard DNS
- **Workloads:** Plex (Quick Sync), Frigate (Coral), Radarr/Sonarr/Prowlarr/SABnzbd
  (behind a Mullvad/Gluetun VPN), Overseerr, RomM, Home Assistant
- **Observability:** Prometheus · Grafana · Alertmanager · Loki · ntfy push alerts
- **Backups:** Restic → NAS nightly + Backblaze B2 weekly

## Layout

```
CLAUDE.md          project context, decisions, conventions (start here)
docs/              architecture, build plan, migration runbook, operations
clusters/minis/    Flux entrypoint (flux-system + Kustomizations)
infrastructure/    controllers, cluster configs, monitoring
apps/              media, frigate, home-assistant
```

## Docs

| Doc | Contents |
|---|---|
| [CLAUDE.md](./CLAUDE.md) | Orientation, decision log, repo conventions, working agreements |
| [docs/architecture.md](./docs/architecture.md) | Hardware, storage, networking, access, resource strategy |
| [docs/build-plan.md](./docs/build-plan.md) | Phased build (0→5), validation gate, YAML patterns |
| [docs/migration-runbook.md](./docs/migration-runbook.md) | Migrating Plex + *arr data, cutover, rollback |
| [docs/operations.md](./docs/operations.md) | Backups, monitoring/alerting, tuning, follow-ups |

## Conventions (short version)

Everything after the initial bootstrap is a git commit. Every workload sets resource
requests/limits and a priority class. App state goes on local NVMe via the `local-nvme`
StorageClass; bulk data lives on the NAS. Secrets are SOPS-encrypted before commit —
the repo is private. Full detail in [CLAUDE.md](./CLAUDE.md).
