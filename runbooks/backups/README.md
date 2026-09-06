# Backup-system rollout

This attended workflow implements the staged design in `docs/backups.md`. It runs on
`minis`, uses canonical host files under `host/minis/`, and treats the existing
`appstate` pipeline as production.

Phase 1 begins with the backup-volume safety guard:

1. Push the implementation branch if `minis` needs to fetch it, but do **not** merge or
   otherwise publish this change to Flux's watched `main` branch yet. Check out that branch
   on `minis` and run `00-preflight.sh` from it. This also checks the bare-root
   mount identity against the backup and verifier's locked-vault pin.
2. Suspend the `monitoring`, `monitoring-controllers`, and `monitoring-configs` Flux
   Kustomizations, then suspend both production Restic CronJobs and wait for every active
   Restic Job to finish. Suspending `monitoring` first prevents Flux from reverting the
   temporary CronJob suspension.
3. From the implementation-branch checkout on `minis`, run `01-install-backup-guard.sh`.
4. Merge/push the reviewed Git change to `main`, resume and reconcile only the `monitoring`
   Kustomization, and run a fresh local backup/restore drill. Leave
   `monitoring-controllers` and `monitoring-configs` suspended until step 14; this prevents
   the node-exporter rollout and enrollment-gated alerts from preceding their host and
   metric prerequisites.

`01-install-backup-guard.sh` temporarily unmounts `/mnt/backups`; it therefore refuses
to run while either backup schedule is enabled or a Restic Job is active. Negative
mount-identity tests use fixtures and never unmount the production filesystem.
The installation handles both an already-detached filesystem after automount shutdown
and one that still needs an explicit unmount, then verifies the mountpoint is uncovered.

The encrypted-vault storage gate follows:

5. `03-provision-vault.sh` creates the LUKS2/ext4 storage and prints its non-secret UUIDs.
6. Pass those UUIDs to `04-install-vault-host-config.sh`; it writes the exact canonical
   `crypttab`, `fstab`, and `/etc/homelab/vault.conf` entries, initializes the filesystem,
   and prompts silently for the local repository password.
   Only the vault entries are added to live mount tables; unrelated entries are preserved
   and conflicting vault entries stop the run. Originals are saved in the printed
   root-only `/etc/vault-mount-config-backup.*` directory before installation.
7. Review and commit the generated non-secret canonical files before deploying vault Pods.
8. On `ryze`, run `07-prepare-ryze-ingest.sh` once to generate the dedicated key and
   commit its public half. Before installing anything, it measures the local documents
   and KDBX against the released contract floors and checks the KDBX signature.
9. On `minis`, run `08-install-vault-ingest-server.sh`, then rerun step 8 on `ryze` to
   pin the host key and enable the four-hour KDBX timer. Run `vault-ingest documents`
   once; no recurring documents timer is installed in this phase.
10. `05-init-and-backup-vault.sh` initializes `/mnt/backups/vault` and prints the exact
   enrollment candidate ID.
11. Pass that full ID to `06-validate-vault-restore.sh`; it runs `check --read-data`,
    restores into the encrypted `.restore-tests` directory, validates content, and creates
    baseline generation 1.
12. Use `10-resolve-validation-hold.sh` only if the shrink guard creates an exact-ID hold;
    acceptance is limited to a revalidated shrink-only candidate, while rejection forgets
    and prunes only the typed local snapshot ID.
13. `11-validate-locked-vault.sh` proves the locked skip, rejected SFTP upload, existing
    appstate independence, and successful post-unlock vault backup.
14. `09-activate-vault.sh` requires the ingestion heartbeat and both break-glass records,
    runs all three enrolled repository checks, and flips the two recurring schedules in
    the working tree for the final reviewed activation commit.

Vault creation remains attended because it requires LUKS and Restic passwords that must
never enter git, command arguments, or shell history. Record and verify both passwords on
two sealed break-glass records: one in the separated home safe and one in the off-site bank
location. Do not treat the local repository as recoverable until both records exist.

Phase 1 keeps `/mnt/backups/.control/vault` as a single copy alongside its repository.
It is not included in another backup. Loss of control state with the repository intact
requires attended reconstruction and revalidation; never invent a baseline or ledger to
resume automatically. Full array loss also loses the local vault repository and source
volume, so it is not merely an enrollment-state recovery. Off-site protection remains a
later phase. See `docs/backups.md` for the deliberate placement of control state beside
the repositories it governs.

Backup, enrollment restore, and shrink acceptance validate the exact snapshot's source
paths, captured file counts and sizes, released floors, credential exclusions, and KDBX
signature. A mismatch with the pre-backup manifest fails validation rather than advancing
the baseline. Rejection records deletion intent before forgetting its exact snapshot, so
an interrupted run can verify absence and finish pruning on retry.

Run `test-review-regressions.sh` locally alongside the other backup tests. Its disposable
fixtures cover source changes during backup, invalid manifests, repository read failures,
interrupted rejection, and both automount shutdown outcomes without touching live storage.
