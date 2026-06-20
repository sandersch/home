# Homelab — Project Context

This file orients an AI coding session (Claude Code) and any human working in this
repo. Read it first. Detailed design and procedures live in [`docs/`](./docs).

## What this is

A single-node, container-first homelab on a MINISFORUM MS-01, managed by GitOps.
The goal is to reproduce (and extend) an existing ArgoCD + microk8s setup on fresh
hardware, using **k3s + Flux CD**, while keeping operational complexity low and
reliability high. Some one-time manual bootstrapping is acceptable; everything
after the bootstrap is a git commit.

The repo is operated alongside a Claude Code session running on a laptop, connected
over SSH and/or the Tailnet. See [Working agreements](#working-agreements-for-an-ai-session).

## Current status

**Pre-build.** This repo currently contains planning docs only. Nothing has been
deployed. The immediate task is to scaffold the repo and begin executing the
[build plan](./docs/build-plan.md), starting at Phase 0 (OS baseline).

## Hardware (summary)

MINISFORUM MS-01 · Intel Core i5-12600H (6 P-cores + 4 E-cores, 12 threads) ·
32 GB DDR5 · 1 TB NVMe · 2×2.5GbE (in use) · 2×10Gb SFP+ (unused) · Intel Coral
USB accelerator · UPS in rack. Quick Sync iGPU drives Plex transcoding. Media and
camera recordings live on a remote NAS over NFS. Full detail in
[architecture.md](./docs/architecture.md).

## Decision log

These are settled. Do not re-litigate without explicit instruction; if you think a
decision is wrong, raise it rather than silently diverging.

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
| Backups | **Restic** → NAS nightly + **Backblaze B2** weekly | Cheap, deduplicating, offsite copy |
| Alerting | **ntfy** (self-hosted) → phone push | Free, self-hosted, simple |
| Camera segment addressing | **`192.168.105.0/24`, host at `.1`**, per-camera NTP target `192.168.105.1` | Frozen once cameras are provisioned: the subnet, the host's NIC2 address, and the NTP server are typed into each camera's web UI (1.3) and baked into DHCP/Frigate, so renumbering means hand-touching every camera. No collision with LAN (`10.137.20/24`), pods/services (`10.42`/`10.43`), or Tailscale (`100.64/10`). Treat as permanent |

Deferred / revisit later (see [operations.md](./docs/operations.md#follow-ups)):
a possible second node, Tailscale Funnel for Plex, Immich.

## Repository structure

Standard Flux layout. `flux bootstrap` creates `clusters/minis/flux-system`.

```
.
├── CLAUDE.md                  # this file
├── docs/                      # planning + runbooks (not applied to cluster)
│   ├── architecture.md
│   ├── build-plan.md
│   ├── migration-runbook.md
│   └── operations.md
├── host/                      # canonical host config for the manual phases (0–1);
│   └── minis/                 #   one subdirectory per host (minis = the MS-01)
│       ├── README.md          #   files under etc/ mirror on-disk paths. NOT cluster-
│       ├── etc/               #   applied — this is the host below k3s. Source of truth;
│       └── fstab.d/           #   build-plan.md points here instead of inlining config
├── clusters/
│   └── minis/
│       ├── flux-system/       # created by `flux bootstrap`; do not hand-edit
│       ├── infrastructure.yaml# Kustomization → ../../infrastructure
│       └── apps.yaml          # Kustomization → ../../apps (dependsOn infra)
├── infrastructure/
│   ├── controllers/           # HelmRepos + HelmReleases: metallb, ingress-nginx,
│   │                          #   cert-manager, tailscale-operator, topolvm
│   ├── configs/               # ClusterIssuer, MetalLB pool, StorageClass,
│   │                          #   PriorityClasses, cluster-wide config
│   └── monitoring/            # kube-prometheus-stack, Loki, ntfy, nut-exporter
└── apps/
    ├── media/                 # namespace + Plex, download pod (gluetun+
    │                          #   sabnzbd+*arr), overseerr, romm
    ├── frigate/
    └── home-assistant/
```

## Conventions

- **One namespace per concern**: `media`, `frigate`, `home-assistant`, plus the
  infra namespaces (`flux-system`, `metallb-system`, `cert-manager`,
  `ingress-nginx`, `tailscale`, `monitoring`). Cross-pod calls use cluster DNS,
  e.g. `http://gluetun.media.svc.cluster.local:7878` (Overseerr → Radarr). The
  download stack (SABnzbd + *arr) shares the Gluetun pod's network namespace and
  talks over `localhost:<port>`.
- **Every workload pod sets resource `requests`/`limits` and a `priorityClassName`.**
  Tiers and exact values are in
  [architecture.md → Resource allocation](./docs/architecture.md#resource-allocation).
  Frigate and Home Assistant are `homelab-critical` (non-evictable); most else is
  `homelab-standard`; backups are best-effort.
- **App state uses the `local-nvme` StorageClass** via a per-app PV + PVC pointing
  at `/opt/<app>/...`. The PV is a `hostPath` volume with `type: DirectoryOrCreate`,
  so the kubelet creates the directory on first mount and adding storage for a new
  app is a pure git change (no SSH). **Scratch data uses the `topolvm-scratch`
  StorageClass** instead — a PVC alone dynamically provisions an enforced,
  resizable ext4 LV from VG free space (no PV manifest). Pattern in
  [build-plan.md → Storage pattern](./docs/build-plan.md#storage-pattern).
- **Secrets are SOPS-encrypted before commit**, always. The repo is private, but
  treat encryption as mandatory anyway — private is a safety net, not a license to
  commit plaintext, and the repo may be selectively shared later.
  `data`/`stringData` fields are encrypted via `.sops.yaml`. Encrypt with
  `sops --encrypt --in-place path/to/secret.yaml`. The only secret that lives
  outside git is the `sops-age` key itself (in-cluster + backed up to a password
  manager).
- **Latency-sensitive state on local NVMe; bulk data on NAS.** Plex metadata,
  Frigate DB, app configs → `/opt` (btrfs). Media, ROMs, recordings, Immich
  originals → NAS NFS. Scratch (Frigate cache, SABnzbd staging) →
  `topolvm-scratch` PVCs (ext4 LVs, enforced, throwaway).
- **Helm charts** are referenced via `HelmRepository` + `HelmRelease` CRDs (Flux),
  not installed imperatively, except during the documented Phase 2 bootstrap.

## Working agreements for an AI session

This cluster runs real services (Plex, security cameras, home automation). Treat it
as production.

- **Default to read-only.** Keep a read-only kubeconfig context as default; switch
  to an admin context explicitly only when a change is intended.
- **Suspend Flux before significant manifest surgery**: `flux suspend kustomization
  apps` so Flux doesn't fight in-progress edits; resume when done.
- **Snapshot before risky local changes**: take a btrfs snapshot of `/opt` before
  any session that touches stateful app config or does an upgrade.
- **Never write plaintext secrets to the repo.** If you generate a Secret manifest,
  SOPS-encrypt it before it is committed. Never print private keys or tokens into
  files under version control.
- **Don't run destructive commands speculatively.** `kubectl delete`,
  `helm uninstall`, `flux delete`, and anything touching PVs/PVCs or `/opt` must be
  deliberate and confirmed — a wrong delete can drop Plex metadata or Frigate state.
- **Validate, don't assume, hardware passthrough.** Confirm `/dev/dri` and the Coral
  device inside a test pod before declaring Plex/Frigate done (see the validation
  gate in the build plan).
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

# Switch kubeconfig context (LAN vs Tailnet, read-only vs admin)
kubectl config get-contexts
kubectl config use-context <name>

# Confirm VPN egress IP from inside the download pod
kubectl exec -n media deploy/gluetun -c sabnzbd -- sh -c 'wget -qO- ifconfig.me'
```

## Where to go next

1. [docs/build-plan.md](./docs/build-plan.md) — phased path, bare metal → running.
2. [docs/architecture.md](./docs/architecture.md) — the design and its rationale.
3. [docs/migration-runbook.md](./docs/migration-runbook.md) — moving Plex + *arr data.
4. [docs/operations.md](./docs/operations.md) — backups, monitoring, tuning, follow-ups.
