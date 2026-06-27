# Build Plan

Bare metal → running stack, in dependency order. Phases 0–3 are strict: each depends
on the one before. Phase 3.5 (data migration) and Phase 4 (workloads) come only after
the **validation gate** passes. Design rationale is in
[architecture.md](./architecture.md).

Legend: 🔧 manual one-time · ⚙️ scripted · 📦 GitOps (git commit). ⚑ = must-validate.

---

## Phase 0 — OS baseline 🔧

**0.0 BIOS / firmware (one-time, before install).** These can't be set from the OS and
silently break passthrough if wrong:
- **VT-d / IOMMU — optional, not required for this build.** Plex reaches Quick Sync via a
  `/dev/dri` hostPath and the Coral via a `/dev/bus/usb` hostPath — both are plain device
  access, *not* DMA/PCI passthrough, so neither needs IOMMU. Leave VT-d on only if you want
  the option of true PCI passthrough later (e.g. a VM); nothing in the current container-first
  design depends on it. The `intel_iommu=on` cmdline in 0.3 is correspondingly optional.
- **iGPU enabled** (not disabled/headless) — Quick Sync transcoding needs `/dev/dri`
  to exist; confirm in 0.3.
- **Secure Boot off** (or be ready to enrol keys) — simplest path for any out-of-tree
  module; revisit only if you specifically want it on.
- Flash to a current MS-01 BIOS while you're in here — firmware fixes for this board's
  NIC/thermal behaviour ship regularly, and reflashing later means another reboot.

