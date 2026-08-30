# Backup policy

> **Status: DRAFT — proposed design, not implemented.** Written 2026-08-30.
>
> Nothing in this document is deployed. The **only** backup pipeline that actually runs
> today is the `appstate` pipeline described under [What exists today](#what-exists-today):
> `restic-nas-backup` nightly and `restic-b2-backup` weekly, covering `/opt`, the k3s
> datastore, and validated hot dumps.
>
> Personal photos, documents, credentials, the `ryze` workstation, and
> the `m5c` MacBook are **currently unprotected** — one copy, on one RAID6 array, in one
> building. Every "not backed up" statement elsewhere in the repo remains accurate.
> Do not read the tables below as a description of running infrastructure, and do not
> describe the RAID array itself as a backup.
>
> The corresponding follow-up item stays open in
> [operations.md → Follow-ups](./operations.md#follow-ups) until this is built and drilled.

## What exists today

`infrastructure/monitoring/` holds a single, well-built pipeline covering cluster app state:

- `restic-nas-backup` — nightly `15 3 * * *`, repo `/repo/nas/opt` on `/mnt/backups`
- `restic-b2-backup` — weekly `30 4 * * 0`, independent read, Backblaze B2 via the S3 backend
- Sources: `/opt` (read-only, `.snapshots` excluded), `/var/lib/rancher/k3s/server/db`,
  plus hot dumps generated in-job
- **Backup contract version 2** — the run hard-fails before `restic backup` unless every
  required artifact was freshly produced *this attempt*: 8 required SQLite exports, a k3s
  `state.db` backup passing `PRAGMA integrity_check` with `kine` rows present, a validated
  Home Assistant archive, and a `mariadb-check` + `--single-transaction` dump of RomM
- Alerts in `configs/alert-rules.yaml` (`homelab.backups`), routed to Pushover, with Dead
  Man's Snitch as the off-node heartbeat
- Rehearsed restore in `runbooks/disaster-recovery/`, which rejects any snapshot whose
  contract version or inventory differs

That anti-false-success contract is the most valuable pattern in the repo and everything
proposed below reuses it. The gap is not quality — it is coverage.

## The data policy (proposed)

One table is the contract. Every proposed manifest points back to it.

| Dataset | Contents | Size | NAS | Off-site (B2) | Offline drive |
|---|---|---|---|---|---|
| `vault` | credentials export, documents, photos, mail archive, firmware, Frigate exports | ~35 GB (+5 GB/yr) | **every 4h** | daily (copy) | quarterly (copy) |
| `appstate` | `/opt`, k3s datastore, hot dumps — **existing, unchanged** | ~20 GB | nightly | weekly | quarterly (copy) |
| `workstations` | `ryze` home (curated), `m5c` home (curated) | ~15 GB | daily push | weekly (copy) | — |
| *(none)* | disk images, Frigate **recordings**, `/mnt/media`, `/mnt/games` | 18 TiB+ | local only, GC'd | — | — |

Photos and documents land in all three columns — RAID6, Backblaze, and an offline disk.
That is the 3-2-1 target, and the offline disk is the only copy the cluster has no
authority to delete.

B2 cost at this footprint is roughly **$0.70–1.00/month**; restore egress is free up to 3×
stored bytes. Cost is not a constraint here — but "generous" is not a policy, so the
retention below is stated as concrete arguments with the recovery window each one buys, and
bounded by an explicit ceiling per repository.

### Retention (proposed)

Cadence sets the *recovery point*; retention sets the *recovery window*. Both belong in this
table, because a policy that names only one cannot answer "how far back can I recover this
file?"

| Repository | Retention arguments | Nominal RPO | Max tolerated staleness | Recovery window | Applied by |
|---|---|---|---|---|---|
| `vault` (NAS) | `--keep-within-hourly 48h --keep-within-daily 30d --keep-within-weekly 12w --keep-within-monthly 24m` | 4h | 8h (`ResticVaultBackupOverdue`) | 24 months | weekly prune job (§ 2) |
| `vault` (B2) | `--keep-within-daily 30d --keep-within-weekly 12w --keep-within-monthly 24m` | 24h | 36h (`ResticVaultCopyOverdue`) | 24 months | weekly prune job, against the B2 repo |
| `vault` (offline) | **none — `forget` never runs**, see below | 90d | 120d (`ResticOfflineDriveStale`) | full history of the drive | nothing prunes it |
| `appstate` (NAS) | `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` — **existing, unchanged** | 24h | 30h (`ResticLocalBackupOverdue`) | ~12 months | inline in `restic-nas-backup` (§ 3) |
| `appstate` (B2) | `--keep-weekly 8 --keep-monthly 12` — **existing, unchanged** | 7d | 8d (`ResticB2BackupOverdue`) | ~12 months | inline in `restic-b2-backup` |
| `appstate` (offline) | none — `forget` never runs | 90d | 120d (`ResticOfflineDriveStale`) | full history of the drive | nothing prunes it |
| `workstations` (NAS) | `--keep-within-daily 30d --keep-within-weekly 12w --keep-within-monthly 12m` | 24h | 7d (`ResticWorkstationBackupStale`) | 12 months | weekly prune job, over hostPath (§ 4) |
| `workstations` (B2) | `--keep-within-weekly 12w --keep-within-monthly 12m` | 7d | 7d (`ResticWorkstationBackupStale`) | 12 months | weekly prune job, against the B2 repo |

**"Nominal" is the schedule, not a guarantee.** These RPOs are what the cadence produces
when every job succeeds. The *true* worst case is unbounded — a job can fail every night, a
workstation can stay asleep for a month, an offline rotation can be skipped because nobody
drove to the safe — and no retention argument bounds any of that. What bounds it is the
alert: the "max tolerated staleness" column is the real contract, because it is the point
at which a human is told the recovery point has drifted past what this policy accepts.
Every row's threshold is set slightly wider than its cadence so a single missed run is not a
page, and every one of those alerts carries `or absent(...)` (§ 9) so a deleted CronJob
fires rather than going quiet.

**Who applies each row.** Retention is not applied uniformly, and the split matters when
reading a repo's history: the new repos are pruned by the weekly `restic-prune-cronjob.yaml`
(§ 2), which addresses each destination directly — the NAS repos over the filesystem, the
workstation repos over hostPath rather than REST (§ 4), and the B2 repos over the S3
backend, where the cluster does hold delete authority. `appstate` is the exception in both
columns: its NAS and B2 retention run *inline* at the end of `restic-nas-backup` and
`restic-b2-backup` respectively, with the keep values supplied per-job through
`RESTIC_KEEP_*` — the existing arrangement, deliberately left alone (§ 3). Nothing prunes
offline media at all.

The `appstate` rows are not a proposal — they record what
`restic-nas-config.yaml` and `restic-b2-cronjob.yaml` already set, so the table describes
the whole system rather than only the new half. Count-based arguments are kept there
deliberately: changing them is a change to a running, DR-drilled pipeline, and the reason
the new repos use `--keep-within-*` instead is specific to them (§ 4).

**Grouping.** `forget` applies its policy per *group*, and restic's default group is
`host,paths`. For the new repos that default is a hazard rather than a nicety: editing an
exclude list or adding a vault subdirectory changes `paths`, which creates a **new group**
whose retention starts over while the old group ages out under a policy nothing is feeding
any more. Every `forget` invocation in this design therefore passes `--group-by host`
explicitly. `appstate` keeps the default — its source paths are fixed by contract v2, so
the failure mode cannot arise there.

**Offline media are cumulative, and there are two drives.** Each drive holds a persistent
restic repository that is only ever copied *into*; `forget` and `prune` never run against
offline media, and a drive is retired by re-initializing it (`--from-repo`,
§ 3), not by pruning it. The two drives alternate quarterly, so the newest offline copy is
at most **90 days old** when rotations happen on time, and **180 days** if the most recent
drive is lost, destroyed, or unreadable. A skipped rotation extends both figures without
limit, which is what the alert exists to catch. That is the number to weigh against `ResticOfflineDriveStale`
firing at 120d (§ 9): the alert catches a *missed* rotation before the worst case doubles
again. At ~35 GB growing 5 GB/yr with no pruning, a 1 TB drive holds well over a decade of
quarterly copies before re-initialization is a real consideration.

Each rotation copies a **tagged checkpoint** — the newest `vault` and `appstate` snapshots
at that moment — rather than every snapshot the NAS has accumulated since the last trip.
The reasoning, and why offline media are deliberately excluded from prune's replication
gate, is in § 2.

### Capacity ceilings (proposed)

`/mnt/backups` is a single 1 TiB `backuplv` shared by every local repository, so generous
retention needs a bound or the vault job and `appstate` eventually compete for the same
disk. Each repository gets a ceiling, and the prune job exports its size so the ceiling is
observable rather than aspirational:

| Repository | Ceiling | Enforcement |
|---|---|---|
| `vault` (NAS) | 250 GiB | `ResticRepoNearCeiling` at 80% (§ 9) |
| `appstate` (NAS) | 250 GiB | same |
| `workstations/ryze` | 100 GiB | rest-server `--max-size`, hard (§ 4) |
| `workstations/m5c` | 100 GiB | rest-server `--max-size`, hard |
| `vault` + `appstate` (B2) | 150 GB | alert only; also what keeps the cost estimate above true |

That totals 700 GiB against 1 TiB, with the margin arriving from the ~177 GiB the legacy
rsnapshot tree releases in phase 6. Only the workstation caps are hard limits — they are the
ones facing an untrusted client. The rest are alerts, because a cluster-side job hitting a
hard cap would fail a backup to protect disk space, which is the wrong trade for data the
cluster itself produces.

## Architecture (proposed)

### 1. A dedicated home for irreplaceable data: `/mnt/vault`

Tier-0 data is currently scattered (`/mnt/media/Pictures`, ad hoc locations, Google's
servers). Create a `vaultlv` LV on `hoardvg` mounted at `/mnt/vault`, 200 GiB, matching the
`nofail,x-systemd.automount` pattern in `host/minis/etc/fstab`:

```
/mnt/vault/{credentials,documents,photos,mail,firmware,frigate-exports}
```

This gives the backup job one source root, one sentinel file, one retention policy, and —
most importantly — a clear boundary between the 18 TiB of re-acquirable media and the
~35 GB that cannot be replaced. Move `/mnt/media/Pictures` here;
**verify Plex has no photo library pointed at it before the move.**

Not exported over NFS. `host/minis/etc/exports` continues to export only `/mnt/media` and
`/mnt/games`.

### 1a. NFS access to photos ends with the move

`/mnt/media/Pictures` is reachable today from workstations through the `/mnt/media`
export. **That access is discontinued, deliberately.** Photos become a host-local archive
that is backed up, not a share that is browsed.

This has to be stated rather than assumed, because the obvious shim does not work: a
symlink at `/mnt/media/Pictures` pointing at `/mnt/vault/photos` is resolved in the *NFS
client's* filesystem namespace, not on the server. The client would follow it to its own
`/mnt/vault/photos`, which does not exist there. Nothing on the server is consulted, so
the symlink is not a compatibility shim — it is the same loss of access, disguised as a
dangling link that reads like corruption. **Leave no symlink behind.** An absent path is
the honest signal.

Two other shapes were considered and rejected:

- **`crossmnt` on the `/mnt/media` export**, with a bind mount at `/mnt/media/Pictures`.
  NFSv4 does not cross filesystem boundaries without it, and adding it would expose the
  vault to every media client under the media export's selectors — precisely the boundary
  this design exists to draw.
- **A separate export for photos.** Workable, but it costs a second LV: under
  `no_subtree_check`, NFS filehandles are per-filesystem, so exporting a subdirectory of a
  single vault filesystem would leave credentials and mail behind a barrier the server does
  not actually enforce. Not worth a filesystem split and a third export for browse access
  nothing depends on.

Consequence to accept up front: after phase 3, photos are reachable only on `minis` (and
through a restore). Anything on `ryze` that pointed into `Pictures` over NFS — file
manager bookmarks, scripts, an image-library path — stops resolving, and the fix is to
work from the workstation's own copy or restore from the vault repo. If browse access
turns out to be wanted later, the answer is Immich — already the candidate for ongoing
photo capture under [Deferred](#deferred-documented-not-built) — serving over HTTP from
the vault, an application boundary rather than `sec=sys`.

### 2. Generic dataset backup job

The existing `backup.sh` is purpose-built for the `/opt` contract and should stay that way —
coupling photo backups to a Plex DB export means a Plex failure silently stops protecting
photos. Instead add a second, simpler script, `backup-dataset.sh`, in a new
`infrastructure/monitoring/restic-vault-config.yaml` ConfigMap. It reuses the proven pieces
of `restic-nas-config.yaml` — `log`/`die`/`require_env`, `assert_fresh_file`, explicit
retention args — but drops the app-specific dump logic and adds guards that matter for bulk
data:

- **Sentinel assertion.** Each source root must contain a `.backup-sentinel` file.
  `/mnt/vault` uses `x-systemd.automount` like its sibling LVs; a failed automount presents
  an *empty directory*, not an error. Without this check the job cheerfully backs up nothing.
- **Floor assertions.** Per-source minimum file count and minimum byte size, from the
  ConfigMap.
- **Snapshot manifest.** The job writes `backup-manifest.json` into `/work` and passes it as
  an extra backup path, so every snapshot carries its own description: dataset contract
  version, the list of required source roots, a SHA-256 of the exclusions file, and the
  per-root file count and byte size the run measured. This is deliberately *lighter* than
  the `appstate` contract — it asserts what was in scope, not that a fixed set of dumps was
  freshly produced — but it closes the same class of hole: a source root silently dropped
  from the ConfigMap takes its own floor assertion with it, so without a manifest the only
  thing left to notice is the shrink guard, and a small root does not move the total enough
  to trip it. The backup run fails if the manifest's required roots do not match the
  configured set, and restore validation rejects any snapshot whose manifest is missing,
  carries an unknown contract version, or lists roots or an exclusions hash the restore was
  not expecting — the same rejection `runbooks/disaster-recovery/` already performs for
  `appstate`. Bump the contract version whenever roots or exclusions change, in the same
  commit.
- **Shrink guard.** Compare the new snapshot against a *healthy baseline* — the largest of
  the last N snapshots, not simply the previous one. Comparing against `[-1]` self-heals in
  the wrong direction: once a truncated snapshot lands, the next run measures against the
  truncated one, sees no shrink, and passes. If the new snapshot is smaller than the
  baseline by more than a configured percentage, complete the backup, write a
  `.prune-hold` file into the repo recording the snapshot ID and the reason, and exit
  non-zero. This is the failure mode that actually destroys archives: an empty or truncated
  backup followed by a prune that reaps every good snapshot.
- **Prune decoupled from backup.** A 4-hourly job must not prune. `forget --prune` moves to
  a separate weekly `restic-prune-cronjob.yaml` covering the **new** repos — `vault` and the
  two workstation repos. `appstate` is not included; see below.

  Because the guard now lives in one job and the prune in another, the guard cannot be a
  decision the backup run makes about its own trailing step — a truncated snapshot at 04:00
  and a prune days later are not connected by anything in-process. **The prune job therefore
  re-derives the precondition itself, per repo, before touching that repo:**

  - the newest snapshot is younger than that repo's expected backup interval;
  - its size and file count are within tolerance of the healthy baseline (the same
    comparison the backup-side guard makes, computed independently);
  - every snapshot `forget` would remove has already been replicated to that repo's
    **B2** destination;
  - no `.prune-hold` file is present in the repo.

  The replication precondition is what keeps the off-site recovery window from being
  quietly shorter than the table in [Retention](#retention-proposed) claims. B2 is a pure
  `copy` destination (§ 3), so a snapshot pruned from the NAS before it was copied never
  reaches off-site at all — and nothing downstream would report a gap, because both repos
  look internally consistent. Matching is by the destination snapshot's `original` field,
  falling back to `id` for snapshots born in that repo, never by `id` alone (§ 3).
  Concretely: run `forget --dry-run --json` to get the removal candidates, collect
  `original`/`id` from B2's `snapshots --json`, and skip the repo if any candidate is
  unmatched. A repo skipped this way is the expected steady state when the copy job has
  failed for a while, so it exports the count of unreplicated candidates as a metric and
  `ResticReplicationLag` (§ 9) fires on it — the prune stall itself is the safe outcome,
  not the problem to fix.

  **Only B2 gates pruning. The offline drives deliberately do not.** They are disconnected
  by design — that is the entire point of the control — so the prune job cannot query them,
  and gating on them would mean either blocking NAS retention until the next rotation (up
  to 90 days, or 180 for a snapshot whose turn falls on the other drive) or trusting a
  stale ledger of what a drive held when it was last plugged in. Instead, **each rotation
  captures a checkpoint rather than mirroring history.** At rotation time the operator tags
  the newest `vault` and `appstate` snapshots `offline-checkpoint-<YYYY>-Q<n>`, copies
  exactly those to the drive in the same session, and records the tag and snapshot IDs in
  the drill table under [Verification](#verification-proposed). Nothing about that decision
  happens while the drive is absent, so there is no ordering constraint for prune to
  enforce and no ledger to drift.

  The consequence to accept: a snapshot created and pruned between two rotations never
  reaches offline media. That is correct for what this copy is *for* — a quarterly,
  cluster-proof checkpoint of current state, not a continuous third mirror. Continuous
  coverage is B2's job, and B2 is the one the prune job can actually verify. (A per-drive
  replication ledger consulted by prune was the alternative; it buys offline coverage of
  intermediate snapshots at the cost of a persisted inventory that is unverifiable for 90
  days at a stretch, and it would still stall NAS pruning whenever a rotation slipped. The
  weaker guarantee that cannot silently rot is the better trade here.)

  Any repo failing a check is skipped — not the whole job — and its skip is exposed as a
  metric so `ResticPruneOverdue` (§ 9) fires on the stall. The `.prune-hold` file is the
  fast path, not the mechanism: prune stays safe on a repo whose backup job crashed before
  writing anything, never ran, or was deleted outright. Clearing a hold is an operator
  action — look at the snapshot, then remove the file — and the repo resumes pruning on the
  next weekly run.

Same security posture as the existing cronjobs: `readOnlyRootFilesystem`, `drop: [ALL]` plus
`DAC_OVERRIDE`, `automountServiceAccountToken: false`, `priorityClassName: homelab-low`,
`nodeSelector` on `minis`, emptyDir `/work` and `/tmp`.

### 3. Replication by `restic copy`, not re-reading the source

Off-site copies come from a `restic-copy-cronjob.yaml` that replicates NAS → B2, rather than
a second independent read of the source. What this buys is **one traversal of the source
tree**: `/mnt/vault` is read by the backup job and written to `/mnt/backups`; the copy job
then reads `/mnt/backups`. (The array is not read once — `/mnt/backups` lives on it too.
The win is that off-site replication never walks the vault tree a second time and cannot
be blocked by a busy or unmounted source.)

It does **not** remove contention. Both jobs touch `/mnt/backups` and the same array, and
nothing prevents a copy from overlapping a backup, so the copy schedule is offset from the
4-hourly cadence and both jobs must tolerate finding the other running. `backup` and `copy`
take non-exclusive repo locks and coexist; the weekly prune takes an exclusive one, which
is a further reason it lives in its own job (§ 2) rather than tailing a backup.

**Chunker parameters are inherited at *destination* init, from the source repo:**

```
restic -r <DEST> init --from-repo <SOURCE> --copy-chunker-params
```

`copy` transfers blobs as they are; it does not re-chunk them. What mismatched parameters
break is *cross-repository deduplication*: blobs arriving from the source are chunked one
way and anything the destination chunked itself another, so identical data is stored twice
and the destination's footprint diverges from the source's. This cannot be retrofitted
without rebuilding the destination, which makes it the most order-sensitive item in the
design — but the constraint lands on B2 and the offline drive, not on the NAS repo.

**The `vault` NAS repo is initialized normally** (`restic init`, no flags); it is the
source everything else inherits from. B2 and each offline destination are then initialized
`--from-repo` the NAS repo, so all three share one chunker configuration.

**Copied snapshots do not keep their IDs.** `restic copy` re-creates the snapshot in the
destination, which gets a new ID and records the source ID in its `original` field (visible
in `snapshots --json`). Two consequences worth being explicit about:

- **A restore drill on one repo is not evidence about the other.** It says nothing about the
  destination's pack files, index, or B2's stored bytes. Each repo needs its own drill —
  which is why [Verification](#verification-proposed) lists a local restore *and* a
  from-B2 restore as separate line items, each running its own
  `restic check --read-data-subset` the way `runbooks/phase5/05-validate-restore.sh` and
  `09-validate-b2-restore.sh` already do.
- **Correlation is by `original`, not by ID.** Anything matching snapshots across repos —
  the copy job's "is this already replicated?" check, the prune job's per-repo newest-
  snapshot metric, an operator eyeballing a drill — must compare `original` (falling back
  to `id` for snapshots born in that repo), never `id` alone.

The existing `appstate` pipeline keeps its independent-read model, **and its inline
retention**: `restic-nas-config.yaml` runs `restic forget … --prune` at the end of its own
backup, immediately after a run that has already hard-failed unless every contract artifact
was freshly produced.

The two controls are **orthogonal, not ranked**. Contract v2 asserts that a fixed set of
required artifacts exists, is fresh, and is internally consistent; the shrink guard asserts
that the snapshot as a whole did not lose bulk it had last time. Neither implies the other.
A large partial deletion elsewhere under `/opt` — outside the eight exports, the k3s dump,
the Home Assistant archive, and the RomM dump — passes contract v2 untouched and would be
pruned inline with nothing to stop it. That is a real gap, and it is not closed here.

Keeping `appstate` on inline pruning is therefore an explicit compatibility choice, with
that shrink risk accepted: this is a working, DR-drilled pipeline, bringing it under the
weekly job would mean two processes pruning one repo under two different policies, and the
rewrite carries more risk today than the gap does. Revisit it if `/opt` grows content that
no contract artifact covers, or once the vault job's guard has run long enough to be worth
porting back.

### 4. Workstations push via append-only REST server

`ryze` and `m5c` aren't cluster nodes. Run `restic/rest-server` in-cluster
(`infrastructure/monitoring/rest-server-*.yaml`), backed by a hostPath on `/mnt/backups`,
exposed over the existing Tailscale operator so the MacBook works off-LAN.

The goal is that a workstation which is compromised, wiped, or ransomwared can add
snapshots but cannot delete or rewrite history, so the recovery path survives the client.
Getting there means keeping three separate things straight — they are easy to collapse into
one "key", and the design does not work if they are:

| | What it is | What it controls |
|---|---|---|
| `--append-only` | a **process flag** on the rest-server binary | deletes and overwrites, for *every* user of that server. There is no per-user append-only credential |
| htpasswd user + password | HTTP authentication | who may reach the endpoint, and — with `--private-repos` — which repo path under it |
| restic repo password | repository encryption | decrypting contents. It grants **no** delete permission through an append-only endpoint; that is the server's call, not the crypto's |

So the server runs `--append-only --private-repos`, and each workstation gets its own repo
path (`/mnt/backups/workstations/{ryze,m5c}`), its own htpasswd credential, and its own repo
password. `--private-repos` is what stops an authenticated `ryze` from reaching `m5c`'s path
at all; distinct repo passwords are what keep it from reading the contents if it does.

**Pruning cannot go through the REST endpoint.** No credential deletes through an
append-only server, so the weekly prune job (§ 2) addresses these repos **directly on the
filesystem** — `restic -r /mnt/backups/workstations/ryze forget --prune` — using the same
hostPath the rest-server is backed by. This is why prune is a cluster-side job rather than
something a client triggers, and it avoids standing up a second, non-append-only Service
whose only purpose would be to hold delete rights.

Prune and a client push do **not** run concurrently: `forget --prune` takes an *exclusive*
repo lock, and restic's locking is enforced on the repo itself, so it applies equally whether
a process arrived over REST or over the hostPath. Locking makes overlap safe, not free — the
loser of a race fails rather than corrupting anything. Give the workstation wrappers
`--retry-lock` (a few minutes is plenty for these repo sizes) and schedule the weekly prune
away from the workstation timers, so a legitimate overlap waits instead of paging.

**Workstation retention is duration-based, not count-based.** Append-only stops a compromised
client from deleting, but not from *pushing*: a flood of snapshots with attacker-chosen
timestamps can walk the real ones out of a `--keep-daily 14`-style window, and prune then
does the deleting on its behalf. These repos therefore use `--keep-within-daily 30d
--keep-within-weekly 12w --keep-within-monthly 12m` (and `--group-by host` — see
[Retention](#retention-proposed)), which is anchored to wall-clock age and
cannot be pushed out by snapshot volume. This is restic's own guidance for append-only
repositories ([security considerations in append-only
mode](https://restic.readthedocs.io/en/stable/060_forget.html#security-considerations-in-append-only-mode)).

**Cap each repo with rest-server's `--max-size`.** The remaining lever a compromised client
keeps is filling the disk, and `/mnt/backups` is shared with `appstate` and `vault` — an
unbounded push takes down the pipelines that matter most. A per-repo cap — 100 GiB each,
against ~5 GB of curated home directory (see
[Capacity ceilings](#capacity-ceilings-proposed)) — turns that from an outage into a failed
workstation backup and a `ResticWorkstationBackupStale` alert (§ 9).

Client config is canonical in this repo under `host/ryze/` and `host/m5c/`, mirroring the
existing `host/minis/etc/` and `host/bastion/etc/` convention:

- `host/ryze/` — systemd service + timer, `restic-excludes`, wrapper script
- `host/m5c/` — launchd plist, `restic-excludes`, wrapper script

Excludes target the obvious bulk (`.cache`, `node_modules`, virtualenvs, Steam, container
images, build dirs) plus `--exclude-caches` to honor `CACHEDIR.TAG`. Target ~5 GB from the
69 GB used on `ryze`. On macOS, exclude `~/Library/Caches` and the Photos/Mail libraries but
**include** `~/Library/Application Support` for app state.

### 5. Google Photos → local canonical

**One-time Takeout bootstrap; ongoing capture deferred.**

The API path (gphotos-sync, rclone's Google Photos backend) strips GPS EXIF and
recompresses, so it is the wrong tool for building an archive intended to be kept forever.
Takeout preserves originals and ships sidecar JSON with the metadata Google holds.

`runbooks/phase6/02-seed-vault-from-takeout.sh` unpacks the Takeout archives into
`/mnt/vault/photos`, merges the sidecar JSON back into file mtimes, de-duplicates against
the existing pre-2018 local archive, and reports counts to eyeball before the first backup
runs. Until ongoing ingestion is solved, photos taken after the bootstrap are protected only
by Google — see [Deferred](#deferred-documented-not-built).

### 6. Mail archive

`mbsync` (isync) CronJob against Gmail via IMAP with an app password, writing a maildir to
`/mnt/vault/mail`. Config in `apps/mail-archive/`, secret as `mail-archive.sops.yaml`
following the `.sops.yaml` `encrypted_regex: ^(data|stringData)$` rule. Because it lands
under `/mnt/vault`, it inherits vault cadence and retention with no extra backup wiring.

### 7. Frigate — exports in, recordings out

Recordings on `/mnt/frigate` stay unprotected, permanently and on purpose. The reason is not
cost:

- **A backup would override the retention policy.** `apps/frigate/config.yml` sets continuous
  recording to 1 day, detections to 30, alerts to 365. A repo with `keep-monthly 12` converts
  *all* of that into a year of retained footage of the house sitting in Backblaze. That is a
  privacy decision worth making deliberately, not inheriting from a default.
- **Dedup gains are ~zero.** H.264/H.265 segments are already compressed and unique per
  segment, so restic stores essentially the full byte volume.
- **The recovery window is wrong.** Camera footage has value in hours and days. Nobody
  restores security video from a monthly snapshot; if something happens you export the clip
  immediately.

That last point identifies what *is* worth keeping. Frigate exports — clips explicitly saved
— are irreplaceable the moment source retention rolls past them, and they currently live at
`/media/frigate/exports` on the same `/mnt/frigate` LV as everything else, with no second
copy.

Add a second hostPath volume to `apps/frigate/deployment.yaml` mounting
`/mnt/vault/frigate-exports` at `/media/frigate/exports`, nested inside the existing
`/mnt/frigate` → `/media/frigate` mount. Frigate writes exports via ffmpeg rather than
hardlinking, so crossing filesystems is safe. Exports then inherit vault cadence, off-site
replication, and the offline copy with no additional backup wiring.

Frigate config and `frigate.db` are already protected — `/opt/frigate/config` is inside the
existing `appstate` source and `frigate/config/frigate.db` is in the
`REQUIRED_SQLITE_DATABASES` inventory, so the contract already hard-fails if it cannot be
exported. Nothing to add.

**One DR note:** after an `appstate` restore, `frigate.db` will reference recording files
that no longer exist. Frigate tolerates this, but the log noise is alarming if unexpected —
worth a line in `runbooks/disaster-recovery/README.md`.

### 8. Break-glass — the part that makes the rest real

Restic repo passwords live in SOPS in this repo; the age key that decrypts them lives in
`age.key` and in the password manager. The password manager export is one of the things
being backed up. **That is a circular dependency: a total loss of `minis` plus loss of
password-manager access makes every backup unreadable.**

The fix is offline and outside the system: a printed / physically-stored card carrying the
age public+private key, all restic repository passwords, the B2 application key ID and
secret, and a one-page pointer to `runbooks/disaster-recovery/`. Two copies, two locations —
one with the rotated external drive, one elsewhere. This document records what is on the
card and when it was last refreshed; the material itself never enters git.

The offline drive uses a **distinct repo password** from the online repos, so leaked cluster
secrets do not grant access to the immutable copy.

| Break-glass card | Status |
|---|---|
| Last refreshed | *not yet produced* |
| Copy 1 location | *TBD — with the rotated offline drive* |
| Copy 2 location | *TBD — separate site* |

### 9. Alerting

Extend the `homelab.backups` group in `infrastructure/monitoring/configs/alert-rules.yaml`,
following the established pattern exactly — including `or absent(...)` so a deleted CronJob
still fires:

| Alert | Condition |
|---|---|
| `ResticVaultBackupOverdue` | no success in 8h (critical) |
| `ResticVaultCopyOverdue` | no B2 copy in 36h (critical) |
| `ResticWorkstationBackupStale` | newest `ryze`/`m5c` snapshot older than 7d (warning) |
| `ResticPruneOverdue` | no prune in 10d (warning) |
| `ResticOfflineDriveStale` | last offline rotation older than 120d (warning) |
| `ResticReplicationLag` | prune skipped a repo for unreplicated snapshots on two consecutive runs (warning) |
| `ResticRepoNearCeiling` | repo size above 80% of its ceiling (warning) |
| `VaultFilesystemDeviceError` | extend existing `BulkStorageMountSetIncomplete` to cover `/mnt/vault` |

Widen the existing `ResticBackupFailed` and `ResticBackupSuspended` regexes from
`restic-(nas|b2)-backup` to cover the new job names. Workstation and offline-drive staleness
cannot key off `kube_cronjob_status_last_successful_time`, so they need a small metric
surface — the prune job writes a textfile/Pushgateway metric with each repo's newest
snapshot timestamp per host.

Dead Man's Snitch continues to cover the "monitoring itself is down" case.

## Files (proposed)

**New — `infrastructure/monitoring/`** (add each to `kustomization.yaml`):
`restic-vault-config.yaml`, `restic-vault-cronjob.yaml`, `restic-vault.sops.yaml`,
`restic-copy-config.yaml`, `restic-vault-copy-cronjob.yaml`,
`restic-workstations-copy-cronjob.yaml`, `restic-prune-cronjob.yaml`,
`rest-server-deployment.yaml`, `rest-server-service.yaml`, `rest-server-storage.yaml`,
`rest-server.sops.yaml`

**New — elsewhere:** `apps/mail-archive/`, `host/ryze/`, `host/m5c/`, `runbooks/phase6/`
(00-preflight → 12, plus `lib.sh` and `README.md` per `runbooks/README.md` conventions)

**Modified:** `apps/frigate/deployment.yaml` (exports volume),
`infrastructure/monitoring/kustomization.yaml`,
`infrastructure/monitoring/configs/alert-rules.yaml`, `host/minis/etc/fstab`,
`docs/architecture.md`, `docs/operations.md` (retire the deferred item **only once
implemented**), `host/minis/etc/exports` (update the "no backup policy yet" comment),
`AGENTS.md` (decision log — record the discontinued photo export)

**Unchanged:** the exports themselves. No `exportfs` change, so
[`runbooks/nfs-exports/`](../runbooks/nfs-exports/) does not need re-running.

**Reused as-is:** the `containers/restic-backup/` image (already carries bash, sqlite, curl,
jq — no rebuild needed unless mbsync moves in-image), `runbooks/lib.sh`, the SOPS/age flow,
the `homelab-low` priority class, and the `assert_fresh_file` / contract-version pattern.

## Phasing (proposed)

Ordered so the highest-value, least-reversible data is protected first.

1. **Vault foundation** — create `vaultlv`, seed credentials + documents, init the `vault`
   NAS repo *normally* — it is the chunker-params source for every later destination
   (§ 3) — first backup, **restore drill**.
   Protects the irreplaceable-and-tiny within the first sitting.
2. **Break-glass card** — produce and distribute it. Do this before there is enough in the
   repos to feel safe, not after.
3. **Photos** — move `/mnt/media/Pictures` into the vault (NFS photo access ends here,
   § 1a — announce it before the move, not after), then Takeout bootstrap, de-dup against
   the local pre-2018 archive, verify counts, fold into vault.
4. **Off-site** — init the B2 vault repo with
   `init --from-repo <NAS> --copy-chunker-params`, wire the copy job, drill a restore
   *from B2* (a passing NAS drill is not evidence about B2 — § 3), add alerts.
5. **Workstations** — rest-server with `--append-only --private-repos` and a per-client
   repo path, htpasswd credential, and repo password (§ 4); point the weekly prune job at
   those repos over hostPath, not REST; enroll `ryze`, then `m5c`.
6. **Housekeeping** — firmware into vault, Frigate exports volume, disk-image GC policy,
   retire the legacy rsnapshot tree on `/mnt/backups` (validate it holds nothing unique
   first — it is ~177 GiB of reclaimable space).
7. **Mail archive** — mbsync app.
8. **Offline drives** — init **both** drives `--from-repo <NAS> --copy-chunker-params`
   (with their own distinct password, § 8) so the alternating rotation has somewhere to go
   from the first quarter onward; first rotation, restore drill from the drive, record the
   rotation date in the drill table.

## Verification (proposed)

Backups are only worth what a restore proves, so every phase ends with one.

- **Per-phase restore drill, per repo.** `runbooks/phase6/06-validate-vault-restore.sh`
  restores to a scratch path and diffs against source, in the shape of the existing
  `runbooks/phase5/05-validate-restore.sh` and `09-validate-b2-restore.sh` — including
  their `restic check --read-data-subset=1/100`. Every repo gets its own: a copy
  destination shares no storage with its source and a passing drill upstream proves
  nothing about it (§ 3).
- **Guard-rail tests, deliberately.** Unmount `/mnt/vault` and confirm the sentinel check
  fails the job. Point the job at a truncated source and confirm the shrink guard fails the
  run and writes `.prune-hold`; then run the prune job and confirm it skips that repo. Run
  the prune job a second time with `.prune-hold` removed but the truncated snapshot still
  newest, and confirm it *still* skips — that is the check that proves the prune job's own
  precondition works rather than merely trusting the marker. These are the checks that
  matter most and the ones that silently rot if never exercised.
- **Manifest rejection.** Restore-validate a snapshot whose manifest lists a source root
  the restore does not expect, and confirm the drill script refuses it rather than
  reporting a successful restore of a partial dataset.
- **Copy-before-forget.** Pause the copy job for long enough that the NAS repo holds
  snapshots B2 does not, then run the prune job and confirm it skips the repo, exports a
  non-zero unreplicated-candidate count, and prunes normally on the next run once the copy
  job has caught up.
- **Off-site independence.** Restore a document and a photo from B2 on a machine that is not
  `minis`, using only the break-glass card — no access to this repo's decrypted secrets.
  This is the only test that validates the disaster path end to end.
- **Vault is not reachable over NFS.** From `ryze`, confirm `/mnt/vault` is not exported
  and cannot be mounted, and that no path under `/mnt/media` resolves into it.
- **Append-only proof.** From `ryze`, attempt `restic forget` against the workstations repo
  and confirm it is rejected.
- **Alert proof.** Suspend each new CronJob and confirm the corresponding alert fires to
  Pushover; `runbooks/phase5/12-test-pushover.sh` is the existing precedent.
- **Flux reconciliation.** `flux reconcile kustomization monitoring --with-source`, then
  confirm no drift and all new CronJobs are scheduled.
- **Quarterly drill**, recorded in the table below with a date — pair it with the offline
  drive rotation so one trip to the safe covers both. The rotation entry records which
  drive was rotated, the `offline-checkpoint-<YYYY>-Q<n>` tag applied, and the snapshot IDs
  copied under it (§ 2), so the contents of a disconnected drive are known without
  connecting it.

| Drill | Last run | Result |
|---|---|---|
| `appstate` local + B2 restore | 2026-08-16 | passed (contract v1 at the time) |
| `vault` local restore | *not yet* | — |
| `vault` B2 restore, break-glass only | *not yet* | — |
| Offline drive rotation (drive A) | *not yet* | — |
| Offline drive rotation (drive B) | *not yet* | — |

## Deferred (documented, not built)

- **Ongoing photo capture.** Until phone uploads land on the array directly (Immich is the
  obvious candidate and already a planned follow-up), post-bootstrap photos are protected
  only by Google. This is the largest remaining gap and should be the next project after the
  bootstrap.
- **`/mnt/media` library** (18 TiB) — re-acquirable, deliberately unprotected.
- **`/mnt/games`** — out of scope by decision. If revisited, the shape is a ROM-only job
  (~8 GB, disk-based systems excluded) against a `bulk` repo, NAS-only, weekly. Adding it
  later is additive: a new repo, one CronJob, one overdue alert. Nothing in this design needs
  to change to accommodate it.
- **Frigate recordings** — excluded on privacy and recovery-window grounds, not cost.
  Revisit only if the camera setup ever produces footage with retention requirements of its
  own; the answer gets *stronger*, not weaker, as cameras are added.
- **Immutable off-site.** The cluster retains delete authority on B2, consistent with the
  tradeoff already accepted in `runbooks/phase5/README.md`. The offline drive is the
  compensating control.
- **Disk images** — local only, age-based GC, never replicated. Useful in the window around
  a planned upgrade and of rapidly decaying value afterward.
