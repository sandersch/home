# Host configuration files

Canonical copies of the **host-level** config written during the manual phases
([build-plan.md](../../docs/build-plan.md) Phases 0–1). These are not applied to the
cluster — they configure the Ubuntu host itself, below k3s. The build plan references
these files instead of inlining the config, so this directory is the source of truth.

Files under `etc/` **mirror their on-disk path** (`host/minis/etc/foo` → `/etc/foo`), so a
restore is a copy. `fstab.d/` is the one exception — its contents are *appended* to
`/etc/fstab`, never used to replace it (see Phase 0.4 below).

## Restoring from scratch

Install the OS per [build-plan.md Phase 0.1](../../docs/build-plan.md#phase-0--os-baseline-)
(partition layout, user, SSH), then drop these files into place and apply each, in
phase order. All paths are owned by `root`; set the perms noted per file.

### Phase 0 — currently captured

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/ssh/sshd_config.d/10-homelab.conf` | same | `root:root` `644` | copy your key up first, then `sudo systemctl restart ssh` (**key-only auth** — see note below) |
| `etc/netplan/00-installer-config.yaml` | `/etc/netplan/00-installer-config.yaml` | `root:root` **`600`** | `sudo netplan generate && sudo netplan apply` |
| `etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | same | `root:root` `644` | (takes effect next boot; stops cloud-init re-rendering netplan) |
| `etc/udev/rules.d/99-coral.rules` | same | `root:root` `644` | `sudo udevadm control --reload-rules && sudo udevadm trigger` |
| `etc/nut/nut.conf` | `/etc/nut/nut.conf` | `root:nut` `640` | see NUT note below |
| `etc/nut/ups.conf` | `/etc/nut/ups.conf` | `root:nut` `640` | " |
| `etc/nut/upsd.conf` | `/etc/nut/upsd.conf` | `root:nut` `640` | " |
| `etc/nut/upsmon.conf` | `/etc/nut/upsmon.conf` | `root:nut` `640` | " (**redacted secret**) |
| `etc/nut/upsd.users` | `/etc/nut/upsd.users` | `root:nut` `640` | " (**redacted secret**) |
| `fstab.d/media-nfs.fstab` | append to `/etc/fstab` | — | `sudo mount -a` then verify `/mnt/media` |

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

**Phase 0.4 (fstab):** append the line(s) in `fstab.d/*.fstab` to the existing
`/etc/fstab` — do not overwrite the file, which contains root/boot UUIDs unique to the
installed disk. Only `/mnt/media` is mounted at this stage; `/mnt/frigate` and
`/mnt/games` are added in Phase 4 with the apps that need them.

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
hook silently won't work. (It's a localhost-only credential — `upsd` listens on
`127.0.0.1` — but the rule stands regardless.)

### Phase 1 — camera-segment isolation

Captured here, ready to copy to the host when Phase 1 is applied (in order). All are
`root:root`; the host has only the stock Ubuntu nftables default until these land.

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/nftables.conf` | `/etc/nftables.conf` | `root:root` `644` | `sudo systemctl enable --now nftables` (replaces the stock default; manages only the `camera_isolation` table — no `flush ruleset`, so k3s's own nft chains survive a reload) |
| `etc/sysctl.d/99-camera-no-ipv6.conf` | same | `root:root` `644` | `sudo sysctl --system` (disables IPv6 on NIC2) |
| `etc/dnsmasq.d/cameras.conf` | same | `root:root` `644` | `sudo systemctl restart dnsmasq` (DHCP-only, NIC2) |
| `etc/chrony/conf.d/cameras.conf` | same | `root:root` `644` | `sudo systemctl restart chrony` (serve NTP to the segment) |

**Phase 1.3 (chrony):** `chrony` is **not** in stock Ubuntu 24.04 (it ships
`systemd-timesyncd`, client-only). Install it in Phase 0.3 and confirm it's the active
daemon (`timedatectl` / `chronyc sources`) before relying on this file. The config has
**no `bindaddress`** by design — see the comment in the file and build-plan.md 1.3.

**Phase 1.2 (dnsmasq):** the committed file has no `dhcp-host` MAC pins yet — those are
blocked on the switch port-isolation (1.1b) and collecting camera MACs, and are required
before Frigate (4c). Add them here as cameras are provisioned. See the TODO in the file.

## Keeping these in sync

These are the source of truth, but they're hand-synced with the host — there's no
automated apply. After changing host config, update the matching file here (or pull it
back with `scp minis:/etc/... host/minis/etc/...`) so a future restore reflects reality.
