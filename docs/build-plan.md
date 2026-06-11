# Build Plan

Bare metal → running stack, in dependency order. Phases 0–3 are strict: each depends
on the one before. Phase 3.5 (data migration) and Phase 4 (workloads) come only after
the **validation gate** passes. Design rationale is in
[architecture.md](./architecture.md).

Legend: 🔧 manual one-time · ⚙️ scripted · 📦 GitOps (git commit). ⚑ = must-validate.

---

## Phase 0 — OS baseline 🔧

**0.1 Install Ubuntu 26.04 LTS** (server, no GUI). During partitioning, create the
layout from [architecture.md](./architecture.md#filesystem-and-volume-layout):
ESP + `/boot` outside LVM, then a single LVM PV on the rest of the disk → VG `vg0`
with LVs `root` 100 GB ext4 (`/`) · `var` 150 GB ext4 (`/var`) · `opt` 250 GB btrfs
(`/opt`) · ~450 GB left **unallocated in the VG**. Do *not* pre-create filesystems
for Frigate cache or SABnzbd staging — those are TopoLVM-provisioned PVCs in
Phase 4, carved from the VG free space. Create a non-root sudo user; disable root
SSH login.

**0.2 Static networking (NIC1 first).** Set NIC1 to a static IP via Netplan before
anything else so the address can't shift mid-bootstrap. Confirm interface names with
`ip link` first.

```yaml
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    enp1s0:                      # NIC1 — verify name
      addresses: [172.17.1.5/24]
      routes: [{ to: default, via: 172.17.1.1 }]
      nameservers: { addresses: [172.17.1.1] }
      dhcp4: false
    enp2s0:                      # NIC2 — camera segment
      addresses: [192.168.104.1/24]
      dhcp4: false
```
`sudo netplan apply` and confirm both interfaces are up.

**0.3 System prep + hardware checks.**
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git vim nfs-common sqlite3 jq age iperf3 nftables dnsmasq nut
ls -la /dev/dri/            # expect card0 + renderD128 (Quick Sync)
lsmod | grep i915           # i915 driver loaded; if not, add to /etc/modules + reboot
getent group render         # note the render GID — needed for the Plex pod
```
If IOMMU is needed for passthrough, add `intel_iommu=on` to the kernel cmdline.

**0.4 NFS mounts.** Add to `/etc/fstab`, then `sudo mount -a` and verify:
```
nas.lan:/media    /mnt/media    nfs  defaults,nofail,_netdev,x-systemd.automount  0 0
nas.lan:/frigate  /mnt/frigate  nfs  defaults,nofail,_netdev,x-systemd.automount  0 0
nas.lan:/roms     /mnt/roms     nfs  defaults,nofail,_netdev,x-systemd.automount  0 0
```
`nofail` is essential — a NAS outage at boot must not block k3s.

**0.5 UPS via NUT.** Configure `/etc/nut/ups.conf` (driver usually `usbhid-ups`),
`/etc/nut/upsmon.conf` (shutdown threshold), `/etc/nut/upsd.conf`. Enable the service.
NUT is host-level and must start **before** k3s so the clean-shutdown hook works even
if the cluster is degraded.

**0.6 udev rules for the Coral.** Pin the device to a stable path:
```
# /etc/udev/rules.d/99-coral.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="1a6e", ATTRS{idProduct}=="089a", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9302", MODE="0666", GROUP="plugdev"
```
`sudo udevadm control --reload-rules && sudo udevadm trigger`. (The Coral enumerates
under two IDs — before and after its firmware loads.)

**0.7 Router DNS.** Add the wildcard record `*.worm.run → 172.17.1.10` (the MetalLB
ingress IP from Phase 2.2, **not** the node's own `172.17.1.5`). Test true
wildcard support with a throwaway hostname before relying on it.

---

## Phase 1 — networking isolation 🔧

**1.1 Camera isolation (nftables).** Drop all camera-initiated traffic. No LAN→camera
forwarding rule is needed: Frigate runs with `hostNetwork: true`, so its RTSP connections
originate from the host on NIC2 and never enter the forward chain.
```
# /etc/nftables.conf (excerpt)
table inet camera_isolation {
  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "enp2s0" drop    # cameras cannot initiate connections to anything
    oifname "enp2s0" drop    # LAN→camera forwarding blocked; access via host only
  }
}
```
Enable nftables. ⚑ From a device on the camera segment, confirm you **cannot** ping
`8.8.8.8` or any `172.17.1.0/24` host. LAN→camera access (e.g. camera web UI) must
go via the node itself (SSH port-forward or a temporary rule).

**1.2 Camera DHCP (dnsmasq).** Bind dnsmasq to NIC2 and serve `192.168.104.0/24`
(host-level service, not a pod). Give cameras stable leases so Frigate can target
known addresses.
```
# /etc/dnsmasq.d/cameras.conf (excerpt)
interface=enp2s0
bind-interfaces
dhcp-range=192.168.104.50,192.168.104.200,12h
# dhcp-host=AA:BB:CC:DD:EE:FF,192.168.104.51   # pin per-camera as needed
```
⚑ Confirm a camera receives a lease in range.

**1.3 NAS throughput.** ⚑ `iperf3 -c nas.lan` should show ~2.3 Gbps. Diagnose before
proceeding — Plex and Frigate both depend on it.

---

## Phase 2 — k3s + cluster infrastructure ⚙️

**2.1 Install k3s.**
```bash
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik --disable servicelb \
  --node-label kubernetes.io/hostname=minis
