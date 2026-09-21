# Legacy rsnapshot archive

Status: the archive was accepted on 2026-09-20. The original tree remains in place pending a
separate attended deletion review. The accepted repository and snapshot IDs, measured sizes,
and verification results are in the
[sanitized evidence](evidence/legacy-rsnapshot-20260920.json). The helper is installed at
`/usr/local/lib/legacy-rsnapshot/legacy-rsnapshot.py` on `minis`; checksum-verified Restic
0.19.1 is installed alongside it. The operator confirmed that the source is retired,
including remote writers, and approved an attended
low-I/O window. A live scan found historical Unix sockets. The operator explicitly accepted
Restic's inherent omission of those entries; their paths and metadata remain in the private
inventory. No regular files or other supported types may be omitted. No original data has
been deleted by this workflow.

This static archive contains `/mnt/backups/snapshots` in the dedicated encrypted
`/mnt/backups/legacy-rsnapshot` repository. Keep it indefinitely: no scheduled backups,
forget, prune, unattended credential, CronJob, or freshness metric. It is an explicit
exception to automated repository-check enrollment. An attended annual full-data check
and representative restore replace automated checking. Until the future SSD copies are
seeded and independently validated, array loss destroys the archive. B2 is outside this
implementation.

## Prepare and measure

Use a reviewed checkout on `minis`, Python 3.11+, and root. Keep the attended session
open through the operation; inventories of the 40 historical directories can take tens
of minutes. An existing persistent terminal session is useful for the archive/restore. Existing production backup
schedules continue. Choose a window outside RAID checks, backup/prune jobs and other heavy
maintenance. Run under `ionice -c 3 nice -n 19`; Restic also limits Go concurrency to two.
The helper never modifies the source, production repositories, or schedules.

```bash
sudo ionice -c 3 nice -n 19 python3 runbooks/backups/legacy-rsnapshot.py preflight
sudo python3 runbooks/backups/workstation-install-restic.py --directory /usr/local/lib/legacy-rsnapshot
sudo /usr/local/lib/legacy-rsnapshot/restic version
```

The existing installer downloads Restic **0.19.1**, verifies the release archive against
upstream SHA256SUMS over HTTPS, and installs it at a dedicated path. Record the checksum
output. Never substitute an unverified binary. The helper requires that exact version.

Preflight validates the same device, ext4 UUID and root-owned `0444` sentinel as the existing
backup runbooks, plus the mount root, canonical paths, and absence of nested mounts. It
refuses missing/empty source trees. It scans local process command lines, cron directories,
and systemd definitions for rsnapshot references. References, including inactive packaged
units, cause a stop for review; do not automatically remove them. Also inspect remote writers,
user timers/custom wrappers and maintenance schedules: the local scan cannot prove their
absence. The archive command requires an attended retirement confirmation.

Disk-backed SQLite inventories keep memory bounded for large historical trees.
Detailed inventories and execution records stay under the root-owned `0700`
`/mnt/backups/.legacy-rsnapshot-control`. Inventories include relative paths, file types,
numeric ownership, modes, nanosecond mtime/ctime, inode/link information, device numbers,
symlink targets and xattrs. Regular-file logical size deduplicates by device/inode; allocated space includes all
entry types. The free-space gate
requires **120% of unique-inode logical bytes plus 10% of current filesystem capacity**.
Do not substitute the historical 119 GiB figure. A failed capacity gate requires a revised
plan, not an override. The archive itself may compress substantially, but that is not assumed.

## Create and verify

Create a unique password in the external password manager and save its independent copy
before continuing. In an interactive terminal on `minis`:

```bash
sudo ionice -c 3 nice -n 19 python3 runbooks/backups/legacy-rsnapshot.py archive
# Substitute the full 64-character ID printed by archive:
sudo ionice -c 3 nice -n 19 python3 runbooks/backups/legacy-rsnapshot.py verify --snapshot FULL_SNAPSHOT_ID
```

Enter the credential only at the silent prompts, never in chat, command arguments or shell
history. The helper writes it to a `0600` temporary file on verified `/run` tmpfs and removes
it on normal exit and handled interruption. SIGTERM, SIGKILL or power loss cannot run cleanup; after an
abrupt kill, deliberately remove only the abandoned `/run/legacy-rsnapshot-password-*`
file associated with that run. A reboot clears tmpfs. No persistent Restic cache is used.

