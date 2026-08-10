# Direct-Attached Storage Migration Work Log

This is the off-host evidence log for the attended migration described in
[`direct-attached-storage-migration.md`](./direct-attached-storage-migration.md).
Initial evidence was collected from Morpheus on 2026-08-09 CDT before the enclosure
was disconnected. Later sections record the attended physical handoff and controlled
MINIS import, including state-changing md/LVM operations. No filesystem write or
production mount has occurred during the MINIS import as of the latest entry.

## Morpheus pre-cutover status

- MINIS is intentionally powered off.
- Morpheus NFS was intentionally stopped and `nfs-kernel-server` masked after its
  only Kubernetes client was shut down. `/etc/exports` remains intact; there are no
  active kernel exports.
- Before release, `md3` was clean and idle: RAID6, 13 active devices, 15 working
  devices, no failed devices, two spares, `[13/13] [UUUUUUUUUUUUU]`.
- Before release, `sync_action=idle`, `mismatch_cnt=0`, and `degraded=0`.
- Array UUID is `74071d44:3bf857f0:85a3a734:9391a964`; event counter is `590370`.
- The operator confirmed that both NAS and B2 backup/restore validations passed
  before release.
- Final `fuser -vm` output showed only the expected kernel mount reference on each
  of `/mnt/media`, `/mnt/games`, `/mnt/frigate`, and `/mnt/backups`; no user-space
  process held a filesystem.
- Morpheus cleanly released the storage stack on 2026-08-09: `sync` completed, all
  four filesystems unmounted normally, `vgchange -an hoardvg` reported zero active
  LVs, every LV attribute became `-wi-------`, and `mdadm --stop /dev/md3` reported
  a clean stop. Post-release checks found no four bulk mounts, no `hoardvg` mapper
  nodes, no md3 sysfs device, and no md3 entry in `/proc/mdstat`.

## Member identity map

Every member reported array UUID `74071d44:3bf857f0:85a3a734:9391a964`, update
time `2026-08-09 01:19:26 CDT`, event counter `590370`, and a complete
`AAAAAAAAAAAAA` array state.

| Serial | Stable member path | md role | md device UUID | md errors |
|---|---|---:|---|---:|
| `PN1334PCKAJ33S` | `/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN1334PCKAJ33S-part1` | active 0 | `ad62093d:2505c4a1:61d3bc78:b4735523` | 0 |
| `WD-WCC4E0624669` | `/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E0624669-part1` | active 1 | `642b6f04:6134a22a:468b5cc4:3bb0a207` | 0 |
| `WD-WX42D642T1VE` | `/dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WX42D642T1VE` | active 2 | `2c7bad76:b1a39e1d:8022e5ee:b0671ae6` | 0 |
| `S300RM4M` | `/dev/disk/by-id/ata-ST4000DM000-1F2168_S300RM4M-part1` | active 3 | `33c8af42:25422813:012d4493:274d25b1` | 0 |
| `WD-WCC4E7KFCARZ` | `/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E7KFCARZ-part1` | active 4 | `4893faf5:56583716:8474f2a7:953f93bb` | 24 |
| `WD-WXJ2AB2HYH10` | `/dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WXJ2AB2HYH10` | active 5 | `69ebf75d:d6a86a1c:fa326bbe:cf0fec18` | 0 |
| `WD-WCC7K5TY8U9P` | `/dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K5TY8U9P-part1` | active 6 | `b4ad417c:05633d92:2717b07b:243cba0c` | 0 |
| `WD-WCC7K2UFNUDN` | `/dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K2UFNUDN-part1` | active 7 | `7eb8224b:4bc01313:c457ecc3:1e9719b8` | 0 |
| `PK1334PEHGXSTS` | `/dev/disk/by-id/ata-HGST_HDN724040ALE640_PK1334PEHGXSTS-part1` | active 8 | `6775bd65:05bb46c5:1473dbbc:9ff0263a` | 0 |
| `PN2334PCKRNVJB` | `/dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2334PCKRNVJB-part1` | active 9 | `ac1f34c6:c89abe46:b8d8c0c0:a5c719a8` | 0 |
| `Z4F08A4E` | `/dev/disk/by-id/ata-ST4000NM0024-1HT178_Z4F08A4E` | active 10 | `b20d5002:8e11a9f2:5f695b8d:c950d56f` | 0 |
| `Z4F07WQV` | `/dev/disk/by-id/ata-ST4000NM0024-1HT178_Z4F07WQV` | active 11 | `e36ac23f:551f36bd:715140c2:514013f7` | 0 |
| `WD-WX52AA2RSJYC` | `/dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WX52AA2RSJYC` | active 12 | `3e591d13:29f35f27:a74bb834:604714e3` | 0 |
| `WD-WCC4E0631383` | `/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E0631383-part1` | spare | `7b25114a:1fbc346e:97664154:20229cce` | 0 |
| `WD-WX42D540749F` | `/dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WX42D540749F` | spare | `5cae8361:50f23588:c54a6023:8615485a` | 0 |

