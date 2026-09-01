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
>
> **Revised 2026-08-30:** `/mnt/vault` is now specified as a LUKS2 volume unlocked manually
> by an operator after each boot (§ 1b). Manual unlock must not delay the host, k3s, camera
> recording, or the existing `appstate` pipeline. Once built, the proposed workstation
> pipeline must remain independent of the vault too. Only vault backup/copy/prune work and
> mail archival degrade while locked, and they alert rather than fail. Vault
> repository, B2, and Gmail archive credentials live inside the encrypted boundary rather
> than in SOPS, so theft of the powered-off node does not supply either a Restic copy and its
> key or a credential that can read the mailbox. Frigate exports
> therefore stay on `/mnt/frigate` and are synced into the vault (§ 7) instead of the vault
> being mounted into the container, as an earlier draft had it.
>
> **Revised 2026-08-31:** recovery objectives are now explicit; Strongbox's encrypted
> `~/Dropbox/ccs.kdbx` file replaces the earlier generic "credentials export" and has a
> concrete restricted-SFTP ingestion contract (§ 1c); workstation B2 storage is one
> destination repository per host; and the capacity, alerting, metric, integrity-check, and
> restore-drill inconsistencies found during review are corrected below.
> Strongbox uses only a master password; both workstations use their existing `~/Documents`
> trees rather than a staging directory; and the two already-owned 2 TB portable USB SSDs
> alternate as the offline tier. Quarterly rotations are deliberately lightweight, with one
> substantive offline restore and full data check per year rather than every quarter.

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
| `vault` | Strongbox/KeePass database archive, documents, photos, mail archive, firmware, Frigate exports | ~35 GB (+5 GB/yr) | **every 4h once ingested** | daily (copy) | quarterly (copy) |
| `appstate` | `/opt`, k3s datastore, hot dumps — **existing, unchanged** | ~20 GB | nightly | weekly | quarterly (copy) |
| `workstations` | `ryze` home (curated), `m5c` home (curated) | **~70 GB** (`ryze` 50, `m5c` 20) | daily push | weekly (copy) | — |
| *(none)* | disk images, Frigate **recordings**, `/mnt/media`, `/mnt/games` | 18 TiB+ | local only, GC'd | — | — |

Photos and documents land in all three columns — RAID6, Backblaze, and an offline disk.
That is the 3-2-1 target, and the offline disk is the only copy the cluster has no
authority to delete.

The vault cadence starts only after data reaches `/mnt/vault`; it is not an ingestion
guarantee. The Strongbox database has its own source-to-vault contract (§ 1c):
`~/Dropbox/ccs.kdbx` is offered by `ryze` every four hours, ingestion alerts at 36 hours,
and the next vault run protects an accepted file within another four hours. Ordinary
documents are offered daily from each workstation's `~/Documents` tree, with a seven-day
staleness alert, and remain independently protected by the daily workstation repositories.
Post-bootstrap phone photos remain Google-only until the deferred photo-ingestion project
is built. These distinctions prevent a four-hour repository schedule from being misread as
a four-hour RPO for data that has not arrived.

**The workstation figure is deliberately pessimistic.** `ryze` is budgeted at **50 GB**
against the ~5 GB an aggressive exclude list is expected to yield from the 69 GB currently
used, because the two numbers measure different failure modes. The 5 GB is what the design
*aims* to produce; the 50 GB is what the capacity plan must survive if the exclude list is
less effective than hoped, if the curated set grows, or if a future enrollment is scoped
more broadly than the first. Sizing the cap to the target is how a 5 GB estimate becomes a
disk outage. `m5c` carries 20 GB on the same reasoning from a smaller starting set. The
phase 5 preflight measures the actual post-exclude size and records it here, so the
pessimistic number is replaced by a measured one rather than left as a permanent guess.

B2 cost at the expected footprint is roughly **$0.70–1.00/month**. The policy ceilings
below bound the total B2 footprint at **300 GB** (100 vault + 50 appstate + 150
workstations), or roughly **$2.10/month at the price checked when this draft was written**;
re-check B2 storage and egress pricing during implementation rather than treating either
figure as permanent. Cost is not a constraint here — but
"generous" is not a policy, so retention is stated as concrete arguments with the recovery
window each one buys and bounded by an explicit ceiling per repository.

### Retention (proposed)

Cadence sets the *recovery point*; retention sets the *recovery window*. Both belong in this
table, because a policy that names only one cannot answer "how far back can I recover this
file?"

| Repository | Retention arguments | Nominal RPO | Max tolerated staleness | Recovery window | Applied by |
|---|---|---|---|---|---|
| `vault` (NAS) | `--keep-within-hourly 48h --keep-within-daily 30d --keep-within-weekly 12w --keep-within-monthly 24m` | 4h | 8h (`ResticVaultBackupOverdue`) | 24 months | weekly prune job (§ 2) |
| `vault` (B2) | `--keep-within-hourly 48h --keep-within-daily 30d --keep-within-weekly 12w --keep-within-monthly 24m` | 24h | 36h (`ResticVaultCopyOverdue`) | 24 months | weekly prune job, against the B2 repo |
| `vault` (offline) | **none — `forget` never runs**, see below | 90d | 120d (`ResticOfflineDriveStale`) | full history of the drive | nothing prunes it |
| `appstate` (NAS) | `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` — **existing, unchanged** | 24h | 30h (`ResticLocalBackupOverdue`) | ~12 months | inline in `restic-nas-backup` (§ 3) |
| `appstate` (B2) | `--keep-weekly 8 --keep-monthly 12` — **existing, unchanged** | 7d | 8d (`ResticB2BackupOverdue`) | ~12 months | inline in `restic-b2-backup` |
| `appstate` (offline) | none — `forget` never runs | 90d | 120d (`ResticOfflineDriveStale`) | full history of the drive | nothing prunes it |
| each workstation (NAS) | `--keep-within 30d --keep-within-daily 30d --keep-within-weekly 12w --keep-within-monthly 12m` | 24h | 7d (`ResticWorkstationBackupStale`) | every snapshot for 30d; selected history for 12 months | weekly prune job, over each hostPath (§ 4) |
| `workstations/ryze` (B2) | `--keep-within 30d --keep-within-weekly 12w --keep-within-monthly 12m` | 7d | 8d (`ResticWorkstationCopyOverdue`) | every copied snapshot for 30d; selected history for 12 months | weekly prune job, against the `ryze` B2 repo |
| `workstations/m5c` (B2) | `--keep-within 30d --keep-within-weekly 12w --keep-within-monthly 12m` | 7d | 8d (`ResticWorkstationCopyOverdue`) | every copied snapshot for 30d; selected history for 12 months | weekly prune job, against the `m5c` B2 repo |

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

For every new NAS→B2 repository pair, the shared job always applies NAS retention first and
B2 retention second. The destination policy must never discard a snapshot before the source
policy makes that same lineage eligible: in particular, vault B2 repeats NAS's
`--keep-within-hourly 48h` tier even though copies run only daily. This ordering lets the
NAS-side gate prove that every source removal candidate is still physically present in B2;
only after the source forget succeeds may B2 independently remove lineages selected by its
own policy.

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

### Recovery-time objectives (proposed)

These are loose operational targets, not availability SLAs. The clock starts when an
operator begins recovery with compatible replacement hardware, repository credentials,
and network access available; hardware procurement and operator unavailability are outside
it.

| Dataset | Recovery target |
|---|---|
| `appstate` | core cluster services restored within 24h |
| `vault` | priority documents and `ccs.kdbx` restored within 24h; full vault within 72h |
| `workstations` | curated home restored within 7d after the replacement OS is ready |
| Mail archive and Frigate exports | restored within 7d; neither blocks service recovery |
| Offline-drive recovery | best effort within 7d, including retrieval of the drive |

Restore drills record elapsed restore time as well as success. If repeated drills miss a
target, change the target or the procedure explicitly rather than continuing to call it an
objective without evidence.

**Offline media are cumulative, and there are two drives.** The two already-owned drives
are 2 TB portable USB SSDs from different production batches. Each is initialized with GPT
and one ext4 filesystem, given a unique label and recorded filesystem UUID, and mounted only
by the attended rotation runbook with `noauto,nodev,nosuid,noexec`. The filesystems do not
add LUKS: Restic already encrypts repository contents and metadata, and another passphrase
would add a recovery dependency without changing the offline threat model. Each physical
drive holds two separate persistent repositories, `vault` and `appstate`; it is never one
mixed repository.
All four repositories are only ever copied *into*: `forget` and `prune` never run against
offline media, and a repository is retired by re-initializing it (`--from-repo`, § 3), not
by pruning it. The two drives alternate quarterly, so the newest offline copy is
at most **90 days old** when rotations happen on time, and **180 days** if the most recent
drive is lost, destroyed, or unreadable. A skipped rotation extends both figures without
limit, which is what the alerts exist to catch. `ResticOfflineDriveStale` evaluates the
newest successful rotation across **either** drive and fires at 120d, so it catches a missed
quarterly rotation without paging merely because the other drive is waiting its normal
turn. A separate per-drive `ResticOfflineDriveRotationOverdue` fires at 210d: each physical
drive is normally updated every 180d, and the extra 30d allows scheduling slack while still
detecting that one SSD was skipped or repeatedly left out of rotation (§ 9). At ~35 GB
growing 5 GB/yr with no pruning, either 2 TB drive has ample headroom for the intended
retention; capacity is measured during rotation rather than projected from a fixed
replacement date.

The drive not being updated remains off-site throughout the attended rotation. The operator
retrieves only the drive whose turn it is and runs one attended command. The runbook verifies
the recorded device and filesystem UUIDs, mounts the expected ext4 filesystem, copies a
**tagged checkpoint** containing the newest validated `vault` and `appstate` snapshots,
confirms both checkpoints are listable from the drive, records the snapshot IDs and success
metric, runs `sync`, and unmounts cleanly. It does not require a quarterly filesystem repair,
SMART test, full repository read, or test restore. The drive returns off-site before the
other drive may be brought home. The reasoning, and why offline media are deliberately
excluded from prune's replication gate, is in § 2.

Once per year, the rotation runbook performs the confidence-building work omitted from the
quarterly path: on the SSD in rotation it runs `restic check --read-data` for both
repositories and restores `ccs.kdbx`, one representative document, and the `appstate`
backup manifest to scratch. The selected SSD alternates by year so each physical drive
receives the full check at least every two years. Filesystem repair and deeper device
diagnostics are response actions for an unclean mount, I/O error, or failed repository
operation, not routine quarterly ceremony. A drive is replaced after persistent errors;
there is no arbitrary age-based retirement date. This intentionally accepts less assurance
than validating both drives every quarter in exchange for a rotation an operator will
realistically perform.

### Capacity ceilings (proposed)

`/mnt/backups` is a single 1 TiB `backuplv` shared by every local repository, so generous
retention needs a bound or the vault job and `appstate` eventually compete for the same
disk. Each repository gets a ceiling, and the prune job exports its size so the ceiling is
observable rather than aspirational:

| Repository | Ceiling | Enforcement |
|---|---|---|
| `vault` (NAS) | 250 GiB | `ResticRepoNearCeiling` at 80% (§ 9) |
| `appstate` (NAS) | 250 GiB | same |
| `workstations/ryze` | 150 GiB | dedicated rest-server `--max-size`, hard (§ 4) |
| `workstations/m5c` | 100 GiB | dedicated rest-server `--max-size`, hard (§ 4) |
| `vault` (B2) | 100 GB | alert only |
| `appstate` (B2) | 50 GB | alert only |
| `workstations/ryze` (B2) | 100 GB | alert only |
| `workstations/m5c` (B2) | 50 GB | alert only |

That totals 750 GiB locally against 1 TiB, with the margin arriving from retiring the legacy
rsnapshot tree in phase 6. Only the workstation caps are hard limits — they are the
ones facing an untrusted client. The rest are alerts, because a cluster-side job hitting a
hard cap would fail a backup to protect disk space, which is the wrong trade for data the
cluster itself produces. A separate filesystem-level alert fires when `/mnt/backups` has
less than 20% free (warning) or 10% free (critical), independently of the per-repository
measurements; the sum of soft ceilings is not itself an enforcement mechanism.

**The 750 GiB is a ceiling sum, not a forecast, and part of the margin is not yet freed.**
Expected steady-state occupancy is far lower — `appstate` is ~20 GB of source today, and
even the pessimistic 50 GB / 20 GB workstation budgets are well under their caps — so the
ceilings are headroom against growth rather than a prediction. What makes them safe to
grant is retiring the legacy rsnapshot tree, and the figure this draft budgets needs
correcting: `~177 GiB` is the **whole-filesystem** usage recorded in the migration worklog,
not a measurement of the tree. The only direct measurement (2026-08-30) puts
`/mnt/backups/snapshots/` at **119 GiB**; the remaining ~58 GiB is other content on the LV.
Plan on the measured 119 GiB and have phase 6 account for the difference rather than
budgeting the larger number. The ceiling sum leaves 258 GiB against the 1,008 GiB
filesystem; while the measured 119 GiB legacy tree still exists, the conservative temporary
margin is 139 GiB. The remaining ~58 GiB already on the LV must be classified during phase
6 so current repository data is not counted twice and unrelated content is not omitted.
Re-derive all three numbers from fresh `du` and `df` output before granting the caps. The
150/100 GiB workstation split is intentional; raising both to a round 200 GiB would consume
another 150 GiB and erase most of the pre-cleanup margin.

**The B2 ceilings are split rather than shared, because a shared one hides which dataset
is growing.** Under the earlier single `vault` + `appstate` 150 GB ceiling, the vault —
35 GB today, growing 5 GB/yr, with a 24-month window and no cross-repository dedup benefit
(§ 3) — could consume the whole allowance and leave `appstate` to trip a combined alert
that names neither dataset. `ResticRepoNearCeiling` fires per repo, so a shared number
would make the alert uninterpretable at exactly the moment it matters. The split is
deliberately asymmetric: `vault` gets 100 GB because it holds irreplaceable data with the
longest recovery window, and `appstate` gets 50 GB because its source is ~20 GB with a
12-month window and roughly flat growth. `workstations` rises to 150 GB total to match the
pessimistic 70 GB source budget plus retention headroom. All three remain alerts rather
than hard caps — B2 is billed, not bounded, and a hard cap there would fail a backup to
save a few dollars a month.