Initialization uses repository format 2 and normal chunker parameters. All Restic commands
use `--compression auto`. Repository permissions must remain `root:root 0700`. Backup has
no exclusions and captures only the absolute source path, host `minis`, and tag
`legacy-rsnapshot`; the snapshot timestamp is the actual archival date. Historical dates
remain in the original directory names. Restic itself skips Unix sockets as accepted above.
See [upstream metadata behavior](https://restic.readthedocs.io/en/stable/040_backup.html#backing-up-special-items-and-metadata)
and [repository compression](https://restic.readthedocs.io/en/stable/045_working_with_repos.html).

Every nonzero backup exit, including 3, fails. Before/after inventories must match exactly
(excluding atime, which reads can change). Only then is a candidate full snapshot ID recorded.
Verification checks that exact ID's host/tag/path, runs `check --read-data`, and compares the
entire supported path/type/size/owner/mode/mtime inventory. All symlink targets are checked through an additional long listing;
representative symlinks are also restored. Restic 0.19.1 JSON listings omit targets, so
unprintable symlink names/targets or names containing ` -> ` fail closed for an attended
alternative verification instead of accepting ambiguous text. Samples cover every top-level historical directory plus hidden
files, executables, hardlink pairs, and xattrs where present. Scratch has a private parent
on `/mnt/backups`, separate from source/repository. Hashes, ownership, permissions, mtime,
symlink targets, sampled xattrs/device numbers and sampled hardlink topology must match.
Directory samples can restore descendants; scratch capacity reserves for
selected paths and directory descendants, metadata overhead, and the filesystem reserve. Scratch is retained for inspection.

Inspect representative historical content from every top-level history directory manually
before typing the full snapshot ID at the acceptance prompt. A failed or unconfirmed check
never creates acceptance. Detailed file names, xattrs and sample hashes stay local. Commit
only a sanitized evidence report: date, repository/snapshot IDs, Restic version and installer
checksum, counts, unique-inode logical and allocated source bytes, allocated repository
bytes, durations, checks, socket omission count, and manual inspection outcome. The measured
space comparison must precede any deletion review. This helper has **no deletion operation**.

## Interruptions and recovery

A lock serializes helper runs. Reruns reuse only the repository ID recorded in enrollment;
an unexpected directory or mismatched identity fails. Interruption between repository
creation and enrollment requires attended identity reconstruction, not automatic adoption.
Never automatically unlock, remove a failed snapshot, or discard a failed candidate.
Failed backups can leave packs/snapshots; retries reuse uploaded data through deduplication.
If inventory and capacity checks completed but the retirement prompt was declined, retry
within two hours using `archive --resume-inventory /mnt/backups/.legacy-rsnapshot-control/<run>/inventory.sqlite`; this reuses only a root-owned, checked inventory from the private control tree, then performs a fresh before/after comparison around backup. If backup completed but candidate recording was interrupted, a retry may create an additional
snapshot. Retain both pending attended review. Once a candidate is recorded, `archive`
refuses another backup; use `verify` with its exact ID. Do not use `latest`.

If a completed attended verification has a root-path alias failure after its successful
`--read-data` check, path/metadata listings, symlink comparison, and restore, use the
version-controlled `finalize` operation with the exact prior run, root-owned restored
inventory, scratch path, and log. It validates the saved zero-exit command records, checks
sample hashes and current source state, then returns to the manual inspection gate. If only
the final manual prompt was interrupted, use `accept --snapshot FULL_SNAPSHOT_ID
--verification-report /mnt/backups/.legacy-rsnapshot-control/<finalize-run>/verification.json`;
it accepts only a root-owned pending report tied to the enrolled repository and exact
candidate ID. Never recreate candidate or accepted records by hand.

Preserve control state with the accepted evidence. If it is lost, recover the repository
using the password-manager credential, inspect `snapshots --json`, and reconstruct the exact
ID and evidence under attended review; do not fabricate an accepted record. A later decision
to remove the original tree must also preserve the accepted inventory and sample hashes.

## Annual check and offline copies

Once annually run the same `verify --snapshot FULL_SNAPSHOT_ID` with the password-manager
credential. After separately approved source deletion, it uses the accepted inventory and
sample hashes instead of requiring the old tree. The full repository read, archived metadata
comparison, representative restore and manual inspection remain mandatory. Check durations
are recorded per run. No claim is made to preserve atime/ctime, inode numbers, physical sparse
layout, or every hardlink relationship after restore; xattrs and hardlinks are sampled.

The future offline-drive design adds a third, separate `legacy-rsnapshot` repository on
each SSD. Initialize format 2 with `--from-repo /mnt/backups/legacy-rsnapshot
--copy-chunker-params` and a distinct password per drive, then copy only the accepted exact
source ID. Record the destination ID and source lineage; do not assume IDs remain identical.
Independently run `check --read-data` and the same inventory/sample restore comparisons on
each destination during enrollment. Include this repository in annual offline checks and
restores. The static archive needs no quarterly recopy or freshness metric. Never prune it.

Tests: `PYTHONDONTWRITEBYTECODE=1 python3 runbooks/backups/test-legacy-rsnapshot.py` uses
real Restic 0.19.1 on disposable fixtures plus injected failures; no live storage is touched.
