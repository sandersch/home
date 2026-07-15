# Phase 5 - backups first

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