## LVM and filesystem identity

| Layer | Name | UUID | Size/state |
|---|---|---|---|
| PV | `/dev/md3` | `ZH6Abs-MP7f-ACXX-wqrK-lGXW-chYe-oBYvng` | 36.38 TiB, active |
| VG | `hoardvg` | `vl1tNj-YKYC-2DZC-5bN3-vt4C-l997-Hrhx08` | 36.38 TiB, 10.01 TiB free |
| LV | `medialv` | `0Zp3Vg-CJUc-dPoj-PIBT-IpXm-SGeO-dsjsWJ` | 25 TiB, active/open |
| LV | `games` | `4pN8Th-2Qrw-opmS-kFLN-T5Ma-KgIU-6gqLf2` | 250 GiB, active/open |
| LV | `frigate` | `We7XaQ-zLfd-uRHB-Lqq7-bYRc-ioAj-cVt0mf` | 100 GiB, active/open |
| LV | `backuplv` | `jX3kK2-BI3g-xfuY-wi7U-DQCL-7B9F-FoUoXa` | 1 TiB, active/open |
| legacy LV | `maverick-vdisk0-rootlv` | `j4GFBD-UF97-JWDp-S3RF-Bbqy-pXiJ-Puf5qQ` | 20 GiB, active/not open; leave unmounted |

| Mount | Source | ext4 UUID | Owner/mode |
|---|---|---|---|
| `/mnt/media` | `/dev/mapper/hoardvg-medialv` | `0a94d86c-76a0-44b5-bc52-930d97ab155f` | `1000:100` / `0775` |
| `/mnt/games` | `/dev/mapper/hoardvg-games` | `b43f1bcc-0556-4ed5-b038-765134aba7d3` | `1000:1000` / `0755` |
| `/mnt/frigate` | `/dev/mapper/hoardvg-frigate` | `0b69665d-53ac-4380-815d-6969713940d6` | `1000:1000` / `2775` |
| `/mnt/backups` | `/dev/mapper/hoardvg-backuplv` | `cc1cedb8-ef22-44b5-b1d0-5ca020d72669` | `65534:65534` / `0755` |
| `/mnt/backups/opt` | within `backuplv` | n/a | `65534:65534` / `0700` |

The captured ACLs contain only the owner/group/other entries implied by these modes;
there are no named access ACL entries. `/mnt/frigate` has the setgid directory bit.

## Recovery configuration captured from Morpheus

Mdadm:

```text
ARRAY /dev/md3 metadata=1.2 UUID=74071d44:3bf857f0:85a3a734:9391a964
```

Mounts:

```fstab
/dev/mapper/hoardvg-medialv  /mnt/media   ext4 defaults 0 2
/dev/mapper/hoardvg-games    /mnt/games   ext4 defaults 0 2
/dev/mapper/hoardvg-frigate  /mnt/frigate ext4 defaults 0 2
/dev/mapper/hoardvg-backuplv /mnt/backups ext4 defaults 0 2
```

Exports:

