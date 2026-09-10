# m5c workstation backup client

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
