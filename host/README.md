# Host configuration files

Canonical copies of the **host-level** config written during the manual phases
([build-plan.md](../docs/build-plan.md) Phases 0–1). These are not applied to the
cluster — they configure the Ubuntu host itself, below k3s. The build plan references
these files instead of inlining the config, so this directory is the source of truth.

Files under `etc/` **mirror their on-disk path** (`host/etc/foo` → `/etc/foo`), so a
restore is a copy. `fstab.d/` is the one exception — its contents are *appended* to
`/etc/fstab`, never used to replace it (see Phase 0.4 below).

## Restoring from scratch

Install the OS per [build-plan.md Phase 0.1](../docs/build-plan.md#phase-0--os-baseline-)
(partition layout, user, SSH), then drop these files into place and apply each, in
phase order. All paths are owned by `root`; set the perms noted per file.

### Phase 0 — currently captured

| Repo file | Destination | Owner / perms | Apply |
|---|---|---|---|
| `etc/netplan/00-installer-config.yaml` | `/etc/netplan/00-installer-config.yaml` | `root:root` **`600`** | `sudo netplan generate && sudo netplan apply` |
| `etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | same | `root:root` `644` | (takes effect next boot; stops cloud-init re-rendering netplan) |
| `etc/udev/rules.d/99-coral.rules` | same | `root:root` `644` | `sudo udevadm control --reload-rules && sudo udevadm trigger` |
| `etc/nut/nut.conf` | `/etc/nut/nut.conf` | `root:nut` `640` | see NUT note below |
| `etc/nut/ups.conf` | `/etc/nut/ups.conf` | `root:nut` `640` | " |
| `etc/nut/upsd.conf` | `/etc/nut/upsd.conf` | `root:nut` `640` | " |
| `etc/nut/upsmon.conf` | `/etc/nut/upsmon.conf` | `root:nut` `640` | " (**redacted secret**) |
| `etc/nut/upsd.users` | `/etc/nut/upsd.users` | `root:nut` `640` | " (**redacted secret**) |
| `fstab.d/media-nfs.fstab` | append to `/etc/fstab` | — | `sudo mount -a` then verify `/mnt/media` |

`netplan` **requires `600`** or it refuses the file with a permissions warning. The
secondary `192.168.1.2/24` on `enp87s0` only appears once NIC2 has carrier
(`optional: true`); that's expected.

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

### Phase 1 — not yet captured

These files don't exist on the host yet; add them here when Phase 1 is built:

- `etc/nftables.conf` — the `camera_isolation` table (Phase 1.1). The host currently
  has only the stock Ubuntu default, so it's deliberately **not** committed yet.
- `etc/sysctl.d/99-camera-no-ipv6.conf` — disable IPv6 on `enp87s0` (Phase 1.1).
- `etc/dnsmasq.d/cameras.conf` — camera-segment DHCP (Phase 1.2).
- `etc/chrony/conf.d/cameras.conf` — camera-segment NTP (Phase 1.3).

## Keeping these in sync

These are the source of truth, but they're hand-synced with the host — there's no
automated apply. After changing host config, update the matching file here (or pull it
back with `scp minis:/etc/... host/etc/...`) so a future restore reflects reality.
