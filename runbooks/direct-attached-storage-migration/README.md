# Direct-Attached Storage Migration Helpers

Attended helpers for the SMART gate in
[`docs/direct-attached-storage-migration.md`](../../docs/direct-attached-storage-migration.md).
Run them on Morpheus while it owns the enclosure, or on whichever host currently
has direct access to all 15 recorded disks.

| Script | Purpose |
|---|---|
| `01-start-smart-tests.sh` | Starts an extended SMART test on each recorded disk that does not already have a self-test in progress. |
| `02-check-smart-tests.sh` | Reports each test's state, coarse remaining percentage, and temperature, followed by an aggregate summary. |

Both scripts require `smartctl`, the exact serial-numbered `/dev/disk/by-id` paths,
and non-interactive access to `sudo` after its initial credential prompt. They act
on whole disks, never `/dev/sdX` names or array-member partitions.

The start helper intentionally allows all 15 extended tests to run concurrently.
This is an explicit operator decision for this enclosure and supersedes the
runbook's conservative two-test concurrency limit for this migration. Keep the
enclosure powered until every test finishes. The scripts do not assemble, mount,
activate, stop, or otherwise modify md, LVM, or filesystems.

Run:

```bash
./runbooks/direct-attached-storage-migration/01-start-smart-tests.sh
./runbooks/direct-attached-storage-migration/02-check-smart-tests.sh
```

The status helper exits nonzero if a disk is missing, cannot be queried, has a
failed/aborted latest extended test, or is idle without a completed extended-test
result. A mix of `RUNNING` and `PASSED` is healthy while the batch drains.
