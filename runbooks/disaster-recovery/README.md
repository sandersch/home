# Full-state disaster recovery

This is the executable half of
[`docs/build-plan.md` → Fresh rebuild and disaster recovery](../../docs/build-plan.md#fresh-rebuild-and-disaster-recovery).
It restores a fresh, empty `/opt` from one exact Restic snapshot and enforces the
required order:

```text
guards committed → infrastructure rebuilt → staged restore → offline validation
→ apps resumed and validated → monitoring/backups resumed and validated
```

This procedure runs **on `minis`** after Phases 0–3. It is for a full rebuild with an
empty `/opt`, not an in-place rollback or a single-application restore. It refuses to
merge into nonempty state unless it is resuming its own recorded, interrupted copy.

## Safety model

- Both `apps` and `monitoring` must have `spec.suspend: true` in the worktree, in
  `HEAD`, and on the live Flux objects before restoration begins.
- Application workload controllers and pods, active monitoring Jobs, and backup
  CronJobs must be absent, so no controller can recreate a writer after preflight.
- `/opt` must be btrfs on `/dev/mapper/vg0-opt`.
- Staging must be a separate mounted filesystem. It defaults to `/mnt/backups` for
  the direct repository and `/mnt/media` for B2; set `RECOVERY_STAGE_ROOT` to another
  exact mountpoint if necessary. It must have enough free space for a complete
  restored `/opt` tree in addition to the Restic repository, if they share a disk.
- A full 64-character snapshot ID is mandatory. `latest` is never accepted.
- The Restic restore lands outside `/opt`. SQLite hot backups replace the live-captured
  `.db`, `.sqlite`, and `.sqlite3` database files in staging, with stale WAL/SHM files
  removed. Before activation, the restore requires the current backup-contract version
  and exact mandatory inventory: both Plex library databases plus the primary Frigate,
  Home Assistant, Prowlarr, Radarr, Sonarr, and Seerr databases.
- The same contract requires a readable Home Assistant managed backup, a structurally
  valid RomM logical dump, and an export-completion timestamp. Any mismatch rejects the
  selected snapshot before anything is copied into `/opt`.
- Contract version 2 additionally requires an integrity-checked, nonempty k3s SQLite
  datastore artifact with the expected `kine` schema. It remains in the root-only
  staging tree and is never copied into `/opt` or installed as the active datastore.
  Optional attended k3s recovery is documented separately in
  [`docs/operations.md`](../../docs/operations.md#optional-emergency-k3s-datastore-recovery).
- The live-captured `romm/db` tree is excluded from both Restic extraction and the
  `/opt` copy. A temporary MariaDB Job imports the transaction-consistent RomM SQL
  dump into a fresh data directory.
- SOPS secrets are streamed directly into Kubernetes; plaintext credentials are not
  written to disk.
- Resume happens only through two committed and pushed git changes. The scripts never
  use imperative `flux resume`.

The recovery record is non-secret and lives at `/var/lib/homelab-recovery/state`.
It binds retries to the selected repository, snapshot, and staging path.

## Prerequisites

1. The failed/old cluster is offline.
2. Restore the existing `age.key` from the password manager to the repository root.
3. Add `spec.suspend: true` to both `clusters/minis/apps.yaml` and
   `clusters/minis/monitoring.yaml`; commit and push before Flux bootstrap.
4. Complete Phases 0–3, including exact direct-mount validation. If this cluster
   serves NFS, run `runbooks/nfs-exports/00`–`03` between Phase 2 and Phase 3: the
   `nfs` blackbox probe reconciles with `monitoring-configs` at Phase 3 and will raise
   `StandardEndpointDown` after ten minutes if nothing is listening on 2049 yet. Its
   `04-validate-monitoring.sh` needs Prometheus, so run that one after Stage 3.
5. Leave `/opt` empty and do not create application resources manually.
6. Explicitly switch from the normal read-only kubeconfig to the admin context for
   this recovery. The preflight checks the required Secret, Job, Namespace, and Flux
   reconciliation permissions before making changes.
7. Run as the non-root sudo user from the repository checkout on `minis` with
   `git`, `jq`, `kubectl`, `mountpoint`, `findmnt`, `rsync`, `sops`, `sqlite3`, `tar`,
   and `yq` available. The scripts check their remaining standard host tools. The
   normal phase runbooks provide the cluster and GitOps tooling.

## Stage 1 — select and restore

Choose the direct repository when its LV is healthy; use B2 when it is not:

```bash
export RECOVERY_SOURCE=nas   # or b2

./runbooks/disaster-recovery/00-preflight.sh
./runbooks/disaster-recovery/01-list-snapshots.sh

export RECOVERY_SNAPSHOT=<full-64-character-id>
./runbooks/disaster-recovery/run-restore.sh
```

For B2, the default staging filesystem is `/mnt/media`. To use a temporary external
filesystem instead, mount it first and export its exact mountpoint:

```bash
export RECOVERY_STAGE_ROOT=/mnt/recovery
```

`run-restore.sh` runs `00`, `02`, `03`, and `04`. The copy into `/opt` is attended and
requires confirmation. A failed Restic Job leaves staging for inspection. If the
`/opt` rsync is interrupted, rerun with the same environment; the recovery record
allows only that same source/snapshot/stage combination to continue.

After inspecting a failed, incomplete Restic staging tree, explicitly reset only that
tree and retry the combined restore:

```bash
export RECOVERY_RESET_RESTIC_STAGE=1
./runbooks/disaster-recovery/run-restore.sh
```

The reset is refused after `/opt` activation starts and requires confirmation.

If temporary RomM initialization fails, inspect the retained Job and staging tree.
After correcting the cause, rerun only its step with an explicit reset:

```bash
export RECOVERY_RESET_ROMM_STAGE=1
./runbooks/disaster-recovery/03-restore-romm.sh
```

That reset deletes only the derived `romm-db-logical` directory under the recorded
snapshot staging tree and still requires confirmation.

## Stage 2 — resume applications

After `04` passes, remove `spec.suspend: true` from
`clusters/minis/apps.yaml` **only**. Commit and push that change while monitoring
remains suspended, then run:

```bash
./runbooks/disaster-recovery/05-resume-apps.sh
```

The script fetches the upstream branch, refuses uncommitted or unpushed state,
reconciles apps, runs the Phase 4 automated validators, and requires confirmation of
the manual media/camera/home-automation gates. If the selected snapshot contains an
established Zigbee2MQTT network, its retained-state validator is included.

## Stage 3 — resume monitoring and backups

Only after Stage 2 passes, remove `spec.suspend: true` from
`clusters/minis/monitoring.yaml`, commit, and push the second change:

```bash
./runbooks/disaster-recovery/06-resume-monitoring.sh
```

This reconciles monitoring, creates fresh direct and B2 backups, runs independent
restore validation against each, and validates NUT telemetry. Set
`RECOVERY_TEST_PUSHOVER=1` to include synthetic Pushover firing/recovery notifications.
The final attended gate requires external monitoring and Dead Man's Snitch health.

Keep the staged tree through an observation window. It is intentionally not deleted
by the runbook. After the new local and B2 restores have passed and the recovered
services remain healthy, archive the active recovery record:

```bash
./runbooks/disaster-recovery/07-close-recovery.sh
```

This makes the state machine ready for a future event but does not remove staging.
Delete only the exact staged path printed by the script, as a separate deliberate
operation.

After deploying backup-contract version 2, create and validate fresh direct and B2
snapshots. Contract-v1 snapshots remain stored according to retention but are
deliberately rejected by current recovery tooling; use the matching older repository
revision if one must be interpreted.

Contract-v2 acceptance passed on 2026-08-22 with direct snapshot `731326fa` and B2
snapshot `fe10c1ff`. Both independently passed k3s SQLite integrity, schema, nonempty
data, and server-token-absence checks in addition to the application recovery contract.

## Scripts

| Script | Purpose |
|---|---|
| `00-preflight.sh` | Prove git/live guards, mount identity, workload quiescence, and staging safety |
| `01-list-snapshots.sh` | List exact eligible snapshots from direct Restic or B2 |
| `02-restore-opt.sh` | Restore to staging, apply SQLite hot backups, and copy into empty `/opt` |
| `03-restore-romm.sh` | Rebuild RomM MariaDB from its logical dump |
| `04-validate-restored-state.sh` | Run the final offline filesystem/database gate |
| `05-resume-apps.sh` | Reconcile the first resume commit and run Phase 4 recovery validation |
| `06-resume-monitoring.sh` | Reconcile the second resume commit and create/validate fresh backups |
| `07-close-recovery.sh` | Archive the completed state record after the observation window |
| `run-restore.sh` | Run the attended offline steps `00`, `02`, `03`, and `04` |