### `/mnt/backups` must fail closed

Every local repository and the control/metric state share `/mnt/backups`. Its existing
`nofail,x-systemd.automount` entry keeps a missing array from blocking boot, but that also
leaves an ordinary directory on the root filesystem at the same path. A backup, copy,
prune, verification, or rest-server process that writes there without proving the mount
could fill the root NVMe while appearing to protect data.

Use two independent guards. First, make the *unmounted* `/mnt/backups` directory
`root:root 0555` and immutable, and add a small boot unit that re-asserts those properties
before `mnt-backups.automount`. Mounting the real filesystem over an immutable directory is
allowed; creating an entry in the uncovered directory is not. Second, put a root-owned
`.backup-sentinel` on the mounted filesystem containing its recorded filesystem UUID. Every
writer — the existing `appstate` jobs, vault jobs, workstation rest-server Deployments,
copy/prune/verification jobs, metric writers, and attended offline runbook — must run the
same preflight before opening a repository or destination credential:

- let the configured automount resolve through a read of the expected sentinel (or have an
  attended host runbook explicitly start `mnt-backups.mount`), then resolve the sentinel
  path with `findmnt --target`; never accept an autofs entry as the backing filesystem;
- require source `/dev/mapper/hoardvg-backuplv`, the recorded filesystem UUID, `ext4`, and
  a read-write mount;
- require the sentinel to be a regular root-owned, non-group/world-writable file on that
  same mount and require its contents to match the recorded UUID; and
- fail before creating a directory, writing a metric, or opening a repository on any
  mismatch. A scheduled Job fails non-zero; rest-server has both a startup/init gate and a
  continuing readiness check, and does not accept clients while either fails; an attended
  runbook stops with an actionable error.

The device, UUID, filesystem type, and sentinel are all required: a path-only check accepts
the root filesystem, a sentinel-only check can accept a copied file, and a device-only check
does not prove the intended filesystem was recreated after an accident. Test the guard with
the real mount, an unmounted fixture, a wrong sentinel, a read-only mount, and a disposable
filesystem with the wrong UUID; never unmount the production backup LV merely to manufacture
a failure case.

## Architecture (proposed)

### 1. A dedicated home for irreplaceable data: `/mnt/vault`

Tier-0 data is currently scattered (`/mnt/media/Pictures`, ad hoc locations, Google's
servers). Create a `vaultlv` LV on `hoardvg`, **LUKS2-encrypted** (§ 1b), mounted at
`/mnt/vault`, 200 GiB. Unlike its siblings in `host/minis/etc/fstab` it is **`noauto,nofail`
with no `x-systemd.automount`** — a deliberate divergence from the surrounding pattern, for
the reasons in § 1b. Do not "fix" it back to match its neighbours:

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

### 1b. Encryption at rest, with manual unlock after reboot

`vaultlv` is a LUKS2 container. Every *copy* of this data is already encrypted — the NAS
repo, B2, and the offline drives are all restic repositories — so `/mnt/vault` is the one
place tier-0 material (the Strongbox database archive, documents, mail, photos) would otherwise sit in
plaintext. Nothing else on `minis` is encrypted today; this is the first place it is worth
the complexity, because it is the largest concentration of secrets on the estate.

**Create it encrypted in phase 1, not later.** Retrofitting means `cryptsetup reencrypt` or
a copy-and-swap, and in both cases the original plaintext extents survive on the `hoardvg`
array until something happens to overwrite them. 35 GB is cheap to seed once; it is not
cheap to un-write.

**Unlock is manual and deliberate.** No TPM enrollment, no keyfile on the unencrypted root:
both would auto-decrypt for anyone who powers the machine on, which defeats the threat this
control exists for. The passphrase is entered by an operator over SSH after each boot, via
`host/minis/usr/local/sbin/vault-unlock` (`cryptsetup open` followed by
`systemctl start mnt-vault.mount`). The recovery passphrase is on the break-glass card
(§ 8).

**What this buys, stated plainly.** In steady state the vault is unlocked essentially all
of the time — it is opened after a reboot and stays open for months — so this defends
nothing against an attacker holding root on a running `minis`. What it defends is the
machine seized or stolen **while powered off**, plus drive disposal and RMA returns: a disk
leaving the building with recoverable extents on it is the most likely way this data
escapes, and the only one with no detection whatsoever. That is a narrow guarantee, and it
is the whole of the guarantee.

That guarantee applies to the Restic copies too. Encrypting the source but leaving the
vault repository passwords in a SOPS-managed Kubernetes Secret would not close the theft
path: `age.key`, the decrypted Secret, or both are recoverable from the same unencrypted
root disk, and `/mnt/backups` then supplies an encrypted copy plus its decryption material.
The vault-specific backup credentials therefore live **inside the LUKS boundary**, never in
SOPS or the Kubernetes API.

**Path contract.** `/mnt/vault` is the host mountpoint. It is used only by host-side
configuration and commands: `fstab`, `crypttab`, `vault-unlock`, node-exporter rules,
runbooks operating directly on `minis`, and each Pod volume's `hostPath.path`. Every
Kubernetes container that consumes the vault mounts that whole hostPath at
`/data/vault`. Consequently, every in-container command, environment variable,
mount-identity check, sentinel check, source or destination, and exclusion uses
`/data/vault`. No container mounts it at `/mnt/vault`, and no Pod mounts a vault
subdirectory separately. Examples below call out host paths only when the distinction
matters.

On the host, the repository credentials are:

```
/mnt/vault/.backup-credentials/
├── nas-password
├── b2-password
├── b2-key-id
└── b2-application-key
```

The directory is `root:root` `0700`; every file is a regular, non-symlink `root:root`
`0600` file. The NAS and B2 repository passwords are independent high-entropy values. The
vault uses a dedicated private B2 bucket and application key that the existing
root-resident `appstate` credential cannot access; the proposed workstation credentials
must be denied access when they are created too. Otherwise theft of `minis` would still
grant delete authority over the vault's off-site copy even if its contents remained
unreadable. A prefix in a bucket reachable by an existing key is not sufficient isolation.
The break-glass cards carry all four values (§ 8), so loss of `vaultlv` does not make its
own backups impossible to restore.

The Gmail app password also lives inside the LUKS boundary, but **not** beside credentials
the mail process has no reason to read:

```
/mnt/vault/.mail-credentials/
└── gmail-app-password
```

