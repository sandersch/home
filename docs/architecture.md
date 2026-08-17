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
| CPU | Intel Core i5-12600H — 4 P-cores + 8 E-cores, 16 threads |
| RAM | 32 GB DDR5 |
| Storage | 1 TB local NVMe plus 60 TB raw / 44 TB RAID6-usable direct-attached enclosure (~40 TiB usable) |
| GPU | Intel iGPU (Quick Sync) for Plex hardware transcoding |
| Accelerator | Intel Coral USB (Frigate object detection) — owned, working |
| Network | 2×2.5GbE ports in use, negotiating at 1Gb today · 2×10Gb SFP+ present, unused for now |
| Power | UPS already in rack |
| Wi-Fi | Disabled unless needed |

Media, ROMs, Frigate recordings, and the on-site Restic repository live on a
**direct-attached mdadm RAID6/LVM/ext4 array** connected through the LSI 9207-8e.
The local NVMe is reserved for the OS, container images, scratch volumes, and
low-latency application state.

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

The external enclosure is a separate storage stack and is never allocated to
TopoLVM:

```
md3       RAID6  13 active × 4 TB + 2 hot spares  ~40 TiB usable
hoardvg   LVM2   PV /dev/md3
medialv   ext4   /mnt/media    25 TiB
games     ext4   /mnt/games   250 GiB
frigate   ext4   /mnt/frigate 100 GiB
backuplv  ext4   /mnt/backups   1 TiB
```

`maverick-vdisk0-rootlv` remains present in `hoardvg` as historical data but is not
mounted or consumed by the current platform. The array identity is pinned to
`/dev/md3` by UUID in the canonical mdadm configuration.

Rationale for the splits:

