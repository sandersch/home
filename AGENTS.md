# Homelab — Project Context

This file orients an AI coding session and any human working in this repo. Read it first. Detailed design and procedures live in [`docs/`](./docs).

## What this is

A single-node, container-first homelab on a MINISFORUM MS-01, managed by GitOps. The goal is to reproduce (and extend) an existing ArgoCD + microk8s setup on fresh hardware, using **k3s + Flux CD**, while keeping operational complexity low and reliability high. Some one-time manual bootstrapping is acceptable; declarative platform and workload changes after bootstrap are git commits. **Home Assistant is the explicit exception:** integrations, automations, HACS, and other UI-managed configuration live on its PVC and are protected by Home Assistant-aware Restic backups rather than represented individually in git.

The repo is operated alongside an AI coding session on a laptop, connected over SSH and/or the Tailnet. See [Working agreements](#working-agreements-for-an-ai-session).

## Current status

**Active build.** The repo is no longer planning-only: Phases 0-4 and the initial
Phase 5 backup/observability slice of the [build plan](./docs/build-plan.md) are
largely implemented. Host-level Phase 0-1 config lives under
[`host/minis/etc`](./host/minis/etc), executable runbooks cover Phases 0-5, Flux
bootstrap output exists under
[`clusters/minis/flux-system`](./clusters/minis/flux-system), infrastructure
controllers/configs are committed, and manifests exist for the media stack, Frigate,
Home Assistant, and MQTT. Core media, Frigate, and the Home Assistant MQTT/Frigate
integration have passed live validation. Z-Wave controller connectivity, device
inclusion, and the Home Assistant integration passed live validation on 2026-08-16.
The stricter Restic required-export contract
version 1 passed fresh local and B2 backup/restore drills on 2026-08-16, including all
eight required SQLite exports, a readable Home Assistant archive, and a successful
22-table RomM import/check. The initial observability stack (Prometheus, Grafana,
Alertmanager, blackbox probes, Flux metrics, rules, and external dead-man routing)
passed live validation on 2026-07-20, including a healthy Dead Man's Snitch check.
Hosted Pushover routing also passed live validation on 2026-07-20 with synthetic
warning/critical firing and resolved notifications delivered to the iPhone.
The nut-exporter workload, CP1500 Grafana dashboard, and critical on-battery rule
passed live validation on 2026-07-25, including the controlled physical mains-loss
drill and Pushover firing and recovery notifications. Zigbee2MQTT's critical HTTPS,
SLZB coordinator TCP, and MQTT-native bridge-health monitoring passed live validation
on 2026-08-16, including fresh retained health metrics, successful blackbox paths,
and healthy rules with no active Zigbee2MQTT alert. Zigbee device pairing, Home
Assistant MQTT discovery, and real automation use are also validated. The bulk-storage RAID enclosure
was migrated intact from Morpheus to the SAS HBA in `minis` on 2026-08-10. Array,
filesystem, reboot-assembly, and application cutover gates passed. Morpheus was
retired the same day and remains powered off, but network-connected, as a cold spare;
it is no longer required for normal network operation. Fresh local and B2 backups and
representative restores passed on 2026-08-10, and more than 48 hours of post-check
observation closed the migration gates on 2026-08-13. The first direct-array
consistency check completed cleanly but caused Frigate I/O stalls; deterministic
timers and a check-only `50000` KiB/s cap are installed, with attended cap validation
deferred to the next check window. The approved numbered UDM firewall policy remains
pending deployment and validation; its matrix is the intended end state, not current
enforcement. Resource tuning, Frigate tuning, and deferred apps follow the migration.
Runtime image and k3s pinning is planned in
[version-management.md](./docs/version-management.md) and remains to be implemented.
This remains a retrofit to a running production cluster, not a greenfield scaffold.

## Hardware (summary)

MINISFORUM MS-01 · Intel Core i5-12600H (4 P-cores + 8 E-cores, 16 threads) · 32 GB DDR5 · 1 TB NVMe · LSI 9207-8e SAS HBA · directly attached 60 TB raw / 44 TB RAID6-usable enclosure (~40 TiB usable) · 2×2.5GbE ports in use, negotiating at 1Gb today · 2×10Gb SFP+ (unused) · Intel Coral USB accelerator · UPS in rack. Quick Sync iGPU drives Plex transcoding. Full detail in [architecture.md](./docs/architecture.md) and the [direct-attached storage migration runbook](./docs/direct-attached-storage-migration.md).

## Decision log

These are settled. Do not re-litigate without explicit instruction; if you think a decision is wrong, raise it rather than silently diverging.

| Area | Decision | Why |
|---|---|---|
| Hypervisor | None (container-first, no Proxmox) | Low complexity; no VM-heavy workloads |
| Orchestrator | k3s, single node | Lightweight; GitOps-friendly |
| GitOps engine | **Flux CD** (not Argo) | Lower footprint, native SOPS, pure-git model |
| Repo host | GitHub, **private** | Limits stack/topology recon; safety margin against accidental plaintext-secret commits (public bots harvest in seconds). `flux bootstrap` handles private repos natively, so auth is no harder. SOPS still used as defense-in-depth |
| Secrets | **SOPS + age** | Flux-native decryption; no extra controller |
| Ingress | ingress-nginx + MetalLB | Stable LB IP; hostname routing |
| TLS | cert-manager + Let's Encrypt **DNS-01** | Real certs even for internal-only services |
| DNS (internal) | Router wildcard `*.worm.run` → MetalLB ingress IP (`10.137.20.10`, **not** the node's `.5`) | One record; ingress routes by host |
| DNS (cameras) | **dnsmasq** host service on NIC2 subnet | DHCP for the isolated camera segment |
| Remote access | **Tailnet + LAN only**, nothing public | Zero inbound exposure; Funnel for Plex later if needed |
| VPN (downloads) | **Mullvad** via **Gluetun**, WireGuard | Strong privacy track record; provider is swappable |
| Media server | **Plex** (lifetime pass) | Wife-acceptance + existing 100 GB metadata |
| Storage (local) | **LVM under everything**; btrfs on `/opt`; **TopoLVM** for scratch | One VG: manual LVs for OS + `/opt` (btrfs snapshots + zstd); TopoLVM provisions enforced, resizable ext4 scratch LVs (Frigate cache, SABnzbd staging) from VG free space. Supersedes the earlier "no LVM" call — partition count + up-front sizing anxiety outweighed the abstraction overlap |
| Backups | **Restic** → direct backup LV nightly + **Backblaze B2** weekly | Cheap, deduplicating, offsite copy |
| Alerting | **Dead Man's Snitch** for the off-node Watchdog; hosted **Pushover** for actionable alerts | The independent heartbeat covers total node/monitoring failure; Pushover delivers warning/critical phone notifications without adding a same-node workload or relay |
| Camera segment addressing | **`192.168.105.0/24`, host at `.1`**, authoritative per-camera `dnsmasq` reservations, NTP target `192.168.105.1` | Frozen once cameras are provisioned: the subnet and host/NTP address are reflected in host config and camera settings, while each camera's reserved DHCP address is baked into dnsmasq and Frigate. Renumbering therefore spans multiple systems. No collision with LAN (`10.137.20/24`), pods/services (`10.42`/`10.43`), or Tailscale (`100.64/10`). Treat as permanent |

Deferred / revisit later (see [operations.md](./docs/operations.md#follow-ups)):
a replacement NTP source for VLAN 10, migration of the SLZB-MRW10U from its current
Trusted/VLAN 30 placement to IoT/VLAN 60, selected NFS exports from `minis`, a
possible second node, Tailscale Funnel for Plex, and Immich.

## Repository structure

Standard Flux layout. `flux bootstrap` creates `clusters/minis/flux-system`.

```
.
├── AGENTS.md                  # this file
├── docs/                      # design, build plan, migration + operations docs
│   ├── architecture.md
│   ├── build-plan.md
│   ├── version-management.md
│   ├── network.md
│   ├── migration-runbook.md
│   ├── direct-attached-storage-migration.md
│   └── operations.md
├── runbooks/                  # executable host/app/backup runbooks for Phases 0–5
├── host/                      # canonical host/switch config for manual phases (0–1)
│   ├── catalyst/              #   Catalyst 3850 reference config
│   └── minis/                 #   MINIS host config mirrored to on-disk paths
│       ├── README.md          #   files under etc/ mirror on-disk paths. NOT cluster-
│       ├── etc/               #   applied — this is the host below k3s. Source of truth;
│       └── fstab.d/           #   build-plan.md points here instead of inlining config
├── clusters/
│   └── minis/
│       ├── flux-system/       # created by `flux bootstrap`; do not hand-edit
│       ├── kustomization.yaml # includes flux-system + ordered Flux Kustomizations
│       ├── infra-controllers.yaml # Kustomization → ../../infrastructure/controllers
│       ├── infra-configs.yaml     # Kustomization → ../../infrastructure/configs
│       ├── apps.yaml              # Kustomization → ../../apps (dependsOn configs)
│       ├── monitoring-base.yaml   # namespace + bootstrap monitoring secrets
│       ├── monitoring-controllers.yaml # kube-prometheus-stack / CRDs
│       ├── monitoring-configs.yaml # blackbox, probes, rules, routing
│       └── monitoring.yaml        # backup slice; legacy name retained for safe ownership
├── infrastructure/
│   ├── controllers/           # HelmRepos + HelmReleases for metallb,
│   │                          #   ingress-nginx, cert-manager, tailscale-operator,
│   │                          #   topolvm; Intel GPU plugin via upstream Kustomization
│   ├── configs/               # ClusterIssuer, MetalLB pool, StorageClass,
│   │                          #   PriorityClasses, cluster-wide config
│   └── monitoring/            # Phase 5 base, controllers, configs, and live backups
└── apps/
    ├── media/                 # namespace + Plex, download pod (gluetun+
    │                          #   sabnzbd+*arr), seerr, romm
    ├── frigate/
    ├── home-assistant/
    ├── mqtt/                  # internal Mosquitto broker for HA/Frigate/Zigbee
    └── zigbee2mqtt/
```

## Conventions

- **One namespace per concern**: `media`, `frigate`, `home-assistant`, `mqtt`, `zigbee2mqtt`, plus the infra namespaces (`flux-system`, `metallb-system`, `cert-manager`, `ingress-nginx`, `tailscale`, `monitoring`). Cross-pod calls use cluster DNS, e.g. `http://gluetun.media.svc.cluster.local:7878` (Seerr → Radarr). The download stack (SABnzbd + *arr) shares the Gluetun pod's network namespace and talks over `localhost:<port>`.
- **Every workload pod sets a `priorityClassName`, and every long-running workload container sets resource `requests`/`limits`.** Tiers and exact values are in [architecture.md → Resource allocation](./docs/architecture.md#resource-allocation). Frigate, Home Assistant, Z-Wave JS UI, Mosquitto, Zigbee2MQTT, and its MQTT exporter use the higher `homelab-critical` scheduling/preemption priority; this reduces their displacement risk but does not make them non-evictable. Most workloads use `homelab-standard`; backups use `homelab-low`. The current pods have Burstable QoS because their requests and limits differ.
- **App state uses the `local-nvme` StorageClass** via a per-app PV + PVC pointing at `/opt/<app>/...`. The PV is a `hostPath` volume with `type: DirectoryOrCreate`, so the kubelet creates the directory on first mount and adding storage for a new app is a pure git change (no SSH). **Scratch data uses the `topolvm-scratch` StorageClass** instead — a PVC alone dynamically provisions an enforced, resizable ext4 LV from VG free space (no PV manifest). Pattern in [build-plan.md → Storage pattern](./docs/build-plan.md#storage-pattern).
- **Put as much reproducible configuration as practical in git.** Kubernetes Secrets committed to the repo are SOPS-encrypted, always. The repo is private, but treat encryption as mandatory anyway — private is a safety net, not a license to commit plaintext, and the repo may be selectively shared later. `data`/`stringData` fields are encrypted via `.sops.yaml`; encrypt with `sops --encrypt --in-place path/to/secret.yaml`. Selected secrets are also saved in the external password manager as an independent recovery source. A smaller set deliberately remains outside git, including the `sops-age` private key and values redacted from canonical host/network configuration.
- **Latency-sensitive state on local NVMe; bulk data on the RAID enclosure.** Plex metadata, Frigate DB, app configs → `/opt` (btrfs). Media, ROMs, recordings, Immich originals → the mdadm/LVM/ext4 array directly attached to MINIS and exposed to pods through `/mnt/...` hostPaths. Scratch (Frigate cache, SABnzbd/qBittorrent incomplete data, Plex transcodes) → `topolvm-scratch` PVCs (ext4 LVs, enforced, throwaway).
- **Helm charts** are referenced via `HelmRepository` + `HelmRelease` CRDs (Flux), not installed imperatively. Phase 2 only installs k3s, creates `flux-system/sops-age`, and bootstraps Flux.

## Working agreements for an AI session

This cluster runs real services (Plex, security cameras, home automation). Treat it as production.

- **Default to read-only.** Keep a read-only kubeconfig context as default; switch to an admin context explicitly only when a change is intended.
- **Suspend Flux before significant manifest surgery**: `flux suspend kustomization apps` so Flux doesn't fight in-progress edits; resume when done.
- **Snapshot before risky local changes**: take a btrfs snapshot of `/opt` before any session that touches stateful app config or does an upgrade.
- **Never write plaintext secrets to the repo.** If you generate a Secret manifest, SOPS-encrypt it before it is committed. Never print private keys or tokens into files under version control.
- **Don't run destructive commands speculatively.** `kubectl delete`, `helm uninstall`, `flux delete`, and anything touching PVs/PVCs or `/opt` must be deliberate and confirmed — a wrong delete can drop Plex metadata or Frigate state.
- **Validate, don't assume, hardware passthrough.** Confirm `/dev/dri` and the Coral device inside a test pod before declaring Plex/Frigate done (see the validation gate in the build plan).
- **Prefer small, reversible commits** Flux can reconcile incrementally.

## Quick reference

```bash
# Force an immediate reconcile (tighter loop than the default interval)
flux reconcile kustomization apps --with-source

# Inspect GitOps state
flux get kustomizations
flux get helmreleases -A
flux logs --all-namespaces --follow

# Encrypt / edit a secret in place
sops --encrypt --in-place apps/media/<app>/secret.yaml
sops apps/media/<app>/secret.yaml          # decrypts into $EDITOR, re-encrypts on save

# Switch kubeconfig context (read-only vs admin)
kubectl config get-contexts
kubectl config use-context <name>

# Confirm VPN egress IP from inside the download pod
kubectl exec -n media deploy/gluetun -c sabnzbd -- sh -c 'wget -qO- ifconfig.me'
```

## Where to go next

1. [runbooks/disaster-recovery/README.md](./runbooks/disaster-recovery/README.md) — executable full-state rebuild and restore procedure.
2. [docs/version-management.md](./docs/version-management.md) — pending image/k3s pinning and ongoing update workflow.
3. [docs/direct-attached-storage-migration-worklog.md](./docs/direct-attached-storage-migration-worklog.md) — completed cutover evidence and post-migration follow-ups.
4. [docs/build-plan.md](./docs/build-plan.md) — phased path, current status, and completion gates.
5. [docs/architecture.md](./docs/architecture.md) — the design and its rationale.
6. [docs/migration-runbook.md](./docs/migration-runbook.md) — historical Plex + *arr migration path.
7. [docs/operations.md](./docs/operations.md) — backups, monitoring, tuning, follow-ups.
