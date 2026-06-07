# Build Plan

Bare metal → running stack, in dependency order. Phases 0–3 are strict: each depends
on the one before. Phase 3.5 (data migration) and Phase 4 (workloads) come only after
the **validation gate** passes. Design rationale is in
[architecture.md](./architecture.md).

Legend: 🔧 manual one-time · ⚙️ scripted · 📦 GitOps (git commit). ⚑ = must-validate.

---

## Phase 0 — OS baseline 🔧

**0.1 Install Ubuntu 24.04 LTS** (server, no GUI). During partitioning, create the
layout from [architecture.md](./architecture.md#filesystem-and-partitioning):
`/` 100 GB ext4 · `/var` 150 GB ext4 · `/opt` 400 GB btrfs · `/frigate/cache` 50 GB
ext4 · ~100 GB unallocated. Create a non-root sudo user; disable root SSH login.

**0.2 Static networking (NIC1 first).** Set NIC1 to a static IP via Netplan before
anything else so the address can't shift mid-bootstrap. Confirm interface names with
`ip link` first.

```yaml
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    enp1s0:                      # NIC1 — verify name
      addresses: [192.168.1.10/24]
      routes: [{ to: default, via: 192.168.1.1 }]
      nameservers: { addresses: [192.168.1.1] }
      dhcp4: false
    enp2s0:                      # NIC2 — camera segment
      addresses: [10.10.0.1/24]
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

**0.7 Router DNS.** Add the wildcard record `*.home.lan → 192.168.1.10`. Test true
wildcard support with a throwaway hostname before relying on it.

---

## Phase 1 — networking isolation 🔧

**1.1 Camera isolation (nftables).** Drop camera→internet and camera→LAN; allow
LAN→camera.
```
# /etc/nftables.conf (excerpt)
table inet camera_isolation {
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "enp2s0" oifname "enp1s0" drop      # camera -> LAN/internet: blocked
    iifname "enp1s0" oifname "enp2s0" accept     # LAN -> camera: allowed
  }
}
```
Enable nftables. ⚑ From a device on the camera segment, confirm you **cannot** ping
`8.8.8.8` or any `192.168.1.0/24` host.

**1.2 Camera DHCP (dnsmasq).** Bind dnsmasq to NIC2 and serve `10.10.0.0/24`
(host-level service, not a pod). Give cameras stable leases so Frigate can target
known addresses.
```
# /etc/dnsmasq.d/cameras.conf (excerpt)
interface=enp2s0
bind-interfaces
dhcp-range=10.10.0.50,10.10.0.200,12h
# dhcp-host=AA:BB:CC:DD:EE:FF,10.10.0.51   # pin per-camera as needed
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
  --node-label kubernetes.io/hostname=ms01
kubectl get nodes            # ms01 Ready
```

**2.2 MetalLB** — stable LoadBalancer IP (the node's static IP) so the wildcard target
is fixed.
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: homelab-pool, namespace: metallb-system }
spec: { addresses: ["192.168.1.10/32"] }   # outside the DHCP range
```

**2.3 ingress-nginx** and **2.4 cert-manager** (Helm during bootstrap; convert to
HelmReleases under `infrastructure/controllers/` once Flux owns the cluster). Create a
**Let's Encrypt DNS-01 ClusterIssuer** (provider API creds via a SOPS secret) so even
internal `*.home.lan` services get real certs.

**2.5 Tailscale operator** — LAN + Tailnet access; configure **split DNS** in the
Tailscale admin console so `*.home.lan` resolves over the tunnel. OAuth creds come from
a SOPS secret. Add a kubeconfig context on the laptop pointing at the node's Tailscale
IP on `:6443`.

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
  --branch=main --path=clusters/ms01 --personal --private
