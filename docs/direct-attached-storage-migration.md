# Direct-Attached Bulk Storage Migration Runbook

Move the existing RAID6 array from Morpheus's SAS HBA to the LSI 9207-8e in
`minis`, then mount its ext4 filesystems directly in the same locations currently
provided by NFS. This is the next operational milestone in the
[build plan](./build-plan.md#immediate-next-step-direct-attached-bulk-storage-migration).

**Status:** planned, not yet executed. This is an attended maintenance procedure,
not an unattended script. Record command output in an off-host work log as each
gate passes.

## Scope and expected impact

The migration moves the existing mdadm/LVM/ext4 stack in place; it does not copy or
reformat data. Kubernetes `hostPath` paths remain unchanged:

| Mount | Consumer | LV / size | Expected filesystem |
|---|---|---|---|
| `/mnt/media` | Plex and the download stack | `medialv` / 25 TiB | `0a94d86c-76a0-44b5-bc52-930d97ab155f` |
| `/mnt/games` | RomM | `games` / 250 GiB | `b43f1bcc-0556-4ed5-b038-765134aba7d3` |
| `/mnt/frigate` | Frigate recordings | `frigate` / 100 GiB | `0b69665d-53ac-4380-815d-6969713940d6` |
| `/mnt/backups` | Local Restic repository | `backuplv` / 1 TiB | `cc1cedb8-ef22-44b5-b1d0-5ca020d72669` |

Expected mount-root ownership and modes are `/mnt/media` `1000:100`/`0775`,
`/mnt/games` `1000:1000`/`0755`, `/mnt/frigate` `1000:1000`/`2775`, and
`/mnt/backups` `65534:65534`/`0755`. The Restic directory
`/mnt/backups/opt` is `65534:65534`/`0700`.

The 25 TiB media filesystem receives a forced offline check, so the maintenance
window may last many hours or several days. Home Assistant, MQTT, Flux, and the core
monitoring stack may remain available. Frigate, Plex, RomM, the download stack, and
local Restic backups remain stopped until direct storage has passed validation and a
MINIS reboot.

## Recorded storage identity

Treat these identifiers, rather than `/dev/sdX` names, as authoritative:

| Layer | Recorded identity |
|---|---|
| MINIS HBA | LSI SAS9207-8e, SAS2308, `mpt3sas`, firmware `20.00.07.00` |
| md array | `/dev/md3`, RAID6, metadata 1.2, UUID `74071d44:3bf857f0:85a3a734:9391a964` |
| md membership | 13 active members and 2 hot spares; healthy state is `[13/13] [UUUUUUUUUUUUU]` |
| LVM PV | UUID `ZH6Abs-MP7f-ACXX-wqrK-lGXW-chYe-oBYvng` on md3 |
| LVM VG | `hoardvg` |
| Active LVs | `medialv`, `games`, `frigate`, `backuplv` |
| Legacy LV | `maverick-vdisk0-rootlv`; leave unmounted and otherwise unchanged |

One current member, serial `WD-WCC4E7KFCARZ`, has accumulated 24 md errors. Its
SMART health and error trend are a specific cutover gate, not a reason to renumber
or replace members during this migration.

## Safety invariants

- The enclosure must never be connected to Morpheus and MINIS simultaneously.
- Never use `mdadm --create`, `mdadm --force`, or accept degraded assembly.
- Never identify a member by `/dev/sdX`; use serial-numbered `/dev/disk/by-id` paths
  and the captured md metadata.
- Never run `e2fsck` on a mounted filesystem.
- Do not let Kubernetes access an unmounted `/mnt/...` directory backed by the MINIS
  root filesystem. The systemd automounts provide the fail-closed boundary.
- Stop at any failed gate. Do not improvise a RAID repair inside this runbook.

## 1. Preconditions — several days before cutover

### 1.1 Finish and validate the current md check

On Morpheus, wait until the current check is completely idle:

```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md3
cat /sys/block/md3/md/sync_action
cat /sys/block/md3/md/mismatch_cnt
cat /sys/block/md3/md/degraded
```

Proceed only when all of the following are true:

- `sync_action` is `idle`.
- `mismatch_cnt` and `degraded` are both `0`.
- md3 has all 13 active members and both spares.
- No member error count increased during the check.

### 1.2 Validate every disk and SAS path

Capture the serial-to-device map, then run `smartctl -x` using stable by-id paths:

```bash
lsblk -d -o NAME,SERIAL,MODEL,SIZE,HCTL
ls -l /dev/disk/by-id/
sudo smartctl -x /dev/disk/by-id/<recorded-disk-id>
sudo smartctl -t long /dev/disk/by-id/<recorded-disk-id>
```

Repeat both commands for all 15 disks, running at most two long tests concurrently
and watching enclosure temperatures. Wait for every test to complete, then collect a
second `smartctl -x` report. Give `WD-WCC4E7KFCARZ` additional review. Abort if any
disk reports failed health, pending sectors, offline uncorrectable sectors, new media
errors, or an increasing md error count. Record link/CRC errors separately;
unexplained or increasing link errors must be resolved before moving the enclosure.

### 1.3 Prove backups and capture recovery state

Run both backup paths and their restore validations using the Phase 5 runbooks:

```bash
./runbooks/phase5/04-run-manual-backup.sh
./runbooks/phase5/05-validate-restore.sh
./runbooks/phase5/08-run-manual-b2-backup.sh
./runbooks/phase5/09-validate-b2-restore.sh
```

Also restore representative files from the separately backed-up hard-to-replace
volumes. Do not treat a successful backup command without a readable restore as a
passed gate.

Save the following outputs off both hosts and outside the JBOD:

```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md3
sudo mdadm --examine --scan
sudo mdadm --examine /dev/disk/by-id/<recorded-member-id>-part1
sudo pvs -o+pv_uuid,devices
sudo vgs -o+vg_uuid
sudo lvs -a -o+lv_uuid,devices
sudo blkid
findmnt --mountpoint /mnt/media
findmnt --mountpoint /mnt/games
findmnt --mountpoint /mnt/frigate
findmnt --mountpoint /mnt/backups
sudo getfacl -p /mnt/media /mnt/games /mnt/frigate /mnt/backups
sudo exportfs -v
```

Record all 15 member serials, roles, event counters, and `/dev/disk/by-id` paths.
Copy Morpheus's fstab, mdadm configuration, and exports file into the off-host
recovery bundle. Capture representative file hashes and directory counts from each
filesystem for post-migration comparison.

### 1.4 Prepare the repository and MINIS

Before the outage, implement and review the host/monitoring changes described in
[Post-migration repository work](#7-post-migration-repository-work). Do not activate
the new fstab entries while NFS still owns the mountpoints.

To prevent an unattended first assembly, temporarily add `AUTO -all` to MINIS's
`/etc/mdadm/mdadm.conf`, leave out the md3 `ARRAY` stanza, and run
`sudo update-initramfs -u`. The final explicit array stanza is installed only after
the read-only import and filesystem checks pass.

Confirm the new HBA and required tools on MINIS:

```bash
lspci -nnk -s 01:00.0
sudo modinfo mpt3sas | head
mdadm --version
lvm version
cat /etc/lvm/lvm.conf | grep -n use_devicesfile
```

The expected adapter is an LSI 9207-8e/SAS2308 using `mpt3sas` firmware P20. LVM's
devices file remains disabled, so `hoardvg` requires no manual allow-list entry.

## 2. Quiesce MINIS workloads

Use the admin kubeconfig explicitly. Suspend reconciliation before scaling anything:

```bash
kubectl config current-context
flux suspend kustomization apps
flux suspend kustomization monitoring
kubectl -n monitoring patch cronjob restic-nas-backup --type merge \
  -p '{"spec":{"suspend":true}}'
kubectl -n monitoring patch cronjob restic-b2-backup --type merge \
  -p '{"spec":{"suspend":true}}'
kubectl -n monitoring get jobs,pods
```

Wait for any active Restic Job to finish; do not terminate it mid-write. Then stop
the bulk-storage consumers:

```bash
kubectl -n frigate scale deployment/frigate --replicas=0
kubectl -n media scale deployment/gluetun --replicas=0
kubectl -n media scale deployment/romm --replicas=0
kubectl -n media scale deployment/plex --replicas=0
kubectl -n frigate get pods -o wide
kubectl -n media get pods -o wide
```

The final pod listings and the following host checks are authoritative:

```bash
sudo fuser -vm /mnt/media /mnt/games /mnt/frigate /mnt/backups
findmnt --mountpoint /mnt/media
findmnt --mountpoint /mnt/games
findmnt --mountpoint /mnt/frigate
findmnt --mountpoint /mnt/backups
```

Only expected kernel/NFS references may remain. Stop the NFS automount and mount
units, then confirm nothing is mounted:

```bash
sudo systemctl stop mnt-media.automount mnt-games.automount \
  mnt-frigate.automount mnt-backups.automount
sudo systemctl stop mnt-media.mount mnt-games.mount \
  mnt-frigate.mount mnt-backups.mount
findmnt --mountpoint /mnt/media
findmnt --mountpoint /mnt/games
findmnt --mountpoint /mnt/frigate
findmnt --mountpoint /mnt/backups
```

## 3. Release the array from Morpheus

Confirm Morpheus has no established NFS connections and no process has an open file
on the four filesystems. Then stop NFS and release every storage layer from the top
down:

```bash
sudo ss -tnp state established '( sport = :2049 )'
sudo exportfs -ua
sudo systemctl stop nfs-kernel-server
sudo fuser -vm /mnt/media /mnt/games /mnt/frigate /mnt/backups
sudo umount /mnt/frigate
sudo umount /mnt/games
sudo umount /mnt/backups
sudo umount /mnt/media
sudo vgchange -an hoardvg
sudo mdadm --stop /dev/md3
cat /proc/mdstat
```

Do not use a lazy or forced unmount. The four filesystems, `hoardvg`, and md3 must all
be inactive. Power down Morpheus and the JBOD if the enclosure does not explicitly
support the required hot-plug sequence.

**Hold point:** verify the SAS cable is physically disconnected from Morpheus before
connecting it to MINIS.

## 4. Attach and import on MINIS

Connect the enclosure to the MINIS HBA and power it in the enclosure manufacturer's
documented order. Boot or rescan MINIS, then inspect discovery before assembly:

```bash
lsblk -d -o NAME,SERIAL,MODEL,SIZE,HCTL
ls -l /dev/disk/by-id/
sudo journalctl -k -b | grep -E 'mpt3sas|scsi|sas|reset|timeout|error'
cat /proc/mdstat
```

Require all 15 recorded serials and no repeated link resets or timeouts. The
temporary `AUTO -all` policy should leave every array inactive. If udev nevertheless
autoassembled md3, stop and investigate before continuing; do not accept an
unattended first assembly even if it appears healthy.

Using the 15 exact partition paths from the recovery bundle, assemble only the
recorded array read-only:

```bash
sudo mdadm --assemble --readonly /dev/md3 \
  --uuid=74071d44:3bf857f0:85a3a734:9391a964 \
  <all-15-recorded-/dev/disk/by-id/...-part1-paths>
cat /proc/mdstat
sudo mdadm --detail /dev/md3
```

Require 13 active members, two spares, matching event counters, and no resync,
recovery, or check. Confirm LVM identity and activate the VG:

```bash
sudo pvscan --cache
sudo pvs -o+pv_uuid,devices
sudo vgchange -ay hoardvg
sudo lvs -a -o+lv_uuid,devices
sudo blkid /dev/hoardvg/medialv /dev/hoardvg/games \
  /dev/hoardvg/frigate /dev/hoardvg/backuplv
```

Mount one filesystem at a time at a temporary location using `ro,noload`, compare
representative hashes, ownership, ACLs, and directory counts, then unmount it. Repeat
for all four LVs:

```bash
sudo mkdir -p /mnt/migration-check
sudo mount -o ro,noload /dev/hoardvg/frigate /mnt/migration-check
findmnt /mnt/migration-check
sudo getfacl -p /mnt/migration-check
sudo umount /mnt/migration-check
```

Do not mount or modify `maverick-vdisk0-rootlv`.

## 5. Forced offline filesystem checks

After all read-only identity checks pass, verify no LV is mounted and make md3
writable:

```bash
findmnt -S /dev/hoardvg/frigate
findmnt -S /dev/hoardvg/games
findmnt -S /dev/hoardvg/backuplv
findmnt -S /dev/hoardvg/medialv
sudo mdadm --readwrite /dev/md3
```

Run the checks from smallest to largest and preserve their logs off-host. Run one
command at a time, record its exit status immediately, and do not begin the next LV
until the current one has passed:

```bash
sudo e2fsck -f -p /dev/hoardvg/frigate
MIG_E2FSCK_STATUS=$?
printf 'e2fsck exit status: %s\n' "$MIG_E2FSCK_STATUS"
```

Accept only exit status 0 (clean) or 1 (errors corrected). Rerun any filesystem that
returned 1 until it returns 0. Then repeat the same command/status sequence for
`/dev/hoardvg/games`, `/dev/hoardvg/backuplv`, and finally
`/dev/hoardvg/medialv`. Stop and review statuses 2, 4, 8, 16, 32, or 128; do not mount
that filesystem.

## 6. Activate direct mounts and restore service

The final MINIS fstab entries use these values:

```fstab
UUID=0a94d86c-76a0-44b5-bc52-930d97ab155f /mnt/media   ext4 defaults,nofail,x-systemd.automount,x-systemd.device-timeout=60s,x-systemd.mount-timeout=60s 0 2
UUID=b43f1bcc-0556-4ed5-b038-765134aba7d3 /mnt/games    ext4 defaults,nofail,x-systemd.automount,x-systemd.device-timeout=60s,x-systemd.mount-timeout=60s 0 2
UUID=0b69665d-53ac-4380-815d-6969713940d6 /mnt/frigate  ext4 defaults,nofail,x-systemd.automount,x-systemd.device-timeout=60s,x-systemd.mount-timeout=60s 0 2
UUID=cc1cedb8-ef22-44b5-b1d0-5ca020d72669 /mnt/backups  ext4 defaults,nofail,x-systemd.automount,x-systemd.device-timeout=60s,x-systemd.mount-timeout=60s 0 2
```

The mdadm configuration must contain the exact array identity:

```text
ARRAY /dev/md3 metadata=1.2 UUID=74071d44:3bf857f0:85a3a734:9391a964
```

Replace the temporary `AUTO -all` policy with the reviewed canonical mdadm file and
install the reviewed direct-mount fstab on MINIS. Then:

```bash
sudo update-initramfs -u
sudo systemctl daemon-reload
sudo systemctl start mnt-media.automount mnt-games.automount \
  mnt-frigate.automount mnt-backups.automount
sudo ls /mnt/media /mnt/games /mnt/frigate /mnt/backups >/dev/null
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS \
  --target /mnt/media
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS --target /mnt/games
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS --target /mnt/frigate
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS --target /mnt/backups
cat /proc/mdstat
```

Every source must resolve to the expected filesystem UUID/LV with `ext4`; none may
resolve to the MINIS root filesystem. Create and remove a uniquely named probe file
in each mount, then confirm the recorded numeric ownership and ACLs are unchanged.

Reboot MINIS once while the four application deployments remain stopped. After the
reboot, require automatic md3 assembly, healthy `hoardvg` activation, all four exact
mounts, and a healthy core cluster before restoring consumers.

Restore applications in this order:

```bash
kubectl -n frigate scale deployment/frigate --replicas=1
kubectl -n media scale deployment/plex --replicas=1
kubectl -n media scale deployment/romm --replicas=1
kubectl -n media scale deployment/gluetun --replicas=1
flux resume kustomization apps
flux reconcile kustomization apps --with-source
```

Validate Frigate recording/playback, Plex scan/stream/Quick Sync, RomM browsing, and
a download/import/hardlink/atomic-rename cycle. Then restore monitoring and backups:

```bash
flux resume kustomization monitoring
flux reconcile kustomization monitoring --with-source
kubectl -n monitoring patch cronjob restic-nas-backup --type merge \
  -p '{"spec":{"suspend":false}}'
kubectl -n monitoring patch cronjob restic-b2-backup --type merge \
  -p '{"spec":{"suspend":false}}'
./runbooks/phase5/04-run-manual-backup.sh
./runbooks/phase5/05-validate-restore.sh
```

Verify Prometheus sees all four filesystems and md3, and that no filesystem-device or
RAID alerts fire. Observe SMART, SAS, mdadm, filesystem, workload, and backup health
for 24–48 hours.

After the observation gate passes, disable Morpheus's four fstab entries, NFS
exports, mdcheck timers, and mdadm autoassembly (`AUTO -all`). Preserve its original
configuration in the off-host recovery bundle, but do not leave Morpheus able to
claim the array automatically.

## 7. Post-migration repository work

The migration is not complete until the repository matches the live design:

- Replace the four NFS entries in `host/minis/etc/fstab` with the UUID entries above.
- Add canonical MINIS mdadm configuration and regenerate initramfs after installing
  it on the host.
- Schedule md checks for 10:00 local on the first Sunday of each month, with a daily
  10:00 continuation while a check remains incomplete.
- Convert NFS-specific Phase 0, Phase 1, Phase 2, Phase 3, and Phase 5 validations to
  verify the exact direct-mounted UUIDs and reject root-filesystem fallthrough.
- Replace NFS-only alerts with mount-path filesystem alerts. Retain the upstream
  `NodeRAIDDegraded` and `NodeRAIDDiskFailure` rules and add stalled-check visibility.
- Update architecture, operations, and workload comments from remote NFS to the
  direct-attached mdadm/LVM/ext4 design. Keep Kubernetes host paths unchanged.

## Rollback

Rollback is available because the same array can be moved back without copying data,
but it always requires a clean single-host handoff.

Rollback immediately for missing members/spares, inconsistent event counters,
degraded assembly, repeated SAS resets, unexpected filesystem identity, serious
`e2fsck` status, or failed application writes.

1. Suspend Flux and backups, stop the four consumer deployments, and verify no open
   files on MINIS.
2. Unmount the four filesystems, run `vgchange -an hoardvg`, and stop md3 cleanly.
3. Power down/isolate the enclosure and disconnect it from MINIS.
4. Connect it only to Morpheus, assemble the recorded array without `--force`, activate
   `hoardvg`, mount the four filesystems, and restore NFS exports.
5. Restore the saved MINIS NFS fstab, reload systemd, trigger the four automounts, and
   verify their NFS sources before restarting applications.
6. Resume workloads, backups, and Flux only after the original NFS path passes the
   same application and restore validations.

If rollback occurs after `e2fsck` or application writes, the procedure is unchanged:
cleanly release the current owner before moving the cable. Never attempt to reconcile
two independently assembled copies because there is only one authoritative array.
