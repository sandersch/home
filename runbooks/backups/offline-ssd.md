# Attended offline SSD backups

The tooling is implemented; **neither physical SSD is recorded as enrolled here**.
Do not enable the staged alerts until A and B have real successful enrollments.
Run on `minis` with exactly one selected USB SSD attached. This workflow does not
change production schedules, online retention, or the original rsnapshot tree.
There is no SSD timer, automount, fstab entry, `forget`, `prune`, or automatic unlock.

## Install and inspect

Install host prerequisites (`python3-yaml`, util-linux, e2fsprogs, cryptsetup,
MariaDB server/client tools), then run from a reviewed checkout on minis:

```sh
sudo runbooks/backups/install-offline-ssd.sh
sudo offline-ssd inspect --drive A --device /dev/disk/by-id/usb-EXACT_DEVICE
```

The installer reuses the upstream-checksum-verified Restic 0.19.1 installer and
copies released vault contracts plus the appstate required-export inventory.
Reinstall after a reviewed contract update. It installs immutable, empty mountpoints
under `/mnt/offline/{A,B}` and creates no backup schedule. `inspect` reports hardware,
signatures, mount use and existing enrollment; it does not change the device.
The NAS backup-volume identity and sentinel guard must pass before control/source
access. Restic uses two CPU threads, nice 19, idle I/O priority, a two-minute lock
retry and a process lock. A conflicting production maintenance job may require a
later retry. Never unlock a repository just to make this workflow proceed.

## Provision and enroll, one drive per session

1. Label the physical drives A and B. Keep the other drive off-site, even during
   initial enrollment. Return the completed drive before retrieving the other.
2. Use `inspect` and the physical device label to identify the **whole** USB disk.
   Record its serial/WWN and stable by-id name. Provisioning rejects mounted devices
   and children, active holders, swap, LVM/RAID/LUKS signatures and enrolled hardware.
3. Run the destructive provisioning command in an interactive terminal. The prompt
   requires the exact by-id path; review it before typing.

   ```sh
   sudo offline-ssd provision --drive A --device /dev/disk/by-id/usb-EXACT_DEVICE
   ```

   This creates GPT, one ext4 partition and label `OFFLINE-A` (`OFFLINE-B` for B).
   The hardware identity, PARTUUID, filesystem UUID and label are saved in
   `/mnt/backups/.control/offline/A.json`, root:root 0600. The control directory is
   root:root 0700. No credentials are saved there.
4. Unlock and validate the encrypted vault through its existing attended procedure.
   Its `.restore-tests` directory is the only location for plaintext vault restores.
   Ensure fresh NAS vault/appstate snapshots exist (at most 8/30 hours old).
5. Run:

   ```sh
   sudo offline-ssd enroll --drive A
   ```

   Enter the three NAS repository passwords silently. Enter each of the three **new
   distinct** SSD passwords twice; a mismatch stops before any destination repository
   is initialized. The second enrollment also asks for the other SSD's passwords from the
   password manager to check all six differ. Store all six destination passwords in
   the external password manager **and both separately stored break-glass cards**.
   Store neither card with either drive. Never enter the Strongbox master password
   into this CLI. Confirm the other drive remains off-site and credential storage.
6. The tool initializes format-2 repositories with the matching source chunker
   parameters, recording each repository ID immediately. It copies exact eligible
   vault/appstate checkpoints and the exact accepted static legacy snapshot.
   Enrollment runs `check --read-data` on all three repositories, restores KDBX and
   a representative document inside the encrypted vault, validates appstate exports
   (including SQLite/k3s, HA tar and isolated RomM import/check), and verifies legacy
   metadata, symlinks, xattrs, sample hashes and sampled hardlink relationships against
   saved NAS acceptance evidence. Open KDBX in Strongbox and inspect the document and
   historical samples before typing `VERIFIED` at each prompt.
7. Wait for the sanitized completion JSON with `stage: complete`,
   `clean_unmount: true`, and a genuine success timestamp. Only success after `sync`
   and normal unmount counts. Return A off-site, then repeat the entire session for B.

Private restore scratch needed for attended inspection is retained for deliberate
cleanup. Vault scratch stays on the encrypted vault. Appstate verification scratch
is removed immediately after verification (including on failure) because the restored
k3s database contains plaintext Kubernetes Secrets. Legacy scratch lives under
`/mnt/backups/.control/offline/verify-*`. Do not commit scratch, inventories, private
paths, passwords, raw command logs, or document names. The source legacy inventory,
`candidate.json` and `accepted.json` must remain available for future verification,
even after any separately authorized retirement of the original rsnapshot tree.
Destination verification never updates NAS archive acceptance.