kubectl get nodes            # minis Ready
```

**2.2 MetalLB** — a stable LoadBalancer IP (`172.17.1.10`, distinct from the node's own
`172.17.1.5`) so the wildcard target is fixed. MetalLB must own its pool addresses, so
the pool cannot reuse the node IP the kernel already answers ARP for.
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: homelab-pool, namespace: metallb-system }
spec: { addresses: ["172.17.1.10/32"] }   # MetalLB owns this; ≠ node IP (.5), outside the DHCP range
```

**2.3 ingress-nginx** and **2.4 cert-manager** (Helm during bootstrap; convert to
HelmReleases under `infrastructure/controllers/` once Flux owns the cluster). Create a
**Let's Encrypt DNS-01 ClusterIssuer** with provider API credentials. SOPS does not
exist yet — create the Secret imperatively:
```bash
kubectl create secret generic cert-manager-dns-creds \
  --namespace cert-manager \
  --from-literal=api-token=<YOUR_TOKEN>
```
When converting cert-manager to a HelmRelease in Phase 3, write the Secret manifest,
`sops --encrypt --in-place` it, and commit — Flux will decrypt it at apply time.

**2.5 Tailscale operator** — LAN + Tailnet access; configure **split DNS** in the
Tailscale admin console so `*.worm.run` resolves over the tunnel. OAuth creds are
likewise created imperatively during bootstrap (SOPS does not exist yet):
```bash
kubectl create secret generic tailscale-oauth \
  --namespace tailscale \
  --from-literal=client-id=<ID> \
  --from-literal=client-secret=<SECRET>
```
Encrypt and commit the Secret manifest when converting to a HelmRelease in Phase 3.
Add a kubeconfig context on the laptop pointing at the node's Tailscale IP on `:6443`.

