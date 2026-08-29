# Host configuration files

Canonical copies of the **host-level** config written during the manual phases
([build-plan.md](../../docs/build-plan.md) Phases 0–1). These are not applied to the
cluster — they configure the Ubuntu host itself, below k3s. The build plan references
these files instead of inlining the config, so this directory is the source of truth.

Files under `etc/` **mirror their on-disk path** (`host/minis/etc/foo` → `/etc/foo`), so a
restore is a copy. `etc/fstab` is captured in full, but read the Phase 0.4 note before
restoring it — the `/boot/efi` line carries a disk-specific UUID.

## Restoring from scratch

Install the OS per [build-plan.md Phase 0.1](../../docs/build-plan.md#phase-0--os-baseline-)
(partition layout, user, SSH), then drop these files into place and apply each, in
phase order. All paths are owned by `root`; set the perms noted per file.

### Phase 0 — captured and runbook-backed

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/ssh/sshd_config.d/10-homelab.conf` | same | `root:root` `644` | copy your key up first, then `sudo systemctl restart ssh` (**key-only auth** — see note below) |
| `etc/netplan/00-installer-config.yaml` | `/etc/netplan/00-installer-config.yaml` | `root:root` **`600`** | `sudo netplan generate && sudo netplan apply` |
| `etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | same | `root:root` `644` | (takes effect next boot; stops cloud-init re-rendering netplan) |
| `etc/udev/rules.d/99-coral.rules` | same | `root:root` `644` | `sudo udevadm control --reload-rules && sudo udevadm trigger` |
| `etc/sysctl.d/99-inotify.conf` | same | `root:root` `644` | `sudo sysctl --system` (raises per-user capacity to 524288 watches and 8192 instances) |
| `etc/nut/nut.conf` | `/etc/nut/nut.conf` | `root:nut` `640` | see NUT note below |
| `etc/nut/ups.conf` | `/etc/nut/ups.conf` | `root:nut` `640` | " |
| `etc/nut/upsd.conf` | `/etc/nut/upsd.conf` | `root:nut` `640` | " |
| `etc/nut/upsmon.conf` | `/etc/nut/upsmon.conf` | `root:nut` `640` | " (**redacted secret**) |
| `etc/nut/upsd.users` | `/etc/nut/upsd.users` | `root:nut` `640` | " (**redacted secret**) |
| `etc/systemd/system/nut-server.service.d/10-wait-online.conf` | same | `root:root` `644` | `sudo systemctl daemon-reload && sudo systemctl restart nut-server` (orders upsd after network-online — its lan0 `LISTEN` must not race address assignment) |
| `etc/mdadm/mdadm.conf` | `/etc/mdadm/mdadm.conf` | `root:root` `644` | install, then `sudo update-initramfs -u`; pins array UUID `74071d44:3bf857f0:85a3a734:9391a964` to `/dev/md3` |
| `etc/systemd/system/mdcheck_start.timer.d/override.conf` | same | `root:root` `644` | `sudo systemctl daemon-reload && sudo systemctl enable --now mdcheck_start.timer` |
| `etc/systemd/system/mdcheck_continue.timer.d/override.conf` | same | `root:root` `644` | `sudo systemctl daemon-reload && sudo systemctl enable --now mdcheck_continue.timer` |
| `etc/systemd/system/mdcheck_start.service.d/override.conf` | same | `root:root` `644` | caps scheduled `md3` checks at `50000` KiB/s and restores the system default afterward |
| `etc/systemd/system/mdcheck_continue.service.d/override.conf` | same | `root:root` `644` | applies the same cap to each continuation window; `sudo systemctl daemon-reload` after install |
| `etc/fstab` | `/etc/fstab` | `root:root` `644` | reconcile the `/boot/efi` UUID with this disk (see Phase 0.4), create the four `/mnt/...` mountpoints, and verify every direct mount against its LVM device and ext4 UUID |

**SSH (key-only):** `sshd_config.d/10-homelab.conf` sets `PasswordAuthentication no` and
`PermitRootLogin no`. On restore, **copy your public key up and confirm a key login works
before restarting `ssh`** — otherwise the restart locks you out. Keep a second session
open during the restart.

`netplan` **requires `600`** or it refuses the file with a permissions warning. The
secondary `192.168.1.2/24` on `cam0` only appears once NIC2 has carrier
(`optional: true`); that's expected.

**Interface names** (`lan0` = NIC1/LAN, `cam0` = NIC2/camera) are pinned by MAC in the
netplan `match`/`set-name` block, which emits a systemd `.link` rule udev applies at
boot. The MACs are this host's two 2.5GbE ports. Note `netplan apply` **cannot rename a
live, addressed interface** — on first apply (or if the NICs are swapped) the rename
takes effect after a **reboot**; until then the kernel `enpXXsY` names persist. All
downstream host config (`nftables.conf`, `dnsmasq.d/cameras.conf`,
`sysctl.d/99-camera-no-ipv6.conf`, `chrony/conf.d/cameras.conf`) references `cam0`, so
these names are now load-bearing — renaming again means sweeping all four in lockstep.

**Phase 0.4 (bulk storage):** `etc/fstab` is the full file from this host. The root/`var`/`opt`
entries are LVM device paths (`/dev/vg0/*`) that the Phase 0.1 partition layout
reproduces, so they restore as-is — but the `/boot/efi` line is keyed by a
**disk-specific UUID** (`/dev/disk/by-uuid/...`) generated at install time. After a
fresh install, replace that UUID with this disk's EFI partition UUID (`blkid`) before
relying on the file, or the boot mount fails. The Phase 0 runbook installs the md3
identity, updates initramfs, installs the attended monthly consistency-check schedule,
and appends all four UUID-based automount entries without replacing the OS fstab.
It verifies `/mnt/media`, `/mnt/games`, `/mnt/frigate`, and `/mnt/backups` against
their exact `hoardvg` devices and filesystem UUIDs.

The monthly RAID check starts on the first Sunday at 10:00 local time. If the stock
six-hour mdadm check window cannot finish, the continuation timer retries daily at
10:00 while `/var/lib/mdcheck/MD_UUID_*` state exists. Service drop-ins cap only the
active `md3` check at `50000` KiB/s and restore `sync_speed_max=system` when each
window ends, so a future recovery is not permanently throttled. Prometheus alerts
when an active `md3` check makes no block progress for 45 minutes.

**Phase 0.5 (NUT):** the configs are the *effective* (non-comment) settings, not a
byte-for-byte copy of the stock files. After placing them, enable the stack:
`sudo systemctl enable --now nut-driver-enumerator nut-server nut-monitor`, then confirm
with `upsc cp1500`. The driver/port (`usbhid-ups`/`auto`) and battery model
(`CyberPower CP1500`) are specific to this host's UPS — adjust if the hardware changes.

### NUT secret note (important)

`upsmon.conf` (the `MONITOR` line) and `upsd.users` (`password =`) share one password,
**redacted here** as `__REPLACE_WITH_UPSMON_PASSWORD__` per the repo's no-plaintext-secrets
rule. On restore, replace **both** with the value from the password manager — they must
match or `upsmon` can't authenticate to `upsd` and the clean-shutdown-on-power-loss
hook silently won't work. (`upsd` also listens on lan0's IP for read-only in-cluster
telemetry clients — see [operations.md → UPS / NUT](../../docs/operations.md#ups--nut) —
so this credential is reachable beyond loopback, though only the `upsmon` role ever
uses it.)

### Phase 1 — camera-segment isolation

Captured here and copied by `runbooks/phase1/` when Phase 1 is applied. All are
`root:root`. If the live host diverges, update these files so the runbooks continue
to describe the real rebuild path.

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/nftables.conf` | `/etc/nftables.conf` | `root:root` `644` | `sudo systemctl enable --now nftables` (replaces the stock default; manages only the `camera_isolation`, `frigate_access`, `ups_access`, and `nfs_access` tables — no `flush ruleset`, so k3s's own nft chains survive a reload) |
| `etc/sysctl.d/99-camera-no-ipv6.conf` | same | `root:root` `644` | `sudo sysctl --system` (disables IPv6 on NIC2) |
| `etc/dnsmasq.d/cameras.conf` | same | `root:root` `644` | `sudo systemctl enable --now dnsmasq` (DHCP-only, NIC2; `port=0` so no `:53` clash with systemd-resolved) |
| `etc/chrony/conf.d/cameras.conf` | same | `root:root` `644` | `sudo systemctl enable --now chrony && sudo systemctl restart chrony` (serve NTP to the segment) |

**Phase 1.3 (chrony):** `chrony` is **not** in stock Ubuntu 24.04 (it ships
`systemd-timesyncd`, client-only). Install it in Phase 0.3 and confirm it's the active
daemon (`timedatectl` / `chronyc sources`) before relying on this file. The config has
**no `bindaddress`** by design — see the comment in the file and build-plan.md 1.3.

**Phase 1.2 (dnsmasq):** the committed file pins the deployed Amcrest camera at
`192.168.105.50`. Add another `dhcp-host` entry in the static `.50-.99` block whenever
a camera is provisioned, and repeat the lease-stability and isolation checks before
adding that camera to Frigate.

### Phase 2 — k3s server configuration

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/rancher/k3s/config.yaml` | `/etc/rancher/k3s/config.yaml` | `root:root` `600` | `sudo systemctl restart k3s` |

### NFS exports — `runbooks/nfs-exports/`

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/nfs.conf.d/10-homelab.conf` | same | `root:root` `644` | `sudo systemctl restart nfs-server` (NFSv4-only; opens nfsd sockets only on `10.137.20.5`/`127.0.0.1`, not on the `cam0` addresses; `nfs_access` separately filters ingress sources/interfaces) |
| `etc/exports` | `/etc/exports` | `root:root` `644` | `sudo exportfs -ra` |
| `etc/systemd/system/nfs-server.service.d/10-wait-mounts.conf` | same | `root:root` `644` | `sudo systemctl daemon-reload` (orders nfsd after the `/mnt/media` and `/mnt/games` automount units) |

`etc/nftables.conf` also carries the `nfs_access` table; it is installed by the Phase 1
step above and by `runbooks/nfs-exports/02-firewall.sh`. **Reload nftables, never restart
it.**

On restore, mask `rpcbind.service`, `rpcbind.socket`, `rpc-statd.service`,
`rpc-statd-notify.service`, and `rpc-gssd.service` — NFSv4-only needs none of them, and
installing `nfs-kernel-server` otherwise leaves rpcbind listening on `0.0.0.0:111`. Phase 0.3
masks them as part of installing the package; `runbooks/nfs-exports/01-install-server-config.sh`
re-verifies the same list and validates the result. Do **not** mask `nfs-mountd.service`: nfsd
still uses `rpc.mountd` as its export-authentication upcall handler under v4. See
[operations.md → NFS exports](../../docs/operations.md#nfs-exports).

The k3s config sets the cluster-wide terminal Pod garbage-collection threshold to 20.
This bounds the failed Pods left by the upstream device-plugin reboot admission race,
as well as other `Failed` and `Succeeded` Pod objects. Once the total exceeds 20,
PodGC deletes the oldest terminal Pods, including their retained logs.

## Keeping these in sync

These are the source of truth, but they're hand-synced with the host — there's no
automated apply. After changing host config, update the matching file here (or pull it
back with `scp minis:/etc/... host/minis/etc/...`) so a future restore reflects reality.
