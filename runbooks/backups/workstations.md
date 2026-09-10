# Workstation enrollment and recovery

Status: implementation staged, **not deployed or enrolled**. Both workstation v1
contracts are released after measured enrollment gates; vault-v3 remains pending.
`infrastructure/monitoring/workstations/` is intentionally outside the active monitoring
Kustomization. Its four CronJobs per host are suspended. Pending contract documents
are explicit blockers, not usable zero-floor contracts.

| Host | NAS cap | B2 ceiling | Client schedule | Documents |
| --- | ---: | ---: | --- | --- |
| ryze | 150 GiB | 100 GB | hourly systemd user due-check | daily restricted SFTP |
| m5c | 100 GiB | 50 GB | hourly launchd agent while logged in | daily restricted SFTP |

Python 3.11+ and checksum-verified Restic 0.19.1 are required on clients. The Mac
uses `/opt/homebrew/bin/python3`; verify that exact executable's Full Disk Access
through launchd. It runs on battery and does not schedule wakes. Missed work is
checked on login/wake and retried while awake. Backup and upload success are separate;
Restic exit 3, permission failures, and manifest mismatch do not advance backup success.

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
checks the resulting snapshot listing against the measured manifest. Symlink
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
  --output /tmp/workstation-ryze-v1.measured.json
```

Use `m5c` and its exclusion file on the Mac. Measurement output must be a new path.
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
  /tmp/workstation-ryze-v1.measured.json --evidence /tmp/ryze-enrollment-evidence.json
```

The release is written identically to host, cluster, and recovery directories.
An existing release cannot be overwritten; identical partial releases can resume.
Replace the matching `*.pending.json` mapping in the staged Kustomization with the
released file. Keep the canonical script/exclusion mirrors byte-identical; the
workstation tests enforce this.

## Host and credential preparation

Confirm m5c's Wi-Fi MAC (inventory currently records `aa:9a:b7:f2:ea:2d`), check UDM
leases/reservations and ARP from VLAN 30 for conflicts, then reserve `10.137.30.7`.
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

Install the client using `workstation-install-client.py --host ... --contract ...
--credentials ...` as the desktop user. This installs configuration and schedule
files but does not enable them. Run the daily command manually to seed NAS and
upload Documents, then invoke server `validate` and `copy`. Record full NAS/B2 IDs
and compare both repositories' config/chunker values. Repeat for m5c after ryze's
NAS/B2 seed is validated.

The SFTP promoter accepts only regular files/directories in a frozen archive,
enforces a 50 GiB bound, serializes per host, atomically records completion, and
never propagates client deletions. Identical successful deliveries refresh the
promotion heartbeat. Enable the promoter's hourly retry timer after its ingestion
tests pass. Ryze remains the only Strongbox uploader.

## Vault v3 activation

After inspecting the promoted Mac document seed, run
`sudo python3 runbooks/backups/workstation-release-vault-v3.py` on minis. This
preserves v1/v2 and releases v3 with measured 80% Mac document floors. It does not
switch the sentinel or active validator.

Coordinate a suspended vault backup/copy/prune window with no running vault Jobs.
Add v3 JSON and exclusions to the vault contract ConfigMap, set
`VAULT_CONTRACT_VERSION=3` in the vault Job environments and host vault.conf, and
atomically replace the mounted sentinel with version 3 while retaining its UUID
and root:root 0444 metadata. The default remains version 2 until this gate.
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
  --metadata-path /absolute/source/path/to/metadata-fixture
```

Supply only the chosen repository's Restic environment JSON. B2 recovery uses its
escrowed credentials independently of minis. The helper creates a new private
scratch directory, uses Restic content verification, checks trees, links, modes,
ownership and modification times, and tests selected extended attributes. On the
Mac, use a fixture with a Finder attribute and a nonempty `com.apple.ResourceFork`;
verify both on restore. Check hidden application state and an executable too.
Manually open each restored KDBX and record the result. Keep actual full IDs,
measurements, elapsed times and metadata names in the evidence file. Scratch is
retained for attended inspection and explicit cleanup.

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
0.19.1, `test-workstation-alerts.py` with `PROMTOOL`, existing backup regressions,
`test-config-scripts.sh`, image-policy validation and both monitoring renders.
The Python plist check is portable; also run `plutil -lint` on the actual installed
Mac plist. Live privacy, DHCP, NetworkPolicy, quota, notification, sleep/wake and
native Mac metadata gates cannot be replaced by Linux fixtures.

No production snapshot IDs, B2 seeds, native restores, notification deliveries,
or seven-day observation are recorded yet. Do not infer activation from the presence
of these files.

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
measurement, identically in the host, cluster and recovery directories. Both staged
ConfigMap entries now reference released contracts. Credentials, host preparation,
deployment, initial backups and native NAS/B2 restore drills remain pending; all
maintenance CronJobs remain suspended.