```

**3.5 Commit the repo skeleton** — see [structure in CLAUDE.md](../CLAUDE.md#repository-structure):
`clusters/ms01/{infrastructure.yaml,apps.yaml}`, `infrastructure/{controllers,configs,monitoring}`,
`apps/{media,frigate,home-assistant}`. `apps.yaml` should `dependsOn` the
infrastructure Kustomization.

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

- [ ] `kubectl get nodes` → `ms01 Ready`
- [ ] ingress-nginx + cert-manager pods Running; ClusterIssuer Ready
- [ ] `flux get kustomizations` → all Reconciled
- [ ] NFS mounts readable from a test pod
- [ ] `/dev/dri/renderD128` visible in a **privileged test pod** (Quick Sync path)
- [ ] Coral device visible in a privileged test pod
- [ ] Camera segment **cannot** reach internet or LAN (ping test)
- [ ] dnsmasq issues a camera lease in range
- [ ] Tailscale operator connected; `*.home.lan` resolves over the Tailnet
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

**4a — Gluetun + Mullvad (deploy first).** Gateway pod in `media`, SABnzbd as a
sidecar in the same pod. ⚑ Confirm the SABnzbd container's egress IP equals the VPN
exit IP before wiring the *arr apps to it. Pattern below.

Then, in parallel once VPN is validated:

**4b — Plex** (standard/burstable). `/dev/dri` hostPath + the render group; NAS media
PVC; `/opt/plex` metadata. ⚑ Run a 1080p transcode and confirm GPU use with
`intel_gpu_top` on the host.

**4c — Frigate** (critical/non-evictable). Coral USB hostPath; cameras on the NIC2
segment; DB on `/opt/frigate`, cache on `/frigate/cache`, recordings on NAS. ⚑ Verify
cameras remain unreachable from the internet.

**4d — remaining stack.** Radarr/Sonarr/Prowlarr (behind VPN, pointing at the Gluetun
Service), Overseerr, RomM, Home Assistant (`hostNetwork: true` for mDNS/Zeroconf
discovery; plus any Zigbee/Z-Wave USB stick via hostPath, like the Coral).

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

The reusable shape for any stateful app. Adding a new app = copy this, change names —
no SSH, directory auto-created.

```yaml
# infrastructure/configs/storageclass.yaml — once, cluster-wide
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: local-nvme }
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
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
  local: { path: /opt/<app>/config }
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: kubernetes.io/hostname, operator: In, values: [ms01] }
---
# apps/<ns>/<app>/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: <app>-config-pvc, namespace: <ns> }
spec:
  storageClassName: local-nvme
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 5Gi } }
```

```yaml
# In the Deployment: create the dir on first run, set limits + priority
spec:
  template:
    spec:
      priorityClassName: homelab-standard      # or homelab-critical
      initContainers:
        - name: init-dirs
          image: busybox
          command: ["sh","-c","mkdir -p /data/opt/<app>/config"]
          volumeMounts: [{ name: opt, mountPath: /data/opt }]
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
        - name: opt
          hostPath: { path: /opt }
```

## Gluetun + SABnzbd pattern

SABnzbd shares Gluetun's network namespace (one pod, two containers); the kill switch
protects egress; *arr apps target the Gluetun Service.

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
        - name: sabnzbd
          image: lscr.io/linuxserver/sabnzbd
          # no special networking — inherits gluetun's namespace
          volumeMounts:
            - { name: config, mountPath: /config }      # /opt/sabnzbd  (NVMe)
            - { name: downloads, mountPath: /downloads }  # NAS NFS
      # volumes: config PVC (local-nvme) + downloads (NFS) ...
```
To switch provider later (e.g. Proton), change the env in `gluetun-mullvad` and
restart — nothing else changes.

## Plex Quick Sync pattern (notes)

- Mount `/dev/dri` as a hostPath volume into the Plex container.
- Grant the **render group** via `securityContext.supplementalGroups: [<RENDER_GID>]`
  (the GID from `getent group render` in Phase 0.3); a privileged pod also works but
  the group is tighter.
- Do **not** set `PLEX_CLAIM` when migrating existing config — the migrated data
  already holds a valid token (see migration runbook).
