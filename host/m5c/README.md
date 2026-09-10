# m5c workstation backup client

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
that Photos/Mail have no unique data. No Mac contract or native restore has been
released or validated yet. Follow the [attended runbook](../../runbooks/backups/workstations.md).

The File Provider layout is supported: `~/Dropbox` may be an absolute or relative
symlink to `~/Library/CloudStorage/Dropbox`. Inventory backs up that real directory
and the alias separately, without following directory symlinks. Enrollment pins
the real KDBX path in `kdbx_path`; server validation checks the same included file.
Other alias targets, symlink ancestors, exclusions hiding the database, and changes
to the released KDBX location fail validation. Existing contracts without this field
continue to require the original real `Dropbox/ccs.kdbx` path.