```exports
/mnt/media   10.137.0.0/16(rw,sync,no_subtree_check)
/mnt/games   10.137.0.0/16(rw,sync,no_subtree_check)
/mnt/backups 10.137.0.0/16(rw,sync,no_subtree_check,root_squash,anonuid=65534,anongid=65534)
/mnt/frigate 10.137.0.0/16(rw,sync,no_subtree_check,root_squash,anonuid=1000,anongid=1000)
```

Rollback must unmask `nfs-kernel-server` before starting it, reload the exports, and
verify the four NFS sources on MINIS before restoring workloads.

## SMART and remaining gates

- Operator decision: all 15 extended SMART tests could run concurrently. This was an
  explicit, accepted deviation from the runbook's conservative two-test limit. The
  enclosure remained powered on Morpheus while the tests ran.
- `WD-WCC4E7KFCARZ`: SMART overall health passed; 33 historical device errors, the
  newest at 64,350 power-on hours versus 91,747 current hours; zero reallocated,
  pending, offline-uncorrectable, or CRC errors. Its md error count remains at the
  recorded 24. An extended test started successfully on 2026-08-09 with an expected
  completion time of 17:59 CDT.
- `WD-WX42D540749F`: clean pre-test baseline with zero media, pending-defect, or
  interface errors and a temperature of 26 C.
- On 2026-08-09, the operator confirmed that all 15 extended SMART tests completed
  successfully. No self-test failure was reported. The tests ran concurrently per
  the accepted operator decision above.
- Repository preparation, temporary read-only content verification, offline
  filesystem checks, and service restoration remain open. MINIS `AUTO -all`
  preparation and HBA/tool validation passed their pre-attach checks.

## MINIS pre-attach preparation

Captured after MINIS booted on 2026-08-09 while the enclosure remained connected
only to Morpheus:

- LSI 9207-8e / SAS2308 at PCI `01:00.0`, bound to `mpt3sas`; firmware
  `20.00.07.00`, chip revision `0x05`.
- No md array assembled and no bulk filesystem mounted.
- mdadm 4.3, LVM 2.03.16, e2fsprogs 1.47.0, and smartmontools are installed.
- Effective LVM default is `use_devicesfile=0`; no system devices file exists.
- `/etc/mdadm/mdadm.conf` contains the temporary `AUTO -all` policy and no `ARRAY`
  stanza. Its original was preserved as `mdadm.conf.pre-direct-storage`, and the
  running-kernel initramfs was regenerated at 17:36 CDT.
- The parent `flux-system` Kustomization and the `apps`/`monitoring` children are
  suspended. Restic CronJobs are suspended with no active jobs. Frigate, Plex,
  RomM, and Gluetun deployments have zero desired replicas.
- A boot-started B2 job failed after quiescing because it reached the RomM MariaDB
  dump after RomM had been scaled to zero. It had already created 17 SQLite hot
  backups and a Home Assistant artifact. This expected maintenance-race failure
  does not replace or invalidate the previously passed B2 backup/restore gate.
- Bare `/mnt/media`, `/mnt/games`, `/mnt/frigate`, and `/mnt/backups` are empty,
  root-owned `0755` mountpoints. The old root-owned Frigate preview-cache artifacts,
  all dated 2026-06-28, were moved intact to
  `/mnt/frigate.root-fallback-20260628`; nothing was deleted.
- After the quarantine, `/proc/mdstat` still showed no assembled array.

## MINIS enclosure handoff and controlled import

Captured on MINIS on 2026-08-09 CDT after all 15 extended SMART tests passed and
the enclosure was moved intact from the Morpheus HBA to the MINIS HBA:

- The disks are exposed through the SAS HBA with numeric
  `/dev/disk/by-id/scsi-3...` WWID paths rather than Morpheus's `ata-...` aliases.
- On the first boot with the enclosure attached, the array unexpectedly
  autoassembled as `/dev/md127` despite the temporary `AUTO -all` policy. It was
  `read-auto`, clean, idle, and non-degraded, with all 13 active members and both
  spares present. No bulk filesystem was mounted.
- Udev also autoactivated all five `hoardvg` LVs. The operator chose to proceed from
  the known-clean state rather than investigate the autoassembly path. A controlled
  `vgchange -an hoardvg` left every LV at `-wi-------`, and
  `mdadm --stop /dev/md127` stopped the array cleanly. `/proc/mdstat` was empty and
  `/sys/block/md127` was absent afterward.