## Quarterly rotation

Normal rotation begins **A in Q4 2026**, after both enrollments. Use A in Q2/Q4 and
B in Q1/Q3, with quarters determined in America/Chicago:

```sh
sudo offline-ssd rotate --drive A
```

Before each rotation, unlock the encrypted vault using its existing attended
procedure and confirm it is mounted. The command checks that encrypted restore
scratch mount before beginning any checkpoint copy or other long-running work.

The command validates hardware, partition, filesystem and repository identities,
rejects substitutions, nested mounts and read-only filesystems, and freezes exact
source IDs and canonical lineages before changing source tags. Vault needs released
contract validation, validation-ledger evidence and no blocking hold/resolution.
Appstate uses its contract version, required export inventory and export timestamp;
there is no appstate JSON backup manifest. Tagging adds
`offline-checkpoint-YYYY-Qn`, preserving all existing tags, then resolves the new IDs.
Copies are independently listed and validated at the destination. Restic's
[tag implementation](https://raw.githubusercontent.com/restic/restic/v0.19.1/cmd/restic/cmd_tag.go)
retains `original` across tag changes; matching also checks tree, time, host and paths.

The capacity gate budgets the selected logical data at 120% plus a 10% filesystem
reserve. It deliberately overestimates deduplicated copy requirements. Capacity
failure needs operator action; it never triggers pruning. Existing successful copies
survive retries. Ordinary rotations do not copy the legacy archive again.

Full verification is automatic on **A in Q4 of even years** and **B in Q3 of odd
years**. A missed verification runs at that drive's next attended rotation. Each
SSD is checked every two years, with one scheduled full verification across the pair
per year. Initial verification is always mandatory. A failed annual check blocks
combined operation success. The annual verification timestamp is separate from the
quarterly success timestamp. Once the complete verification result is durably
recorded, a retry reuses it instead of repeating full repository reads, restores,
and attended inspection prompts. If interrupted before that result is saved, those
gates run again because their completion was not recorded.

## Interruptions and evidence

Rerun the **same command and drive**. It resumes the recorded operation, including
its original quarter and frozen snapshots; it never silently selects newer data.
Do not delete pending operation records to bypass a failed freshness/eligibility gate.
After an interruption, the SSD may remain mounted. The CLI verifies that mount on
retry. If stopping for the day, inspect the recorded device, run `sync -f` on the
verified mount, and unmount normally; success remains pending. Never use lazy or
forced unmount as a substitute for the completion gate.

An interruption between `init` and recording the ID intentionally blocks automatic
adoption. Provisioning similarly records intent before formatting. Preserve the
records and disk; investigate exact identity and partial state in a separately
reviewed attended recovery. Do not reformat or manually invent enrollment IDs.
A missing source checkpoint or stale source blocks only a copy that is not yet
present on the SSD. On resume, an exact matching destination copy is revalidated
against its frozen lineage and dataset contract without requiring the NAS source
to remain fresh or present. Ambiguous lineage, a new vault validation hold, lost
mount, or wrong identity remains a stop condition requiring operator action.

A completed same-quarter rerun reports existing evidence without updating its time.
A crash after normal unmount but before the durable completion write requires
remount/revalidation and another clean unmount. It does not infer success from absence
of a mount. A completed enrollment can recover its final enrollment marker from the
successful operation if that last state write was interrupted.

```sh
sudo offline-ssd status
sudo offline-ssd status --drive A
sudo offline-ssd status --rebuild-metrics
```

Status and successful command output include only drive, quarter, exact checkpoint
IDs/lineages, snapshot times, capacity, repository usage, verification time, elapsed
time and clean-unmount outcome. Copy that sanitized evidence into the backup drill
table only after actual acceptance. Do not replace pending physical gates with test
fixture results. `status --rebuild-metrics` atomically rebuilds both timestamp series
from successful records; missing state emits zero and failures preserve prior success.

After both genuine enrollment successes, verify the metric file is collected by
node-exporter, then add `../offline` to
`infrastructure/monitoring/configs/kustomization.yaml` in a reviewed GitOps commit.
The staged rules warn if the newest drive exceeds 120 days or all metrics are absent,
and if either drive exceeds 210 days or its series is absent. Do not synthesize
initial timestamps. Alert activation is deliberately pending physical acceptance.

## Independent recovery on Linux

Recovery needs a retrieved SSD, its break-glass passwords and a Linux machine with
Restic 0.19.1. It does **not** require minis, Kubernetes, the NAS, or its control
records. The SSD filesystem contains only the three self-contained encrypted repos.
Use a private trusted recovery machine and identify the USB disk by its physical
label, serial, partition UUID and filesystem UUID from the cards/enrollment notes.
Inspect with `lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,UUID,PARTUUID,LABEL,MOUNTPOINTS`.
Do not provision, enroll, format or run repair during recovery. Use a root shell for
Restic so the repositories are readable and restored numeric ownership is preserved.

```sh
sudo -i
umask 077
mkdir -p /mnt/recovered-ssd
mount -t ext4 -o ro,noload,nodev,nosuid,noexec /dev/disk/by-uuid/EXACT_UUID /mnt/recovered-ssd
findmnt /mnt/recovered-ssd
# Restic prompts silently. --no-lock permits read-only media; --no-cache avoids disk cache.
restic --no-lock --no-cache -r /mnt/recovered-ssd/vault snapshots --json
restic --no-lock --no-cache -r /mnt/recovered-ssd/appstate snapshots --json
restic --no-lock --no-cache -r /mnt/recovered-ssd/legacy-rsnapshot snapshots --json
```

Select the **full 64-character destination ID**, matching checkpoint tag, host,
paths and snapshot timestamp; do not blindly use `latest`. Independently inspect
`cat config` and `cat snapshot FULL_ID` if comparing recorded identities.
Restore vault content only onto a validated encrypted recovery filesystem, never
onto the SSD. Use a fresh private (0700) directory for each restore:

```sh
umask 077
# These are example target paths on the recovery machine, prepared and verified by the operator.
restic --no-lock --no-cache -r /mnt/recovered-ssd/vault restore FULL_VAULT_ID --target /encrypted-recovery/vault-stage
restic --no-lock --no-cache -r /mnt/recovered-ssd/appstate restore FULL_APPSTATE_ID --verify --target /private-recovery/appstate-stage --exclude /data/opt/romm/db
restic --no-lock --no-cache -r /mnt/recovered-ssd/appstate snapshots --json FULL_APPSTATE_ID > /private-recovery/appstate-stage/offline-snapshot.json
restic --no-lock --no-cache -r /mnt/recovered-ssd/legacy-rsnapshot restore FULL_LEGACY_ID --target /private-recovery/legacy-stage
```

Verify KDBX opens and representative documents/history are readable. Appstate restores
`data/opt` (excluding the live-captured `data/opt/romm/db`) and `work/hot-dumps`, including
the logical RomM dump. Preserve those together. Hand the staged tree into the
[disaster-recovery procedure](../disaster-recovery/README.md): validate the hot-dump
contract, overlay SQLite exports, import/check RomM, validate the HA archive, and use
the consistent `work/hot-dumps/k3s/state.db.sqlite-backup` for the attended k3s rebuild.
On the rebuilt minis, follow disaster recovery's GitOps suspension and empty `/opt`
preflight. Transfer the verified stage with numeric ownership, xattrs and hardlinks
onto the recovery staging filesystem at
`RECOVERY_STAGE_ROOT/homelab-recovery/FULL_APPSTATE_ID`. Set:

```sh
export RECOVERY_SOURCE=offline
export RECOVERY_SNAPSHOT=FULL_APPSTATE_ID
export RECOVERY_STAGE_ROOT=/mnt/media
runbooks/disaster-recovery/00-preflight.sh
runbooks/disaster-recovery/02-restore-opt.sh
```

`RECOVERY_STAGE_ROOT` must be its own mounted filesystem, as required by the existing
DR guard. The offline path checks `offline-snapshot.json` against the exact selected
ID, host, paths and tags, validates the hot-dump contract, and asks for attended stage
adoption. It never starts a repository-fetch Job or needs NAS/B2 credentials. Continue
with DR steps 03–07 for RomM import, state validation and guarded application resume.
These activation steps run on the rebuilt host; the independent SSD restore above
requires none of its services. The server token is intentionally absent; recover required bootstrap credentials from
the independent password-manager/card sources. Do not run a NAS-fetch phase over an
already restored SSD stage, and do not start applications on unvalidated raw files.
Unmount the retrieved drive normally when finished and return it off-site.

## Acceptance checklist

| Gate | A | B |
|---|---|---|
| Physical identity and guarded provisioning | pending | pending |
| Six unique passwords saved in manager and both cards | pending | pending |
| Exact checkpoint seed and legacy copy | pending | pending |
| Full reads, representative restores, Strongbox open | pending | pending |
| Independent recovery drill and sanitized evidence | pending | pending |
| Clean unmount and return off-site | pending | pending |

Monitoring activation remains pending both columns. Mail archival, workstation-home
SSD copies, online retention changes and rsnapshot source deletion are out of scope.
