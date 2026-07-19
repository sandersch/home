# Phase 5 - NAS and offsite backups

Scripts for the backup-first slice of
[build-plan.md Phase 5](../../docs/build-plan.md#phase-5--observability--expansion-).

## Order

Run these after Phase 4 is validated and the NAS has a dedicated backup export at
`backups.nfs.service.matrix:/mnt/backups`.

| Script | Purpose |
|---|---|
| `00-preflight.sh` | Validate Phase 5 backup manifests and kustomize output |
| `01-backups-nfs-mount.sh` | Add `/mnt/backups` to `/etc/fstab`, mount it, and verify write access |
| `02-encrypt-restic-secret.sh` | Create the SOPS-encrypted `monitoring/restic-nas` Secret |
| `03-init-restic-nas-repo.sh` | Initialize `/mnt/backups/opt` as a Restic repo |
| `04-run-manual-backup.sh` | Run one backup immediately from the CronJob |
| `05-validate-restore.sh` | Check the latest snapshot, RomM dump, HA backup artifact, and a SQLite dump |
| `06-encrypt-restic-b2-secret.sh` | Generate the independent SOPS-encrypted B2 repository Secret |
| `07-init-restic-b2-repo.sh` | Reconcile monitoring and initialize the B2 repository idempotently |
| `08-run-manual-b2-backup.sh` | Run the weekly B2 CronJob manually |
| `09-validate-b2-restore.sh` | Restore representative B2 artifacts without the NAS |

Both repositories have passed initialization, manual backup, and representative restore
validation. The nightly NAS and first naturally scheduled weekly B2 backups both
completed successfully on 2026-07-19.

## Secret generation

Create a long-lived Home Assistant token dedicated to backups, then run:

```bash
export HOME_ASSISTANT_TOKEN=...
./runbooks/phase5/02-encrypt-restic-secret.sh
```

`RESTIC_PASSWORD` is generated when omitted only if there is no existing Restic Secret;
on reruns, the existing value is preserved so the initialized Restic repository stays
readable. `HOME_ASSISTANT_TOKEN` is also preserved on reruns when omitted.
`ROMM_DB_PASSWORD` is read from the existing SOPS-encrypted RomM Secret's
`MARIADB_PASSWORD` key when omitted, because that is the password MariaDB uses for the
`romm` database user. The script warns if RomM's app-facing `DB_PASSWD` value differs
from `MARIADB_PASSWORD`.

The script writes plaintext only under a temporary directory, encrypts the Secret to
`infrastructure/monitoring/restic-nas.sops.yaml`, and adds it to the monitoring
kustomization.

If a manual backup fails with `mariadb-dump: Got error: 1045` for
`romm@<pod-ip>`, regenerate `infrastructure/monitoring/restic-nas.sops.yaml` with
this script, commit/reconcile `monitoring`, and rerun `04-run-manual-backup.sh`.

## Image

The backup CronJob uses `ghcr.io/sandersch/restic-backup:0.19.0-1`. Build and publish it
with the `restic-backup-image` GitHub Actions workflow before reconciling monitoring.

## Backblaze B2 offsite repository

Provision B2 before running script 06:

1. Create a dedicated private bucket with default server-side encryption enabled.
   Leave Object Lock disabled; once enabled it cannot be disabled, and a lock would
   prevent scheduled `forget --prune` from deleting expired Restic data.
2. Set the bucket lifecycle to **Keep only the latest version of each object**. B2
   buckets are versioned, and Restic's S3 backend otherwise leaves hidden older
   versions consuming storage.
3. Create a non-expiring application key restricted to this bucket with **Read and
   Write** access and **Allow List All Bucket Names** enabled. The latter is required
   for S3-compatible clients using a bucket-restricted key.
4. Record the bucket name, S3 endpoint, key ID, application key, and the Restic
   password generated in the next step in the password manager.

Generate the Secret with the values from Backblaze:

```bash
export B2_BUCKET=...
export B2_ENDPOINT=https://s3.us-west-004.backblazeb2.com
export B2_KEY_ID=...
export B2_APPLICATION_KEY=...
./runbooks/phase5/06-encrypt-restic-b2-secret.sh
```

The script writes plaintext only inside a temporary directory. It creates
`RESTIC_REPOSITORY=s3:<endpoint>/<bucket>/opt`, generates a distinct repository
password when one is not supplied, preserves every existing value on reruns, and adds
the encrypted Secret to the monitoring kustomization. The weekly job reads the
existing NAS Secret for the Home Assistant token and RomM password instead of
duplicating them.

Commit the encrypted Secret, reconcile and validate while the CronJob is suspended:

```bash
./runbooks/phase5/07-init-restic-b2-repo.sh
./runbooks/phase5/08-run-manual-b2-backup.sh
./runbooks/phase5/09-validate-b2-restore.sh
```

Only after all three succeed, ensure `suspend: false` in
`infrastructure/monitoring/restic-b2-cronjob.yaml`, commit, and reconcile monitoring.
The offsite schedule is Sunday at 04:30 America/Chicago, with 8 weekly and 12 monthly
snapshots and no daily tier.

References: [Restic's Backblaze guidance](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#backblaze-b2),
[Backblaze lifecycle rules](https://www.backblaze.com/docs/en/cloud-storage-lifecycle-rules),
and [S3-compatible application keys](https://www.backblaze.com/docs/cloud-storage-s3-compatible-app-keys).
