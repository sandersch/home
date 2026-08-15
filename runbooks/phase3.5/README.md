# Phase 3.5 - app data migration

Scripts for [build-plan.md Phase 3.5](../../docs/build-plan.md#phase-35--app-data-migration-).
Run them on `minis` after the Phase 3 validation gate is complete.

This is the original stopped-host archive migration path. A current-state rebuild must
use the build plan's Restic suspend/restore/resume sequence instead; do not overwrite a
newer Restic recovery with this historical archive.

The old hosts are stopped, and their container config directories are available at
`/mnt/media/to_archive/config` on the bulk array. This phase copies that stopped-host state
to local NVMe under `/opt`. It does not deploy workloads or change Kubernetes state.

## Prerequisites

- Phase 3 validation has passed.
- The old hosts are stopped, so the archive is a quiesced final source.
- `/mnt/media` is mounted on `minis` and contains `/mnt/media/to_archive/config`.
- `/opt` is mounted on `minis` and has enough free space.
- `rsync`, `setpriv`, and `sqlite3` are installed on `minis`.

## Source and destination

| App | Source | Destination |
|---|---|---|
| Plex | `/mnt/media/to_archive/config/plex-config/` | `/opt/plex/config/` |
| Radarr | `/mnt/media/to_archive/config/radarr-config/` | `/opt/radarr/config/` |
| Sonarr | `/mnt/media/to_archive/config/sonarr-config/` | `/opt/sonarr/config/` |
| Prowlarr | `/mnt/media/to_archive/config/prowlarr-config/` | `/opt/prowlarr/config/` |

Seerr, RomM, Home Assistant, Frigate, and SABnzbd queue/history are intentionally
not migrated in this phase.

## Order

Run scripts in numeric order, or run `./run-all.sh`.

| Script | What it does | Mutates host? |
|---|---|---|
| `00-preflight.sh` | Checks host, exact direct media mount, archive, source files, `/opt` capacity, and empty destinations | no |
| `01-copy-configs.sh` | Copies configs with `rsync -aHAX --numeric-ids --delete` and fixes ownership | yes |
| `02-validate-copy.sh` | Checks expected files, Plex DB readability, *arr SQLite integrity, ownership, and `/opt` usage | no |

## Safety notes

- `01-copy-configs.sh` uses `--delete`. By default, preflight fails if a destination
  config directory already contains data.
- To intentionally replace existing destination data, set:

  ```bash
  PHASE35_ALLOW_EXISTING_DEST=1 ./run-all.sh
  ```

- Plex `lost+found` and `Library/Application Support/Plex Media Server/Cache/Shaders`
  are excluded. The shader cache is regenerable and may not be readable from the
  archive.
- The copy script detects each archive directory's numeric owner and runs `rsync` as
  that UID/GID. This preserves access to
  restrictive files such as Plex `0600`/`0660` config and cache files.
- Plex library DB validation uses schema/table read checks instead of
  `PRAGMA integrity_check` because Plex can define a custom SQLite tokenizer that
  the system `sqlite3` binary cannot load.
- Migrated files are chowned to `1000:1000`, matching the LinuxServer container
  defaults used by the planned workloads.

## Phase 4 handoff

- Deploy Plex using `/opt/plex/config`; do not set `PLEX_CLAIM`.
- Deploy Radarr, Sonarr, and Prowlarr using `/opt/<app>/config`.
- Validate Plex library/auth, Quick Sync transcode, *arr history/settings, VPN
  egress, and a Prowlarr -> Radarr/Sonarr -> SABnzbd test flow.
- No final rsync is needed unless the archive changes after this phase.