**2.6 PriorityClasses** — apply `homelab-critical` and `homelab-standard` (see
[architecture.md → Resource allocation](./architecture.md#resource-allocation)). These
are referenced by every workload, so they exist before apps.

---

## Phase 3 — Flux GitOps bootstrap ⚙️

**3.1 age keypair.**
```bash
age-keygen -o age.key         # copy the public key from stdout
# >>> back up age.key to the password manager NOW, before continuing <<<
```

**3.2 Store the private key in-cluster.**
```bash
kubectl create namespace flux-system
kubectl create secret generic sops-age \
  --namespace flux-system --from-file=age.agekey=age.key
```

**3.3 `.sops.yaml`** at the repo root:
```yaml
creation_rules:
  - path_regex: .*\.yaml
    encrypted_regex: ^(data|stringData)$
    age: <YOUR_AGE_PUBLIC_KEY>
```

**3.4 Bootstrap Flux** (creates the repo if absent — **private** by default — commits
Flux manifests, generates a deploy key, and starts reconciling). `--private` is the
default for `flux bootstrap github`; it's passed explicitly here so the intent is
obvious and a future edit can't silently flip it to public:
```bash
flux bootstrap github \
  --owner=sandersch --repository=home \
  --branch=main --path=clusters/minis --personal --private
```

**3.5 Commit the repo skeleton** — see [structure in CLAUDE.md](../CLAUDE.md#repository-structure):
`clusters/minis/{infrastructure.yaml,apps.yaml}`, `infrastructure/{controllers,configs,monitoring}`,
`apps/{media,frigate,home-assistant}`. `apps.yaml` should `dependsOn` the
infrastructure Kustomization. Include the **TopoLVM HelmRelease** in
`infrastructure/controllers/` (lvmd embedded in the node DaemonSet, device-class →
`vg0`, a `spare-gb` reserve) and the `topolvm-scratch` StorageClass in
`infrastructure/configs/` — Phase 4's scratch PVCs need them, and the `dependsOn`
ordering guarantees they exist first.

**3.6 Enable SOPS decryption** on the Flux Kustomizations:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: apps, namespace: flux-system }
spec:
  decryption:
    provider: sops
    secretRef: { name: sops-age }
  # ...path, sourceRef, dependsOn: [{ name: infrastructure }]
```
From here: write a Secret, `sops --encrypt --in-place secret.yaml`, commit — Flux
decrypts at apply time.

---

## ✅ Validation gate

Do **not** start Phase 3.5/4 until all of these are green:

- [ ] `kubectl get nodes` → `minis Ready`
- [ ] ingress-nginx + cert-manager pods Running; ClusterIssuer Ready
- [ ] `flux get kustomizations` → all Reconciled
- [ ] NFS mounts readable from a test pod
- [ ] `/dev/dri/renderD128` visible in a **privileged test pod** (Quick Sync path)
- [ ] Coral device visible in a privileged test pod
- [ ] Camera segment **cannot** reach internet or LAN (ping test)
- [ ] dnsmasq issues a camera lease in range
- [ ] Tailscale operator connected; `*.worm.run` resolves over the Tailnet
- [ ] SOPS decrypt works (reconcile a Kustomization containing an encrypted Secret)
- [ ] NUT active and reporting battery status

The device-passthrough items are far easier to debug now, without app complexity on
top.

---

## Phase 3.5 — app data migration 🔧

Run the **old stack and new stack in parallel**; cut over only after validation. Full
procedure (VACUUM, rsync flags, service-URL rewrites, cutover, rollback) is in
[migration-runbook.md](./migration-runbook.md).

- **Migrate:** Plex (metadata/DB), Radarr, Sonarr, Prowlarr.
- **Fresh installs, no migration:** Overseerr, RomM, Home Assistant, Frigate.
- Keep the old node intact and powered off (not wiped) for ~2 weeks post-cutover as a
  rollback path.

---

## Phase 4 — core workloads 📦

GitOps from here. Every pod sets resource requests/limits + a priorityClassName.

**4a — download pod: Gluetun + Mullvad + SABnzbd + *arr (deploy first).** One pod in
`media`: Gluetun plus SABnzbd, Prowlarr, Radarr, and Sonarr sharing its network
namespace. Intra-stack calls are `localhost:<port>`; everything outside the pod uses
the Gluetun Service. ⚑ Confirm the egress IP from inside the pod equals the VPN exit
IP before configuring indexers/downloads. Pattern below.

Then, in parallel once VPN is validated:

**4b — Plex** (standard/burstable). `/dev/dri` hostPath + the render group; media via
hostPath to `/mnt/media` (NFS mounted on host by fstab in Phase 0.4); `/opt/plex`
metadata. ⚑ Run a 1080p transcode and confirm GPU use with `intel_gpu_top` on the host.

**4c — Frigate** (critical/non-evictable). `hostNetwork: true` so RTSP connections to
cameras originate from the host (source IP `192.168.104.1`) without passing through the
forward chain — this is what makes the nftables camera isolation work. Coral USB
hostPath; DB on `/opt/frigate`, cache on a `topolvm-scratch` PVC (50 Gi ext4 LV),
recordings via hostPath to `/mnt/frigate`. ⚑ Verify
cameras remain unreachable from the internet.

**4d — remaining stack.** Overseerr (pointed at the *arrs via the Gluetun Service),
RomM, Home Assistant (`hostNetwork: true` for mDNS/Zeroconf discovery; plus any
Zigbee/Z-Wave USB stick via hostPath, like the Coral).

---

## Phase 5 — observability + expansion 📦

- **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager) via HelmRelease.
- **Loki + Promtail** for logs; **nut-exporter** for UPS metrics; **ntfy** pod for
  push alerts. Alert definitions and routing in
  [operations.md](./operations.md#monitoring--alerting).
- **Restic CronJob** for backups — stand this up early in Phase 5, *before* Immich
  adds a large new data surface. Design in
  [operations.md](./operations.md#backups).
- **Immich (later)** — coordinate the initial import during a quiet window and watch
  memory (its ML container is the one big consumer). Originals on NAS; thumbs/ML on
  `/opt/immich`; benefits from Quick Sync.
- **Tune resource limits** from real Grafana data after ~1 week.

---

## Storage pattern

Two reusable shapes: **app state** (snapshotted `/opt` subdirectory, static
hostPath PV + PVC) and **scratch** (TopoLVM-provisioned ext4 LV, PVC only).
Adding a new app = copy the right one, change names — no SSH; the app-state
directory is auto-created, the scratch LV is provisioned on schedule.

```yaml
# infrastructure/configs/storageclass.yaml — once, cluster-wide
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: local-nvme }
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
# Strips the default annotation from k3s's built-in local-path StorageClass.
# Without any default, PVCs that omit storageClassName stay Pending rather than
# silently landing on /var/lib/rancher/k3s/storage.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
---
# Scratch class — TopoLVM provisions a thick ext4 LV from vg0 free space per PVC.
# The LV is a kernel-enforced size cap (unlike hostPath); growing it is a PVC edit.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: topolvm-scratch }
provisioner: topolvm.io
parameters: { "csi.storage.k8s.io/fstype": "ext4" }
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
---
# apps/<ns>/<app>/pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata: { name: <app>-config-pv }
spec:
  capacity: { storage: 5Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  hostPath: { path: /opt/<app>/config, type: DirectoryOrCreate }
  claimRef:                              # pins this PV to exactly one PVC; prevents
    namespace: <ns>                      # the scheduler binding it to a different app
    name: <app>-config-pvc
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: kubernetes.io/hostname, operator: In, values: [minis] }
---
# apps/<ns>/<app>/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: <app>-config-pvc, namespace: <ns> }
spec:
  storageClassName: local-nvme
  accessModes: [ReadWriteOnce]
  volumeName: <app>-config-pv           # pins this PVC to the matching PV by name
  resources: { requests: { storage: 5Gi } }
---
# Scratch variant (frigate-cache, sabnzbd-incomplete, future Immich cache):
# no PV manifest and no claimRef/volumeName pinning — TopoLVM creates the LV
# when the pod first schedules. reclaimPolicy Delete is correct: the data is
# regenerable and the space returns to vg0 when the PVC is deleted.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: sabnzbd-incomplete-pvc, namespace: media }
spec:
  storageClassName: topolvm-scratch
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 50Gi } }
```

```yaml
# In the Deployment: set limits + priority. The PV's DirectoryOrCreate makes the
# dir on first mount, so no init container / mkdir is needed.
spec:
  template:
    spec:
      priorityClassName: homelab-standard      # or homelab-critical
      containers:
        - name: <app>
          # image, env (SOPS secrets), ports ...
          resources:
            requests: { cpu: "250m", memory: 256Mi }
            limits:   { cpu: "1",    memory: 512Mi }
          volumeMounts: [{ name: config, mountPath: /config }]
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: <app>-config-pvc }
```

## Download pod pattern (Gluetun + SABnzbd + *arr)

SABnzbd, Prowlarr, Radarr, and Sonarr share Gluetun's network namespace (one pod,
five containers): all WAN egress rides the tunnel and the kill switch protects it;
intra-stack calls are `localhost:<port>`; callers outside the pod (Overseerr,
browsers) use the Gluetun Service at the app's port. **Both firewall env vars below
are required** — outbound subnets alone does not allow inbound UI/API traffic.

```yaml
spec:
  template:
    spec:
      priorityClassName: homelab-standard
      containers:
        - name: gluetun
          image: ghcr.io/qdm12/gluetun
          securityContext: { capabilities: { add: [NET_ADMIN] } }
          envFrom: [{ secretRef: { name: gluetun-mullvad } }]   # SOPS-encrypted
          # VPN_SERVICE_PROVIDER=mullvad, VPN_TYPE=wireguard,
          # WIREGUARD_PRIVATE_KEY=..., SERVER_COUNTRIES=...
          # FIREWALL_INPUT_PORTS=8080,9696,7878,8989     # inbound: UIs, Overseerr
          # FIREWALL_OUTBOUND_SUBNETS=10.42.0.0/16,10.43.0.0/16,172.17.1.0/24
          #   (k3s pod + Service CIDRs, LAN — keeps cluster DNS/NAS/Plex reachable)
        - name: sabnzbd                          # localhost:8080
          image: lscr.io/linuxserver/sabnzbd
          # no special networking — inherits gluetun's namespace (as do the *arrs)
          volumeMounts:
            - { name: sabnzbd-config, mountPath: /config }      # /opt/sabnzbd (btrfs NVMe)
            - { name: sabnzbd-incomplete, mountPath: /incomplete } # topolvm-scratch PVC (ext4 LV)
            - { name: downloads, mountPath: /downloads }         # NAS NFS
        - name: prowlarr                         # localhost:9696
          image: lscr.io/linuxserver/prowlarr
          volumeMounts: [{ name: prowlarr-config, mountPath: /config }]
        - name: radarr                           # localhost:7878
          image: lscr.io/linuxserver/radarr
          volumeMounts:
            - { name: radarr-config, mountPath: /config }
            - { name: media, mountPath: /media }             # NAS NFS
        - name: sonarr                           # localhost:8989
          image: lscr.io/linuxserver/sonarr
          volumeMounts:
            - { name: sonarr-config, mountPath: /config }
            - { name: media, mountPath: /media }
      volumes:
        # config PVCs — local-nvme StorageClass, each bound to a pre-created PV under /opt
        - { name: sabnzbd-config,   persistentVolumeClaim: { claimName: sabnzbd-config-pvc } }
        - { name: prowlarr-config,  persistentVolumeClaim: { claimName: prowlarr-config-pvc } }
        - { name: radarr-config,    persistentVolumeClaim: { claimName: radarr-config-pvc } }
        - { name: sonarr-config,    persistentVolumeClaim: { claimName: sonarr-config-pvc } }
        # TopoLVM scratch LV — size-enforced, high-write, not snapshotted (see architecture.md)
        - { name: sabnzbd-incomplete, persistentVolumeClaim: { claimName: sabnzbd-incomplete-pvc } }
        # NAS paths — NFS mounted on host via fstab (Phase 0.4); pods use hostPath, no NFS PVC
        - { name: media,     hostPath: { path: /mnt/media,           type: Directory } }
      # Every container sets its own requests/limits per the allocation table.
```
Accepted caveats: any image bump or manifest change to **any** container recreates
the whole pod and re-establishes the tunnel (the stack is briefly down together);
the app containers' public DNS lookups go via cluster DNS over the node's WAN
(lookups only — the traffic itself is tunneled). To switch provider later (e.g.
Proton), change the env in `gluetun-mullvad` and restart — nothing else changes.

## Plex Quick Sync pattern (notes)

- Mount `/dev/dri` as a hostPath volume into the Plex container.
- Grant the **render group** via `securityContext.supplementalGroups: [<RENDER_GID>]`
  (the GID from `getent group render` in Phase 0.3); a privileged pod also works but
  the group is tighter.
- Do **not** set `PLEX_CLAIM` when migrating existing config — the migrated data
  already holds a valid token (see migration runbook).