- **`/var` 100 GB** — container image layers for ~10 apps plus k3s SQLite datastore state and
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
  snapshot-worthless data: Frigate's cache/buffer, SABnzbd and qBittorrent incomplete
  staging, and Plex transcodes, each on an ext4 LV provisioned
  from VG free space by a PVC. The LV boundary is a kernel-enforced per-PVC cap —
  a runaway download queue cannot eat the headroom Frigate's cache needs during a
  enclosure outage — and `allowVolumeExpansion` makes growing one an online PVC edit,
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
| NIC1 (`lan0`) | Primary LAN | `10.137.20.5/24` | Internet, host SSH, k3s API |
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
for ping diagnostics, then drops the rest from `cam0`. Expected DNS retries to TCP or
UDP port 53 are silently dropped; other drops are logged (rate-limited `cam-drop-*`
prefixes) so unusual blocked traffic remains visible in the journal. The segment is
IPv4-only (IPv6 disabled on `cam0`); any ICMPv6 falls to the drop. `policy accept` is intentional —
`policy drop` would break k3s pod networking, because every hook chain (these and
k3s's own iptables-nft chains) is evaluated independently for each packet, and a drop
verdict in any chain is final even when another chain accepts. Frigate runs with
`hostNetwork: true`, so its RTSP connections to cameras originate from the host's NIC2
address (`192.168.105.1`) and never pass through the forward chain. Validate before
cameras go live: from the camera segment, ping `8.8.8.8` and a LAN host
(`10.137.20.5`) must both fail, and `nc -vz 192.168.105.1 22` (a port that is actually
listening) must fail — ICMP echo-request to the host still succeeds.

**Frigate host-listener isolation (nftables, host-level).** Frigate's host networking
also exposes its listeners on the host's non-camera interfaces. The separate
`frigate_access` input chain permits the unauthenticated TCP/5000 UI/API only over
loopback and drops it from LAN, Tailnet, camera, and pod-network interfaces.
Authenticated TCP/8971 remains reachable through the Kubernetes Service and Ingress.

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

Bulk-storage traffic no longer traverses the LAN. Validate the direct storage path
with the Phase 1.4 read/write probe and watch md/SAS/filesystem metrics under load.
Nothing currently exports the bulk filesystems over NFS. A deferred NFS service on
`minis` may expose `/mnt/media` and `/mnt/games` when a remote consumer needs them;
`/mnt/frigate` remains local to the colocated Frigate workload, and `/mnt/backups`
stays unexported unless a concrete use appears.

## Storage architecture

The rule: **latency-sensitive state on local NVMe; bulk data on the direct array.**

| App | Data | Location | Filesystem |
|---|---|---|---|
| Plex | Metadata/DB (~100 GB) | `/opt/plex` | btrfs (NVMe) |
| Plex | Media library | `/mnt/media` | direct mdadm/LVM/ext4 |
| Plex | Transcode workspace | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| Frigate | DB + config | `/opt/frigate` | btrfs (NVMe) |
| Frigate | Cache / temp | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| Frigate | Recordings/clips | `/mnt/frigate` | direct mdadm/LVM/ext4 |
| Radarr/Sonarr/Prowlarr | Config + SQLite | `/opt/<app>` | btrfs (NVMe) |
| SABnzbd | Config + DB | `/opt/sabnzbd` | btrfs (NVMe) |
| SABnzbd | Incomplete (staging) | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| SABnzbd | Complete (handoff) | `/mnt/media` (same filesystem as the library, so *arr imports are hardlink/atomic-move) | direct mdadm/LVM/ext4 |
| qBittorrent | Config + DB | `/opt/qbittorrent` | btrfs (NVMe) |
| qBittorrent | Incomplete (staging) | `topolvm-scratch` PVC | ext4 LV (NVMe) |
| qBittorrent | Complete (handoff) | `/mnt/media/downloads/torrents` (same filesystem as the library, so *arr imports are hardlink/atomic-move) | direct mdadm/LVM/ext4 |
| Seerr | Request DB | `/opt/seerr` | btrfs (NVMe) |
| RomM | DB/metadata | `/opt/romm` | btrfs (NVMe) |
| RomM | ROM library | `/mnt/games` | direct mdadm/LVM/ext4 |
| Home Assistant | Recorder DB + state | `/opt/home-assistant` | btrfs (NVMe) |
| Z-Wave JS UI | Settings, security keys, logs + controller backups | `/opt/zwave-js-ui` | btrfs (NVMe) |
| Mosquitto | Retained MQTT data | `/opt/mosquitto/data` | btrfs (NVMe) |
| Zigbee2MQTT | Device DB + coordinator backup + network config | `/opt/zigbee2mqtt` | btrfs (NVMe) |
| Immich (later) | Thumbnails + ML cache | `/opt/immich` | btrfs (NVMe) |
| Immich (later) | Originals | direct bulk array | mdadm/LVM/ext4 |

The four UUID-based ext4 mounts use `nofail,x-systemd.automount` plus bounded device
and mount timeouts. This lets the host boot if the enclosure is absent while exact
device/UUID validation prevents an unmounted hostPath directory from masquerading as
bulk storage.

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

Tailnet access is implemented by the in-cluster Tailscale operator; the host does not
need its own Tailscale daemon. Its Connector advertises only the MetalLB ingress IP
(`10.137.20.10/32`) and the router DNS IP (`10.137.20.1/32`). The node address
(`10.137.20.5`), SSH, and the k3s API (`:6443`) are not part of those advertised
routes; administrative kubeconfig access currently targets the node on the LAN.

## Access model

**LAN + Tailnet only. Nothing is exposed to the public internet.**

- The **Tailscale operator** runs in-cluster. Its subnet-router Connector carries the
  two deliberately narrow `/32` routes above, so ingress-backed services are reachable
  on the LAN and remotely from Tailnet devices without advertising the full server
  VLAN. **Split DNS** is configured in the Tailscale admin console so `*.worm.run`
  resolves through `10.137.20.1` to the MetalLB ingress IP — application access looks
  identical remotely and locally.
- For a small household this is strictly better than public Plex: put both people's
  personal devices on the Tailnet once and get full remote streaming with zero inbound
  exposure.
- **Tradeoff:** sharing with people who won't install Tailscale, or casting to dumb
  client devices in places you don't control (a hotel/relative's TV/Roku), doesn't
  work cleanly — those clients can't join the Tailnet. If that need arises, expose
  **only Plex** via **Tailscale Funnel** as one candidate (Tailscale terminates the
  public connection, so no router port-forward is required). Funnel remains beta and
  has non-configurable bandwidth limits, so sustained Plex throughput and target-client
  behavior must be tested before adopting it. It remains a later add—locking down
  something already public is the harder direction. Tracked as a follow-up.

## Secrets architecture

**SOPS + age**, decrypted natively by Flux at apply time.

- Encrypted secret files live in the (private) repo; only ciphertext is committed. A
  `.sops.yaml` encrypts `data`/`stringData` fields with the cluster's age public key.
  The repo being private is defense-in-depth, not the primary control — committing
  only ciphertext is what keeps secrets safe even if the repo is later shared.
- As much reproducible configuration as practical lives in git. Secrets that Kubernetes
  needs declaratively are normally committed as SOPS ciphertext. Selected secrets are
  also saved in the external password manager as an independent recovery source; the
  age **private key** and values redacted from canonical host or network-device
  configuration deliberately remain outside git and must be restored from there. The
  age key is also stored in-cluster as the `sops-age` Secret; protect it because rotating
  it means re-encrypting every committed SOPS secret.
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
toward those ranges (cluster DNS and Plex), and `FIREWALL_INPUT_PORTS=8080,8090,9696,7878,8989`
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
| Mosquitto | No | Cluster-internal MQTT broker |
| Z-Wave JS UI | No | Talks to the LAN-attached controller and Home Assistant internally |
| Zigbee2MQTT | No | Talks to the LAN-attached coordinator and Mosquitto internally |
| RomM | No | Fully internal |

Validate that egress from inside the pod equals the VPN exit IP **before**
configuring indexers or download clients (see the quick-reference command in
AGENTS.md).

## Resource allocation