Reserve numeric UID/GID **`2000:2000`** for the mail archive. The mail-archive preflight
(phase 7 of [Phasing](#phasing-proposed)) fails if
`getent passwd 2000` or `getent group 2000` finds an unrelated host identity; no login
account is required on the host, because hostPath permissions use the numeric IDs directly.
The mounted vault filesystem root is `root:root` `0711`: UID 2000 can traverse a known path
but cannot list the root. This is distinct from the unmounted underlying `/mnt/vault`
directory, which remains `root:root` `0555` plus immutable (§ 1b).

The host permissions are exact:

| Path | Owner | Mode | Mail access |
|---|---|---|---|
| `/mnt/vault/.mail-credentials` | `root:2000` | `0750` | traverse and read directory |
| `/mnt/vault/.mail-credentials/gmail-app-password` | `root:2000` | `0440` | read only |
| `/mnt/vault/mail` | `2000:2000` | `0700` | read and write |
| `/mnt/vault/.backup-credentials` | `root:root` | `0700` | none |

Every credential is a regular, non-symlink file. All other vault datasets deny UID/GID
2000 at their own directory boundary. The app password is also stored in the external
password manager as its independent recovery source; it is not printed on the break-glass
cards because it can be revoked and reissued through Google without being needed to decrypt
an existing backup.

Every vault Pod maps hostPath `/mnt/vault` to `/data/vault`, verifies the backing
filesystem identity at `/data/vault` and then `/data/vault/.backup-sentinel` *before*
looking for credentials, and passes only **paths** in its Pod specification:

- `RESTIC_PASSWORD_FILE=/data/vault/.backup-credentials/nas-password` for the NAS job;
- `RESTIC_FROM_PASSWORD_FILE=/data/vault/.backup-credentials/nas-password` and
  `RESTIC_PASSWORD_FILE=/data/vault/.backup-credentials/b2-password` for NAS → B2
  `restic copy`;
- the corresponding password-file path for each vault prune operation.

They do not mount individual credential files with hostPath `type: File` or `subPath`.
Those paths correctly do not exist while locked, so kubelet would reject the Pod before its
in-process identity check could perform the intended exit-0 skip. Mounting the always-present
root and resolving files in-process preserves both the encrypted boundary and quiet
degradation.

The B2 wrapper reads its key ID and application key from those files only after the mount
identity and sentinel checks succeed, exports them inside its own process, and never prints
them. No `restic-vault.sops.yaml`, Kubernetes Secret, literal Pod environment value,
command-line secret, or root-filesystem credential cache exists. `/work`, `/tmp`, and
`RESTIC_CACHE_DIR` use `emptyDir.medium: Memory`; swap is disabled, so a completed or
interrupted Job does not leave decrypted metadata or credential spill under
`/var/lib/kubelet`.

Both `.backup-credentials` and `.mail-credentials` are excluded by exact,
contract-versioned rules and may not appear in a snapshot. The backup job verifies both
exclusions before writing and rejects its own new snapshot if `restic ls` finds either
directory anyway. Restore validation repeats the same negative assertions. A secret
exclusion is not allowed to rely only on operator memory or a broad wildcard.

The cost accepted in exchange: after an unattended reboot, new or changed tier-0 data is
not ingested or backed up until a human unlocks the vault. Vault backup, copy, and vault-only
prune work skip; once deployed, the shared prune job continues with the proposed workstation
repositories. The host, k3s, camera recording, and existing `appstate` pipeline remain
unattended, and the workstation pipeline must do the same after it is built. This is no
additional availability loss over manual vault unlock itself, and `VaultLocked` (§ 9)
bounds the window operationally.

#### The host and core services must recover unattended

Manual unlock is only acceptable if nothing important waits on it. Three requirements
follow, and the third is the one that is not automatic.

**1. Boot must not block, and neither may a job that touches the path.** The
`/etc/crypttab` entry carries `noauto`, so `systemd-cryptsetup@vault.service` is not
pulled in by `cryptsetup.target` and boot never stalls on a passphrase prompt at a console
nobody is sitting at.

**The fstab entry is `noauto,nofail` and deliberately does *not* use
`x-systemd.automount`**, breaking with every sibling in `host/minis/etc/fstab`. The sibling
pattern is actively wrong here, and in a way that is easy to miss because "the mount just
fails" sounds like the desired behaviour:

- An access to `/mnt/vault` **activates the automount unit**, which starts `mnt-vault.mount`,
  which is ordered on the backing device unit. While the container is locked that device
  does not exist, so the caller does not get a prompt error — it **blocks for the full
  `x-systemd.device-timeout`** (60s in the sibling entries) before the mount fails. A
  mount-identity check that is supposed to detect a locked vault instantly and exit 0 instead
  hangs for a minute per source root, on every run, for as long as the vault stays locked.
- `noauto` in crypttab means only that nothing pulls the unlock service in *at boot* — not
  that nothing can. A mount attempt is exactly the "something else" that can pull it in, and
  the unlock service dispatches a `systemd-ask-password` request. On a headless host that
  request goes to a password agent nobody is watching and sits there pending, which is the
  failure this whole arrangement exists to avoid.

Without the automount, a locked `/mnt/vault` is simply the bare, immutable mountpoint directory
on the root filesystem: `[ -f /mnt/vault/.backup-sentinel ]` returns false immediately, no
device unit is consulted, no timeout elapses, and no password agent is involved. Mounting is
then solely `vault-unlock`'s job. The crypttab entry pins the LUKS UUID. The helper verifies
that UUID on the raw LV before prompting, runs `cryptsetup open`, verifies the configured
ext4 UUID and filesystem type on the resulting mapper, and closes the mapper and fails on
any mismatch; only then does it run `systemctl start mnt-vault.mount` (the unit still exists
under `noauto`; it is merely not wanted by `local-fs.target`). For the same reason the
fstab entry names
`/dev/mapper/vault` rather than a filesystem `UUID=`, which does not resolve until the
container is open.

**The crypttab mapping is named `vault`, not `vaultlv`, and the difference is
load-bearing.** The LV is `hoardvg/vaultlv`, so the *ciphertext* device is
`/dev/mapper/hoardvg-vaultlv`; the mapping opened over it is the *plaintext* device. Naming
that mapping `vaultlv` too would put ciphertext and plaintext at
`/dev/mapper/hoardvg-vaultlv` and `/dev/mapper/vaultlv` — two adjacent, nearly identical
paths where filesystem tools belong only on the plaintext mapping. During initial
provisioning, `mkfs` targets `/dev/mapper/vault`; after initialization, running `mkfs` on
either path is destructive. Running it on the ciphertext LV destroys the LUKS header and
every copy's decryption path with it. `vault` is unmistakable at a glance and at a
tab-completion. It is also the only device pin in `alert-rules.yaml` that is not
`hoardvg-*`, which under the old name would have read like a typo to anyone auditing the
rules; under this one it reads as what it is — a mapper device that is deliberately not an
LV. Everywhere below, `vaultlv` means the LV and the LUKS container on it, and
`/dev/mapper/vault` means the decrypted filesystem.

Nothing else on the host references `/mnt/vault`, and `/mnt/backups` is a separate,
unencrypted LV — so k3s, the existing `appstate` pipeline, and camera recording all come up
and keep running exactly as they do today, locked vault or not. The proposed workstation
repositories have the same independence once deployed.

**2. Writes must fail closed.** This does *not* come for free, and it is the sharp edge of
the design — it is also made sharper, not duller, by dropping the automount. A mountpoint is
an ordinary directory on the parent filesystem whenever nothing is mounted over it, and with
`noauto` nothing ever tries to mount on access. So a Pod writer that opens
`/data/vault/mail/…` while the vault is locked gets no error merely from the bind mount:
that path maps to the bare host `/mnt/vault/mail/…` on `vg0/root`, and mbsync would archive
Gmail onto the root filesystem until it filled. Two guards, both required:

- **An immutable underlying `/mnt/vault` directory** — `chmod 0555 root:root` *and*
  `chattr +i`, applied before anything mounts over it.

  Permissions alone are not enough, and an earlier draft of this document was wrong to claim
  they were. `0555` is bypassed by root and by any process holding `CAP_DAC_OVERRIDE` — and
  the Restic jobs hold exactly that: the security posture inherited from `restic-nas-cronjob.yaml`
  is `drop: [ALL]` plus `DAC_OVERRIDE` (§ 2), which is precisely the capability that ignores
  the permission bits. Under `0555` alone a Restic job could write into a locked vault's
  mountpoint without so much as a warning.

  The immutable attribute is enforced independently of DAC: creating, removing, or renaming
  an entry inside an immutable directory returns **`EPERM` even for root with
  `CAP_DAC_OVERRIDE`**, and clearing the flag requires `CAP_LINUX_IMMUTABLE`, which
  `drop: [ALL]` + `DAC_OVERRIDE` does not grant. Mounting over the directory is unaffected —
  the flag lives on the underlying inode, so it is inert whenever the vault is mounted and
  the vault's own root permissions govern as usual. Keep the `0555` as well: it costs
  nothing and gives every non-privileged process an honest error before the flag is reached.

  Two operational hazards come with it, both of which must be handled or the guard silently
  disappears:

  - **Never `chattr +i` while the vault is mounted.** The path would resolve to the *mounted
    filesystem's* root inode, making the real vault immutable and breaking every write into
    it. Every place that sets the flag first aborts if `mountpoint -q /mnt/vault` succeeds;
    only a positively confirmed unmounted path may receive the attribute.
  - **The flag is invisible to `ls` and easy to lose** — a `mkdir -p` in a runbook, a
    directory recreated by hand, a restore of the root filesystem. A small systemd unit
    ordered `Before=mnt-vault.mount` asserts both the mode and the flag at boot, and
    `vault-unlock` re-asserts them before mounting. `lsattr -d /mnt/vault` is the way to see
    it; the locked-vault drill checks it directly.

- **A mount-identity and sentinel check in every writer**, not only in the backup job —
  `/data/vault` must resolve to the expected vault filesystem and
  `/data/vault/.backup-sentinel` must be present before any credential or destination is
  touched (§ 2). The same guard the read side already uses, now applied in both directions.
  The identity check distinguishes an ordinary locked vault, which skips cleanly, from a
  mounted wrong filesystem or a damaged vault, which fails rather than being mistaken for
  normal degradation.

- **One whole-root mapping, deliberately:** `hostPath.path: /mnt/vault`, `type: Directory`,
  and `volumeMount.mountPath: /data/vault`. Kubelet validates the host path before the
  container can run, so using `/mnt/vault/mail` or `/mnt/vault/frigate-exports` as separate
  hostPaths would produce `FailedMount` while locked and the identity check could never
  execute its quiet skip. The bare immutable host `/mnt/vault` directory always exists,
  which lets the Pod start; the check at `/data/vault` then classifies that exact bare-root
  state as locked before credentials, the sentinel, or a write path are consulted. The
  immutable inode is the backstop if that ordering is ever bypassed.

  Least privilege moves inside the container boundary: the mail job runs as a dedicated
  `2000:2000` without `DAC_OVERRIDE`, the vault's other top-level directories are not
  readable by that identity, it can read only
  `/data/vault/.mail-credentials/gmail-app-password`, and only `/data/vault/mail/` is
  writable by it. The Frigate ingestion init
  container likewise runs as a dedicated non-root UID which can read the source exports and
  write only `/data/vault/frigate-exports/`; the Restic container mounts the same vault
  volume read-only. Copy and prune mount it read-only for credentials. No workload uses
  `DirectoryOrCreate` below the host `/mnt/vault` or mounts a second vault path.

**3. No service may depend on the vault to start.** Frigate is the case this actually
binds — see § 7, where exports stay on `/mnt/frigate` and are synced into the vault, rather
than the vault being mounted into the container. Backups (§ 2) and mail archival (§ 6) may
safely remain unavailable until unlock; they skip, emit a metric, and alert.

### 1c. Workstation-to-vault ingestion over restricted SFTP

Strongbox syncs its encrypted KeePass database through Dropbox, and the ordinary filesystem
path on both workstations is exactly `~/Dropbox/ccs.kdbx`. That KDBX file is the backup
artifact; there is no routine CSV or plaintext password export. Strongbox/Dropbox remains
the live synchronization path, so manual vault unlock never affects password-manager use.
The vault receives an archival copy rather than becoming Strongbox's primary SFTP backend.

`ryze` is the designated uploader because its systemd timer is the more predictable
execution surface. Every four hours it:

1. proves `~/Dropbox/ccs.kdbx` is a local, non-symlink regular file rather than a cloud
   placeholder, checks the KDBX signature and a measured minimum size, and records its
   metadata;
2. copies it to a private memory-backed path below `/run/user/$UID`, then proves the source
   size and modification time did not change during the copy;
3. uploads it with its dedicated SSH key to a temporary name under the SFTP inbox and
   atomically renames it into place; and
4. updates a separate success heartbeat even when the database content hash is unchanged.

The host runs a dedicated ingestion-only `sshd` listener on the selected Tailnet/trusted
address and a non-management port, with `AllowUsers vault-ingest-ryze vault-ingest-m5c`
and only key-authenticated `internal-sftp` for those identities. Each has its own root-owned,
non-writable `ChrootDirectory` below `/mnt/vault/inbox/<host>` and may write only its child
`upload/` directory; shell, forwarding, tunnelling, agent forwarding, cross-host inbox
access, and direct access to canonical vault directories are disabled. The host
firewall/Tailnet policy admits each identity only from its selected trusted source. The
ordinary management `sshd` configuration and reachability do not change, and there is no
public listener. While the vault is locked,
the chroot is absent and upload fails safely rather than writing to the root filesystem.
The client retains the last local success state and retries on its next timer; the server's
`VaultLocked` alert names the usual cause.

A host-side promotion service accepts only the expected `ccs.kdbx` name, validates it as a
regular non-symlink file with the expected KDBX signature, size floor, and stable hash, then
atomically replaces `/mnt/vault/credentials/strongbox/ccs.kdbx`. It never unlocks the
database and holds no Strongbox master credential. `StrongboxVaultIngestionStale` warns
when the last successful offered-and-promoted copy is older than 36 hours while the vault
is mounted; `VaultLocked` owns the locked state. Both workstation
backup contracts also include the exact `~/Dropbox/ccs.kdbx` path, so the daily workstation
repositories remain an independent recovery route when vault ingestion is unavailable.

Ordinary documents use the same transport but a separate `upload/documents/` subtree. Both
workstations upload their existing `~/Documents` tree daily; no extra `VaultDrop` staging
directory is required. This is archival ingestion, not a bidirectional document share:
promotion validates names, types, ownership, and size and writes into separate canonical
paths, `/mnt/vault/documents/ryze/` and `/mnt/vault/documents/m5c/`. It never propagates a
client deletion into the vault. Keeping host namespaces avoids same-name collisions and
makes provenance explicit; cross-host duplicates are accepted until an attended cleanup
decides they are truly identical. A per-host heartbeat distinguishes "nothing changed"
from "the delivery job did not run," and `VaultDocumentsIngestionStale` warns when either
mounted-vault heartbeat is older than seven days. The daily workstation repositories also
include each `~/Documents` tree directly, so a failed vault delivery does not leave the
working copy unprotected.

Restic does **not** serve as this ingestion transport. Restoring client-created snapshots
into the canonical vault on a schedule would turn a backup format into a transfer queue,
require the vault side to trust client-controlled paths and snapshot selection, and blur the
source of truth.

Strongbox uses only a master password. That password remains independent of the file: its
sealed recovery record must not be stored only inside `ccs.kdbx`, and no automation receives
it. The recovery drill supplies it manually when opening a restored database.

### 2. Generic dataset backup job

The existing `backup.sh` is purpose-built for the `/opt` contract and should stay that way —
coupling photo backups to a Plex DB export means a Plex failure silently stops protecting
photos. Instead add a second, simpler script, `backup-dataset.sh`, in a new
`infrastructure/monitoring/restic-vault-config.yaml` ConfigMap. It reuses the proven pieces
of `restic-nas-config.yaml` — `log`/`die`/`require_env`, `assert_fresh_file`, explicit
retention args — but drops the app-specific dump logic and adds guards that matter for bulk
data:

- **Mount identity before sentinel.** The script inspects the actual hostPath bind mount in
  `/proc/self/mountinfo` (or equivalently with `findmnt`) before touching a source or
  credential. If the in-container `/data/vault` mount has the pinned host-root
  backing-source/type tuple for the bare host mountpoint, that is the expected locked or
  otherwise unavailable state: exit 0, export a `vault_locked` metric, and let
  `VaultLocked` (§ 9) name the remedy. If it has the pinned `/dev/mapper/vault`
  backing-source/type tuple, continue. Any other tuple is a hard failure. The host unlock
  helper separately verifies the configured LUKS and ext4 UUIDs before mounting. The
  rendered job configuration pins both runtime tuples, and the live drill records the exact
  mountinfo form Kubernetes exposes so a bind-mount formatting assumption cannot weaken
  this check.
- **Sentinel assertion after identity.** Every source root on an expected mounted filesystem
  must contain its contract-versioned `.backup-sentinel`; for the vault, the exact check is
  `/data/vault/.backup-sentinel`. If the expected vault filesystem is mounted but its
  sentinel is absent, the job fails: that means a damaged, incorrectly initialized, or
  wrong vault, not an ordinary locked reboot. Without this check the job can cheerfully back
  up an empty mounted filesystem. The same file is the write-side guard for every job that
  writes into the vault (§ 1b, § 6, § 7), so one sentinel covers both directions. Because
  the vault has no automount, the preceding locked-state check remains cheap and cannot
  queue a passphrase prompt. `ResticVaultBackupOverdue` remains the backstop for the case
  where the vault is unlocked and the job still is not succeeding.
- **Credentials are files behind the sentinel.** Only after the vault identity and
  sentinel checks pass does the job validate `/data/vault/.backup-credentials` (§ 1b):
  exact owner and mode, regular files rather than symlinks, and nonempty values. It sets
  `RESTIC_PASSWORD_FILE`; the password itself never enters the Pod specification or a
  Kubernetes Secret. A missing or malformed credential on a mounted vault is a failed run,
  not a locked-vault skip.
- **Floor assertions.** Per-source minimum file count and minimum byte size, from the
  ConfigMap.
- **Pre-backup ingestion step.** A dedicated non-root init container checks mount identity
  and the sentinel, then copies the separately mapped host
  `/mnt/frigate/exports` (`/data/frigate-exports` in the init container) into
  `/data/vault/frigate-exports` (§ 7), so exports written while the vault was locked are
  protected on the first run after an unlock. Unix ownership lets it write only that
  destination and denies it access to `.backup-credentials` and `.mail-credentials`; the
  Restic container that follows mounts `/data/vault` read-only. The copy runs inside the
  identity-and-sentinel guard, never outside it.
- **An immutable contract, then a measured manifest.** The authoritative input is the
  committed file `infrastructure/monitoring/contracts/vault-v1.json`. It contains the exact
  ordered source roots, exact exclusion-file SHA-256, sentinels, and per-root floors. The
  backup script reads that file directly; it does not construct the required-root list from
  the same environment variables it is meant to police. A ConfigMap mounts the file
  byte-for-byte, and the restore runbook carries a byte-identical copy under
  `runbooks/disaster-recovery/contracts/` so recovery does not depend on a generated live
  ConfigMap. CI rejects modification or deletion of a released `vault-vN.json`, verifies
  both copies are identical, and contains explicit assertions for v1's exact roots and
  exclusion hash. A scope change therefore creates `vault-v2.json` and updates an explicit
  current-version pointer; it never edits v1 in place.

  The job writes `backup-manifest.json` into `/work` and passes it as an extra backup path,
  so every snapshot carries the *measured realization* of that contract: contract version
  and contract-file SHA-256, the required roots, exclusion hash, and each root's measured
  file count and byte size. Before backing up, the script proves that its mounted roots,
  sentinels, exclusions, and floors exactly match the independent contract. Restore
  validation rejects a missing manifest, an unknown contract version or hash, or any root
  or exclusion mismatch. This separation closes the self-referential failure mode where a
  root is dropped from both the backup input and the manifest generator and the two still
  agree.
- **Credential exclusion is executable policy.** The exact in-container paths
  `/data/vault/.backup-credentials` and `/data/vault/.mail-credentials` are present in the
  versioned exclusions file. Before backup, the script refuses to run if either rule is
  absent or broader than its exact hidden directory. After backup it runs `restic ls`
  against the exact new snapshot and fails the Job, writes a hold under the root-only
  `/mnt/backups/.control/vault/holds/` control directory, and pages if either
  credential-directory path appears. Holds and validation state never live *inside* a
  restic repository, where a client or repo operation could alter or copy them. Restore
  validation makes the same negative assertions before accepting a snapshot.
- **Shrink guard.** Compare the new snapshot against a *healthy baseline* — the largest of
  the last N snapshots, not simply the previous one. Comparing against `[-1]` self-heals in
  the wrong direction: once a truncated snapshot lands, the next run measures against the
  truncated one, sees no shrink, and passes. If the new snapshot is smaller than the
  baseline by more than a configured percentage, complete the backup, write a hold in the
  external control directory recording the snapshot ID and reason, and exit non-zero. This
  is the failure mode that actually destroys archives: an empty or truncated backup
  followed by a prune that reaps every good snapshot.

  **A source-side hold is an alarm, not an override.** Holds are structured JSON records under
  `/mnt/backups/.control/<repo>/holds/`, keyed by canonical lineage and containing the exact
  snapshot ID, reason, contract version/hash, measured root counts and bytes, baseline
  generation, and creation time. Backup may continue producing investigative snapshots,
  but copy and prune skip the affected NAS→B2 repository pair while any source hold remains
  unresolved. Deleting a hold file by hand is unsupported and authorizes nothing: the
  independent validation and baseline checks still fail closed.

  Resolution is an attended operation through
  `runbooks/backups/resolve-validation-hold.sh`, with the source repository and full
  snapshot ID as mandatory arguments and a typed-ID confirmation before any mutation. It
  uses a root-only state record keyed by repository, hold, and full ID so only the same
  interrupted resolution may resume. On a new resolution it reopens the repository, proves
  that the hold still names that exact snapshot and lineage, re-runs the manifest, contract,
  floor, credential-negative, clock, and repository checks, and records an audit result
  without copying file contents or secrets. On resume it accepts a missing snapshot only
  when the state record proves the exact-ID forget step already completed and confirms that
  ID remains absent. It then permits exactly one of two outcomes:

  - **Reject.** Use this for truncation, wrong scope, credential inclusion, corruption, or
    an unexplained shrink. The helper first proves the lineage is absent from every B2
    destination; unexpected replication is a separate incident and aborts this path. It
    writes a rejection record, runs `restic forget <exact-snapshot-id>` against the source
    repository, confirms that exact snapshot is gone, and runs `restic prune`. Only after
    both commands succeed does it remove the hold. The rejected lineage is never added to
    the validation ledger. An interruption leaves the hold in place, and rerunning the same
    command resumes by checking which exact steps already completed.
  - **Accept legitimate shrink.** This is available only when shrink is the sole failed
    check; a credential, contract, manifest, floor, clock, or repository-integrity failure
    cannot be waived. The operator supplies a nonempty reason after inspecting the measured
    per-root delta and confirming the deletion is intentional. The helper revalidates the
    exact snapshot, atomically records its lineage in the validation ledger, and atomically
    replaces `/mnt/backups/.control/<repo>/baseline.json` with a new generation anchored at
    that snapshot. The baseline record contains the anchor ID/lineage, contract version and
    hash, measured counts and bytes, prior generation, acceptance time, operator, and
    reason. It removes the hold last.

  The healthy-baseline window is scoped to the current baseline generation: comparisons use
  the accepted anchor plus the largest of the last N positively validated snapshots at or
  after that anchor. Older, larger snapshots remain restorable but cannot make an approved
  shrink fail forever. Initial enrollment creates generation 1 only after the first backup
  and restore drill pass; unattended jobs may add healthy snapshots to its comparison
  window but may never start a new generation or lower the anchor. Because copy is gated by
  unresolved holds and the resolver removes the hold last, a crash between ledger and
  baseline updates cannot release a half-accepted snapshot off-site. The accept operation is
  idempotent for the same hold, snapshot, and target generation and rejects conflicting
  retries.
- **Only positively validated snapshots may leave the NAS.** `restic backup --json` yields
  the exact candidate snapshot ID. The job validates that snapshot's manifest, floors,
  shrink result, and credential-negative listing; only then does it atomically append the
  snapshot's canonical lineage ID to a root-only validation ledger under
  `/mnt/backups/.control/<repo>/validated`. A `validated` tag may be added for operator
  readability, but it is not authority: workstation clients can choose their own tags, and
  tag changes themselves create a new snapshot identity. The authoritative key is
  `original // id`, followed through any tag or copy operation. A candidate that fails a
  check remains encrypted locally for investigation, is held from pruning, and is absent
  from the ledger. The copy job reads only exact ledger entries, repeats the manifest and
  negative checks, and invokes `restic copy <snapshot-id>` explicitly; it never calls an
  unqualified `restic copy` or copies `latest`. After destination validation it records the
  destination's matching canonical lineage in the destination ledger. The ledgers contain
  no file data or secrets, can be reconstructed by attended revalidation, and fail closed
  if missing or malformed.

  A ledger records **validation evidence**, not repository presence. It is intentionally
  historical: retention may remove a snapshot without erasing the fact that its lineage was
  once validated. Every consumer therefore reconciles it with a fresh `snapshots --json`
  listing and treats only their intersection as the current validated set. A stale ledger
  row can never make copy, prune, metrics, or an operator conclude that a missing B2
  snapshot still exists. Conversely, an actual snapshot absent from the ledger remains
  unvalidated until attended revalidation records it.
- **Prune decoupled from backup.** A 4-hourly job must not prune. Retention and prune work
  move to a separate weekly `restic-prune-cronjob.yaml` covering the **new** repos — `vault`
  and the two workstation repos. `appstate` is not included; see below.

  Because the guard now lives in one job and the prune in another, the guard cannot be a
  decision the backup run makes about its own trailing step — a truncated snapshot at 04:00
  and a prune days later are not connected by anything in-process. **The prune job therefore
  re-derives the precondition itself, per repo, before touching that repo:**

  - the newest snapshot is younger than that repo's expected backup interval;
  - its size and file count are within tolerance of the healthy baseline (the same
    comparison the backup-side guard makes, computed independently);
  - the newest snapshot and every removal candidate are present in the root-controlled
    validation ledger, rather than merely carrying a client-selectable tag;
  - for a NAS repository, every validated snapshot `forget` would remove has already been
    replicated to its **B2** destination and is both physically present there and recorded
    in its destination validation ledger; this downstream-replication gate does not apply
    while pruning the B2 destination itself;
  - no hold is present in `/mnt/backups/.control/<repo>/`.

  The replication precondition is what keeps the off-site recovery window from being
  quietly shorter than the table in [Retention](#retention-proposed) claims. B2 is a pure
  `copy` destination (§ 3), so a snapshot pruned from the NAS before it was copied never
  reaches off-site at all — and nothing downstream would report a gap, because both repos
  look internally consistent. Matching is by canonical lineage — `original` falling back
  to `id` — on **both** sides, never by `id` alone (§ 3).
  Concretely: run `forget --dry-run --json` to get the removal candidates, collect
  `original`/`id` from B2's `snapshots --json`, cross-check both sides against the
  validation ledgers, and skip the NAS repo if any candidate is unmatched. A repo skipped
  this way is the expected steady state when the copy job has
  failed for a while, so it exports the count of unreplicated candidates as a metric and
  `ResticReplicationLag` (§ 9) fires on it — the prune stall itself is the safe outcome,
  not the problem to fix.

  **The destructive step consumes the verified IDs, not the policy a second time.** The
  dry-run releases its Restic lock before the next command, so a new backup can arrive after
  candidate selection. Re-running `forget` with the policy could then select a different
  set from the one whose validation and replication were proved. Instead, after verifying
  the candidate set, the job runs `restic forget <candidate-id>...` with those exact source
  repository IDs and then runs `restic prune` separately. A snapshot created between the
  dry-run and explicit forget is therefore outside the deletion set. If any selected ID is
  no longer present when the destructive step begins, that repository is skipped and
  reported rather than silently recomputing policy.

  **Ordering is per pair: NAS first, B2 second.** Vault B2 carries the same
  `--keep-within-hourly 48h` tier as vault NAS, so it cannot age out an hourly lineage that
  NAS still needs to prove replicated on a later run. The job completes the NAS candidate
  check, explicit forget, and prune before evaluating the corresponding B2 policy. B2 then
  performs its own dry-run, ledger/health checks, exact-ID forget, and prune; it has no
  downstream-replication gate. The same source-before-destination order applies separately
  to `workstations/ryze` and `workstations/m5c`.

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
  metric so `ResticPruneOverdue` (§ 9) fires on the stall. The external hold is the fast
  path, not the mechanism: prune stays safe on a repo whose backup job crashed before
  writing anything, never ran, or was deleted outright. A hold is cleared only by the
  attended reject or accept workflow above. Removing its file manually does not change the
  validation ledger or baseline generation, so the independent precondition continues to
  block pruning rather than treating file deletion as approval.

Same security posture as the existing backup cronjobs — `readOnlyRootFilesystem`,
`drop: [ALL]` plus `DAC_OVERRIDE` (which is why the locked-vault write guard cannot be
permission bits, § 1b), `automountServiceAccountToken: false`, `priorityClassName:
homelab-low`, and `nodeSelector` on `minis`. `/work`, `/tmp`, and `RESTIC_CACHE_DIR` are
memory-backed `emptyDir` volumes, not the default node-backed form. The mail job is the
exception to `DAC_OVERRIDE`: it runs as `2000:2000` and can write only the vault's
`/data/vault/mail/` directory (§ 1b).

### 3. Replication by `restic copy`, not re-reading the source

Off-site copies come from a `restic-copy-cronjob.yaml` that replicates NAS → B2, rather than
a second independent read of the source. What this buys is **one traversal of the source
tree**: the backup job reads host `/mnt/vault` through its `/data/vault` mount and writes to
`/mnt/backups`; the copy job then reads `/mnt/backups`. (The array is not read once —
`/mnt/backups` lives on it too. The win is that off-site replication never walks the vault
tree a second time and cannot be delayed by activity in that source tree. It is still
intentionally unavailable while the vault is locked because its credentials remain inside
that boundary, as described below.)

It does **not** remove contention. Both jobs touch `/mnt/backups` and the same array, and
nothing prevents a copy from overlapping a backup, so the copy schedule is offset from the
4-hourly cadence and both jobs must tolerate finding the other running. `backup` and `copy`
take non-exclusive repo locks and coexist; the weekly prune takes an exclusive one, which
is a further reason it lives in its own job (§ 2) rather than tailing a backup.

Replication is an allow-list operation, not a mirror command. The job enumerates only
canonical lineage IDs both present in a fresh NAS `snapshots --json` listing and recorded in
the NAS validation ledger, then revalidates each source snapshot. It copies explicit source
snapshot IDs whose lineage is absent from a fresh destination `snapshots --json` listing;
a historical destination-ledger row alone never suppresses a copy. After `restic copy`, it
locates the destination snapshot by canonical lineage, validates that exact destination,
and only then records the destination-ledger entry and success metric. Invalid candidates,
snapshots that merely claim a `validated` tag, and actual destination snapshots absent from
the validation ledger are never eligible as proof of a healthy copy; the latter condition
is held for attended revalidation rather than overwritten or silently accepted. This
prevents a post-backup contract or secret-exclusion failure from being faithfully
replicated off-site and prevents stale ledger state from disguising a missing B2 snapshot.

**The copy is intentionally vault-gated even though its data source is `/mnt/backups`.** It
maps host `/mnt/vault` at `/data/vault` to obtain the source and destination password files
and the dedicated B2 application key (§ 1b), sets `RESTIC_FROM_PASSWORD_FILE` and
`RESTIC_PASSWORD_FILE` to paths below `/data/vault/.backup-credentials`, and reads the B2
values into its own process only after checking `/data/vault` and its sentinel. While the
vault is locked it exits 0 without contacting B2. That can delay a snapshot which landed
locally just before a reboot, so the attended unlock workflow triggers an immediate vault
backup followed by a copy rather than waiting for their next schedules; the host-only
`vault-unlock` helper itself needs no Kubernetes credential. The ordinary 36-hour copy
alert remains the backstop.

The same rule applies to retention. Once deployed, the shared prune job may continue
pruning workstation repositories with their SOPS-managed credentials while the vault is
locked, but skips the vault NAS and B2 repositories individually because their password
files are unavailable. It must not copy vault credentials into a Kubernetes Secret or a
node-backed temporary directory to make locked-state pruning possible; a safe retention
stall is preferable to reopening the powered-off theft path.

**Chunker parameters are inherited at *destination* init, from the source repo:**

```
restic -r <DEST> init --from-repo <SOURCE> --copy-chunker-params
```

`copy` transfers blobs as they are; it does not re-chunk them. What mismatched parameters
break is *cross-repository deduplication*: blobs arriving from the source are chunked one
way and anything the destination chunked itself another, so identical data is stored twice
and the destination's footprint diverges from the source's. This cannot be retrofitted
without rebuilding the destination, which makes it the most order-sensitive item in the
design — but the constraint lands on B2 and each offline repository, not on the NAS repo.

**The `vault` NAS repo is initialized normally** (`restic init`, no flags); it is the
source its destinations inherit from. The vault B2 repository and the `vault` repository
on each offline drive are initialized `--from-repo <vault-NAS> --copy-chunker-params`.
Separately, the `appstate` repository on each drive is initialized
`--from-repo <appstate-NAS> --copy-chunker-params`. A physical drive is only a carrier; it
does not collapse the two datasets into one repository or one password.

Workstation off-site storage follows the same one-source/one-destination rule. `ryze` and
`m5c` each have a distinct B2 repository, repository password, validation ledger, and
ceiling. Initialize `workstations/ryze` (B2) from the `ryze` NAS repository and
`workstations/m5c` (B2) from the `m5c` NAS repository with `--copy-chunker-params`; never
copy both NAS repositories into one shared B2 repository. Their separate 100 GB and 50 GB
ceilings sum to the 150 GB workstation allowance without hiding which host is growing.

**Copied and retagged snapshots do not necessarily keep their IDs.** `restic copy`
re-creates a snapshot in the destination, which gets a new ID and records source lineage in
its `original` field (visible in `snapshots --json`); tag operations can introduce another
identity hop. Two consequences worth being explicit about:

- **A restore drill on one repo is not evidence about the other.** It says nothing about the
  destination's pack files, index, or B2's stored bytes. Each repo needs its own drill —
  which is why [Verification](#verification-proposed) lists a local restore *and* a
  from-B2 restore as separate line items, each running its own data-reading repository
  check. Implementation drills and the annual offline drill use `restic check --read-data`;
  they do not copy the existing fixed `1/100` subset unchanged (§ Verification).
- **Correlation is by canonical lineage, not by ID.** Anything matching snapshots across repos —
  the copy job's "is this already replicated?" check, the prune job's per-repo newest-
  snapshot metric, an operator eyeballing a drill — must compare `original // id` on both
  sides, never `id` alone. The external validation ledgers use the same key.

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

`ryze` and `m5c` aren't cluster nodes. Run **two** `restic/rest-server` Deployments in the
cluster, one per workstation, each backed by its own fixed hostPath under
`/mnt/backups/workstations/` and exposed as its own Tailscale endpoint. A single shared
server is rejected because rest-server's `--max-size` is a limit for the server's whole
configured path, not a per-private-repository quota.

The goal is that a workstation which is compromised, wiped, or ransomwared can add
snapshots but cannot delete or rewrite history, so the recovery path survives the client.
Getting there means keeping three separate things straight — they are easy to collapse into
one "key", and the design does not work if they are:

| | What it is | What it controls |
|---|---|---|
| `--append-only` | a **process flag** on the rest-server binary | deletes and overwrites, for *every* user of that server. There is no per-user append-only credential |
| htpasswd user + password | HTTP authentication | who may reach that workstation's dedicated endpoint |
| restic repo password | repository encryption | decrypting contents. It grants **no** delete permission through an append-only endpoint; that is the server's call, not the crypto's |

The `ryze` Deployment runs `--append-only --max-size=161061273600`; the `m5c` Deployment
runs `--append-only --max-size=107374182400`. Each addresses exactly one repository root,
`/mnt/backups/workstations/ryze` or `/mnt/backups/workstations/m5c`, and has one-entry htpasswd data, one Service/Tailscale
hostname, and one repository password. `--private-repos` is deliberately **not** used: its
extra username subdirectory would add no isolation when the entire process, endpoint,
credential, path, and quota are already per-client. NetworkPolicy admits only the
Tailscale proxy and the monitoring namespace jobs. Both Deployments use `Recreate`, a
single replica, a PodDisruptionBudget, and `automountServiceAccountToken: false`; two
processes must never serve the same repository path.

**Pruning cannot go through the REST endpoint.** No credential deletes through an
append-only server, so the weekly prune job (§ 2) addresses these repos **directly on the
filesystem** — using the same hostPath the rest-server is backed by and the dry-run,
exact-ID `forget`, then separate `prune` sequence in § 2. This is why prune is a cluster-side
job rather than something a client triggers, and it avoids standing up a second,
non-append-only Service whose only purpose would be to hold delete rights.

Prune and a client push do **not** run concurrently: destructive `forget` and `prune`
operations take exclusive repo locks, and restic's locking is enforced on the repo itself,
so it applies equally whether a process arrived over REST or over the hostPath. Locking
makes overlap safe, not free — the loser of a race fails rather than corrupting anything.
Give the workstation wrappers
`--retry-lock` (a few minutes is plenty for these repo sizes) and schedule the weekly prune
away from the workstation timers, so a legitimate overlap waits instead of paging.

There is one non-obvious quota consequence. rest-server accounts repository size in memory;
a direct hostPath prune bypasses that accounting, so the server continues to believe the
deleted bytes exist until it restarts. After each successful workstation prune, the job
therefore PATCHes a timestamp annotation on the corresponding Deployment and waits for its
replacement Pod to become Ready. The prune job receives a projected, short-lived Service
Account token and a Role limited to `get`/`patch` on the two named rest-server Deployments;
no rest-server Pod receives a token. If the PATCH or readiness wait fails, that repository's
prune is reported failed and its success metric is not advanced. The stale overcount fails
closed by refusing future uploads; it cannot permit the real repository to exceed its
configured 150 GiB or 100 GiB cap.
This restart-and-recount behavior is part of the restore/prune drill, not an implementation
detail that may be omitted.

**Workstation retention is duration-based, not count-based.** Append-only stops a compromised
client from deleting, but not from *pushing*: a flood of snapshots with attacker-chosen
timestamps can walk the real ones out of a `--keep-daily 14`-style window, and prune then
does the deleting on its behalf. These repos therefore start with the unbucketed safety
window `--keep-within 30d`, then add `--keep-within-daily 30d --keep-within-weekly 12w
--keep-within-monthly 12m` (and `--group-by host` — see
[Retention](#retention-proposed)), which is anchored to wall-clock age and
cannot be pushed out by snapshot volume. This is restic's own guidance for append-only
repositories ([security considerations in append-only
mode](https://restic.readthedocs.io/en/stable/060_forget.html#security-considerations-in-append-only-mode)).

Duration retention still trusts snapshot clocks. Before validation, copy, or prune, the
cluster rejects and holds any workstation snapshot more than 10 minutes in the future or
with a time older than the last accepted snapshot by more than the documented clock-skew
tolerance. A future-dated snapshot must never become the baseline or extend retention
indefinitely. The condition exports `ResticWorkstationSnapshotTimeInvalid`; clearing it
requires fixing the client clock and attended inspection of the held snapshot.

**Cap each repo with its dedicated rest-server's `--max-size`.** The remaining lever a compromised client
keeps is filling the disk, and `/mnt/backups` is shared with `appstate` and `vault` — an
unbounded push takes down the pipelines that matter most. A per-repo cap — **150 GiB for `ryze` and 100 GiB for `m5c`**, against the pessimistic
50 GB / 20 GB source budgets in [The data policy](#the-data-policy-proposed) — turns that
from an outage into a failed workstation backup and a `ResticWorkstationBackupStale` alert
(§ 9). The caps are 3x and 5x their budgeted source size, which is the headroom retention
needs: 12 months of `--keep-within-monthly` history plus the unbucketed 30-day window costs
far more than one snapshot. This statement depends on the dedicated-process topology and
post-prune recount above; it would be false for one shared `--private-repos` process.

Client config is canonical in this repo under `host/ryze/` and `host/m5c/`, mirroring the
existing `host/minis/etc/` and `host/bastion/etc/` convention:

- `host/ryze/` — systemd service + timer, `restic-excludes`, wrapper script
- `host/m5c/` — launchd plist, `restic-excludes`, wrapper script

Each released client scope has an immutable contract,
`workstation-ryze-v1.json` or `workstation-m5c-v1.json`, committed beside the wrapper and
copied into the recovery runbook. It fixes the exact source roots, exclusion-file hash,
minimum file and byte floors, expected hostname, and the required
`~/Dropbox/ccs.kdbx` and `~/Documents` paths. The wrapper includes a measured manifest in
every snapshot.
Cluster-side validation checks that contract and manifest, the KDBX presence and size,
snapshot time, and shrink tolerance before adding the canonical lineage to the validation
ledger. Without that positive decision the snapshot is neither copied nor eligible for
pruning.

Excludes target the obvious bulk (`.cache`, `node_modules`, virtualenvs, Steam, container
images, build dirs) plus `--exclude-caches` to honor `CACHEDIR.TAG`. Target ~5 GB from the
69 GB used on `ryze`, **but plan capacity at 50 GB** (see the sizing note in
[The data policy](#the-data-policy-proposed)). On macOS, exclude `~/Library/Caches` and the
Photos/Mail libraries but **include** `~/Library/Application Support` for app state. Both
host contracts explicitly include `~/Dropbox/ccs.kdbx` even if a broader Dropbox exclusion
is added later.

**The preflight must measure rather than assume.** `restic backup --dry-run` (or `restic
backup` against a throwaway repo) reports the exact post-exclude byte and file count for the
committed exclude list. Phase 5 records both numbers here and compares them against the
50 GB budget; a first run that materially exceeds it is a reason to tighten the excludes
before enrollment, not a surprise discovered when the cap is hit months later.

The Mac scope records three accepted facts from the owner: iCloud Drive does not use
Optimize Storage, neither Photos nor Mail is a unique source of data, and the purpose of
this repository is curated workstation recovery rather than a full-disk or Time Machine
clone. It also proves Dropbox has materialized `ccs.kdbx` locally rather than presenting an
online-only placeholder. The preflight records those settings and stops enrollment if any is false; otherwise
an excluded cloud placeholder could look like a local file without its contents being
recoverable. Full Disk Access for the launchd/restic binary is still required and tested,
because otherwise macOS privacy controls can silently omit protected home-library paths.

### 5. Google Photos → local canonical

**One-time Takeout bootstrap; ongoing capture deferred.**

The API path (gphotos-sync, rclone's Google Photos backend) strips GPS EXIF and
recompresses, so it is the wrong tool for building an archive intended to be kept forever.
Takeout preserves originals and ships sidecar JSON with the metadata Google holds.

`runbooks/backups/02-seed-vault-from-takeout.sh` unpacks the Takeout archives into
`/mnt/vault/photos`, merges the sidecar JSON back into file mtimes, de-duplicates against
the existing pre-2018 local archive, and reports counts to eyeball before the first backup
runs. Until ongoing ingestion is solved, photos taken after the bootstrap are protected only
by Google — see [Deferred](#deferred-documented-not-built).

### 6. Mail archive

`mbsync` (isync) CronJob against Gmail via IMAP with an app password, writing a maildir to
`/data/vault/mail` (host `/mnt/vault/mail`). Config lives in `apps/mail-archive/`, but there
is deliberately no `mail-archive.sops.yaml`: the app password is read from
`/data/vault/.mail-credentials/gmail-app-password` (§ 1b), after the mount-identity and
sentinel checks pass. The password never enters a Kubernetes Secret, Pod environment value,
command argument, ConfigMap, or node-backed temporary file. Because the archive lands on
the vault filesystem, it inherits vault cadence and retention with no extra backup wiring.

**This is a historical archive, not a mirror.** Mail removed or permanently deleted from
Gmail remains in the local Maildir and therefore in subsequent vault snapshots. The channel
configuration is pull-only and names the operations explicitly:

```
Sync Pull New Old
Create Near
Remove None
Expunge None
MaxMessages 0
CopyArrivalDate yes
SyncState *
```

`Gone` and `Flags` are intentionally absent: `Gone` would propagate remote disappearance,
and Gmail's deleted state is itself a flag that must not be copied into an archive and later
expunged. Nothing is ever pushed to Gmail. The selected Gmail mailboxes are `INBOX`,
`[Gmail]/All Mail`, `[Gmail]/Spam`, and `[Gmail]/Trash`; arbitrary label mailboxes are
excluded to avoid multiplying copies for every label, while Spam and Trash are included
so a message first seen there is not missed before Gmail expires it. `INBOX` deliberately
duplicates messages also present in All Mail so the familiar inbox view survives recovery;
Restic deduplicates the repeated content in its repository. This preserves mail
from the first successful sync onward; it cannot recover messages Gmail permanently deleted
before enrollment. The committed config and validation test these exact semantics against
the [isync operation definitions](https://isync.sourceforge.io/mbsync.html), rather than
relying on `Sync Full` defaults.

Run daily at 01:30, before the next 4-hour vault snapshot. A successful run validates the
Maildir structure and atomically updates a last-success metric; `MailArchiveStale` warns at
36 hours while the vault is mounted and includes `or absent(...)`; `VaultLocked` owns the
locked state. Maildir delivery is rename-based and mbsync protects
each mailbox's state file, so an overlapping read-only restic walk is safe: at worst a
message arriving during the walk appears in the next 4-hour snapshot. The CronJob uses
`concurrencyPolicy: Forbid` so two syncs never share state.

Use a dedicated repo-built image from `containers/mail-archive/`, containing only `mbsync`
(isync), CA certificates, and the minimal wrapper needed for the identity/sentinel guard and
metrics. Its `mail` account and image `USER` are fixed at `2000:2000`; the manifest still
sets the numeric identity explicitly so a future image change cannot silently change host
access. The image follows [version-management.md](./version-management.md): an immutable
release tag plus publisher digest, a version file, an attended build/publish workflow, and
the existing image-policy and Renovate checks.

The CronJob sets `automountServiceAccountToken: false`, `runAsNonRoot: true`,
`runAsUser: 2000`, `runAsGroup: 2000`, `allowPrivilegeEscalation: false`,
`readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`, and
`capabilities.drop: [ALL]`; it does not set `fsGroup` or use a root init container to rewrite
hostPath ownership. Config and CA material mount read-only. Any writable runtime path other
than `/data/vault/mail` is a memory-backed `emptyDir`, so the node root filesystem receives
neither mail state nor credentials.

**Mail archival may be unavailable until unlock, and that is acceptable** — Gmail still
holds the mail; the archive is the second copy, not the only one. The job asserts the vault
mount identity at `/data/vault` and `/data/vault/.backup-sentinel` before invoking `mbsync`
and, when the vault is locked (§ 1b), skips with the same exit-0-plus-metric shape as the
backup job (§ 2). This guard matters more here than anywhere else in the design: without it,
mbsync writes a maildir through `/data/vault` onto `vg0/root` under the unmounted host
mountpoint and fills the root filesystem. The immutable mountpoint (§ 1b) is the backstop if
the check is ever bypassed — note that permissions alone are not the estate-wide control
because the Restic jobs hold `DAC_OVERRIDE`. This mail job is deliberately narrower: it
runs as `2000:2000` without that capability, can read only its group-readable app-password
file, and can write only `/data/vault/mail/` (§ 1b).

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

**Exports stay on `/mnt/frigate` and are copied into the vault; Frigate never mounts the
vault.** Camera recording is a core service and must recover unattended after a reboot
(§ 1b), so it cannot hold a startup dependency on a filesystem that waits for a human with a
passphrase.

The startup dependency is only half the argument, and the smaller half. The direct mount
fails worse at *write* time: an export saved while the vault is locked lands on the root
filesystem at a path that looks entirely correct, and is then shadowed the moment someone
unlocks. It is not lost so much as invisible — the worst possible shape for data whose only
distinction is that a human deliberately chose to save it. (The obvious Kubernetes guard
does not help: hostPath `type: Directory` admits the pod regardless, because the mountpoint
directory exists whether or not anything is mounted on it — § 1b.)

So `apps/frigate/deployment.yaml` is left alone, exports continue to be written to
`/media/frigate/exports` on the `/mnt/frigate` LV, and the 4h vault job (§ 2) copies host
`/mnt/frigate/exports` → `/mnt/vault/frigate-exports` immediately before `restic backup`.
Inside its init container those paths are `/data/frigate-exports` →
`/data/vault/frigate-exports`. An unlock is therefore followed by ingestion and protection
in one pass. Frigate writes exports via ffmpeg rather than hardlinking, so crossing
filesystems is safe. Exports then inherit vault cadence, off-site replication, and the
offline copy.

The ingestion is archival, not a mirror: it never uses `--delete`, so removing a saved clip
from Frigate does not silently remove the vault copy. It considers only regular non-symlink
files whose size and modification time remain stable across the copy, writes a temporary
destination, validates the resulting image or video container, and renames it atomically.
A file still being written is deferred to the next run. A same-name destination with
different content is a hard failure requiring attended resolution rather than an overwrite.

This trades a hard dependency for eventual consistency: an export is unprotected between
being written and the next successful vault run — nominally 4h, unbounded while the vault
stays locked — and briefly exists in two places, which is immaterial at this size. Frigate's
retention does not sweep the exports directory, so nothing deletes an export out from under
a locked vault while it waits.

Frigate config and `frigate.db` are already protected — `/opt/frigate/config` is inside the
existing `appstate` source and `frigate/config/frigate.db` is in the
`REQUIRED_SQLITE_DATABASES` inventory, so the contract already hard-fails if it cannot be
exported. Nothing to add.

**One DR note:** after an `appstate` restore, `frigate.db` will reference recording files
that no longer exist. Frigate tolerates this, but the log noise is alarming if unexpected —
worth a line in `runbooks/disaster-recovery/README.md`.

### 8. Break-glass — the part that makes the rest real

The existing `appstate` repository passwords live in SOPS in this repo. The proposed
workstation operational secrets will also live in SOPS when that pipeline is built; the age
key that decrypts the existing and future values lives in `age.key` and in the password
manager. The **vault** repositories are the deliberate exception: their NAS and B2
passwords and dedicated B2 application key live only under the encrypted
`/mnt/vault/.backup-credentials` directory (§ 1b), never in SOPS or a Kubernetes Secret.
That is what prevents a powered-off stolen `minis` from supplying both an encrypted vault
copy and the key needed to read it.

The Gmail app password is the second exception. Its operational copy lives only under
`/mnt/vault/.mail-credentials`, and its independent recovery copy lives in the external
password manager. It is excluded from Restic along with the repository credentials. Loss
of both copies is an availability problem, not a backup-decryption problem: revoke the old
app password in Google, issue a replacement, and resume `mbsync`.

The encrypted Strongbox database `ccs.kdbx` is itself part of the vault and workstation
datasets. **That still creates a recovery circularity:** restoring the file is useless if
total device loss also removes its master password, and putting that password only inside
Strongbox cannot solve the problem.

The fix is offline and outside the system: a printed / physically-stored card carrying the
age public+private key, all restic repository passwords, **the `vaultlv` LUKS passphrase**
(§ 1b), the B2 application key ID and secret, and a one-page pointer to
`runbooks/disaster-recovery/`. The Strongbox master password is carried on the card or on a
separately sealed record stored in the same two locations; it never enters git or an
automated restore script. Two sealed copies live in two locations: one in a secure
home safe physically separated from `minis` and every backup drive, and one in an off-site
bank safe-deposit box. A card is never stored with an offline drive: doing so would place
the encrypted repository beside its password and collapse the control to the physical
security of one package. This document records what is on each card and when it was last
refreshed; the material itself never enters git.

The runbook pointer assumes GitHub is available and the private repository can be recovered
through the owner's normal GitHub account-recovery path. That dependency is explicitly
accepted; no offline clone, printed runbook, or separate Git bundle is required by this
policy. The break-glass drill must still prove account recovery settings and a second factor
are usable without `minis` or either workstation, because a URL on paper is not a recovery
procedure if the account is inaccessible.

The vault NAS repo, vault B2 repo, and all four offline repositories use **distinct repo
passwords**. The two repositories on one physical drive do not share a password.
The dedicated vault B2 application key cannot access `appstate` or future workstation
data. Conversely, the existing `appstate` B2 credential and future workstation B2
credentials cannot access the vault's private bucket. A leaked cluster secret therefore
grants neither decryption nor deletion authority over a vault copy.

The repository credential files inside `vaultlv` are operational copies, not backups of
themselves. They are deliberately excluded from every Restic snapshot (§ 2); the two cards
are their independent recovery source. Each repository-credential rotation updates both
cards in the same attended session and proves the new value against its repository before
the old value is retired. A Gmail app-password rotation instead updates the encrypted file
and the external password manager in the same attended session, proves a successful IMAP
login, and then revokes the old value.

The LUKS passphrase belongs on the card for a reason distinct from the rest of its contents.
Every other secret there protects a *backup*; this one protects the **source**. Losing it
does not merely make a copy unreadable — it strands `/mnt/vault` on a `minis` that is
otherwise healthy, which is the one failure the restic repos cannot help with, because they
are recovered *to* that filesystem. It is also the only card entry an operator needs during
routine operation rather than during a disaster (§ 1b), so it is the entry most likely to be
memorized and therefore the one most likely to be quietly wrong on the card. Verify it by
actually unlocking with it at each refresh.

| Break-glass card | Status |
|---|---|
| Last refreshed | *not yet produced* |
| Copy 1 location | Secure home safe, away from `minis` and every backup drive |
| Copy 2 location | Off-site bank safe-deposit box |

### 9. Alerting

Extend the `homelab.backups` group in `infrastructure/monitoring/configs/alert-rules.yaml`,
using `or absent(...)` on expected CronJob or textfile surfaces so deletion still fires,
except for the deliberately mount-gated filesystem rule described below:

| Alert | Condition |
|---|---|
| `ResticVaultBackupOverdue` | newest validated NAS snapshot older than 8h while vault mounted (critical) |
| `ResticVaultCopyOverdue` | newest validated B2 lineage older than 36h while vault mounted (critical) |
| `ResticWorkstationCopyOverdue` | no workstation→B2 copy in 8d (warning) — per host |
| `ResticWorkstationSnapshotTimeInvalid` | a held workstation snapshot has an implausible clock (warning) — § 4 |
| `ResticSnapshotValidationHeld` | unresolved validation hold for 15m — critical for `vault`, warning per workstation repo |
| `MailArchiveFailed` | mail archive Job failed with no later success (warning) |
| `MailArchiveStale` | no successful mail archive in 36h while vault mounted (warning) |
| `StrongboxVaultIngestionStale` | no successful `ccs.kdbx` promotion in 36h while vault mounted (warning) |
| `VaultDocumentsIngestionStale` | no successful `~/Documents` promotion in 7d while vault mounted (warning) — per host |
| `ResticWorkstationBackupStale` | newest `ryze`/`m5c` snapshot older than 7d (warning) |
| `BackupsVolumeFillingUp` | `/mnt/backups` below 20% free (warning) / 10% free (critical) |
| `ResticPruneOverdue` | no prune in 10d (warning) |
| `ResticOfflineDriveStale` | newest successful offline rotation across either drive older than 120d (warning) |
| `ResticOfflineDriveRotationOverdue` | last successful rotation of an individual drive older than 210d (warning) — per drive |
| `ResticReplicationLag` | prune skipped a repo for unreplicated snapshots on two consecutive runs (warning) |
| `ResticRepoNearCeiling` | repo size above 80% of its ceiling (warning) |
| `ResticRepositoryCheckOverdue` | no successful monthly structural + rotating data check in 40d (warning) — per NAS/B2 repo; vault destinations arm only while mounted |
| `ResticRestoreDrillOverdue` | quarterly program older than 100d, or a repo/destination without its required annual semantic drill in 400d (warning); vault destinations arm only while mounted |
| `VaultLocked` | `/mnt/vault` not mounted for 30m (warning) — see below |
| `VaultFilesystemDeviceError` | `node_filesystem_device_error` on a **mounted** `/mnt/vault` for 5m (critical) — see below |

`VaultLocked` exists because manual unlock (§ 1b) introduces a state nothing else in this
table models: the host rebooted cleanly, every core service is healthy, the existing vault
data remains encrypted, but ingestion and vault backup/copy/prune work are paused.
The two vault-overdue rules key off validated repository state, not CronJob success, because
a locked-vault skip exits zero and would otherwise look fresh. They are also joined to the
mounted-vault filesystem series: while locked, `VaultLocked` is the single actionable
warning; after unlock, an old NAS or B2 recovery point becomes critical at its stated
threshold. This avoids both false freshness from successful skips and duplicate critical
pages during an intentional locked period.

It keys off the mount rather than a CronJob's last success — the same `absent()` shape the
bulk set uses, but as its own rule:

```
absent(node_filesystem_size_bytes{device="/dev/mapper/vault",fstype="ext4",mountpoint="/mnt/vault"})
for: 30m   severity: warning
```

**`/mnt/vault` must stay out of `BulkStorageMountSetIncomplete`.** An earlier draft of this
document said to extend that alert to cover the vault; that is wrong, and the reason is
worth stating so nobody re-adds it. That rule is a chain of `absent()` clauses over the
always-required mounts, `for: 5m` at **critical** severity
(`infrastructure/monitoring/configs/alert-rules.yaml`). Its set is
`nofail,x-systemd.automount`, where "not mounted" means something broke. The vault is
`noauto` (§ 1b), where "not mounted" is the *expected* state after every reboot — so a vault
clause would deliver a critical page five minutes into every intentional locked period, and
duplicate `VaultLocked` besides. `VaultLocked` exists precisely so this condition gets its
own threshold and its own severity, which a clause in a shared rule cannot have.

**And `VaultFilesystemDeviceError` must evaluate only while the vault is mounted**, or it
reintroduces the same defect one alert over. It follows `BulkStorageFilesystemDeviceError`:

```
node_filesystem_device_error{device="/dev/mapper/vault",fstype="ext4",mountpoint="/mnt/vault"} == 1
for: 5m   severity: critical
```

That is mount-gated for free, because node-exporter emits `node_filesystem_device_error`
only for filesystems currently in `/proc/mounts`. While the vault is locked the series does
not exist, the comparison has nothing to evaluate, and the rule stays silent — which is the
correct behaviour, since a locked container cannot report a device error.

> **Exception to this section's house rule: do *not* wrap this one in `or absent(...)`.**
> Everything else here adds that clause so a deleted CronJob fires rather than going quiet.
> Applying it to a mount-gated rule inverts the logic — `absent()` is true for the whole of
> every locked period, and the alert becomes a critical page on normal operation. This is the
> one rule in the group where the pattern must not be followed, and it looks exactly like an
> oversight to anyone applying the house rule mechanically.

The two conditions are genuinely different and route to different responses: `VaultLocked`
means nobody has unlocked it yet, which a human fixes with a passphrase over SSH;
`VaultFilesystemDeviceError` means a mounted vault's filesystem is reporting errors, which
is a hardware or corruption problem and a different runbook entirely. Extending the existing
`BulkStorageFilesystemDeviceError` regex to include `/dev/mapper/vault` would in fact be
*safe* — same mount-gating — but it is kept separate so it can carry a vault-specific
runbook pointer. The asymmetry is the thing to remember: the device-error rule tolerates
the vault, the mount-set rule does not.

Widen the existing critical `ResticBackupFailed` regex without dropping its two running
jobs, and do not fold warning-only mail, workstation-copy, or prune failures into it. The
critical rule covers `restic-nas-backup`, `restic-b2-backup`, `restic-vault-backup`, and
`restic-vault-copy` using the same `kube_job_created * kube_job_owner and
kube_job_status_failed` join shape:

```
expr: |
  max by (namespace, owner_name) (
    (
      kube_job_created{namespace="monitoring",job_name=~"restic-(nas-backup|b2-backup|vault-backup|vault-copy)-.*"}
      * on (namespace, job_name) group_left(owner_name)
        kube_job_owner{namespace="monitoring",owner_kind="CronJob",owner_is_controller="true",owner_name=~"restic-(nas-backup|b2-backup|vault-backup|vault-copy)"}
    )
    and on (namespace, job_name)
      (kube_job_status_failed{namespace="monitoring",job_name=~"restic-(nas-backup|b2-backup|vault-backup|vault-copy)-.*"} > 0)
  )
  > on (namespace, owner_name)
  label_replace(
    kube_cronjob_status_last_successful_time{namespace="monitoring",cronjob=~"restic-(nas-backup|b2-backup|vault-backup|vault-copy)"},
    "owner_name", "$1", "cronjob", "(.*)"
  )
```

`ResticBackupSuspended` may cover every Restic CronJob because suspension has the same
warning severity and remedy. Failed `restic-workstations-copy` and `restic-prune` runs use
the same last-success join in separate warning rules, so they cannot turn a degraded
workstation copy or retention delay into a critical appstate page.

**`mail-archive` needs its own rule rather than a regex on `ResticBackupFailed`,** because
the two want different severities and different remedies. A failed Restic run means the
cluster's app state is unprotected — that is a critical page. A failed mbsync run means the
*second* copy of the mail did not update while Gmail still holds the original; it is a
warning to investigate, not a 3 a.m. page. Folding it into the critical rule would train the
operator to distrust criticals:

```
expr: |
  max by (namespace, owner_name) (
    (
      kube_job_created{namespace="monitoring",job_name=~"mail-archive-.*"}
      * on (namespace, job_name) group_left(owner_name)
        kube_job_owner{namespace="monitoring",owner_kind="CronJob",owner_name="mail-archive"}
    )
    and on (namespace, job_name)
      (kube_job_status_failed{namespace="monitoring",job_name=~"mail-archive-.*"} > 0)
  )
  > on (namespace, owner_name)
  label_replace(
    kube_cronjob_status_last_successful_time{namespace="monitoring",cronjob="mail-archive"},
    "owner_name", "$1", "cronjob", "(.*)"
  )
for: 15m   severity: warning
```

Note that the `> on (...)` comparison silently *disarms* this alert until the CronJob has
had one successful run. That is deliberate in `ResticBackupFailed` — a job that has never
succeeded is a deployment problem the deployer is still watching — and it is right here too,
but it means `MailArchiveFailed` cannot catch a mail job that fails on its very first run.
`MailArchiveStale` (36h, § 6) is the backstop for that window, and it is why both exist.

**`ResticWorkstationCopyOverdue` keys off destination state per host, not one shared
CronJob timestamp.** A successful no-op copy run does not prove that both B2 repositories
contain a current validated snapshot. The backup-state exporter emits the newest validated
destination lineage timestamp for each host, and the alert preserves that `host` label:

```
expr: |
  (time() - homelab_restic_destination_snapshot_timestamp_seconds{dataset="workstations",destination="b2"} > 8 * 24 * 60 * 60)
  or absent(homelab_restic_destination_snapshot_timestamp_seconds{dataset="workstations",destination="b2"})
for: 30m   severity: warning
```

It is a warning, not a critical, because the workstation NAS copy remains available;
a lagging replication job degrades the off-site recovery window
without losing data. That is the same reasoning that makes `ResticB2BackupOverdue` fire at
8d with a 30m `for` — match its shape.

**`BackupsVolumeFillingUp` follows the `OptFilesystemFillingUp` precedent** — the same
`avail / size` ratio against a pinned mountpoint, in the `homelab.node-and-apps` group
alongside it rather than in `homelab.backups`, because it is a filesystem condition and not
a property of any backup job:

```
- alert: BackupsVolumeFillingUp
  expr: |
    node_filesystem_avail_bytes{device="/dev/mapper/hoardvg-backuplv",mountpoint="/mnt/backups"}
    / node_filesystem_size_bytes{device="/dev/mapper/hoardvg-backuplv",mountpoint="/mnt/backups"} < 0.20
  for: 30m
  labels: { severity: warning }
- alert: BackupsVolumeNearlyFull
  expr: |
    node_filesystem_avail_bytes{device="/dev/mapper/hoardvg-backuplv",mountpoint="/mnt/backups"}
    / node_filesystem_size_bytes{device="/dev/mapper/hoardvg-backuplv",mountpoint="/mnt/backups"} < 0.10
  for: 10m
  labels: { severity: critical }
```

Pinning `device` as well as `mountpoint` matters here: `/mnt/backups` is
`nofail,x-systemd.automount`, so a failed array assembly leaves an autofs mount present at
the same path. Matching on `mountpoint` alone would then divide by the autofs entry's size
and produce a ratio that looks plausible while the real repository is unreachable. The
`device` selector makes the series absent instead, which is the honest signal — and it is
the reason this rule correctly goes quiet rather than lying during an array failure, where
`BulkStorageMountSetIncomplete` owns the page.

### The metric surface for job-derived alerts

Repository state cannot always key off `kube_cronjob_status_last_successful_time`. A copy
CronJob can succeed with nothing eligible, a locked-vault mail job deliberately exits zero
without archiving, and manual offline rotation has no CronJob at all. Enable node-exporter's
textfile collector and mount the root-only host directory
`/mnt/backups/.control/metrics/` into it. Trusted jobs and attended runbooks write one
owner-specific `.prom` file through temporary-file-plus-rename; workstation clients cannot
reach the directory. This adds no Pushgateway or long-running custom exporter.

The surface covers every state-derived rule, not only repository age:

- newest validated NAS and B2 snapshot timestamp per dataset and workstation host;
- per-repository size and configured ceiling;
- prune success, validation-held state and oldest-hold age per repo, unreplicated
  removal-candidate count, and consecutive replication-gated skip count; the metric uses a
  bounded reason class rather than snapshot IDs or free-form operator text as labels;
- invalid workstation snapshot-time holds;
- last successful structural check, rotating data-subset number, and data-check success per
  NAS/B2 repository; last successful quarterly restore program run and annual semantic
  restore per repository/destination;
- last successful offline rotation per physical drive; the global rule computes the newest
  of those two timestamps rather than relying on a separate heartbeat;
- last successful mail archive that actually ran `mbsync`; and
- last successful Strongbox `ccs.kdbx` offer and promotion; and
- last successful `~/Documents` offer and promotion per workstation host.

The metric files always contain the complete configured label set, including both
workstation hosts and both offline drives; a missing underlying state is emitted as zero
rather than silently dropping one host from a vector. `ResticOfflineDriveStale` takes the
maximum of the two per-drive timestamps, while `ResticOfflineDriveRotationOverdue`
evaluates each labeled series independently. There is no separate aggregate heartbeat that
can drift from the per-drive state. Alerts still carry `or absent(...)` to catch deletion
of the collector surface itself.

State is refreshed whenever a process already opens the relevant repository: vault local
on its four-hour backup, vault B2 on daily copy, appstate local nightly and B2 weekly,
workstation local during daily cluster-side validation and B2 during weekly copy. Prune
contributes its genuinely weekly outcome. This avoids the false claim that one daily copy
job opens every repository while still observing each ceiling on the cadence that can grow
that destination.

Dead Man's Snitch continues to cover the "monitoring itself is down" case.

## Files (proposed)

**New — `infrastructure/monitoring/`** (add each to `kustomization.yaml`):
`restic-vault-config.yaml`, `restic-vault-cronjob.yaml`, `restic-copy-config.yaml`,
`restic-vault-copy-cronjob.yaml`,
`restic-workstations-copy-cronjob.yaml`, `restic-prune-cronjob.yaml`,
`restic-verify-cronjob.yaml`,
`rest-server-deployment.yaml`, `rest-server-service.yaml`, `rest-server-storage.yaml`,
`rest-server.sops.yaml`

**Intentionally absent:** `restic-vault.sops.yaml` and `mail-archive.sops.yaml`. These
credentials are written directly under the mounted, encrypted `.backup-credentials` and
`.mail-credentials` directories, with silent prompts, by the phase that first needs each
one: phase 1 the vault NAS repository password, phase 4 the distinct vault B2 repository
password and dedicated B2 application-key files, and phase 7 the Gmail app password. Each
of those phases verifies that no rendered vault or mail Pod references a Kubernetes Secret
for them (§ 1b). The values themselves never enter git; the break-glass cards recover the
vault repository credentials, while the external password manager holds the independent
Gmail app-password copy.

**New — elsewhere:** `apps/mail-archive/`,
`containers/mail-archive/{Containerfile,VERSION}`,
`.github/workflows/mail-archive-image.yaml`, `host/ryze/`, `host/m5c/`, and
`runbooks/backups/` (00-preflight → 12, the separately callable attended
`resolve-validation-hold.sh`, plus `lib.sh` and `README.md` per `runbooks/README.md`
conventions), plus the released vault and per-workstation contracts under both
`infrastructure/monitoring/contracts/` and
`runbooks/disaster-recovery/contracts/`.

**`runbooks/backups/` is a directory-level workflow, not a numbered build-plan phase.** It
joins `direct-attached-storage-migration/`, `disaster-recovery/`, `bastion/`, and
`nfs-exports/` as an exception to the one-subdirectory-per-phase model in
`runbooks/README.md`. That is the right shape here: this work spans host, cluster, and
workstation surfaces and is run in stages over months, rather than once from an SSH-ready
host in build-plan order. So `docs/build-plan.md` stays at Phase 5 and gains nothing, and
the numbered phases in [Phasing](#phasing-proposed) below are stages *within* this
workflow — they are **not** `runbooks/phaseN/` directories, and they do not correspond to
the existing `runbooks/phase5/` scripts this document cites.

**Modified:** `infrastructure/monitoring/kustomization.yaml`,
`infrastructure/monitoring/configs/alert-rules.yaml`,
`infrastructure/monitoring/controllers/kube-prometheus-stack.yaml` (enable and mount the
node-exporter textfile collector at `/mnt/backups/.control/metrics`),
`host/minis/etc/fstab` — the vault entry is `noauto,nofail` on `/dev/mapper/vault`,
intentionally unlike its automounted siblings (§ 1b),
`host/minis/etc/crypttab` (new `noauto` entry mapping `vault` onto the
`hoardvg/vaultlv` LUKS container, pinned by LUKS UUID — § 1b),
`host/minis/usr/local/sbin/vault-unlock` (new),
`host/minis/etc/ssh/sshd_config_vault_ingest` plus its dedicated systemd service/socket
(new restricted SFTP listener),
`host/minis/usr/local/sbin/vault-ingest` and its systemd service (new KDBX/document
promotion path),
`host/minis/etc/systemd/system/vault-mountpoint-guard.service` (new — asserts `0555` and
`chattr +i` on the unmounted mountpoint, ordered `Before=mnt-vault.mount`),
`host/minis/etc/systemd/system/backups-mountpoint-guard.service` (new — asserts the same
fail-closed properties on the unmounted `/mnt/backups` directory before its automount),
`docs/architecture.md`, `docs/version-management.md` (document the second repo-built image),
`docs/operations.md` (retire the deferred item **only once implemented**),
`runbooks/README.md` (add `runbooks/backups/` to the directory-level workflow list — the
"four directory-level workflows are exceptions" sentence and the phase table both become
five),
`host/minis/etc/exports` (update the "no backup policy yet" comment),
`AGENTS.md` (decision log — record the discontinued photo export **and** the manual-unlock
trade-off in § 1b)

**Deliberately unmodified:** `apps/frigate/deployment.yaml`. The earlier draft mounted
the host subdirectory `/mnt/vault/frigate-exports` into Frigate; § 7 replaces that with a
sync so camera recording never waits on an unlocked vault.

**Unchanged:** the exports themselves. No `exportfs` change, so
[`runbooks/nfs-exports/`](../runbooks/nfs-exports/) does not need re-running.

**Reused as-is:** the `containers/restic-backup/` image (already carries bash, sqlite, curl,
and jq; mail uses its separate least-privilege image), `runbooks/lib.sh`, the SOPS/age flow
for non-vault secrets, the `homelab-low` priority class, and the `assert_fresh_file` /
contract-version pattern. Vault Job manifests change `/work` and `/tmp` to
`emptyDir.medium: Memory` and point `RESTIC_CACHE_DIR` there (§ 1b).

## Phasing (proposed)

Ordered so the highest-value, least-reversible data is protected first.

1. **Vault foundation** — create `vaultlv` **as a LUKS2 container from the start** (§ 1b —
   retrofitting leaves plaintext extents on the array), add the `noauto` crypttab entry
   mapping it to `vault` (**not** `vaultlv` — § 1b), the
   `noauto,nofail` fstab entry on `/dev/mapper/vault` (**no `x-systemd.automount`** — § 1b),
   and the `0555` **immutable** mountpoint plus the boot unit that re-asserts it,
   initialize the mounted filesystem root as `root:root` `0711`, install `vault-unlock`,
   create the root-only `.backup-credentials` directory and NAS password file, seed
   `ccs.kdbx` + documents, init the `vault` NAS repo *normally* — it is the chunker-params
   source for every later destination (§ 3) — first backup, prove the credential-directory
   exclusion, **restore drill**. Then install the restricted SFTP inbox, promotion service,
   `ryze` four-hour `ccs.kdbx` uploader, and 36-hour ingestion alert; prove a locked vault
   rejects the upload without writing beneath the mountpoint.
   Protects the irreplaceable-and-tiny within the first sitting.
2. **Break-glass card** — produce and distribute it, LUKS passphrase included (§ 8). Do
   this before there is enough in the repos to feel safe, not after — and note that from
   phase 1 onward the passphrase is a single point of failure for the source filesystem, so
   this phase is load-bearing earlier than it looks.
3. **Photos** — move `/mnt/media/Pictures` into the vault (NFS photo access ends here,
   § 1a — announce it before the move, not after), then Takeout bootstrap, de-dup against
   the local pre-2018 archive, verify counts, fold into vault.
4. **Off-site** — create a dedicated private B2 bucket whose application key is inaccessible
   to the root-resident `appstate` key or the proposed workstation keys, verify the existing
   `appstate` key is not authorized for the new bucket, impose the same restriction when the
   workstation keys are created, write the vault key files and a distinct B2 repo password
   under `.backup-credentials`, then init the B2 vault repo with
   `init --from-repo <NAS> --copy-chunker-params`. Wire the password-file-based copy job,
   drill a restore *from B2* (a passing NAS drill is not evidence about B2 — § 3), add
   alerts.
5. **Workstations** — **two** rest-server Deployments, each with `--append-only` and a
   per-client repo path, htpasswd credential, and repo password (§ 4). Do **not** pass
   `--private-repos`: one shared process would make `--max-size` a server-wide limit and
   quietly collapse the 150/100 GiB per-workstation caps in
   [Capacity ceilings](#capacity-ceilings-proposed) into one shared process-wide quota. Point the
   weekly prune job at those repos over hostPath, not REST. Initialize two corresponding B2
   repositories from their own NAS sources with `--copy-chunker-params`, then enroll `ryze`
   and `m5c` against their released contracts. Add each host's daily `~/Documents` uploader,
   isolated SFTP identity and inbox, host-namespaced promotion path, heartbeat, and seven-day
   ingestion alert.
6. **Housekeeping** — firmware into vault, Frigate exports sync job (§ 7 — a sync, not a
   volume mount), disk-image GC policy,
   retire the legacy rsnapshot tree on `/mnt/backups` (validate it holds nothing unique
   first). Budget **119 GiB** of reclaimable space from the 2026-08-30 `du -hsx
   /mnt/backups/snapshots/`, not the ~177 GiB whole-LV figure recorded in the migration
   worklog; account for the ~58 GiB difference in this pass.
7. **Mail archive** — fail preflight if host UID or GID 2000 is already assigned, build and
   immutably pin the dedicated mail image, verify the mounted vault root and create the mail
   paths with the exact ownership and modes in § 1b, write the Gmail app password with a
   silent prompt, save its independent copy in the external password manager, deploy the
   `2000:2000` mbsync app without a Kubernetes Secret or `fsGroup`, and prove a successful
   sync, least-privilege boundary, and credential exclusion from the next vault snapshot.
8. **Offline drives** — init **both** drives `--from-repo <NAS> --copy-chunker-params`
   (with their own distinct password, § 8) on the two existing 2 TB portable USB SSDs, record
   their labels and filesystem UUIDs, and install the single-command attended rotation
   runbook. Seed and validate each drive in separate attended sessions before normal
   alternation begins, so both per-drive rotation timestamps have a real initial checkpoint
   and the 210d rule does not start from an invented success. Return one drive off-site
   before retrieving the other, as required above. Then use the lightweight quarterly and
   substantive annual procedures above.

Enrollment of any NAS or B2 repository is incomplete until the recurring verification job
and metrics below include it. Add the local vault repo in phase 1, its B2 destination in
phase 4, and both destinations for each workstation in phase 5; the existing `appstate`
pair joins when the checker is first installed. Install the `/mnt/backups` mountpoint guard
before the first new writer in phase 1, then retrofit the shared preflight into the existing
`appstate` writers in the same attended change.

## Verification (proposed)

Backups are only worth what a restore proves, so every phase ends with one.

- **Per-phase restore drill, per repo.** `runbooks/backups/06-validate-vault-restore.sh`
  restores to a scratch path and diffs against source, in the shape of the existing
  `runbooks/phase5/05-validate-restore.sh` and `09-validate-b2-restore.sh`, but uses
  `restic check --read-data` rather than repeating their fixed `1/100` subset. A fixed
  `n/t` value always selects the same partition. Every repo gets its own check: a copy
  destination shares no storage with its source and a passing drill upstream proves
  nothing about it (§ 3). Record elapsed restore time against the targets above.
- **Backup-LV identity guard.** Prove every writer uses the shared `/mnt/backups` preflight
  and that rest-server readiness includes it. Against disposable fixtures, accept the exact
  expected device/filesystem/UUID/read-write/sentinel tuple and reject an uncovered
  mountpoint, autofs-only entry, wrong or permissive sentinel, read-only mount, wrong device,
  wrong filesystem type, and wrong UUID before a repository credential is opened or any
  file is created. Confirm the host boot unit restores `root:root 0555` plus the immutable
  bit on the bare mountpoint and does not prevent the real LV from mounting. Do not unmount
  the production backup LV to run negative tests.
- **Recurring online repository checks.** A monthly `restic-verify` CronJob checks every
  enrolled NAS and B2 repository independently. It first runs structural `restic check`,
  then `restic check --read-data-subset=<month>/12`, where `<month>` is the calendar month
  number from 1 through 12. The changing numerator is load-bearing: a fixed `1/12` would
  reread the same partition forever. This bounds normal B2 verification egress to roughly
  one stored-repository read per year while continually exercising local and remote pack
  reads. Run it away from backups, copy, prune, the md consistency window, and the quarterly
  restore; a failure in one repository is recorded without skipping the remaining repos.
  Vault checks skip without advancing success state while the vault is locked because their
  repository credentials correctly remain unavailable; their overdue alerts are mount-gated
  like the vault backup/copy alerts so `VaultLocked` remains the one warning in that state.
  The 40-day alert evaluates each other configured repository from day one and is enabled
  for a vault repository only after its first real successful check — never seed a fictional
  timestamp to silence rollout.
- **Recurring restores test meaning, not merely packs.** Once per quarter, run the attended
  restore workflow against at least one online repository/destination, rotating datasets and
  NAS/B2 destinations rather than repeatedly choosing the smallest repo. Once per year,
  every online NAS and B2 repository gets its own semantic drill: `appstate` must pass the
  released restore contract; `vault` must restore and validate `ccs.kdbx`, a document, a
  photo, mail, and a Frigate export when present; and each workstation repo must restore the
  file and metadata matrix below. Restore into a newly created scratch directory, never over
  a live source, record elapsed time and exact repository/destination, and remove scratch
  data only after validation. The quarterly program is overdue at 100 days and an individual
  annual repo/destination drill at 400 days. A quarterly run counts toward the annual
  requirement only when it performs that repository's full semantic matrix. These online
  checks supplement rather than replace the separate annual offline-drive procedure.
- **Powered-off credential boundary.** With the vault unmounted and the mapper closed,
  render every manifest and inspect the live API: no vault NAS/B2 repository password,
  vault B2 application key, or Gmail app password may exist in a Kubernetes Secret, Pod
  environment value, command argument, ConfigMap, root-filesystem credential file, or
  node-backed `emptyDir`.
  Confirm `restic snapshots` cannot open the local vault repo using only material available
  on the root NVMe, and that the root-resident B2 application keys cannot access the vault's
  dedicated private bucket. Then unlock and prove that password-file-based backup, copy, and
  prune all succeed. Perform these checks by structure and credential identity; never print
  secret values into the drill log.
- **Credential exclusion.** After each local and B2 backup, use `restic ls` to prove no
  `/data/vault/.backup-credentials` or `/data/vault/.mail-credentials` path exists in the
  exact new snapshot. Restore validation must reject a deliberately constructed test
  snapshot containing either path even if every positive manifest assertion otherwise
  passes.
- **Strongbox ingestion and recovery.** With the vault unlocked, change a harmless test
  entry in `~/Dropbox/ccs.kdbx`, let the `ryze` timer upload it, and prove the SFTP chroot
  cannot list or write outside `upload/`. Confirm temporary-name upload, atomic promotion,
  KDBX signature/size checks, and the success heartbeat. Lock the vault and prove the next
  upload fails without creating anything below the bare mountpoint, then unlock and confirm
  retry succeeds. Restore `ccs.kdbx` independently from the vault NAS repo, vault B2 repo,
  `ryze` workstation repo, and `m5c` workstation repo; manually open each restored copy in
  Strongbox without exposing the master credential in logs or automation.
- **Mail identity boundary.** Before creating mail-owned paths, prove host UID and GID 2000
  are unassigned. Verify the rendered CronJob has the exact § 6 security context, no
  `fsGroup`, no root ownership-fixing init container, and the pinned repo-built image. In
  the running mail container, prove `id -u` and `id -g` are both 2000; it can read (but
  never print) only `/data/vault/.mail-credentials/gmail-app-password`, create and remove a
  probe under `/data/vault/mail`, and complete an IMAP sync. The same process must fail to
  list `/data/vault`, read `/data/vault/.backup-credentials`, read another vault dataset,
  or create a top-level vault entry. Finally, verify `stat` still reports the exact § 1b
  ownership and modes; the Pod must not repair drift by changing them.
- **Locked-vault behaviour, end to end.** Reboot `minis` without unlocking and confirm the
  whole degraded path is the intended one: the host and k3s come up, camera recording keeps
  running, Frigate exports still land on `/mnt/frigate`, the `appstate` and workstation
  pipelines are unaffected, the vault backup/copy/mail work and vault portions of prune
  skip with exit 0 rather than failing, workstation pruning still runs, and `VaultLocked`
  fires at 30m — **and that it is the only thing that fires**.
  Hold the locked state past 30m and confirm no *critical* alert appears in that window:
  a critical at the 5m mark means the vault was folded into `BulkStorageMountSetIncomplete`,
  and one from `VaultFilesystemDeviceError` means an `or absent(...)` was added to it (§ 9).
  Both are regressions this drill exists to catch. **Time the mount-identity check** — it must return in
  milliseconds, not after a device timeout; a multi-second result means an automount crept
  back into the fstab entry (§ 1b) and every locked-vault run is now stalling. Confirm too
  that `systemd-ask-password --list` is empty, i.e. nothing queued a passphrase prompt at a
  console nobody is watching, and that the job reports the pinned bare-host-root identity
  rather than merely inferring "locked" from a missing sentinel. Then test the fail-closed
  guard **against the exact privilege the real jobs hold, not against an unprivileged
  shell**: `lsattr -d /mnt/vault`
  shows `i`, a host write as root fails with `EPERM`, and a write below
  `/data/vault` from a Pod running the § 2 security context (`drop: [ALL]`,
  `add: [DAC_OVERRIDE]`, same image and user) also fails with `EPERM` rather than landing on
  `vg0/root` (§ 1b). The unprivileged case passing proves nothing here — `0555` alone would
  pass it while the actual jobs sailed through.
  Finally unlock, run the attended post-unlock backup and copy, and confirm it ingests the
  exports written while locked and replicates the resulting snapshot. This is the drill
  that proves manual unlock is a degradation rather than an outage — and it is the one that
  rots fastest, because it only ever runs when someone deliberately schedules it.
- **Guard-rail tests, deliberately.** Exercise the mount validator against controlled
  fixtures mounted at the production in-container path `/data/vault`: the pinned bare-root
  tuple must produce the locked exit-0 result; the expected vault tuple with a missing or
  wrong sentinel must fail; and any third backing filesystem tuple must fail before a
  credential or destination path is touched. Do not manufacture those latter states by
  rebinding the host's production `/mnt/vault` path. Point the job at a truncated source and
  confirm the shrink guard fails the run, writes the structured lineage-keyed hold, and
  causes both copy and prune to skip that repo. In a disposable fixture, remove the hold
  file by hand while leaving the truncated snapshot newest and confirm prune *still* skips
  because the snapshot is absent from the validation ledger and outside the approved
  baseline generation — that proves the marker is not authorization.

  Exercise both attended resolutions against disposable repositories. For **reject**,
  confirm the helper requires the full typed snapshot ID, refuses a lineage found in B2,
  records the rejection, forgets only the held source snapshot, completes prune, and removes
  the hold last; interrupt it after forget and prove an idempotent rerun finishes safely.
  For **accept**, use a deliberately smaller but otherwise valid snapshot, confirm every
  non-shrink check is rerun, and verify the helper writes the validation-ledger entry and a
  new baseline generation before removing the hold. The next same-size backup must validate
  against the new generation even while older, larger snapshots remain restorable. Interrupt
  acceptance between ledger and baseline writes and prove copy and prune remain gated until
  the same resolution resumes. Attempting to accept a credential, contract, floor, clock,
  or integrity failure must be rejected. These are the checks that matter most and the ones
  that silently rot if never exercised.
- **Manifest rejection.** Restore-validate a snapshot whose manifest lists a source root
  the restore does not expect, and confirm the drill script refuses it rather than
  reporting a successful restore of a partial dataset.
- **Restore and parse mail and Frigate exports, not just seeded files.** A vault-wide
  snapshot diff does not prove either is usable — a
  zero-byte Maildir file or a truncated `.mp4` both compare equal against the source that
  produced them. Both are therefore restored to a scratch path and validated by content,
  not merely by presence:

  - **Mail.** Restore `/data/vault/mail` and assert each mailbox contains the
    `cur`/`new`/`tmp` triad and the exact isync state expected from `SyncState *`
    (`.mbsyncstate` plus Maildir UID metadata such as `.uidvalidity`). For every source
    mailbox that was nonempty at backup time, validate at least one non-zero-byte regular
    message whose `Message-ID` parses and whose byte count matches the source. Spam or Trash
    may legitimately be empty; the drill must not invent a failure merely to satisfy a
    positive-count assertion. Seed a harmless test message when a representative content
    restore is required.
  - **Frigate exports.** Restore `/data/vault/frigate-exports` and assert each file is
    non-zero, that the count matches the source directory at backup time, and that the
    container is recognized — `ffprobe` reports a video stream with a nonzero duration, or
    the equivalent for the image exports. This is the check that distinguishes a copied
    file from a playable clip, which is the only property an export has.

  Run both against a **local** snapshot and a **B2** snapshot (§ 3: a passing upstream
  drill proves nothing about a copy destination), and record the result in the drill table.
  Because these datasets are small, there is no reason to subsample — validate all of them.
  Even `restic check --read-data` cannot catch either semantic failure on its own: it proves
  the repository can return bytes, not that the bytes constitute a valid message or video.
- **Copy-before-forget.** Pause the copy job for long enough that the NAS repo holds
  snapshots B2 does not, then run the prune job and confirm it skips the repo, exports a
  non-zero unreplicated-candidate count, and prunes normally on the next run once the copy
  job has caught up.
- **Retention ordering and exact-candidate deletion.** In paired disposable repositories,
  create the vault's four-hour snapshot pattern and run both retention policies across more
  than one weekly cycle. Confirm B2's matching 48-hour hourly tier never removes a lineage
  NAS still retains, and confirm the job processes NAS before B2. After NAS dry-run
  candidate selection but before the destructive command, add another valid snapshot; the
  job must forget only the previously verified explicit IDs and leave the new snapshot
  untouched. Remove a copied destination snapshot while retaining its historical validation
  ledger row, then run copy again: the fresh destination listing must expose the absence and
  cause that source lineage to be copied and validated again. Finally, create an actual B2
  snapshot with no destination-ledger entry and confirm it is held for attended
  revalidation rather than accepted as replication proof.
- **Off-site independence.** Restore a document and a photo from B2 on a machine that is not
  `minis`, using only the break-glass card — no access to this repo's decrypted secrets.
  This is the only test that validates the disaster path end to end.
- **Vault is not reachable over NFS.** From `ryze`, confirm `/mnt/vault` is not exported
  and cannot be mounted, and that no path under `/mnt/media` resolves into it.
- **Append-only proof.** From `ryze`, attempt `restic forget` against the workstations repo
  and confirm it is rejected; repeat from `m5c` against its distinct endpoint.
- **Workstation recovery.** Restore representative files from each host's NAS and B2
  repositories onto a scratch installation, including a regular file, directory tree,
  symlink, executable, hidden application-state file, and `ccs.kdbx`. Verify ownership and
  mode on Linux and the metadata the macOS contract promises to preserve. Record separate
  drill rows for `ryze` and `m5c`; one host is not evidence for the other.
- **Alert proof.** Suspend each new CronJob and confirm the corresponding alert fires to
  Pushover; separately disable the `ryze` ingestion timer, age its last-success state past
  36 hours in the controlled test fixture, and prove `StrongboxVaultIngestionStale` routes.
  Disable each host's document-ingestion timer in turn, age its heartbeat past seven days,
  and prove `VaultDocumentsIngestionStale` preserves the affected `host` label.
  Create controlled vault and workstation validation holds, age them past 15 minutes, and
  prove `ResticSnapshotValidationHeld` routes the vault as critical and the affected
  workstation repo as warning without using snapshot IDs or free-form reasons as metric
  labels.
  Age a repository-check timestamp beyond 40 days and prove
  `ResticRepositoryCheckOverdue` preserves its dataset and destination labels; remove the
  series and prove the `absent()` arm also fires. Repeat for the 100-day quarterly and
  400-day per-repository annual restore states. With the vault locked, prove its check/drill
  age does not duplicate `VaultLocked`, then unlock and prove stale state becomes actionable.
  Exercise the offline metrics separately: two per-drive timestamps 90d and 180d old must
  fire neither offline alert; aging the newest of both beyond 120d must fire
  `ResticOfflineDriveStale`; and aging only one labeled drive beyond 210d must fire
  `ResticOfflineDriveRotationOverdue` for that drive without firing the global stale rule
  while the other drive remains current.
  `runbooks/phase5/12-test-pushover.sh` is the existing precedent.
- **Flux reconciliation.** `flux reconcile kustomization monitoring --with-source`, then
  confirm no drift and all new CronJobs are scheduled.
- **Quarterly offline rotation**, recorded in the table below with a date. It is intentionally
  not a restore drill: the one-command runbook verifies drive identity, copies and lists the
  two `offline-checkpoint-<YYYY>-Q<n>` snapshots, records their IDs, and unmounts cleanly.
  Once annually, alternate the selected SSD and add full `--read-data` checks plus scratch
  restores of `ccs.kdbx`, one document, and the `appstate` manifest. The contents of a
  disconnected drive therefore remain recorded without making an elaborate quarterly test
  a precondition for maintaining the offline copy.

| Drill | Last run | Result |
|---|---|---|
| `appstate` local + B2 restore | 2026-08-22 | passed (contract v2; local `731326fa`, B2 `fe10c1ff`) |
| `vault` local restore | *not yet* | — |
| `vault` B2 restore, break-glass only | *not yet* | — |
| Strongbox `ccs.kdbx` ingestion + four-source open | *not yet* | — |
| `ryze` workstation local + B2 restore | *not yet* | — |
| `m5c` workstation local + B2 restore | *not yet* | — |
| Mail archive restore (local + B2) | *not yet* | — |
| Frigate exports restore (local + B2) | *not yet* | — |
| Offline drive rotation (drive A) | *not yet* | — |
| Offline drive rotation (drive B) | *not yet* | — |
| Annual offline data check + representative restore | *not yet* | — |
| Recurring online repository checks (all NAS + B2 repos) | *not yet* | — |
| Quarterly online restore program | *not yet* | — |
| Locked-vault degraded boot (§ 1b) | *not yet* | — |

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
