# homelab

Managed with **k3s + Flux CD**; secrets encrypted in-repo with **SOPS + age**.

> **Status: active build.** Phases 0-4 and the initial Phase 5 backup/observability
> stack are largely implemented and live-validated. The bulk-storage RAID enclosure
> was moved intact from Morpheus to the SAS HBA in `minis` on 2026-08-10; the array,
> filesystems, reboot assembly, and dependent workloads passed cutover validation.
> Morpheus was retired the same day and remains powered off as a cold spare. The
> approved numbered UDM firewall policy is still pending deployment and validation;
> its matrix describes the intended end state, not current enforcement.

## Stack at a glance

- **Platform:** Ubuntu 24.04 LTS · k3s · Flux CD · MetalLB · ingress-nginx · cert-manager
- **Access:** LAN + Tailnet only (nothing public) · `*.worm.run` via router wildcard DNS
- **Current workload manifests:** Plex (Quick Sync), Frigate (Coral),
  Radarr/Sonarr/Prowlarr/SABnzbd/qBittorrent behind Mullvad/Gluetun, Seerr, RomM,
  Home Assistant, Mosquitto, Z-Wave JS UI, and Zigbee2MQTT
- **Backups:** nightly direct-array Restic plus an independent weekly Backblaze B2 copy;
  required-export contract version 1 passed fresh local and B2 backup/restore drills
  on 2026-08-16. **Cluster app state only** — bulk-array content (including personal
  pictures) and the workstations are not backed up; see the draft policy in
  [docs/backups.md](./docs/backups.md)
- **Next:** deploy and validate the approved UDM firewall policy, pin k3s, close the
  media resource-tuning gate, validate the mdcheck cap, then tune Frigate. Runtime
  images are already immutable and covered by the image-policy/Renovate workflow.

## Layout

```
AGENTS.md          project context, decisions, conventions (start here)
docs/              architecture, build plan, migration runbooks, operations
runbooks/          phases 0–5 plus attended bastion/DR/migration workflows
host/              canonical MINIS, Catalyst, and OpenBSD bastion config
clusters/minis/    Flux entrypoint (flux-system + Kustomizations)
infrastructure/    controllers, cluster configs, Phase 5 backups/monitoring
apps/              media, frigate, home-assistant, mqtt, zigbee2mqtt
```

## Docs

| Doc | Contents |
|---|---|
| [AGENTS.md](./AGENTS.md) | Orientation, decision log, repo conventions, working agreements |
| [docs/architecture.md](./docs/architecture.md) | Hardware, storage, networking, access, resource strategy |
| [docs/build-plan.md](./docs/build-plan.md) | Phased build (0→5), validation gate, YAML patterns |
| [docs/version-management.md](./docs/version-management.md) | Immutable image policy, Renovate workflow, update/rollback procedure, and pending k3s pin |
| [docs/migration-runbook.md](./docs/migration-runbook.md) | Migrating Plex + *arr data, cutover, rollback |
| [docs/direct-attached-storage-migration.md](./docs/direct-attached-storage-migration.md) | Moving the RAID enclosure from Morpheus to direct attachment on MINIS |
| [docs/operations.md](./docs/operations.md) | Backups, monitoring/alerting, tuning, follow-ups |
| [docs/backups.md](./docs/backups.md) | **Draft** whole-estate backup policy — proposed design, not implemented |

## Conventions (short version)

Declarative platform and workload changes after the initial bootstrap are git commits.
Home Assistant is the explicit exception: its integrations, automations, HACS, and
other UI-managed configuration live on the backed-up Home Assistant PVC. Every
workload sets resource requests/limits and a priority class. App state goes on local
NVMe via the `local-nvme` StorageClass; bulk data is on the mdadm/LVM/ext4 array
directly attached to the MINIS SAS HBA. Secrets are
SOPS-encrypted before commit — the repo is private. Full detail in [AGENTS.md](./AGENTS.md).
