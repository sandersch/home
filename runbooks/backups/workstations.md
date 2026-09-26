# Workstation enrollment and recovery

Status: rest-servers deployed; ryze has an accepted v2 seed (generation 2) and a
successful B2 copy. Native NAS/B2 content restores, both manual KDBX openings, and
the complete metadata gate passed on 2026-09-12. The supplemental Linux fixture was
backed up by the real Ryze client, validated, copied to B2, and independently restored
from both destinations; its xattr, symlink-target, ownership, mode, timestamp, and
representative-file results are recorded in the [recovery evidence](evidence/ryze-recovery-20260912.json).
The live activation gates and their evidence are tracked in the [activation record](evidence/ryze-activation-20260912.json).
Both workstation v1 and v2 contracts are released. `infrastructure/monitoring/workstations/`
is in the active monitoring Kustomization. Both hosts' four CronJobs are enabled.
Both hosts' NAS/B2 repositories are initialized. M5c has accepted NAS snapshots and
a successful B2 copy. Native NAS and B2 content and metadata verification passed on
2026-09-14/15, and both restored KDBX copies opened successfully. Its
[activation record](evidence/m5c-activation-20260912.json) records the completed
pre-schedule gates, enabled client, and first scheduled validation/copy results. The
vault v3 contract rollout completed on 2026-09-20; NAS/B2 recovery, fresh ingestion
promotion, the 24-hour observation, guarded manual retention, and the first scheduled
NAS/B2 prune all passed. See the [promotion evidence](evidence/vault-v3-promotion-20260916.json)
and [backup policy status](../../docs/backups.md#phasing-vault-v3-rollout-complete).
The September 26 [operational acceptance audit](evidence/workstation-acceptance-20260926.json)
closes M5c’s seven-day observation and natural weekly copy/prune gates. Ryze is
currently healthy, but its September 21 copy and September 22 prune failed; manual
September 23 recovery does not close its observation or natural weekly-cycle gates.
Both hosts have fresh NAS/B2 check-success evidence from September 16; natural
monthly-check acceptance remains separate and open. See [Checks and evidence](#checks-and-evidence).

| Host | NAS cap | B2 ceiling | Client schedule | Documents |
| --- | ---: | ---: | --- | --- |
| ryze | 150 GiB | 100 GB | hourly systemd user due-check | daily restricted SFTP |
| m5c | 100 GiB | 50 GB | hourly launchd agent while logged in | daily restricted SFTP |

Python 3.11+ and checksum-verified Restic 0.19.1 are required on clients. The Mac
uses `/opt/homebrew/bin/python3`; verify that exact executable's Full Disk Access
through launchd. It runs on battery and does not schedule wakes. Missed work is
checked on login/wake and retried while awake. Backup and upload success are separate;
Restic exit 3, permission failures, and unexplained or out-of-bounds manifest drift do not
advance backup success.

## Scope and preflight

The operator also confirmed that m5c's
`Library/CloudStorage/GoogleDrive-sanderscharlie@gmail.com` tree is fully present on
ryze and intended for backup there. Exclude that exact account tree on m5c, leaving
other accounts unaffected. Before releasing ryze's contract, verify its actual Google
Drive source location is inside the curated scope and locally readable; do not infer
coverage from cloud synchronization alone.

The identical shared Dropbox tree is protected in full by ryze. The Mac includes
only its required `ccs.kdbx`, preserving the Dropbox alias and real parent directories;
other Dropbox contents are omitted without reading cloud placeholders. Non-Dropbox
home content remains in scope. `only-file:<home-relative-file>` excludes every other
entry beneath that file's parent; ordinary exclusions still apply to the kept file.
This policy changes the Mac exclusion hash and requires a fresh enrollment measurement.

The exclusion files under `host/<host>/etc/workstation-backup/` are the reviewed
source policy. A bare glob matches any path component; a rule containing `/` is an
anchored home-relative subtree pattern, with each component matched separately
(wildcards cannot cross `/`). The client resolves exclusions to escaped absolute
Restic exclusions, skips cache-tagged directories and mounted filesystems, and
checks the resulting snapshot listing against the pre-backup manifest (see
[Churn tolerance](#churn-tolerance)). Symlink
targets are read from authenticated tree blobs because `restic ls --json` omits them.
Documents must contain included regular files and Dropbox/ccs.kdbx must be a readable
local regular KDBX of at least 100 KiB. Hidden application state and Mac
Library/Application Support are included. Runtime sockets, caches, installers,
dependency environments, games, and designated build output are omitted.

Before measuring, inspect projects whose meaningful source directories are named
`build`, `dist`, or `target`; relocate or narrow exclusions before releasing v1 if
those directories contain irreplaceable inputs. Every included regular file is
read during measurement. Do not bypass unreadable files with a blanket exclusion.

On each host:

```sh
sudo python3 runbooks/backups/workstation-install-restic.py
python3 host/workstations/workstation.py measure --host ryze \
  --excludes host/ryze/etc/workstation-backup/excludes \
  --contract-version N --output /tmp/workstation-ryze-vN.measured.json
```

Use `m5c` and its exclusion file on the Mac. Measurement output must be a new path,
and `N` is the host's next unreleased contract version.
The proposal fixes source root, logical hostname, exclusion hash, total and Documents
file/byte measurements, 80% floors, and the fixed KDBX floor. Review logical bytes
against 50 GB / 20 GB source budgets and actual NAS headroom; do not release a
contract solely because it fits the hard cap.

Mac preflight is attended: verify FileVault, disable iCloud Optimize Storage,
materialize Dropbox content, and confirm Photos/Mail contain no unique data. Install
the shared script temporarily and run the **measure command as a launchd job using
the same Python executable** before creating the released contract. Record the
launchd job's exit status and output, including readable protected Library paths.
A successful Terminal run does not establish Full Disk Access for launchd.

Create an evidence JSON with `host`, `inventory_reviewed`, `capacity_reviewed`, and
`required_content_readable` set to true only after inspection. Mac evidence also
requires `fda_launchd_passed`, `icloud_optimize_disabled`,
`photos_mail_no_unique_data`, and `dropbox_materialized`. Include actual measurements,
OS/version, execution path, timestamp, operator, and any privacy checks in the record.

```sh
python3 runbooks/backups/workstation-release-contract.py \
  /tmp/workstation-ryze-vN.measured.json --evidence /tmp/ryze-enrollment-evidence.json
```

The release writes `workstation-<host>-vN.json` and a frozen copy of the exclusions,
`workstation-<host>-vN.excludes`, identically to host, cluster, and recovery
directories. An existing release cannot be overwritten; identical partial releases
can resume, and vN requires v(N-1) to be released first. Add both files to the
contracts ConfigMap and never remove a released version. Keep the canonical script
mirror byte-identical; the workstation tests enforce this and the mappings.

### Contract versions

`host/<host>/etc/workstation-backup/excludes` is the working policy. Released
versions are immutable, so any exclusion change is a new measurement and the next
contract version; the client refuses to run when its exclusions differ from its
installed contract. The installer takes exclusions from the contract's own frozen
`.excludes` file.

Validation reads the contract named by each snapshot's manifest and applies that
version's exclusions and floors, so historical snapshots stay verifiable. Every
released version is pinned in root control state when first loaded (the pre-versioning
`contract_sha256` becomes the v1 pin); a changed or missing pinned version stops all
maintenance. The first accepted snapshot of a higher version starts a new shrink
baseline generation and records a `contract-transition` resolution. A snapshot whose
version is below the newest accepted one is held as `contract-downgrade`; reinstall
the current contract on the client and reject the exact held ID.

### Churn tolerance

The client writes its manifest from an inventory taken before Restic runs, so on a
desktop in use the snapshot normally differs from it. v1 contracts have no
`churn_tolerance` and still require an exact match. From v2, the release fixes
`churn_tolerance`: at most `min(1000, 0.5%)` of measured files may differ, and none
at or under `Documents` or the KDBX path. The server enforces those bounds; it
measures floors, exclusions and required content from the actual snapshot, and
requires the manifest's own totals to match its records.

The client additionally requires every differing path to be explained by the live
filesystem: a changed or added path must have a ctime after the backup started (less
two seconds of clock slack), and a vanished path must have a surviving ancestor
changed since then. An unchanged file missing from the snapshot is an omission, so
success is not advanced. Accepted churn is logged as `accepted N paths changed during
backup`. A change under Documents or to the KDBX during a run fails that run; the next
hourly retry repeats it.

After all client checks pass, a tolerant-contract client writes a small encrypted
completion receipt as a separate append-only Restic snapshot, using the reserved
path `/.workstation-backup-validation/<full-home-snapshot-id>.json`. Its payload
binds the exact home snapshot ID, tree ID, contract and exclusion hash. Publishing
the receipt must succeed before local backup success advances. Strict v1 snapshots
do not require receipts.

Maintenance independently validates the home snapshot and requires a matching,
size-bounded receipt before accepting any tolerant-contract snapshot, even one
with no manifest drift. Missing receipts produce a `client-validation-incomplete`
hold: no trusted freshness, copying or retention advances. If validation races
receipt publication, the next validation automatically clears the hold once the
receipt arrives and all checks pass. A failed or interrupted client run that never
published a receipt remains held; make a fresh successful backup, then use the
attended exact-ID rejection procedure for the incomplete snapshot and validate
again. Do not manufacture receipts for failed runs.

The receipt communicates successful completion by the enrolled client; it cannot
prove live ctimes against a compromised client. Server-side floors, exclusions,
required content and churn bounds remain mandatory. Neither tags nor `original`
fields establish completion. The checked receipt payload and its exact IDs are
saved in root-owned acceptance state, which also binds any B2 counterpart. Receipts
are NAS ingestion metadata, are not copied as home backups, and never contribute
to freshness or retention's time anchor. Normal NAS retention removes validated
receipts only after their home snapshot is gone; the root-owned acceptance evidence
survives. Unrecognized receipts are retained for attended inspection.

Deploy the updated maintenance code and install the updated client before making
the first v2 seed. Existing suspended schedules and native restore gates still apply.

## Host and credential preparation

The operator confirmed m5c's static IP assignment at `10.137.30.7` on 2026-09-10;
SSH verified that address and active Wi-Fi MAC `aa:9a:b7:f2:ea:2d`.
The operator also confirmed Private Wi-Fi Address is **Fixed** for the home network;
the assignment uses that fixed private MAC, not hardware MAC `c0:c7:db:ed:b5:bd`.
Before host preparation, check UDM leases/reservations and ARP from VLAN 30 for conflicts.
Record the checks before installing the staged nftables rule allowing that source
to minis TCP 2222. If the MAC differs, update and review the inventory first.
Verify UID/GID 2101 are unused or already belong to vault-ingest-m5c.

Generate m5c's dedicated ingestion identity inside `~/.config/vault-ingest/` with
mode 0700 and key mode 0600. Commit **only** its public key as
`host/minis/etc/ssh/vault-ingest-authorized-keys/vault-ingest-m5c`. Pin minis's SSH
host key in the client's dedicated known_hosts file using an independently trusted
fingerprint. Do not use an unverified scan as the trust decision.

Run `bash runbooks/backups/workstation-prepare-minis.sh` from the reviewed checkout
on minis. It checks mount identity, available capacity, directory ownership and the
attended network gate, prepares the independent repository/control directories,
and installs the SFTP identity and host components. It does not initialize repos or
enable workstation schedules. Take the required `/opt` snapshot before changing
stateful configuration. Host configuration changes remain attended operations.

Create a private B2 bucket per host with independent bucket-scoped read/list/write/delete
application credentials. Disable bucket lifecycle expiry; Restic owns retention.
Do not reuse appstate or vault credentials. Preserve the account recovery source in
the password manager, independent of either workstation. Install `htpasswd`
(apache2-utils on Linux) on the enrollment operator machine.

```sh
python3 runbooks/backups/workstation-credentials.py create --host ryze \
  --secret infrastructure/monitoring/workstations/ryze.sops.yaml
```

Repeat for m5c. Passwords are random, HTTP authentication uses bcrypt, and plaintext
is passed to SOPS in memory. Add only the encrypted files to the staged
Kustomization. `export-client --host ... --secret ... --output ...` exports only
that client's NAS repository/authentication/encryption fields to private storage
outside the checkout. Never give clients the maintenance JSON or B2 credentials.

## Staged deployment and seed

Render `kustomize build infrastructure/monitoring/workstations`, run the tests below,
and review the diff. Add `workstations` to the active monitoring Kustomization in
a reviewed Git commit once paths, secrets and measured contracts are ready. Follow
the repository's GitOps suspension/reconciliation procedure for live changes. Keep
every new CronJob suspended. Verify each rest-server and its Tailscale HTTPS Ingress,
append-only flag, distinct quota, NetworkPolicy, mount guard, and readiness.

Use a one-off Job copied from the corresponding validation CronJob, changing its
command to an attended shell/sleep long enough for `kubectl exec -it`, then invoke:

```sh
python3 /scripts/maintenance.py initialize --host ryze
```

Initialization only treats Restic exit 10 as absence; all other failures stop. B2
uses NAS chunker parameters, and a resumed initialization verifies they match.
Use the same Job template for attended `validate`, `copy`, and `check` operations.
Do not mount the vault into workstation Jobs. Prune Jobs alone receive the API
token needed to patch/get the two named Deployments for quota recount.

Maintenance logs timestamped JSON phase records to stderr: `start`, `progress`
every 30 seconds, and `complete` or `failed`, with monotonic `elapsed_seconds`.
Use `kubectl --context homelab-readonly logs -n monitoring job/JOB_NAME -c maintenance -f`.
`maintenance-lock-wait` measures the shared per-host advisory lock wait separately
from `maintenance-action`. Within the action, `snapshot-discovery`,
`snapshot-listing`, `listing-decode`, `comparisons`, `required-content-read`,
`client-completion-verification`, `transfer`, and `destination-identity`
identify the work. `metrics-collection` covers the final repository queries and
size collection. Phases can nest; elapsed times are inclusive, not additive.

Restic phases include cumulative `stdout_bytes`, `stdout_lines`, `stderr_bytes`,
and `stderr_lines`, without logging captured payloads, paths, credentials or
command arguments. Stderr remains visible in the Job log while its counters are
updated, so backend retry and progress messages can be correlated with the
heartbeat. For `ls --json`,
lines count emitted JSON records (including the snapshot header), not verified
files. An unchanged counter means no new stdout, not proof of a stalled process:
index loading, backend reads, transfer, and Restic's own repository-lock retry
can be silent. Restic stderr remains visible, including its lock retry messages;
that wait occurs inside the Restic phase, separately from `maintenance-lock-wait`.
There is no transfer percentage unless Restic itself emits one. These logs do not
change validation, cache policy, schedules, or the meaning of success metrics.

Routine workstation copying validates new NAS sources before transfer, then matches
each destination's tree hash, hostname, source paths, and timestamp to the accepted
source. It records exact NAS/B2 IDs only after a unique matching counterpart is
present. Interrupted copies recover through the same identity match; client-supplied
`original` fields are never authority. Already accepted sources and copied destinations
do not need another full inventory/manifest scan during copying.

Copy success means every accepted source has a matching destination snapshot; it
does not certify that every referenced B2 object is currently readable. The separate
monthly `check` jobs run structural verification and a rotating `--read-data-subset`
on both repositories, while attended restore drills exercise recovery. NAS retention
still performs full source/destination contract validation before deleting a source
snapshot (`destination-verification` in prune logs). This preserves the stronger
deletion gate while removing repeated full inventories from routine copy runs.

For attended diagnostics, set `WORKSTATION_RESTIC_VERBOSE=1` on a temporary
`check` Job. The client adds Restic's `--verbose` flag only to repository checks;
the recurring CronJobs do not set this variable.

Install the client using `workstation-install-client.py --host ... --contract ...
--credentials ...` as the desktop user. This installs configuration and schedule
files but does not enable them. Run the daily command manually to seed NAS and
upload Documents, then invoke server `validate` and `copy`. Record full NAS/B2 IDs
and compare both repositories' config/chunker values. Repeat for m5c after ryze's
NAS/B2 seed is validated.

The client logs JSON phase start/progress/complete/failed records to stderr with
30-second heartbeats and monotonic elapsed time. `backup-total` includes inventory,
manifest writing, Restic backup, snapshot listing/decoding, comparisons, churn
verification, and completion-receipt publication. Inventory reports completed
files/directories, bytes read (including partial files), and average bytes/second.
`enrollment_files` is a historical reference, not a current total or percentage.
Every backup still reads every included file before invoking Restic. Restic phases
report stdout byte/line counts; backup phases also expose allowlisted numeric
status/summary fields when Restic emits them. Paths and captured payloads are not
included in these progress records. Lock-busy and not-due skips are explicit.

The restore helper writes phase records to stderr and `restore-verification.log`.
Its report's `elapsed_seconds` now covers snapshot discovery, restore with content
verification (unless `--verify-only`), snapshot listing/decoding, and all metadata
checks. Metadata progress reports nodes examined and verified; the listing total
also includes ancestor/root entries that are skipped. Selected metadata tree reads
report requests/cache hits, and each repository read has a heartbeat. Repeated
tree-read durations accumulate. Phase times can overlap and must not all be added
together. Restic restore output remains visible directly; heartbeats establish
that the wrapper is running, not that data is moving. A failed phase logs `failed`
without turning an incomplete operation into success.

Snapshot validation checks every expected path and its type, including that every
expected symlink is present as a symlink. It does not globally compare symlink
target strings: Restic already stores those targets in its authenticated tree,
and checking them required thousands of separate metadata reads. The required
Dropbox/KDBX path is still selected from the reviewed scope contract, while
ordinary symlink targets are outside the recurring comparison. Native restore
drills may inspect selected target strings when that is part of the recovery gate.

For a wrapper-only update, wait for the client's existing backup lock to become
available, retain the installed script as a rollback copy, and atomically replace
only `/usr/local/lib/workstation-backup/workstation.py` while holding that lock.
Verify its SHA256 against the canonical source. Preserve the installed credentials,
contracts and schedule activation state. Updating the file does not change a
running Python process. The cluster mirror is delivered by the `monitoring` Flux
Kustomization; check the mounted ConfigMap script before starting new maintenance
work. Existing jobs must finish before deploying a shared-script update.

The SFTP promoter accepts only regular files/directories in a frozen archive,
enforces a 50 GiB bound, serializes per host, atomically records completion, and
never propagates client deletions. Identical successful deliveries refresh the
promotion heartbeat. Enable the promoter's hourly retry timer after its ingestion
tests pass. Ryze remains the only Strongbox uploader.

## Vault v3 activation

**Completed 2026-09-20.** The active vault contract is v3 at baseline generation 2;
NAS/B2 recovery, fresh ingestion promotion, 24-hour observation, guarded manual retention,
and the first scheduled NAS/B2 prune passed. The steps below preserve the attended
transition procedure for audit and future reference.

After inspecting the promoted Mac document seed, run
`sudo python3 runbooks/backups/workstation-release-vault-v3.py` on minis. This
preserves v1/v2 and releases v3 with measured 80% Mac document floors. It does not
switch the sentinel or active validator.

Coordinate a suspended vault backup/copy/prune window with no running vault Jobs.
Add v3 JSON and exclusions to the vault contract ConfigMap, set
`VAULT_CONTRACT_VERSION=3` in the vault Job environments and host vault.conf, and
atomically replace the mounted sentinel with version 3 while retaining its UUID
and root:root 0444 metadata. During the transition, the active version remains v2 until
this gate passes; the live system has since completed the gate and runs v3.
Before replacing the sentinel, reinstall `vault-unlock` and `vault-ingest-promote`
from the repository and confirm with `cmp` that each installed copy matches. A stale
promoter rejects every upload with `vault sentinel contract mismatch`, which surfaces
only as `StrongboxVaultIngestionStale` 36 hours later. After the switch, start
`vault-ingest-promote.service` once and confirm it exits 0.
Update the current vault baseline through its existing attended contract transition
and restore procedure; never overwrite a v2 baseline merely to silence a hold.
Validate a new v3 NAS snapshot and its B2 restore before resuming schedules.
The snapshot validator continues selecting historical v1/v2 contracts from the
snapshot's manifest, so old recovery points remain usable.

## Recovery and activation evidence

Run independent NAS and B2 restores for each host on its native OS:

```sh
python3 runbooks/backups/workstation-restore.py --snapshot FULL_64_CHARACTER_ID \
  --destination nas --credentials PRIVATE_NAS_CREDENTIALS.json \
  --scratch-parent PRIVATE_EXISTING_DIRECTORY \
  --metadata-path /absolute/source/path/to/metadata-fixture \
  --symlink-path /absolute/source/path/to/relative-link \
  --symlink-path /absolute/source/path/to/absolute-link
```

Supply only the chosen repository's Restic environment JSON. B2 recovery uses its
escrowed credentials independently of minis. The helper creates a new private
scratch directory, uses Restic content verification, checks every expected entry's
type (including symlink presence), modes, ownership and modification times, and
tests selected extended attributes. Symlink target strings are compared only for
the repeatable `--symlink-path` samples, using authenticated snapshot metadata.
Select backed-up relative and absolute link fixtures and any important operational
links (such as a Dropbox alias). Targets are compared as strings without following
them; an absolute link need not resolve within scratch. With no samples, only
symlink presence is checked. The report records the presence count, selected target
scope and successful sample paths; it does not claim exhaustive target verification.
This avoids a separate Restic process for every directory containing symlinks.
An incorrect target on an unselected link can escape the custom comparison.
On the Mac, use a fixture with a Finder attribute and a nonempty `com.apple.ResourceFork`;
verify both on restore. Check hidden application state and an executable too.
Manually open each restored KDBX and record the result. Keep actual full IDs,
measurements, elapsed times and metadata names in the evidence file. Scratch is
retained for attended inspection and explicit cleanup.

To rerun metadata verification on an already extracted home, use the same exact
snapshot and destination with `--verify-only --restored-home /path/to/scratch/home`
and the selected metadata/symlink paths. This skips extraction and Restic content
verification; retain the earlier successful content-verification evidence and
reference it with `--content-reference /path/to/evidence`. That option records a
reference, not a fresh content check. Updating the helper does not change an
already-running process.

Promise curated file recovery within seven days after a replacement OS is ready:
contents, modes, modification times, symlinks and tested native metadata. This is
not disk imaging or a Time Machine replacement. Repeat representative NAS/B2
restores quarterly and a full curated home restore annually. Monthly per-host
checks include structural validation plus a rotating one-twelfth data read.

Before enabling client schedules, supply `--enable --evidence ...` to the client
installer. Required booleans are documented in that script and include independent
restores, manual KDBX opening, append-only denial, network retry, successful document
promotion and vault-lock independence. Mac activation also requires launchd privacy,
FileVault, cloud settings and metadata evidence. Exercise append-only deletion and
quota exhaustion/recount **only on disposable fixture repositories**, and test
cross-host credentials and cluster NetworkPolicy independently. Prove warning and
resolved Pushover delivery using the established synthetic alert workflow.

Workstation alerts stay quiet until `maintenance.py` records a host's first seed
snapshot as accepted or held, which sets `homelab_workstation_enrolled` to 1.
Initialization alone does not enroll a host. Zero copy, prune and check timestamps
then count from the enrollment timestamp, so a new seed has each rule's full window.
`ResticWorkstationEnrollmentLost` fires if enrollment metrics vanish or revert
afterwards, because that would otherwise silence every gated rule.

Enable validate (daily 05:30), copy (Monday 05:45), prune (Tuesday 00:30), and monthly
check schedules through reviewed commits only after both destinations' recovery
gates pass. All cluster times are America/Chicago. Observe seven days and one
successful weekly copy/prune cycle per host before marking the phase complete.

## Holds, retention and rollback

Root control state lives under `/mnt/backups/.control/workstation-<host>` outside
the repositories. Validation processes snapshots chronologically, checks the ten-minute
future/high-water clock limits, and compares content to the immutable contract and
manifest. Seven healthy snapshots establish the rolling median baseline; a 20%
shrink creates a hold. Holds stop copy and retention. No tag or `original` field is
authority for the exact source ID.

Attended resolution in a maintenance Job:

```sh
python3 /scripts/maintenance.py reject --host ryze --destination nas \
  --id FULL_ID --reason 'reviewed explanation'
python3 /scripts/maintenance.py accept-shrink --host ryze --id FULL_ID
```

Rejection deliberately forgets only the inspected exact ID and retains an audit
record; it is resumable after interruption. Acceptance is allowed only for a shrink
that passes all other checks and starts a new baseline generation. It cannot bypass
required-content floors or clock validation.

Retention is `--group-by host --keep-within 30d --keep-within-daily 30d
--keep-within-weekly 84d --keep-within-monthly 12m`. Restic 0.19.1 rejects `12w`;
84d expresses the intended twelve weeks. `--keep-within` is relative to the newest
snapshot, not wall clock. Each NAS candidate requires a physically present,
content-validated B2 counterpart before explicit-ID forget. Snapshot-set changes
during planning abort the pass. NAS prune precedes B2 prune, with a required server
restart and readiness wait to refresh quota accounting before prune success advances.

Rollback suspends new CronJobs and client schedules, disables the two Ingress
endpoints, and retains repositories, SOPS credentials and root control state.
Do not remove the entire Flux-managed directory with pruning enabled: that would
also remove credential resources needed for recovery. Preserve v3 artifacts for
historical restores even if active vault configuration is reverted in an attended
suspended window.

## Checks and evidence

### 2026-09-26 operational acceptance audit

The [sanitized live evidence](evidence/workstation-acceptance-20260926.json) combines
read-only Kubernetes status with seven days of native 30-second Prometheus samples
(September 19–26). Each workstation health series contains 20,160 samples with a
maximum scrape gap of 30.020 seconds. Historical Job metrics preserve results that
Kubernetes has already removed; CronJob `lastSuccessfulTime` alone would misleadingly
attribute the retained manual successes to scheduled execution.

| Gate | M5c | Ryze |
| --- | --- | --- |
| Current freshness, ingestion, holds, capacity and enrollment | Passed | Passed |
| Daily scheduled validation, September 20–26 | Passed, all seven runs | Passed, all seven runs |
| Seven-day operational observation | Passed | Open: maintenance failures and firing job alerts occurred during the window |
| Natural weekly copy/prune | Passed, September 21/22 | Open: scheduled copy/prune failed; September 23 manual retries succeeded |
| Current NAS/B2 repository-check health | Passed, September 16 success timestamps | Passed, September 16 success timestamps |
| Natural monthly-check acceptance | Open | Open |

M5c’s scheduled `restic-m5c-copy-29833125` completed at
`2026-09-21T15:12:57Z`; `restic-m5c-prune-29834250` completed at
`2026-09-22T05:43:28Z`. Prometheus retains their CronJob ownership, successful-pod
counts and completion timestamps. The observation window contains no M5c failed
maintenance Jobs or firing workstation alerts. Its operational acceptance is closed;
the separate monthly scheduled-check gate remains open.

Ryze’s `restic-ryze-copy-29833125`, `restic-ryze-prune-29834250`, and
`restic-ryze-prune-manual-20260923` produced `KubeJobFailed` alerts. The retained
September 23 copy and prune retries completed successfully, and no relevant alerts
are currently pending or firing. These recovered failures prevent declaring a clean
seven-day operational observation. Verify the next natural copy on September 28 at
05:45 and prune on September 29 at 00:30 America/Chicago, and complete seven days of
observation after recovery, including failures and alerts. The September 22 copy
implementation change is recorded in `5b19475`; this audit does not infer the exact
cause of deleted failed Jobs from their names or duration.

Both hosts remained enrolled, with zero holds or invalid snapshot times, successful
size collection, and fresh Documents promotion throughout the seven-day window.
NAS snapshot age stayed below seven days and B2 below eight days. At capture, NAS/B2
repository sizes were respectively 11.95/11.43 GB for Ryze and 21.87/21.54 GB for M5c,
all below the 80% warning threshold. Both rest-servers are ready and carry September 23
quota-recount markers. M5c’s latest accepted NAS/B2 snapshot dates to September 21
(about 4.9 days old); successful daily validation does not mean a fresh client backup.
Watch for a fresh M5c delivery before its seven-day NAS limit.

September 16 NAS/B2 check-success metrics prove current repository-check health.
The retained B2 verbose-check Jobs were manually instantiated; neither those nor a
CronJob success timestamp proves a natural monthly cycle. Inspect the next scheduled
checks on October 15 at 02:30 America/Chicago. No production schedules, repositories,
credentials, or client state were changed during this audit.

### Earlier enrollment and observation records

2026-09-10 host preparation completed from `d7cafa1` on minis, after creating
`/opt/.snapshots/pre-workstations-d7cafa1`. Both repository directories and root
control directories were prepared, and UID/GID 2101 were assigned to
`vault-ingest-m5c`. The restricted listener and source-IP firewall rule were
installed. An SFTP session from m5c authenticated with its dedicated key and
independently pinned minis host key, reporting `/upload` as its working directory.
Both SOPS workstation credentials decrypt successfully and use separate B2 keys
and independent repository passwords. No initial backup or restore is claimed by
these preparation checks; all eight maintenance CronJobs remain suspended.

That statement describes the 2026-09-10 preparation point. Current status as of
2026-09-19: Ryze schedules were enabled on 2026-09-12 and m5c schedules on 2026-09-15;
all eight maintenance CronJobs report `SUSPEND=false`. Both hosts have successful recent
validation jobs. M5c completed its first scheduled copy, prune, and validation. Ryze's
scheduled copy and validation succeeded, and its previously missing prune was run manually
on 2026-09-16; both NAS and B2 phases completed successfully. For m5c, the operator
confirmed successful daily validation throughout the week and no active Prometheus or
Alertmanager alerts. The live NAS/B2 freshness, Documents-promotion freshness, hold, and
repository-size snapshot passed all current thresholds; see the [m5c observation evidence](evidence/m5c-observation-20260919.json).
M5c’s remaining gates are seven days of observation and one normal scheduled weekly
copy/prune cycle; the monthly-check gate remains separate and open. On September 20,
the operator corrected the observation start from August 13 to September 15, matching
client activation. The September 19 health result therefore covers four calendar days;
the seven-day gate can close no earlier than September 22, with confirming evidence.

Mac attended inventory completed through launchd with exit code 0 at
2026-09-10T04:36:02Z: 261,860 files / 25,872,475,952 bytes, including 12 Documents
files / 3,288,711 bytes. The operator confirmed the Documents totals are expected.
The [measurement](evidence/m5c-measured-20260910.json) pins the reviewed exclusion
hash and real Dropbox KDBX path. The [enrollment checks](evidence/m5c-enrollment-20260910.json)
record confirmed privacy/readability settings and attended capacity checks (360 GiB
free on the Mac; 758 GiB free on the expected NAS ext4 volume). The m5c v1 contract
is released in the host, cluster and recovery contract directories, pending commit
and deployment activation. This is not proof of backup or restore; no schedules
are activated by recording it. The staged cluster ConfigMap references the released
contract; the package remains outside the active monitoring Kustomization.

Run `test-workstations.py` with `WORKSTATION_RESTIC` pointing at verified Restic
0.19.1 (its empty repositories are checked in with deliberately weak scrypt keys;
regenerate them with `fixtures/make-workstation-repositories.py`),
`test-workstation-alerts.py` with `PROMTOOL`, existing backup regressions,
`test-config-scripts.sh`, image-policy validation and both monitoring renders.
The Python plist check is portable; also run `plutil -lint` on the actual installed
Mac plist. Live privacy, DHCP, NetworkPolicy, quota, notification, sleep/wake and
native Mac metadata gates cannot be replaced by Linux fixtures.

The dated entries below preserve rollout history. The 2026-09-12 recovery record
supersedes earlier pending ryze seed/copy/restore statements. Notification delivery,
remaining activation checks, and seven-day observation are not established by
these recovery results. Do not infer activation from the presence of evidence files.

Local implementation verification (2026-09-08–09): the curated ryze inventory
completed at 552,840 regular files / 27,921,624,561 bytes; Documents measured 538
files / 296,757,693 bytes. Disposable Restic repositories exercised exact-ID copy,
required-content/manifest drift, omitted files, clock skew, shrink acceptance,
interrupted copy/rejection, missing B2 counterparts and failed recount. Promtool
validated all 18 new rules and independently tested missing NAS/B2/Documents
metrics for each host and locked-vault document suppression. The real pinned
rest-server fixture returned 401 for the other host's credentials, 403 for snapshot
deletion and 507 for quota exhaustion, then accepted a backup after direct prune
and restart. These are fixture results, not production enrollment or Mac recovery
evidence. Docker reassigned the fixture's dynamic host port on restart; the fixture
now rediscovers it and uses a bounded readiness check.

Ryze's existing measured inventory has the current exclusion hash. The operator
identified `~/GDrive` as the shared Google Drive source. An attended check found it
is a local directory on the home filesystem with 238 readable regular files and
537,072,860 bytes (~513 MiB), so it was included in that measured ryze scope. The
[ryze enrollment evidence](evidence/ryze-enrollment-20260910.json) records this and
the capacity check. The ryze v1 contract was released on 2026-09-10 from that saved
measurement, identically in the host, cluster and recovery directories. Credentials,
host preparation and deployment were completed later that day (above); initial
backups and native NAS/B2 restore drills remain pending, and all maintenance CronJobs
remain suspended.

2026-09-11 deployment and ryze seed attempt. The Tailscale Ingresses stayed without
an address until HTTPS was enabled on the tailnet; ryze then joined the tailnet with
`--accept-routes` left false because it is already on the LAN. Both endpoints resolve
and return 401 unauthenticated over a verifying certificate. The running servers use
`--append-only` with `--max-size` 161061273600 (ryze) and 107374182400 (m5c), each
serving only its own hostPath; both NetworkPolicies admit only that host's Tailscale
proxy and labelled maintenance Jobs on port 8000, and the mount guard passed. Denial
of unlabelled pods and of cross-host credentials was not re-tested live.

ryze's repositories were initialized from an attended Job at 03:46Z: NAS
`0bb298b1e54a468d2d911d03cb7b8394dc1dc3540e755b6bee09fb30e412cd98` and B2
`ee32a7cffd6d8413d11c9fcbceefdc1314b7c92b3900bf87d99fdd9f35d9557d`, both format 2 with
chunker polynomial `325f7bfd55d179`. The first manual `daily` run wrote NAS snapshot
`bbff493974095c55e80255b87e2b6313dea2b87c857ba13cc686beb681272e62` but did not advance
success: 28 of ~648k paths changed during the 11-minute scan (Chrome profile state,
Klipper history, Dropbox metrics, Claude Code session files and a `git pull` in
`~/src/home`). The Documents upload succeeded. That snapshot is v1 and will be held
by the first `validate`; reject that exact ID once a v2 seed exists, then validate
again within the hour so `ResticWorkstationEnrollmentLost` does not fire. The v2
exclusions drop regenerable and volatile state (Klipper, kubectl and application
caches, Claude Code and Codex transcripts and runtime databases), and v2 carries a
churn tolerance so in-scope files changing mid-backup no longer fail it.

2026-09-11 ryze v2 contract release. The [completed measurement](evidence/ryze-measured-20260911.json)
at 04:50:20Z contains 525,617 home files / 26,992,623,308 bytes and unchanged
Documents totals of 538 files / 296,757,693 bytes. The
[release evidence](evidence/ryze-enrollment-20260911.json) records the exclusion and
capacity review. The immutable v2 JSON and frozen exclusions are released identically
in host, cluster and recovery directories and mapped in the contracts ConfigMap.
The contract permits at most 1,000 changed paths while protecting Documents and
the KDBX path. Deploy the updated maintenance code and contract, install the updated
client with v2, and retry the manual seed before proceeding to validation and B2
copy. At contract release, no successful v2 seed or native restore was claimed;
the following entry records subsequent results. Schedules remain disabled.

### 2026-09-12 ryze recovery evidence and remaining gates

The [sanitized recovery record](evidence/ryze-recovery-20260912.json) records the
accepted v2 snapshot, generation 2 transition, rejected v1 snapshot, clear validation
holds, and successful attended B2 copy. The copy ran from 23:48:05Z on September 11
to 02:21:06Z on September 12, with recurring ryze CronJobs still suspended.

Each native restore extracted 618,536 nodes (25.427 GiB) and passed Restic content
verification for 526,288 files. Both restored KDBX files were manually opened by
the operator. The initial unprivileged restores could not preserve 17 root-owned
nodes. A fresh privileged NAS restore passed the original helper, including
symlink targets; its full elapsed time was approximately 68 minutes.

B2 scratch ownership was repaired using NAS snapshot metadata, then file
types/sizes, numeric owners, modes, timestamps, and 2,534 symlink entries were
checked against the actual B2 snapshot. This follow-up checked **symlink presence
only**, so those retained-tree checks did not establish B2 target-string verification. Neither
original restore selected an extended-attribute sample. The supplemental fixture below
subsequently closed both metadata gaps. Earlier session summaries calling both complete
overstated the metadata coverage. The B2 scratch report also inherited a 36-second
NAS repair duration; the committed record explicitly excludes it as a B2 timing.
B2 extraction took 3h24m14s and content verification 1h36m32.819s; no reliable total
drill duration was captured.

Credentials for the B2 restore were recovered through SOPS + age on Ryze, independently
of minis. This does not establish password-manager credential retrieval. The vault's
separate break-glass-card document/photo drill must not be represented as a workstation
result or automatically imposed as an additional workstation restore requirement.

The supplemental Linux fixture closed the metadata gap. The real Ryze client created
NAS snapshot `47705a5c…929fd4`; the existing validation Job
`restic-ryze-validate-fixture-20260912` completed successfully, and the existing copy
Job `restic-ryze-copy-fixture-20260912` produced B2 snapshot
`a8b006b4…0be267`. Fresh privileged restores from both destinations verified the
fixture xattr `user.homelab.restore-fixture`, authenticated symlink targets, and
representative executable/hidden-state files. Full IDs, phase timings, reports, and
Job timestamps are in the recovery evidence. The fixture is explicitly supplemental
evidence and does not replace the retained historical content-verification results.

### 2026-09-12 Ryze activation

The live activation gates passed: cross-host credential denial, labelled and unlabelled
NetworkPolicy probes, the isolated-network retry with an independent failure marker,
Documents promotion, locked-vault and independent appstate backup behavior, attended
NAS/B2 repository checks, and synthetic Pushover warning/resolved delivery. The
required `/opt` snapshot was taken before the vault drill. The Ryze client was
installed and enabled with the evidence-gated installer, and commit `173b486` enabled
only `restic-ryze-validate`, `restic-ryze-copy`, `restic-ryze-prune`, and
`restic-ryze-check`; M5c remained suspended at that point (it activated September 15). Commit `6e14f02` records the activation
evidence. Seven-day observation, weekly copy/prune, and monthly check gates remain
open.

Retain the scratch artifacts until inspection and evidence review are complete.
The committed JSON records measured results and limitations; it is not an activation
approval file and must not be used to bypass the installer's required evidence fields.

### 2026-09-12 M5c activation preparation

Live preflight found M5c's server ready, all four M5c CronJobs suspended, and
746 GiB available on the expected NAS ext4 volume. The Mac runs macOS 26.6.2 with
FileVault enabled and 359 GiB available. Its existing Tailscale identity was
reconnected with subnet-route acceptance disabled; the backup endpoint then
returned HTTP 401 unauthenticated over verified HTTPS.

The attended `restic-m5c-enroll-20260912` Job initialized the dedicated NAS and B2
repositories and verified matching chunker parameters. Full repository IDs are
recorded in the M5c activation record. Initialization does not establish backup
freshness or enroll the host for freshness alerts.

A native fixture was created in `~/workstation-recovery-fixture-20260912`, inside
the included home scope, with FinderInfo, a nonempty ResourceFork, an executable,
hidden state and a relative symlink. A fresh v2 measurement was started through
launchd using `/opt/homebrew/bin/python3` and the current client staged in private
state storage. The approved exclusions are unchanged. The fixture has not yet
been backed up or restored. The Mac still needs the privileged installation of
pinned Restic and the current client before seeding; no schedules were enabled.

### 2026-09-14 M5c NAS restore verification

Since preparation, the installed client passed a fresh launchd readability measurement,
the server accepted two NAS snapshots, and the attended copy Job copied both to B2
on 2026-09-13 local time. The activation record contains the snapshot mapping and
installation evidence; client and maintenance schedules remain disabled.

The operator reported successful native NAS restore and verification for snapshot
`52e7cfdfc5ff467c21fbcb1af9b5a62f12034e95690fe0ab4a3d8089e47d3c6c` on
2026-09-14 at 19:21 CDT (2026-09-15 at 00:21 UTC). The
[full restore evidence](evidence/m5c-nas-restore-20260915.json) records 361,195
restored nodes, 24.245 GiB restored, and successful Restic content verification
for 263,198 files. The privileged restore then passed metadata checks for all
361,195 nodes, 49,074 symlinks, the selected relative-link target, FinderInfo,
ResourceFork, the Node executable, and hidden `.CFUserTextEncoding` state. The
restore excluded only `com.apple.file-provider-domain-id`, which macOS rejected
in the scratch tree. The earlier
[metadata-only report](evidence/m5c-nas-restore-verification-20260914.json)
is retained separately.

The independent B2 restore and both manual KDBX openings passed; see the
[B2 recovery evidence](evidence/m5c-b2-restore-20260915.json). The following
activation entry supersedes the earlier pending statements.

### 2026-09-15 M5c activation complete

All evidence-gated pre-schedule checks passed: disposable append-only deletion
denial and quota/recount, isolated-network failure and retry, Documents promotion,
locked-vault skip with independent appstate backup and post-unlock recovery, NAS/B2
repository checks, and synthetic Pushover warning/resolved delivery. The M5c client
was enabled from the completed evidence file. Reviewed commit `b389906` set
`restic-m5c-validate`, `restic-m5c-copy`, `restic-m5c-prune`, and `restic-m5c-check`
to `suspend: false`; Flux applied that revision.

The first scheduled M5c copy completed successfully after approximately 140 minutes.
The first scheduled validation then completed successfully in 10 seconds after the
copy released the repository lock. The validation metric reported success with no
hold. Seven-day observation and one successful scheduled weekly copy/prune cycle
remain open. The separate vault-v3 transition completed on 2026-09-20; its first
scheduled NAS/B2 prune succeeded as recorded in [backup policy](../../docs/backups.md#phasing-vault-v3-rollout-complete).