One 16-thread CPU and 32 GB RAM are shared by workloads with very different urgency.
The strategy: CPU `requests` reserve scheduler capacity and influence CPU shares under
contention, while `limits` are ceilings. `PriorityClass` influences scheduling and
preemption so critical workloads are favored when capacity is scarce; it does not make
a pod immune to eviction or failure.

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

(Backups use the explicit `homelab-low` class. Their Kubernetes QoS class is Burstable
rather than BestEffort because requests and limits are set but differ. The lower
priority makes them preferred preemption candidates relative to critical services.
During node-pressure eviction, the kubelet separately considers whether usage exceeds
requests, then pod priority, then usage relative to requests.)

| Workload | CPU req / limit | Mem req / limit | Priority class / notes |
|---|---|---|---|
| **Frigate** | 2 / 4 | 2Gi / 4Gi | `homelab-critical` |
| **Home Assistant** | 0.5 / 2 | 512Mi / 2Gi | `homelab-critical` |
| **Z-Wave JS UI** | 0.1 / 1 | 256Mi / 1Gi | `homelab-critical` |
| **Mosquitto** | 50m / 250m | 64Mi / 256Mi | `homelab-critical` |
| **Zigbee2MQTT** | 0.1 / 1 | 256Mi / 1Gi | `homelab-critical` |
| **Zigbee2MQTT MQTT exporter** | 25m / 100m | 64Mi / 128Mi | `homelab-critical` |
| Plex | 1 / 6 | 1536Mi / 4Gi | `homelab-standard`; high CPU burst ceiling |
| Gluetun | 25m / 2 | 96Mi / 1Gi | `homelab-standard`; download pod |
| SABnzbd | 125m / 2 | 256Mi / 1Gi | `homelab-standard`; download pod |
| qBittorrent | 25m / 2 | 64Mi / 1Gi | `homelab-standard`; download pod |
| Prowlarr | 50m / 1 | 256Mi / 512Mi | `homelab-standard`; download pod |
| Radarr | 150m / 1 | 384Mi / 768Mi | `homelab-standard`; download pod |
| Sonarr | 100m / 1 | 512Mi / 768Mi | `homelab-standard`; download pod |
| Seerr | 50m / 1 | 512Mi / 768Mi | `homelab-standard` |
| RomM | 100m / 500m | 384Mi / 768Mi | `homelab-standard` |
| MariaDB (RomM sidecar) | 100m / 500m | 256Mi / 768Mi | `homelab-standard` |
| Valkey (RomM sidecar) | 50m / 250m | 64Mi / 256Mi | `homelab-standard` |
| Monitoring stack | 0.5 / 2 | 1Gi / 3Gi | `homelab-standard` |
| Restic CronJob | 0.25 / 1 | 256Mi / 1Gi | `homelab-low` |

These request/limit pairs produce Burstable QoS. Priority class and QoS are separate:
priority governs scheduling/preemption preference. During node-pressure eviction, the
kubelet considers whether usage exceeds requests, then priority, then usage relative to
requests; the Burstable label itself does not provide eviction immunity.

The media rows reserve exactly **1.775 cores / 4320Mi**. Their limits intentionally
leave room to burst while host RAM remains available for the OS, k3s, and spikes.

Key reasoning:

- **Frigate is favored under contention.** Its comparatively large CPU request gives
  it more CPU share under contention, and its high priority makes the scheduler prefer
  it over standard workloads when placement or preemption is necessary. These controls
  reduce starvation and displacement risk; they do not make Frigate non-evictable or
  provide a real-time CPU guarantee.
- **Plex can burst into spare CPU.** Its low request (1 core) with a high limit (6
  cores) lets it use idle capacity for a transcode storm; under contention, CPU request
  weights favor Frigate's larger reservation rather than guaranteeing either workload
  an exclusive core set. **Quick Sync offloads the actual transcode to the iGPU**, so
  this CPU budget is mostly Plex's bookkeeping rather than the video work.
- **Memory is the harder constraint than CPU.** CPU contention usually slows things;
  memory contention can trigger OOM kills or node-pressure eviction. Limits
  intentionally overcommit, so conservative sizing and reserved host headroom reduce
  risk; priority influences which pending pods can schedule and which lower-priority
  pods may be preempted, but it cannot guarantee survival during memory pressure. This
  is why **Immich is deferred** — its ML container is the one big memory consumer that
  could tip the balance, so it is added deliberately later with a coordinated import.
- **P/E cores:** the Linux scheduler currently places work across performance and
  efficiency cores. If measured detection latency eventually justifies exclusive CPU
  placement, Frigate would first need Guaranteed QoS with equal integer CPU request and
  limit, plus kubelet static CPU Manager and host-level CPU-set/topology controls that
  make the intended P-cores eligible. Static CPU Manager alone allocates exclusive CPUs
  but does not specifically select P-cores.

**Treat these numbers as conservative starting points.** Once the monitoring stack is
live, watch real usage for ~1 week and tune; each change is a one-line manifest edit
Flux reconciles.
