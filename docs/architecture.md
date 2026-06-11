# Architecture

Design decisions and their rationale. For the step-by-step build, see
[build-plan.md](./build-plan.md). Settled decisions are summarized in the
[root CLAUDE.md decision log](../CLAUDE.md#decision-log).

## Design priorities

In priority order, these guide every tradeoff below:

1. Low operational complexity.
2. Reliability over maximum performance.
3. Efficient Plex transcoding via Quick Sync.
4. Responsive Frigate decoding/storage.
5. Expansion headroom without premature optimization.

## Hardware

| Component | Detail |
|---|---|
| Chassis | MINISFORUM MS-01 |
| CPU | Intel Core i5-12600H — 6 P-cores + 4 E-cores, 12 threads |
| RAM | 32 GB DDR5 |
| Storage | 1 TB local NVMe (OS + containers + app state + Frigate cache) |
| GPU | Intel iGPU (Quick Sync) for Plex hardware transcoding |
| Accelerator | Intel Coral USB (Frigate object detection) — owned, working |
| Network | 2×2.5GbE (in use) · 2×10Gb SFP+ (present, unused for now) |
| Power | UPS already in rack |
| Wi-Fi | Disabled unless needed |

Media library and Frigate recordings live on a **remote NAS with spinning disks**,
reached over NFS. The local NVMe is reserved for the OS, container images, Frigate
cache/temp, and low-latency application state.

The 10Gb SFP+ backplane exists but is **not** a current requirement; 2.5GbE is
sufficient for active workloads. Don't build for 10G yet — that's premature
optimization per priority 5.

## Filesystem and partitioning

Raw GPT partitions, **no LVM**. LVM was considered (familiar, growable) but adds an
abstraction layer that partly overlaps btrfs' own volume management; for this mix the
friction isn't worth it. ZFS was rejected (wants dedicated ARC RAM, no native Ubuntu
kernel integration, value is in multi-disk integrity we don't have). The chosen
layout pairs ext4 (boring, reliable) with btrfs only where snapshots/compression earn
their keep.

```
/              100 GB   ext4    OS
/var           150 GB   ext4    container images + k3s state (image layers dominate)
/opt           250 GB   btrfs   ALL low-latency app state (snapshots + zstd)
/frigate/cache  50 GB   ext4    Frigate temp/buffer only (high-write, throwaway)
~250 GB         —       —       unallocated (future partitions, no repartition needed)
```

Rationale for the splits:

- **`/var` 150 GB** — container image layers for ~10 apps plus k3s/etcd state and
  logs. Generous so it's never a worry; 120 GB would also be fine with periodic
  `crictl rmi --prune`.
- **`/opt` btrfs** — the one filesystem that benefits from snapshots (roll back
  before app upgrades) and zstd compression (the SQLite-heavy small-write workloads
  of Plex/Frigate/*arr/HA). This is where all valuable app state lives.
- **`/frigate/cache` ext4, separate** — pure throughput, no snapshots wanted, kept
  off btrfs so high-write churn doesn't interact with snapshot bookkeeping. Frigate's
  DB lives on `/opt` (snapshotted), only its cache/buffer lives here.
- **~250 GB unallocated** — headroom to add a partition later (e.g. if Immich's local
  cache grows) without repartitioning.

## Networking

Dual-NIC design separating trusted traffic from cameras.

| Interface | Role | Address (example) | Notes |
|---|---|---|---|
| NIC1 (`enp1s0`) | Primary LAN | `192.168.1.10/24` | Internet, NAS NFS, DNS, ingress |
| NIC2 (`enp2s0`) | Camera segment | `10.10.0.1/24` | Isolated; serves DHCP; Frigate only |

> Confirm actual interface names on the box (`ip link`) before writing Netplan.

**Camera isolation (nftables, host-level).** The `camera_isolation` table uses `policy accept` with two explicit drop rules: `iifname "enp2s0" drop` blocks camera-initiated connections (camera→internet, camera→LAN), and `oifname "enp2s0" drop` blocks forwarded LAN→camera traffic (access to camera web UIs must go via the host, e.g. SSH port-forward). `policy accept` is intentional — `policy drop` would break k3s pod networking, because every hook chain (this one and k3s's own iptables-nft chains) is evaluated independently for each packet, and a drop verdict in any chain is final even when another chain accepts. Frigate runs with `hostNetwork: true`, so its RTSP connections to cameras originate from the host's NIC2 address (`10.10.0.1`) and never pass through the forward chain. Validate before cameras go live: ping `8.8.8.8` and a LAN host from the camera segment — both must fail.

**Camera DHCP (dnsmasq, host-level).** `dnsmasq` runs as a host systemd service bound
to NIC2, serving DHCP on `10.10.0.0/24`. It lives with networking (Phase 1) rather
than in the cluster: it serves a physical segment and should be independent of cluster
state. (An earlier sketch put it in a pod; host-level is the cleaner, more reliable
choice for DHCP on a physical NIC.) Cameras get stable leases so Frigate can target
them at known addresses.

**Internal DNS (router).** A single wildcard record `*.worm.run → 192.168.1.10` points
all service hostnames at the node; ingress-nginx routes by `Host` header. Adding a
service needs no new DNS record, just an Ingress manifest. Confirm the router supports
*true wildcard* records (most capable routers do; some consumer ones only allow
explicit hostnames) — test with a throwaway hostname before depending on it.

**NAS throughput.** Validate 2.5GbE to the NAS with `iperf3` (~2.3 Gbps expected)
before deploying Plex/Frigate — both depend on it.

## Storage architecture

The rule: **latency-sensitive state on local NVMe; bulk/regenerable data on NAS.**

| App | Data | Location | Filesystem |
|---|---|---|---|
| Plex | Metadata/DB (~100 GB) | `/opt/plex` | btrfs (NVMe) |
| Plex | Media library | NAS | NFS |
| Frigate | DB + config | `/opt/frigate` | btrfs (NVMe) |
| Frigate | Cache / temp | `/frigate/cache` | ext4 (NVMe) |
| Frigate | Recordings/clips | NAS | NFS |
| Radarr/Sonarr/Prowlarr | Config + SQLite | `/opt/<app>` | btrfs (NVMe) |
| SABnzbd | Incomplete (staging) | `/opt/sabnzbd` | btrfs (NVMe) |
| SABnzbd | Complete (handoff) | NAS | NFS |
| Overseerr | Request DB | `/opt/overseerr` | btrfs (NVMe) |
| RomM | DB/metadata | `/opt/romm` | btrfs (NVMe) |
| RomM | ROM library | NAS | NFS |
| Home Assistant | Recorder DB + state | `/opt/home-assistant` | btrfs (NVMe) |
| Immich (later) | Thumbnails + ML cache | `/opt/immich` | btrfs (NVMe) |
| Immich (later) | Originals | NAS | NFS |

NFS mounts use `nofail,_netdev,x-systemd.automount` so a NAS hiccup at boot doesn't
block k3s from starting.

### Local-storage provisioning pattern

App state is provisioned with a `no-provisioner` **`local-nvme` StorageClass**
(`WaitForFirstConsumer`, `reclaimPolicy: Retain`) plus a per-app `PersistentVolume`
that uses a **`hostPath` volume with `type: DirectoryOrCreate`** pointing at
`/opt/<app>/...`, with `nodeAffinity` pinned to `minis`, bound by a
`PersistentVolumeClaim`. `DirectoryOrCreate` makes the kubelet create the directory
on first mount — meaning **adding storage for a new app is a pure git change**, no
SSH. (A `local:` PV can't do this: its path must already exist or the mount fails
before any init container could create it.) Concrete YAML is in
[build-plan.md → Storage pattern](./build-plan.md#storage-pattern).

## Cluster platform

- **k3s**, single node, installed with `--disable traefik --disable servicelb`
  (we bring our own ingress and LB).
- **MetalLB** provides a stable LoadBalancer IP (the node's static IP) so the router
  wildcard target never changes.
- **ingress-nginx** terminates HTTP(S) and routes by hostname.
- **cert-manager** issues real certificates via **Let's Encrypt DNS-01** (HTTP-01 is
  impossible since nothing is publicly reachable). This needs the public domain's DNS
  provider API credentials; the dependency is accepted. Renewals every ~90 days, so a
  brief provider outage isn't fatal.

The k3s API (`:6443`) is reachable on the Tailnet so the laptop/Claude Code can hold a
kubeconfig context pointing at the node's Tailscale IP.

## Access model

**LAN + Tailnet only. Nothing is exposed to the public internet.**

- The **Tailscale operator** runs in-cluster; services are reachable on the LAN and,
  remotely, to devices on the Tailnet. **Split DNS** is configured in the Tailscale
  admin console so `*.worm.run` resolves correctly over the tunnel — remote access
  looks identical to local.
- For a small household this is strictly better than public Plex: put both people's
  personal devices on the Tailnet once and get full remote streaming with zero inbound
  exposure.
- **Tradeoff:** sharing with people who won't install Tailscale, or casting to dumb
  client devices in places you don't control (a hotel/relative's TV/Roku), doesn't
  work cleanly — those clients can't join the Tailnet. If that need arises, expose
  **only Plex** via **Tailscale Funnel** (Tailscale terminates the public connection;
  no router port-forward, no exposing the Plex process directly). That's a cleaner
  path than re-enabling Plex's native remote access, and it's a later add — locking
  down something already public is the harder direction. Tracked as a follow-up.

## Secrets architecture

**SOPS + age**, decrypted natively by Flux at apply time.

- Encrypted secret files live in the (private) repo; only ciphertext is committed. A
  `.sops.yaml` encrypts `data`/`stringData` fields with the cluster's age public key.
  The repo being private is defense-in-depth, not the primary control — committing
  only ciphertext is what keeps secrets safe even if the repo is later shared.
- The age **private key** is the one secret outside git: stored in-cluster as the
  `sops-age` Secret and backed up to a password manager. Protect this key; rotating it
  means re-encrypting every secret.
- This was chosen over Sealed Secrets (extra controller, painful rotation) and
  External Secrets + Vault (overkill for one node, bootstrap chicken-and-egg). SOPS is
  ~10 min of one-time setup; thereafter encrypting a new secret is one command.

## VPN for downloads

**Mullvad over Gluetun**, WireGuard. Mullvad was chosen over Proton/Nord for its
demonstrated privacy posture (no-email signup, flat pricing, drives destroyed under a
2023 search warrant) — but **Gluetun abstracts the provider**, so switching to Proton
is just a few env-var changes and a pod restart. Gigabit internet is not a constraint:
WireGuard retains ~80%+ of line rate, and download traffic is capped by indexer/server
speed well below that anyway.

**Topology.** One **Gluetun gateway pod** in the `media` namespace. **SABnzbd,
Prowlarr, Radarr, and Sonarr all run as containers in that same pod**, sharing
Gluetun's network namespace — so *every* WAN egress (SABnzbd's downloads, Prowlarr's
indexer queries, the *arrs' metadata fetches and trigger traffic) leaves through the
tunnel, not the node's WAN. Because they share one netns they reach each other over
`localhost:<port>` (SABnzbd 8080, Prowlarr 9696, Radarr 7878, Sonarr 8989 — no
conflicts), and the pod's Service publishes those same ports to the LAN and Tailnet
so the web UIs and Overseerr/Plex callers can reach them. Gluetun's **kill switch**
(on by default) drops WAN traffic if the tunnel fails — leave it on. Two firewall
settings are both required for reachability: `FIREWALL_OUTBOUND_SUBNETS` (cluster
pod/Service CIDRs plus the LAN subnet) permits connections the pod *initiates*
toward those ranges (cluster DNS, NAS, Plex), and `FIREWALL_INPUT_PORTS=8080,9696,7878,8989`
permits connections initiated *into* the pod (browsers, Overseerr → the *arrs) —
the outbound setting alone does not allow inbound. Two accepted tradeoffs:
(1) **coupled lifecycle** — any image bump or manifest change to any of the five
containers recreates the whole pod and re-establishes the tunnel; acceptable for a
download stack that is down together anyway when the tunnel is. (2) **DNS does not
ride the tunnel** — the app containers keep the kubelet-written cluster DNS (that's
what resolves Service names), so their *public* hostname lookups egress via CoreDNS
over the node's WAN; only the lookups leak, the traffic itself is tunneled.

| App | Behind VPN? | Why |
|---|---|---|
| SABnzbd | **Yes** | Download traffic (container in the Gluetun pod) |
| Prowlarr | **Yes** | Indexer queries (container in the Gluetun pod) |
| Radarr / Sonarr | **Yes** | Metadata fetches + download triggers (containers in the Gluetun pod) |
| Overseerr | No | Talks only to Plex + *arr internally |
| Plex | No | Needs its own direct/relayed remote path |
| Frigate | No | Camera traffic, fully internal |
| Home Assistant | No | Needs LAN access for device discovery |
| RomM | No | Fully internal |

Validate that egress from inside the pod equals the VPN exit IP **before**
configuring indexers or download clients (see the quick-reference command in
CLAUDE.md).

## Resource allocation

One 12-thread CPU and 32 GB RAM are shared by workloads with very different urgency.
The strategy: **CPU `requests` are guarantees, `limits` are ceilings**, and the gap
between them is where contention is managed. Two `PriorityClass`es ensure that under
genuine pressure the *right* things survive.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: homelab-critical }
value: 1000000
preemptionPolicy: PreemptLowerPriority
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: homelab-standard }
value: 1000
```

(Backups run at default/best-effort, i.e. no class or a low one, so they're evicted
first.)

| Workload | CPU req / limit | Mem req / limit | Tier |
|---|---|---|---|
| **Frigate** | 2 / 4 | 2Gi / 4Gi | critical · non-evictable |
| **Home Assistant** | 0.5 / 2 | 512Mi / 2Gi | critical · non-evictable |
| Plex | 1 / 6 | 1Gi / 4Gi | standard · burstable |
| Gluetun + SABnzbd (download pod) | 0.5 / 2 | 512Mi / 1Gi | standard |
| *arr (each, containers in the download pod) | 0.25 / 1 | 256Mi / 512Mi | standard |
| Overseerr / RomM | 0.1 / 0.5 | 128Mi / 512Mi | standard |
| Monitoring stack | 0.5 / 2 | 1Gi / 3Gi | standard |
| Restic CronJob | 0.25 / 1 | 256Mi / 1Gi | low · best-effort |

Sum of requests ≈ **5.7 cores / ~8.5 Gi** — comfortably under capacity, leaving room
to burst. ~6 GB RAM is reserved as headroom for the OS, k3s, and spikes.

Key reasoning:

- **Frigate is protected.** A high guaranteed request plus critical, non-evictable
  priority means a Plex transcode storm can't starve object detection — the one
  workload with real-time consequences (missed camera events).
- **Plex bursts but yields.** Its low request (1 core) with a high limit (6 cores)
  lets it grab spare capacity for a transcode storm, but it gives that capacity back
  the instant Frigate needs its guaranteed share. **Quick Sync offloads the actual
  transcode to the iGPU**, so this CPU budget is mostly Plex's bookkeeping, not the
  video work — which is why the burst is safe.
- **Memory is the harder constraint than CPU.** CPU contention only slows things;
  memory contention OOM-kills. Limits intentionally overcommit, so the reserved
  headroom plus critical-tier protection are what keep important pods alive if several
  apps spike at once. This is exactly why **Immich is deferred** — its ML container is
  the one big memory consumer that could tip the balance, so it's added deliberately
  later with a coordinated import.
- **P/E cores:** the Linux CFS scheduler spreads work across performance and
  efficiency cores fine. Pinning Frigate to P-cores via the static CPU-manager policy
  is an escalation path *only if* detection latency proves problematic under load —
  not a preemptive step.

**Treat these numbers as conservative starting points.** Once the monitoring stack is
live, watch real usage for ~1 week and tune; each change is a one-line manifest edit
Flux reconciles.
