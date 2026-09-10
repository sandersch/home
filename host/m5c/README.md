# m5c workstation backup client

Approved omission: all of `Library/Mobile Documents` is outside recovery scope,
including iCloud app documents, Notes, Mail, dictionaries and synced history. The
operator confirmed this tree is unused. This supersedes the individual iCloud
exclusions. The required home `Documents` directory must remain local and readable;
if it redirects into this excluded tree, enrollment must stop rather than waive it.
Local Safari bookmarks and preferences remain in scope.

Approved recovery limitation: the root-owned, mode-0600 file
`Library/Group Containers/group.com.apple.secure-control-center-preferences/Library/Preferences/group.com.apple.secure-control-center-preferences.av.plist`
is excluded. Settings stored in this file are outside the recovery promise; other
preferences remain in scope. Do not change its permissions or elevate the backup
client to recover this omission.

The Google Drive account tree at `Library/CloudStorage/GoogleDrive-sanderscharlie@gmail.com`
is excluded on m5c: the operator confirmed it is fully present on ryze and intended
to be backed up there. Verify its actual ryze path and included, locally readable
contents during enrollment; this scope decision is not evidence of a completed backup.

Shared Dropbox content is backed up in full by ryze. On m5c, only
`Dropbox/ccs.kdbx` (at its real File Provider location) is included; other Dropbox
content is omitted before reading or materializing it. Non-Dropbox home scope is
unchanged. This relies on the attended confirmation that both Dropbox trees match.

Canonical exclusions, the launchd agent and the documents-only SFTP wrapper are
staged here. Shared Python client code is in `host/workstations/`. The installed
agent runs hourly while logged in, including on battery, with no scheduled wake.

Enrollment requires the actual launchd Full Disk Access check, FileVault, disabled
iCloud Optimize Storage, locally materialized Dropbox content, and confirmation
that Photos/Mail have no unique data. The measured m5c v1 contract is released in
the repository; credential enrollment, native restores and schedule activation
remain pending. Follow the [attended runbook](../../runbooks/backups/workstations.md).

The File Provider layout is supported: `~/Dropbox` may be an absolute or relative
symlink to `~/Library/CloudStorage/Dropbox`. Inventory backs up that real directory
and the alias separately, without following directory symlinks. Enrollment pins
the real KDBX path in `kdbx_path`; server validation checks the same included file.
Other alias targets, symlink ancestors, exclusions hiding the database, and changes
to the released KDBX location fail validation. Existing contracts without this field
continue to require the original real `Dropbox/ccs.kdbx` path.