**0.1 Install Ubuntu 24.04 LTS** (server, no GUI; chosen over 26.04 — too new for
the one production node, and the MS-01's hardware is fully supported). No full-disk
encryption — unattended reboot after a UPS shutdown must work. No swap partition
(kubelet requires swap off). During partitioning, create the
layout from [architecture.md](./architecture.md#filesystem-and-volume-layout):
the ESP outside LVM (`/boot` lives on the `root` LV — GRUB reads it from LVM), then a
single LVM PV on the rest of the disk → VG `vg0` with LVs `root` 100 GB ext4 (`/`) ·
`var` 100 GB ext4 (`/var`) · `opt` 100 GB btrfs (`/opt`) · ~650 GB left
**unallocated in the VG**. Do *not* pre-create filesystems
for Frigate cache or SABnzbd staging — those are TopoLVM-provisioned PVCs in
Phase 4, carved from the VG free space.

Set the hostname to **`minis`** (`sudo hostnamectl set-hostname minis`) — the node
name k3s derives from it is load-bearing: every app PV pins `nodeAffinity` to
`kubernetes.io/hostname: minis`, so a mismatched hostname leaves every app PVC
`Pending` (see 2.1). Create a non-root sudo user (`charlie`). Harden SSH per
[`host/minis/etc/ssh/sshd_config.d/10-homelab.conf`](../host/minis/etc/ssh/sshd_config.d/10-homelab.conf):
key-only auth (`PasswordAuthentication no`) and no root login. Copy your key up
(`ssh-copy-id charlie@10.137.20.5`) **before** disabling passwords, then
`sudo systemctl restart ssh` and confirm a key login works in a second session before
closing the first — SSH is the sanctioned tunnel path for camera web UIs (1.1), so it's
reachable on LAN + Tailnet and worth locking down.

**0.2 Static networking (NIC1 first).** Set NIC1 to a static IP via Netplan before
anything else so the address can't shift mid-bootstrap. The kernel auto-names the two
2.5GbE ports something like `enpXXs0` — the exact name is PCI-enumeration dependent and
can shift if hardware is rearranged, so identify the ports by **MAC**, not by name:
NIC1 = `38:05:25:35:fb:d3`, NIC2 = `38:05:25:35:fb:d2`. The netplan config pins these to
the friendly names **`lan0`** and **`cam0`** by MAC (`match`/`set-name`), which all later
config references — that rename is exactly what makes the names stable regardless of how
the kernel enumerated them. The rename lands on reboot — `netplan apply` cannot rename a
live, addressed link. The unused 10G SFP+ ports enumerate as `enpXs0f0np0`/`enpXs0f1np1`.
Also disable cloud-init's network rendering or it regenerates the installer's DHCP stub
on reboot.

→ Apply [`host/minis/etc/netplan/00-installer-config.yaml`](../host/minis/etc/netplan/00-installer-config.yaml)
(NIC1 static `10.137.20.5/24`; NIC2 `192.168.105.1/24` plus the `192.168.1.2/24`
factory-default-camera alias, with `optional: true` so a carrierless NIC2 can't block
boot) and [`host/minis/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`](../host/minis/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg).
Netplan must be mode `600`. Then `sudo netplan generate && sudo netplan apply` and
confirm both interfaces are up.

**0.3 System prep + hardware checks.**
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git vim nfs-common sqlite3 jq age iperf3 nftables dnsmasq nut chrony
sudo timedatectl set-timezone America/Chicago   # set the HOST tz explicitly — Frigate event
                            #   timestamps and cross-log correlation depend on it; the default
                            #   is often UTC. (chrony in 1.3 serves time to cameras; this sets
                            #   the host's own clock display/zone.)
swapon --show               # MUST be empty — kubelet refuses swap. The installer often
                            #   creates /swap.img even with no swap partition; if present:
                            #   sudo swapoff -a && sudo rm /swap.img, then remove its
                            #   /etc/fstab line so it stays off across reboots.
ls -la /dev/dri/            # expect cardN + renderD128 (Quick Sync)
lsmod | grep i915           # i915 driver loaded; if not, add to /etc/modules + reboot
getent group render         # render GID — needed for the Plex pod. On this node: 993
rfkill block wifi           # WiFi (wlpXYs0) is unused; block it to shrink attack surface.
                            #   `rfkill` state persists across reboots on Ubuntu.
rfkill block bluetooth      # Bluetooth (hci0) is likewise unused — block it too.
```
IOMMU is **not** needed for this build — the iGPU and Coral are reached by hostPath device
access, not PCI passthrough (see 0.0). Only if you later add true PCI passthrough: set
`intel_iommu=on` in `GRUB_CMDLINE_LINUX` (`/etc/default/grub`), `sudo update-grub`, reboot —
and capture the grub file into `host/minis/etc/default/grub` so a restore stays a copy.

**0.4 NFS mounts.** [`host/minis/etc/fstab`](../host/minis/etc/fstab) is the full fstab
from this host. The root/`var`/`opt` entries are LVM device paths the Phase 0.1 layout
reproduces, but the `/boot/efi` line carries a disk-specific UUID — reconcile it with
this disk (`blkid`) before use. Restore the file (or just append the
`media.nfs.service.matrix:/mnt/media` line on an existing install), then `sudo mount -a`
and verify `/mnt/media`. `nofail` is essential — a NAS outage at boot must not block k3s.
Additional mounts (`/mnt/frigate`, `/mnt/games`) will be added in Phase 4 when the apps
that need them are configured. Completed downloads are *not* a separate export — SABnzbd
hands off under `/mnt/media` so the download dir and the *arr library share one filesystem
(hardlink/atomic-move imports). The NAS hostname `media.nfs.service.matrix` resolves via the
router nameserver (`10.137.20.1`, set in 0.2) — there is no `/etc/hosts` fallback, so the
boot-time mount depends on the router's DNS; confirm it resolves (`getent hosts
media.nfs.service.matrix`) before `mount -a`.

**0.5 UPS via NUT.** Apply the configs in [`host/minis/etc/nut/`](../host/minis/etc/nut/) (`nut.conf`,
`ups.conf`, `upsd.conf`, `upsmon.conf`, `upsd.users`; mode `640 root:nut`). The driver
(`usbhid-ups`) and model (`CyberPower CP1500`) are specific to this host's UPS. The
`upsmon`/`upsd` password is **redacted** in the repo — restore it from the password
manager, identical in both files (see [host/minis/README.md](../host/minis/README.md#nut-secret-note-important)).
Enable the stack (`sudo systemctl enable --now nut-driver-enumerator nut-server nut-monitor`).
NUT is host-level and must start **before** k3s so the clean-shutdown hook works even if
the cluster is degraded.

**0.6 udev rules for the Coral.** Apply
[`host/minis/etc/udev/rules.d/99-coral.rules`](../host/minis/etc/udev/rules.d/99-coral.rules) to give
the device stable, non-root permissions (`MODE=0666`, `GROUP=plugdev`), then
`sudo udevadm control --reload-rules && sudo udevadm trigger`. (The Coral enumerates
under two USB IDs — before and after its firmware loads — so the rule matches both; the
rule sets permissions, it does not create a symlink.) Frigate reaches the device via a
`/dev/bus/usb` hostPath in Phase 4c — these permissions are what let the container open
it without running fully privileged.

**0.7 Router DNS.** Add the wildcard record `*.worm.run → 10.137.20.10` (the MetalLB
ingress IP from Phase 2.2, **not** the node's own `10.137.20.5`). Test true
wildcard support with a throwaway hostname before relying on it.

---

## Phase 1 — networking isolation 🔧

**1.1 Camera isolation (nftables).** Two hooks. The **forward** chain drops everything
routed to or from the segment (camera→internet, camera→LAN, LAN→camera). The **input**
chain drops everything a camera sends *to the host itself* except the few things the
segment legitimately needs — without it, the forward rules leave host services
(`k3s :6443` and `kubelet :10250`, both bound to `0.0.0.0` by default; `SSH :22`; and
every `hostNetwork` pod — Frigate, Home Assistant) reachable from a compromised
camera on `192.168.105.1`. RTSP needs no allow rule: Frigate (the host) *initiates* to
the camera, so the camera's replies are `established` and the host's own egress to the
camera is on the output hook, not forward.
```
# /etc/nftables.conf (excerpt)
# Scope teardown to OUR table only — do NOT use a top-level `flush ruleset` here.
# k3s/flannel/kube-proxy inject rules into the nat/filter/mangle tables at runtime;
# a global flush on `systemctl reload nftables` would wipe them and break pod
# networking until k3s re-syncs. This delete+recreate is idempotent and k3s-safe.
table inet camera_isolation {}
delete table inet camera_isolation
table inet camera_isolation {
  chain forward {
    type filter hook forward priority 0; policy accept;
    # Rate-limited log (no verdict → falls through), then an unconditional counter drop.
    # The log rule must NOT carry the drop verdict: if `limit` gated the drop, packets
    # over the rate would skip it and hit `policy accept`. Logging a compromised/chatty
    # camera's blocked traffic is the whole point of the segment; rate-limit so a camera
    # in a retry loop can't flood the journal.
    iifname "cam0" limit rate 10/minute log prefix "cam-drop-fwd-in "  # camera→anywhere
    iifname "cam0" counter drop
    oifname "cam0" limit rate 10/minute log prefix "cam-drop-fwd-out " # LAN→camera (host-only access)
    oifname "cam0" counter drop
  }
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "cam0" ct state established,related accept   # RTSP/stream replies
    iifname "cam0" udp dport 67 accept                   # DHCP (dnsmasq)
    iifname "cam0" udp dport 123 accept                  # NTP (chrony, see 1.3)
    iifname "cam0" icmp type echo-request accept         # ping diagnostics ONLY (v4); a broad
                                                            #   `ip protocol icmp` allow would also let a
                                                            #   camera send the host ICMP redirects. Host→camera
                                                            #   ping replies still pass via `established`.
    iifname "cam0" limit rate 10/minute log prefix "cam-drop-input "  # all other camera→host
    iifname "cam0" counter drop
  }
}
```
The camera segment is **IPv4-only**. The `inet` table covers both families, and the
`icmp type echo-request` diagnostic allow is IPv4-only — ICMPv6 (router/neighbor
discovery) from a camera falls to the final drop. To remove the IPv6 surface entirely
rather than rely on that, disable it on NIC2:
```
# /etc/sysctl.d/99-camera-no-ipv6.conf
net.ipv6.conf.cam0.disable_ipv6 = 1
```
`sudo sysctl --system` to apply.
`policy accept` on both chains is intentional (see [architecture.md](./architecture.md#networking));
the explicit drops do the work without breaking k3s's own nft chains. Enable nftables.
⚑ From a device on the camera segment, confirm you **cannot** ping `8.8.8.8` or any
`10.137.20.0/24` host, and that ICMP to the host (`192.168.105.1`) still **succeeds**
(the diagnostics allow). **Caveat — the forward-chain drop is not actually exercised at
this stage:** `net.ipv4.ip_forward` is `0` on stock Ubuntu and only gets flipped to `1`
by k3s in Phase 2, so right now the host won't route camera→internet/LAN regardless of
nftables (and a correctly-DHCP'd camera has no default route anyway). The "cannot ping
`8.8.8.8`" check therefore passes trivially and `cam-drop-fwd-*` will never log here — only
the **input** chain is genuinely testable now. The forward drop must be re-validated at the
gate (post-k3s) from a test device with a manual IP **and** a manual gateway of
`192.168.105.1`; see the gate. To prove the input chain actually drops host services, test a
port with something **listening** behind it: SSH (`nc -vz 192.168.105.1 22`) is up from
Phase 0 and must **fail**. The other host services don't exist yet — k3s `:6443` lands
in Phase 2, Frigate `:5000` in Phase 4 — so `nc` to them fails because nothing listens,
not because the firewall blocks it; that's not a real test. For a definitive check now,
run a throwaway listener bound to all interfaces on the host
(`python3 -m http.server 8000`) and confirm the camera segment cannot reach it, then
stop it. **Re-validate `:6443` (Phase 2) and `:5000` (Phase 4) once those services are
actually up** — see the validation gate.
After the rules are live, confirm the drop logging works: trigger a blocked connection
from the segment and watch for the `cam-drop-*` prefixes in `journalctl -k -f`.

**1.1b Intra-segment isolation is a switch responsibility, not the host's.** These rules
only govern traffic that reaches the node; two cameras on the same L2 segment talk
directly through the switch and never hit it. A compromised camera could pivot to its
peers unless the switch isolates the camera ports from each other. The camera segment
runs on a **Cisco Catalyst 3850**, which supports this — configure **protected ports**
(`switchport protected` on each camera access port, plus `switchport block unicast`/
`block multicast` so unknown-unicast/flood traffic isn't leaked between them). A blanket
PVLAN is the heavier alternative if you later need more than protected ports gives.
**Leave the host uplink port _unprotected_** — protected ports can't talk to each other, so
protecting the uplink would kill host↔camera RTSP. (Protected ports also only isolate within
a single switch/stack; if cameras ever span a second switch over a trunk, you'd need PVLANs.
The segment is a single 3850 today, so protected ports suffice.)

⚑ This is a **blocker, not a follow-up**: network isolation must be complete before any
camera is connected and before Frigate goes live (Phase 4c). Validate by attempting a
ping or port scan **between two cameras on the segment** — it must fail. Until this is
done the posture is "no internet, no LAN reach, but cameras are *not* isolated from one
another," which is not an acceptable state to run cameras in.

LAN→camera access (e.g. a camera web UI for setup) goes through the node, since direct
forwarding is dropped. Tunnel the camera's HTTP port to your workstation over SSH:
```bash
# reach camera 192.168.105.101's web UI at http://localhost:8080 on your laptop
ssh -L 8080:192.168.105.101:80 charlie@10.137.20.5
```
The host can route to the camera segment (it owns `192.168.105.1`); only *forwarded*
LAN→camera traffic is blocked, so the SSH-forwarded connection originating on the host
works. Tear down the tunnel when done — no standing rule is added.

**Provisioning a factory-default / static camera.** New Amcrest cameras default to DHCP
and land on a `192.168.105.x` lease (reach them via the tunnel above). But a reset, a
static-default firmware, or a second-hand camera previously set static will instead sit
at the factory `192.168.1.108` and ignore DHCP. NIC2 carries a secondary address
(`192.168.1.2/24`, set in 0.2) precisely to reach those without a bench network — tunnel
to the default address, enable DHCP + set NTP/credentials, then it rejoins the `105`
segment:
```bash
ssh -L 8080:192.168.1.108:80 charlie@10.137.20.5   # camera default UI at localhost:8080
```
This is a one-at-a-time recovery path (every factory camera is `192.168.1.108`), not the
normal flow. The nftables rules need no change — they are `iifname "cam0"`-scoped, so
the alias subnet is already covered.

**1.2 Camera DHCP (dnsmasq).** Bind dnsmasq to NIC2 and serve `192.168.105.0/24`
(host-level service, not a pod). Give cameras stable leases so Frigate can target
known addresses. `sudo systemctl enable --now dnsmasq` so it survives a reboot.
(`port=0` means dnsmasq runs no resolver, so it does **not** collide with
`systemd-resolved` on `:53` — no need to disable resolved.)
```
# /etc/dnsmasq.d/cameras.conf (excerpt)
interface=cam0
bind-dynamic            # binds as the interface appears; survives a boot with no
                        # carrier on NIC2 (it's optional:true). bind-interfaces would
                        # fail to start if no camera is connected at boot.
port=0                  # DHCP only — no DNS. Frigate targets cameras by IP, and a
                        # resolver here would be an outbound beacon path for a
                        # compromised camera (queries forwarded via the host's WAN).
dhcp-range=192.168.105.100,192.168.105.199,12h  # DYNAMIC pool only; static reservations
                        # (dhcp-host) live in a dedicated .50-.99 block, so a pinned camera IP
                        # can't collide with a transient lease. Split fixed up front — once cameras
                        # are pinned their IPs are baked into NTP/Frigate config.
dhcp-authoritative      # sole DHCP server on an isolated segment; speeds up leases
# Only the 105 subnet gets a range. NIC2's 192.168.1.2/24 alias (for reaching a
# factory-default camera at .108, see 1.1) is intentionally NOT served DHCP — it's a
# manual provisioning path, not part of the live segment.
# Hand cameras the host as their NTP server (option 42) — BEST EFFORT ONLY. Amcrest/
# Dahua cameras generally ignore option 42 and use the NTP server set in their own web
# UI, so this is a backstop, not the source of truth; the authoritative NTP config is
# set per-camera in 1.3. Deliberately empty router and DNS options: an isolated segment
# needs no default route or resolver, and withholding them stops cameras even attempting
# off-segment traffic or DNS beacons (the forward drop is the backstop).
dhcp-option=option:router
dhcp-option=option:dns-server
dhcp-option=option:ntp-server,192.168.105.1
# dhcp-host=AA:BB:CC:DD:EE:FF,192.168.105.51   # pin per-camera in the static .50-.99 block
```
⚑ Confirm a DHCP client receives a lease in range. Real cameras aren't connected yet at
this stage (that's gated on the switch isolation in 1.1b), so validate with a **test
laptop** plugged into the camera segment — it should get a `192.168.105.100–.199` lease, the
host (`.1`) as NTP server, and **no** default route or DNS server.

> **TODO — pin every camera before Frigate (4c).** The "stable leases" Frigate relies
> on are only guaranteed by `dhcp-host` MAC reservations; plain dynamic leases can
> reshuffle across a lease-DB loss or long outage and break Frigate's IP-addressed
> camera config. This is **blocked on finishing the switch port-isolation config (1.1b)
> first** — cameras aren't connected until that's done, and their MACs aren't known
> until they are. Once isolated and connected: collect each camera's MAC, add a
> `dhcp-host=<mac>,192.168.105.<n>` line here (in the `.50-.99` static block), restart
> dnsmasq, and confirm each camera holds its reserved IP across a restart. Promote this
> to a validation-gate item gating 4c.

**1.3 Camera NTP (chrony).** Cameras have no internet, so they need a local time source
or their clocks drift and recording timestamps/event correlation in Frigate go wrong.
Serve NTP from the host with **chrony** — install it in 0.3 (it supersedes Ubuntu
24.04's default `systemd-timesyncd`, which is an SNTP *client* only and cannot serve
the segment; confirm with `timedatectl` / `chronyc sources` that chrony, not timesyncd,
is now the active daemon):
```
# /etc/chrony/conf.d/cameras.conf
# Answer NTP from the camera segment.
allow 192.168.105.0/24
# Serve the host's own clock as a fallback so the segment stays served during a WAN
# outage (else chrony goes unsynced and REFUSES to serve, and the cameras have no
# other time source → they drift).
local stratum 10
```
chrony listens on all interfaces (default) — we deliberately do **not** `bindaddress`
to NIC2. Binding to `192.168.105.1` would require that address to exist on `cam0`
when chrony starts, but NIC2 is `optional: true` and may have no carrier at boot, so
the bind could fail and silently leave the segment unserved (dnsmasq sidesteps this with
`bind-dynamic`; chrony has no lazy-bind equivalent). Listening everywhere is harmless:
`allow 192.168.105.0/24` only authorizes the camera subnet, so a request arriving on the
LAN reaches the socket but is refused — not worth the boot-order fragility of binding. The matching `udp dport 123` allow rule is already in the 1.1 input chain.
`sudo systemctl enable --now chrony` (then restart to pick up the drop-in). ⚑ From a
camera-segment device, `chronyc -h 192.168.105.1 tracking`
(or any NTP query) succeeds.

**Configure NTP on each camera directly — this is the source of truth, not DHCP.** In
the Amcrest web UI: Setup → System → General → Date & Time → enable NTP, set the server
to `192.168.105.1`. Without internet the cameras have no other time source, and they
generally ignore the DHCP option 42 hint, so a misconfigured camera will silently drift
and corrupt Frigate event timestamps. ⚑ After setup, confirm each camera's clock is in
sync (visible in the camera UI / on Frigate's first snapshots).

**1.4 NAS throughput.** ⚑ Run `iperf3 -s` on the NAS (it's a Linux box), then
`iperf3 -c media.nfs.service.matrix` from the node. **Current expectation ~940 Mbps**,
not line rate: `minis` and the NAS both attach directly to the UDM Pro's 1 GbE RJ45 LAN
ports (no intermediate switch in this path), so 2.5GbE can't be realized end-to-end until
both hosts move off those 1G RJ45 ports onto faster links (e.g. SFP+) — don't chase the
2.3 Gbps figure yet. iperf3 measures raw TCP; the metric Plex/Frigate actually care about is
NFS read/write, so once the mounts are up (Phase 0.4) also spot-check with `fio`/`dd`
over `/mnt/media`. Diagnose anything well under ~940 Mbps before proceeding.

---

## Phase 2 — k3s + Flux bootstrap prerequisites ⚙️

This phase is intentionally small. The only imperative cluster writes are the k3s
install, the `flux-system/sops-age` Secret, and `flux bootstrap`. Everything else
that changes Kubernetes state is reconciled by Flux from git in Phase 3.

**2.1 Install k3s.**
```bash
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik --disable servicelb \
  --node-name minis          # node name drives the kubelet-set kubernetes.io/hostname
                             #   label the PV nodeAffinity pins to; requires hostname=minis (0.1).
                             #   Do NOT override that label via --node-label — it conflicts.
kubectl get nodes            # minis Ready
```

**2.2 age keypair.**
```bash
age-keygen -o age.key         # copy the public key from stdout
# >>> back up age.key to the password manager NOW, before continuing <<<
```

**2.3 Store the private key in-cluster.**
```bash
kubectl create namespace flux-system
kubectl create secret generic sops-age \
  --namespace flux-system --from-file=age.agekey=age.key
```

**2.4 `.sops.yaml`** at the repo root:
```yaml
creation_rules:
  - path_regex: .*\.yaml
    encrypted_regex: ^(data|stringData)$
    age: <YOUR_AGE_PUBLIC_KEY>
```

**2.4.1 Install the Flux CLI.**
```bash
curl -s https://fluxcd.io/install.sh | sudo bash
flux version --client
```

**2.5 Bootstrap Flux** (creates the repo if absent — **private** by default — commits
Flux manifests, generates a deploy key, and starts reconciling). `--private` is the
default for `flux bootstrap github`; it's passed explicitly here so the intent is
obvious and a future edit can't silently flip it to public:
```bash
flux bootstrap github \
  --owner=sandersch --repository=home \
  --branch=main --path=clusters/minis --personal --private
```

---

## Phase 3 — GitOps-managed cluster infrastructure ⚙️

Phase 3 is the first normal Flux commit after bootstrap. Do not install controllers
with imperative Helm commands and then convert them later; commit the desired state
directly as Flux `HelmRepository`, `HelmRelease`, and Kubernetes manifests.

**3.1 Commit the ordered Flux skeleton** — see
[structure in AGENTS.md](../AGENTS.md#repository-structure):
`clusters/minis/{kustomization.yaml,infra-controllers.yaml,infra-configs.yaml,apps.yaml}`,
`infrastructure/{controllers,configs,monitoring}`, and
`apps/{media,frigate,home-assistant}`.
At the planning stage, app and infrastructure target directories may contain only
brief README placeholders; add a real `kustomization.yaml` to each Flux target path
when the first manifests for that path are committed.

Use separate Kustomizations so CRD-backed config does not race the controllers that
install those CRDs:

- `infra-controllers` → `./infrastructure/controllers`, `wait: true`
- `infra-configs` → `./infrastructure/configs`, `dependsOn: infra-controllers`,
  `wait: true`, SOPS decryption enabled
- `apps` → `./apps`, `dependsOn: infra-configs`, SOPS decryption enabled

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: infra-controllers, namespace: flux-system }
spec:
  interval: 10m
  path: ./infrastructure/controllers
  prune: true
  sourceRef: { kind: GitRepository, name: flux-system }
  wait: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: infra-configs, namespace: flux-system }
spec:
  dependsOn: [{ name: infra-controllers }]
  decryption:
    provider: sops
    secretRef: { name: sops-age }
  interval: 10m
  path: ./infrastructure/configs
  prune: true
  sourceRef: { kind: GitRepository, name: flux-system }
  wait: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: apps, namespace: flux-system }
spec:
  dependsOn: [{ name: infra-configs }]
  decryption:
    provider: sops
    secretRef: { name: sops-age }
  interval: 10m
  path: ./apps
  prune: true
  sourceRef: { kind: GitRepository, name: flux-system }
  wait: true
```
From here: write a Secret, `sops --encrypt --in-place secret.yaml`, commit — Flux
decrypts at apply time.

**3.2 Controllers in `infrastructure/controllers/`.** Commit namespaces,
`HelmRepository` objects, and `HelmRelease` objects for:

- MetalLB
- ingress-nginx
- cert-manager, with CRDs installed by the Helm release
- Tailscale operator
- TopoLVM, with lvmd embedded in the node DaemonSet, device-class → `vg0`, and a
  `spare-gb` reserve

**3.3 Config in `infrastructure/configs/`.** Commit the CRD-backed resources and
cluster-wide config that depend on the controllers:

- MetalLB `IPAddressPool` + `L2Advertisement`. The pool is `10.137.20.10/32`,
  distinct from the node's own `10.137.20.5`; MetalLB must own the address it
  announces.
- ingress-nginx LoadBalancer configuration that receives `10.137.20.10`
- cert-manager Let's Encrypt DNS-01 `ClusterIssuer` solving via **Google Cloud
  DNS**: the solver's `cloudDNS.project` names the GCP project hosting the zone,
  and `cloudDNS.serviceAccountSecretRef` points at an encrypted Secret holding a
  service-account key JSON (DNS Administrator on that project). Per cert-manager's
  CloudDNS DNS-01 guide: https://cert-manager.io/docs/configuration/acme/dns01/google/
- encrypted Tailscale OAuth Secret and any operator config needed for Tailnet access
- `homelab-critical` and `homelab-standard` `PriorityClass` objects
- `local-nvme`, non-default `local-path`, and `topolvm-scratch` `StorageClass` objects

Configure **split DNS** in the Tailscale admin console so `*.worm.run` resolves over
the tunnel. Add a kubeconfig context on the laptop pointing at the node's Tailscale IP
on `:6443`.

---

## ✅ Validation gate

Do **not** start Phase 3.5/4 until all of these are green:

- [ ] `kubectl get nodes` → `minis Ready`
- [ ] `flux get kustomizations` → `flux-system`, `infra-controllers`,
      `infra-configs`, and `apps` Reconciled
- [ ] `flux get helmreleases -A` → MetalLB, ingress-nginx, cert-manager, Tailscale
      operator, and TopoLVM Ready
- [ ] `kubectl get crd` confirms MetalLB, cert-manager, Tailscale, and TopoLVM CRDs
      exist before config resources apply
- [ ] ingress-nginx + cert-manager pods Running; ClusterIssuer Ready
- [ ] `kubectl get svc -n ingress-nginx` shows LoadBalancer IP `10.137.20.10`
- [ ] NFS mounts readable from a test pod
- [ ] `/dev/dri/renderD128` visible in a **privileged test pod** (Quick Sync path)
- [ ] Coral device visible in a privileged test pod
- [ ] Camera segment **cannot** reach internet or LAN (ping `8.8.8.8` + a `10.137.20.x` host both fail). **Run this with k3s up (ip_forward=1) from a test device with a static IP + manual gateway `192.168.105.1`** — otherwise the forward drop is untested (see 1.1) and `cam-drop-fwd-*` should appear in the journal
- [ ] Camera segment **cannot** reach host services — `nc -vz 192.168.105.1 22` fails (SSH is listening, so this is a real test); `:6443` now also fails with k3s up. Re-check `:5000` after Frigate (Phase 4c)
- [ ] `cam-drop-*` log entries appear in `journalctl -k` when a blocked connection is attempted from the segment
- [ ] Two cameras on the segment **cannot** reach each other (switch protected ports, 1.1b)
- [ ] dnsmasq issues a camera lease in range
- [ ] Every real camera has a `dhcp-host=<mac>,192.168.105.<50-99>` reservation and
      keeps the same IP across a dnsmasq restart before Frigate goes live
- [ ] Camera segment gets NTP from the host (`192.168.105.1`); each camera's own NTP is set to `192.168.105.1` and its clock is in sync
- [ ] Tailscale operator connected; `*.worm.run` resolves over the Tailnet
- [ ] SOPS decrypt works (reconcile an encrypted Secret and confirm Flux applies it
      without plaintext in git)
- [ ] NUT active and reporting battery status

The device-passthrough items are far easier to debug now, without app complexity on
top.

---

## Phase 3.5 — app data migration 🔧

This phase is only the pre-work copy after the validation gate. Copy existing
Plex/Radarr/Sonarr/Prowlarr state from the old stack to `/opt/...` on `minis` while
the old stack continues serving. The migrated workloads are deployed in Phase 4 using
this copied data; cutover does not happen here.

Copy procedure details (VACUUM, rsync flags, ownership, and URL notes) are in
[migration-runbook.md](./migration-runbook.md).
Executable host-side scripts for the stopped-host archive copy live in
[`runbooks/phase3.5`](../runbooks/phase3.5/).

- **Migrate:** Plex (metadata/DB), Radarr, Sonarr, Prowlarr.
- **Fresh installs, no migration:** Seerr, RomM, Home Assistant, Frigate.
- Keep the old stack intact for Phase 4 validation and rollback.

---

## Phase 4 — core workloads 📦

GitOps from here. Every pod sets resource requests/limits + a priorityClassName.
Deploy workloads with NAS media mounts read-only initially where practical. Validate
the copied app state and hardware paths first; only after validation do you cut over,
flip NAS writes on, and run the final rsync for app-config changes made during the
parallel run. `/mnt/frigate` and `/mnt/games` are not mounted in Phase 0, so add them
to the host fstab during this phase before deploying Frigate or RomM.

**4a — download pod: Gluetun + Mullvad + SABnzbd + *arr (deploy first).** One pod in
`media`: Gluetun plus SABnzbd, Prowlarr, Radarr, and Sonarr sharing its network
namespace. Intra-stack calls are `localhost:<port>`; everything outside the pod uses
the Gluetun Service. ⚑ Confirm the egress IP from inside the pod equals the VPN exit
IP before configuring indexers/downloads, then validate *arr history and a test
download flow. Pattern below.

Then, in parallel once VPN is validated:

**4b — Plex** (standard/burstable). `/dev/dri` hostPath + the render group; media via
hostPath to `/mnt/media` (NFS mounted on host by fstab in Phase 0.4); `/opt/plex`
metadata. ⚑ Confirm the migrated library/metadata is intact, then run a 1080p
transcode and confirm GPU use with `intel_gpu_top` on the host.

**4c — Frigate** (critical/non-evictable). `hostNetwork: true` so RTSP connections to
cameras originate from the host (source IP `192.168.105.1`) without passing through the
forward chain — this is what makes the nftables camera isolation work. Coral USB
hostPath; DB on `/opt/frigate`, cache on a `topolvm-scratch` PVC (50 Gi ext4 LV),
recordings via hostPath to `/mnt/frigate`. ⚑ Before Frigate goes live, confirm every
real camera has a stable `.50-.99` `dhcp-host` reservation across a dnsmasq restart;
then verify cameras remain unreachable from the internet.

**4d — remaining stack.** Seerr (pointed at the *arrs via the Gluetun Service),
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
intra-stack calls are `localhost:<port>`; callers outside the pod (Seerr,
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
          # FIREWALL_INPUT_PORTS=8080,9696,7878,8989     # inbound: UIs, Seerr
          # FIREWALL_OUTBOUND_SUBNETS=10.42.0.0/16,10.43.0.0/16,10.137.20.0/24
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
        # SABnzbd's completed-download handoff lives under the SAME /mnt/media export, so the
        # *arr library and the download dir are one filesystem — required for hardlink/atomic-move
        # imports. Mount it at a path consistent with the *arrs (or set an *arr remote-path
        # mapping) so they see SABnzbd's complete dir and the library on the same mount.
        - { name: downloads, hostPath: { path: /mnt/media,           type: Directory } }
      # Every container sets its own requests/limits per the allocation table.
```
Accepted caveats: any image bump or manifest change to **any** container recreates
the whole pod and re-establishes the tunnel (the stack is briefly down together);
the app containers' public DNS lookups go via cluster DNS over the node's WAN
(lookups only — the traffic itself is tunneled). To switch provider later (e.g.
Proton), change the env in `gluetun-mullvad` and restart — nothing else changes.

## Plex Quick Sync pattern (notes)

- Install Intel's GPU device plugin from the pinned upstream Flux source in
  `infrastructure/controllers/intel-gpu-plugin`.
- Request `gpu.intel.com/i915: "1"` in the Plex container's requests and limits.
  The device plugin authorizes the Quick Sync device through kubelet/containerd;
  do not bind-mount `/dev/dri` directly.
- Keep `securityContext.supplementalGroups: [993]` for compatibility with the
  host render group from Phase 0.3, but do not use a privileged Plex container.
- Do **not** set `PLEX_CLAIM` when migrating existing config — the migrated data
  already holds a valid token (see migration runbook).
