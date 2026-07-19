# Architecture

Design decisions and their rationale. For the step-by-step build, see
[build-plan.md](./build-plan.md). Settled decisions are summarized in the
[root AGENTS.md decision log](../AGENTS.md#decision-log).

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
| Network | 2×2.5GbE ports in use, negotiating at 1Gb today · 2×10Gb SFP+ present, unused for now |
| Power | UPS already in rack |
| Wi-Fi | Disabled unless needed |

Media library and Frigate recordings live on a **remote NAS with spinning disks**,
reached over NFS. The local NVMe is reserved for the OS, container images, Frigate
cache/temp, and low-latency application state.

The 10Gb SFP+ backplane exists but is **not** a current requirement. The host NICs are
2.5GbE-capable, but the current router/switch ports they attach to are 1GbE, so the
server and camera links negotiate at 1Gb today.

## Filesystem and volume layout

**LVM under everything**: one PV/VG spanning the NVMe (after the ESP; `/boot` is on the
`root` LV, not its own partition), manual
LVs for the OS filesystems, and the VG's free space handed to **TopoLVM** for
dynamically provisioned scratch volumes. An earlier revision of this design rejected
LVM as overlapping btrfs' volume management; that call was reversed — the partition
count and up-front sizing bets it forced (two dedicated scratch partitions plus a
guess at headroom placement) outweighed the abstraction overlap. With one VG, every
filesystem is growable online and leftover space is generic headroom rather than a
bet on which mount will need it. ZFS remains rejected (wants dedicated ARC RAM, no
native Ubuntu kernel integration, value is in multi-disk integrity we don't have).
ext4 stays the default (boring, reliable); btrfs only where snapshots/compression
earn their keep.

```
ESP (/boot/efi) 1 GB vfat       (outside LVM; /boot itself is on vg0/root)
vg0/root   100 GB  ext4  /      OS (incl. /boot)
vg0/var    100 GB  ext4  /var   container images + k3s state (image layers dominate)
vg0/opt    100 GB  btrfs /opt   ALL low-latency app state (snapshots + zstd)
vg0 free  ~650 GB  —     —      TopoLVM device-class: scratch PVCs + lvextend headroom
```

Rationale for the splits:

- **`/var` 100 GB** — container image layers for ~10 apps plus k3s/etcd state and
  logs. A starting point, not a ceiling: every manual LV grows online from the VG free
  pool, so we start each at a conservative 100 GB and `lvextend` only what real usage
  demands rather than betting the sizing up front. Periodic `crictl rmi --prune` keeps
  image churn in check.
- **`/opt` btrfs, manual LV — deliberately *not* TopoLVM-managed** — the one
  filesystem that benefits from snapshots (roll back before app upgrades) and zstd
  compression (the SQLite-heavy small-write workloads of Plex/Frigate/*arr/HA).
  This is where all valuable app state lives. TopoLVM's snapshot story (thin pools
  + CSI VolumeSnapshots) would be a downgrade: thin-pool exhaustion errors every LV
  in the pool, and per-app LVs lose compression and the one-command subvolume
  rollback. SABnzbd *config* lives here; the incomplete staging dir does not.
- **Scratch via TopoLVM (thick LVs, no thin pool)** — high-write, fully regenerable,
  snapshot-worthless data: Frigate's cache/buffer and SABnzbd's incomplete staging
  dir (large NZBs downloaded and unpacked in place), each an ext4 LV provisioned
  from VG free space by a PVC. The LV boundary is a kernel-enforced per-PVC cap —
  a runaway download queue cannot eat the headroom Frigate's cache needs during a
  NAS outage — and `allowVolumeExpansion` makes growing one an online PVC edit,
  i.e. a git commit. Kept off btrfs so the churn doesn't pollute `/opt` snapshot
  bookkeeping. Frigate's DB and SABnzbd's config stay on `/opt` (snapshotted).
- **~650 GB VG free space** — generic headroom: new scratch PVCs (e.g. a future
  Immich cache) or `lvextend` of any manual LV, no repartitioning. Starting the OS LVs
  small (100 GB each) is what leaves the pool this large. Set TopoLVM's
  `spare-gb` so dynamic PVCs can't squeeze out planned growth of the manual LVs.

## Networking

Dual-NIC design separating trusted traffic from cameras.

| Interface | Role | Address | Notes |
|---|---|---|---|
| NIC1 (`lan0`) | Primary LAN | `10.137.20.5/24` | Internet, NAS NFS, host SSH, k3s API |
| NIC2 (`cam0`) | Camera segment | `192.168.105.1/24` | Isolated; serves DHCP; Frigate only |

> The 2.5GbE ports (Intel I226-V) are pinned to `lan0`/`cam0` by MAC, so their raw
> kernel names don't matter. The unused 10G SFP+ ports enumerate as
> `enpXs0f0np0`/`enpXs0f1np1` and WiFi as `wlpXYs0` — placeholder names, since the exact
> PCI-enumeration index can shift if hardware is rearranged.

> Ingress is **not** on NIC1's `.5`. MetalLB announces a separate LoadBalancer IP
> (`10.137.20.10`) for service/ingress traffic via L2 ARP; keeping it off the node IP
> avoids a conflict with the address the kernel already owns. Reserve `.10` (and the
> node's `.5`) outside the router's DHCP range.

**Camera isolation (nftables, host-level).** The `camera_isolation` table hooks two
chains, both `policy accept` with explicit drops. The **forward** chain handles
*routed* traffic: `iifname "cam0" drop` blocks camera-initiated connections
(camera→internet, camera→LAN) and `oifname "cam0" drop` blocks forwarded LAN→camera
traffic (access to camera web UIs goes via the host, e.g. SSH port-forward). The
**input** chain handles traffic the camera sends *to the host itself* — which the
forward chain never sees, since locally-delivered packets hit the input hook. Without
it, host services bound to `0.0.0.0` (k3s `:6443`, kubelet `:10250`, SSH, and every
`hostNetwork` pod: Frigate, Home Assistant) would be reachable from a compromised
camera on `192.168.105.1`. Plex uses normal pod networking with Service/Ingress/Tailnet
access unless a future requirement justifies otherwise. The input chain allows only
`ct state established,related` (RTSP replies — Frigate initiates, so this is the
return path), DHCP (`udp dport 67`), NTP (`udp dport 123`), and IPv4 ICMP echo-request
for ping diagnostics, then drops the rest from `cam0`. The drops are logged
(rate-limited `cam-drop-*` prefixes) so a compromised camera's blocked traffic is
visible in the journal rather than silently discarded. The segment is IPv4-only (IPv6
disabled on `cam0`); any ICMPv6 falls to the drop. `policy accept` is intentional —
`policy drop` would break k3s pod networking, because every hook chain (these and
k3s's own iptables-nft chains) is evaluated independently for each packet, and a drop
verdict in any chain is final even when another chain accepts. Frigate runs with
`hostNetwork: true`, so its RTSP connections to cameras originate from the host's NIC2
address (`192.168.105.1`) and never pass through the forward chain. Validate before
cameras go live: from the camera segment, ping `8.8.8.8` and a LAN host
(`10.137.20.5`) must both fail, and `nc -vz 192.168.105.1 22` (a port that is actually
listening) must fail — ICMP echo-request to the host still succeeds.

**Intra-segment isolation (switch).** The host rules only see traffic that reaches the node; camera-to-camera traffic stays on the L2 switch. The Catalyst 3850 carrying the segment is configured with **protected ports** so a compromised camera cannot pivot to its peers. This is a prerequisite for going live, not a later hardening step — no camera is connected until both the host rules and switch isolation are in place.

**Camera DHCP (dnsmasq, host-level).** `dnsmasq` runs as a host systemd service bound
to NIC2, serving DHCP on `192.168.105.0/24`. It lives with networking (Phase 1) rather
than in the cluster: it serves a physical segment and should be independent of cluster
state. (An earlier sketch put it in a pod; host-level is the cleaner, more reliable
choice for DHCP on a physical NIC.) It binds with `bind-dynamic` (so it survives a boot
with no carrier on the optional NIC2) and runs DHCP-only via `port=0` — no resolver,
which would otherwise be an outbound beacon path for a compromised camera. Cameras get
stable leases so Frigate can target them at known addresses.

**Internal DNS (router).** A single wildcard record `*.worm.run → 10.137.20.10` points
all service hostnames at the **MetalLB ingress IP** (`10.137.20.10`, distinct from the
node's own `10.137.20.5`); ingress-nginx routes by `Host` header. Adding a
service needs no new DNS record, just an Ingress manifest. Confirm the router supports
*true wildcard* records (most capable routers do; some consumer ones only allow
explicit hostnames) — test with a throwaway hostname before depending on it.

**NAS throughput.** Validate the NAS link with `iperf3` before deploying Plex/Frigate —
both depend on it. The *design target* is 2.5GbE end-to-end (~2.3 Gbps), but `minis`
and the NAS both attach directly to the UDM Pro's **1 GbE RJ45 LAN ports** (Ports 3 and
2 respectively — no intermediate switch in this path), so the realistic interim
expectation is **~940 Mbps**; 2.5GbE can't be realized until both hosts move off those
1G RJ45 ports onto faster links (e.g. SFP+). Don't chase the 2.3 Gbps figure until then — see
[build-plan.md → 1.4](./build-plan.md#phase-1--networking-isolation-).

## Storage architecture

The rule: **latency-sensitive state on local NVMe; bulk/regenerable data on NAS.**

| App | Data | Location | Filesystem |
|---|---|---|---|
| Plex | Metadata/DB (~100 GB) | `/opt/plex` | btrfs (NVMe) |
| Plex | Media library | NAS | NFS |
| Frigate | DB + config | `/opt/frigate` | btrfs (NVMe) |
| Frigate | Cache / temp | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| Frigate | Recordings/clips | NAS | NFS |
| Radarr/Sonarr/Prowlarr | Config + SQLite | `/opt/<app>` | btrfs (NVMe) |
| SABnzbd | Config + DB | `/opt/sabnzbd` | btrfs (NVMe) |
| SABnzbd | Incomplete (staging) | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| SABnzbd | Complete (handoff) | NAS, under `/mnt/media` (same export as the library — one filesystem, so *arr imports are hardlink/atomic-move) | NFS |
| qBittorrent | Config + DB | `/opt/qbittorrent` | btrfs (NVMe) |
| qBittorrent | Incomplete (staging) | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| qBittorrent | Complete (handoff) | NAS, under `/mnt/media/downloads/torrents` (same export as the library — one filesystem, so *arr imports are hardlink/atomic-move) | NFS |
| Seerr | Request DB | `/opt/seerr` | btrfs (NVMe) |
| RomM | DB/metadata | `/opt/romm` | btrfs (NVMe) |
| RomM | ROM library | NAS | NFS |
| Home Assistant | Recorder DB + state | `/opt/home-assistant` | btrfs (NVMe) |
| Z-Wave JS UI | Settings, security keys, logs + controller backups | `/opt/zwave-js-ui` | btrfs (NVMe) |
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
before any init container could create it.)

Scratch data uses the **`topolvm-scratch` StorageClass** (`provisioner: topolvm.io`,
`WaitForFirstConsumer`, `allowVolumeExpansion: true`, non-default) instead: a PVC
alone provisions a thick ext4 LV from `vg0` free space — no PV manifest, and unlike
hostPath the requested size is kernel-enforced. TopoLVM runs as a HelmRelease in
`infrastructure/controllers/` (lvmd embedded in the node DaemonSet, not a host
systemd unit, so it stays in git); it sits only in the provisioning path — mounted
LVs keep working if the controller is down. Concrete YAML for both patterns is in
[build-plan.md → Storage pattern](./build-plan.md#storage-pattern).

## Cluster platform

- **k3s**, single node, installed with `--disable traefik --disable servicelb`
  (we bring our own ingress and LB).
- **MetalLB** provides a stable LoadBalancer IP (`10.137.20.10`, a dedicated address it
  owns — *not* the node's own `10.137.20.5`) so the router wildcard target never
  changes. Service traffic and host SSH / the k3s API thus live on separate IPs.
- **ingress-nginx** terminates HTTP(S) and routes by hostname.
- **cert-manager** issues real certificates via **Let's Encrypt DNS-01** (HTTP-01 is
  impossible since nothing is publicly reachable). The solver uses **Google Cloud DNS**
  (`cloudDNS.project` + `serviceAccountSecretRef`), so this needs a GCP service-account
  key with DNS Administrator on the zone's project, stored as an encrypted Secret; the
  dependency is accepted. Renewals every ~90 days, so a brief provider outage isn't fatal.

The k3s API (`:6443`) is reachable on the Tailnet so the laptop/AI coding session can hold a
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
qBittorrent, Prowlarr, Radarr, and Sonarr all run as containers in that same pod**,
sharing Gluetun's network namespace — so *every* WAN egress (SABnzbd/qBittorrent
downloads, Prowlarr's indexer queries, the *arrs' metadata fetches and trigger
traffic) leaves through the tunnel, not the node's WAN. Because they share one netns
they reach each other over `localhost:<port>` (SABnzbd 8080, qBittorrent 8090,
Prowlarr 9696, Radarr 7878, Sonarr 8989 — no conflicts), and the pod's Service
publishes those same UI/API ports to the LAN and Tailnet so the web UIs and Seerr/Plex
callers can reach them. Gluetun's **kill switch**
(on by default) drops WAN traffic if the tunnel fails — leave it on. Two firewall
settings are both required for reachability: `FIREWALL_OUTBOUND_SUBNETS` (cluster
pod/Service CIDRs plus the LAN subnet) permits connections the pod *initiates*
toward those ranges (cluster DNS, NAS, Plex), and `FIREWALL_INPUT_PORTS=8080,8090,9696,7878,8989`
permits connections initiated *into* the pod (browsers, Seerr → the *arrs) —
the outbound setting alone does not allow inbound. These non-secret Gluetun settings
live in a plaintext ConfigMap; the SOPS Secret only carries the WireGuard address and
private key. Two accepted tradeoffs:
(1) **coupled lifecycle** — any image bump or manifest change to any of the six
containers recreates the whole pod and re-establishes the tunnel; acceptable for a
download stack that is down together anyway when the tunnel is. (2) **DNS does not
ride the tunnel** — the app containers keep the kubelet-written cluster DNS (that's
what resolves Service names), so their *public* hostname lookups egress via CoreDNS
over the node's WAN; only the lookups leak, the traffic itself is tunneled.

| App | Behind VPN? | Why |
|---|---|---|
| SABnzbd | **Yes** | Download traffic (container in the Gluetun pod) |
| qBittorrent | **Yes** | Torrent traffic (container in the Gluetun pod; no exposed peer port on Mullvad) |
| Prowlarr | **Yes** | Indexer queries (container in the Gluetun pod) |
| Radarr / Sonarr | **Yes** | Metadata fetches + download triggers (containers in the Gluetun pod) |
| Seerr | No | Talks only to Plex + *arr internally |
| Plex | No | Needs its own direct/relayed remote path |
| Frigate | No | Camera traffic, fully internal |
| Home Assistant | No | Needs LAN access for device discovery |
| RomM | No | Fully internal |

Validate that egress from inside the pod equals the VPN exit IP **before**
configuring indexers or download clients (see the quick-reference command in
AGENTS.md).

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
| **Z-Wave JS UI** | 0.1 / 1 | 256Mi / 1Gi | critical · non-evictable |
| Plex | 1 / 6 | 1Gi / 4Gi | standard · burstable |
| Gluetun + SABnzbd (download pod) | 0.5 / 2 | 512Mi / 1Gi | standard |
| qBittorrent (container in the download pod) | 0.5 / 2 | 512Mi / 1Gi | standard |
| *arr (each, containers in the download pod) | 0.25 / 1 | 256Mi / 512Mi | standard |
| Seerr / RomM | 0.1 / 0.5 | 128Mi / 512Mi | standard |
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