- Two member-superblock spot checks after the stop agreed on array UUID
  `74071d44:3bf857f0:85a3a734:9391a964`, update time
  `2026-08-09 11:48:32 CDT`, event counter `590370`, complete array state, and their
  expected active roles 0 and 1.
- The 15 matching numeric SCSI WWID member paths were selected by the exact recorded
  array UUID. The array was then explicitly assembled as `/dev/md3` with
  `--readonly`, reporting 13 drives and two spares.
- Controlled `/dev/md3` state is `readonly`, `sync_action=idle`, `degraded=0`, and
  clean RAID6 with `[13/13] [UUUUUUUUUUUUU]`. It has 13 active devices, 15 working
  devices, zero failed devices, two spares, UUID
  `74071d44:3bf857f0:85a3a734:9391a964`, and event counter `590370`. No resync,
  recovery, reshape, or check is running.
- LVM exposed the four intended filesystem LVs. `blkid` confirmed ext4 with 4096-byte
  blocks and exact filesystem UUIDs:

  | LV | Filesystem UUID |
  |---|---|
  | `medialv` | `0a94d86c-76a0-44b5-bc52-930d97ab155f` |
  | `games` | `b43f1bcc-0556-4ed5-b038-765134aba7d3` |
  | `frigate` | `0b69665d-53ac-4380-815d-6969713940d6` |
  | `backuplv` | `cc1cedb8-ef22-44b5-b1d0-5ca020d72669` |

- `maverick-vdisk0-rootlv` remains explicitly out of scope and must not be mounted.
- Next gate: mount each intended LV individually at `/mnt/migration-check` with
  `ro,noload`, compare ownership, ACLs, shallow directory counts, and representative
  hashes to the baselines below, and unmount it before checking the next LV.

## Low-I/O pre-unmount fingerprints

Captured as user `charlie` while both filesystems and SMART tests were active. The
directory counts and listing fingerprints cover at most two levels. Expected
permission denials excluded `lost+found` on media and backups and `/mnt/backups/opt`;
the same user and scope must be used for a like-for-like post-migration comparison.

| Mount | Used | Shallow directory count | Shallow listing SHA-256 |
|---|---:|---:|---|
| `/mnt/media` | 18 TiB / 25 TiB (71%) | 1,094 | `6ad763bd5e7e8f23e076d5746b47d0008ef1c0291c7414854d4a524208f65f57` |
| `/mnt/games` | 73 GiB / 246 GiB (32%) | 40 | `6add988c1c196aa1a826d4c734a1e2f59361ac6618173c877a0f4af5ec929cc4` |
| `/mnt/frigate` | 51 GiB / 98 GiB (55%) | 47 | `71c51f558ab0892348f5cff82427e0d677ef360791ae4a180a9e74acda7b33ac` |
| `/mnt/backups` | 177 GiB / 1,008 GiB (19%) | 50 | `92492acf3c545e36242d5d6a32316ff9eddfe2576eea2cf9948aac9aeba0bd91` |

Representative content hashes:

| Mount | File | SHA-256 |
|---|---|---|
| `/mnt/media` | `Pictures/Summer 2004/P1010017.JPG` | `7c71729cd59dd2308d22b67bbd8b4638bfd755922e05c954ff67833478dafa9a` |
| `/mnt/games` | `bios/ps2/SCPH-30000_BIOS_V4_JAP_150.ROM1` | `42cd213f274ca06f8ed37f5781a1b1e075e4e45dfd26bbeeceb6666328145001` |
| `/mnt/frigate` | `clips/amcrest_105_50-1785789581.394572-pgokdg.jpg` | `1dbe5f58dc383f710baf3510486fba2cb91441d7658daf8aab78bd9ffc1ffba2` |
| `/mnt/backups` | `snapshots/daily.6/ryze/var/.updated` | `29306e2388433747903747f00172bc91a80bc1ae1a1719b05fa0438532089bde` |
