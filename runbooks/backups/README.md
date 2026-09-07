# Backup-system rollout

This attended workflow implemented the vault foundation in `docs/backups.md`. It runs on
`minis`, uses canonical host files under `host/minis/`, and treats the appstate and local
vault pipelines as production. The rollout is complete; the numbered installation steps
below are retained for recovery or a future rebuild, not routine operation.

Phase 1 begins with the backup-volume safety guard:

1. For a future rebuild, start from the reviewed `main` branch and run `00-preflight.sh`.
   Do not follow the historical branch-only workflow from earlier revisions. This also
   checks the bare-root mount identity against the backup and verifier's locked-vault pin.
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
    For an ordinary post-enrollment photo snapshot, use `12-validate-vault-photos.sh`; it
    restores the exact ID and SHA-256 compares all photos without changing enrollment.
12. Use `10-resolve-validation-hold.sh` only if the shrink guard creates an exact-ID hold;
    acceptance is limited to a revalidated shrink-only candidate, while rejection forgets
    and prunes only the typed local snapshot ID.
13. `11-validate-locked-vault.sh` proves the locked skip, rejected SFTP upload, existing
    appstate independence, and successful post-unlock vault backup.
14. `09-activate-vault.sh` required the ingestion heartbeat and both break-glass records,
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

Phase 4 enrollment uses `13-enroll-vault-b2.sh` after creating the dedicated bucket and
installing `/etc/homelab/vault-b2.conf`. The copy and prune CronJobs are committed
suspended. Run the enrollment script, perform the manual copy and B2 restore gates, then
enable both schedules in a reviewed Git change. A locked vault is an intentional successful
skip; it must not cause the copy job to read credentials from the root filesystem.
Use `14-validate-vault-b2-restore.sh` with a full destination snapshot ID for the attended
representative restore; it validates the released contract, `ccs.kdbx`, one document, and
one photo without changing the NAS baseline. If a destination snapshot is present without
ledger evidence, the copy job creates a destination hold; use
`15-resolve-vault-b2-validation-hold.sh` with its exact B2 snapshot ID to revalidate it and
record the ledger evidence.

Phase 4 host enrollment stages credentials only in verified `/dev/shm` tmpfs and
opens the source repository inside a privileged process. Secret values are read
inside that process rather than passed through sudo arguments; host B2 commands
also disable persistent Restic caches. `test-phase4-b2.sh` runs behavioral fixtures
for timestamp offsets/fractions, enrollment permissions and failures, and the
credential boundary without contacting B2 or the cluster.

`test-prune-alerts.py` runs the deployed prune rules through `promtool`, covering
first-run failure, recovery, initial enrollment grace, repeated scheduling, and
mounted/enabled gates. It also verifies that copy metrics preserve the enrollment
timestamp across subsequent runs. CI uses an immutable Prometheus container;
locally, put `promtool` on PATH or set `PROMTOOL` to its command.

The vault prune job checks B2 holds and independently validates the newest B2
snapshot against the vault's healthy baseline before selecting removal candidates.
It checks destination holds again after NAS pruning, before B2 deletion.
`test-phase4-b2.sh` includes disposable retention fixtures for these guards,
file/byte shrink thresholds, and successful exact-ID deletion ordering.
