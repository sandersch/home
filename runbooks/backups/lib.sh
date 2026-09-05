#!/usr/bin/env bash

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

export BACKUPS_MOUNT=/mnt/backups
export BACKUPS_SOURCE=/dev/mapper/hoardvg-backuplv
export BACKUPS_UUID=cc1cedb8-ef22-44b5-b1d0-5ca020d72669
export BACKUPS_SENTINEL="$BACKUPS_MOUNT/.backup-sentinel"
export BACKUPS_GUARD_SCRIPT="$REPO_ROOT/host/minis/usr/local/sbin/backups-mountpoint-guard"
export BACKUPS_GUARD_UNIT="$REPO_ROOT/host/minis/etc/systemd/system/backups-mountpoint-guard.service"

assert_backup_sentinel() {
  local metadata value
  sudo test -f "$BACKUPS_SENTINEL" || die "$BACKUPS_SENTINEL is missing"
  sudo test ! -L "$BACKUPS_SENTINEL" || die "$BACKUPS_SENTINEL must not be a symlink"
  metadata="$(sudo stat -c '%u:%g:%a' "$BACKUPS_SENTINEL")"
  [ "$metadata" = 0:0:444 ] \
    || die "$BACKUPS_SENTINEL is $metadata, expected 0:0:444"
  value="$(sudo sed -n '1p' "$BACKUPS_SENTINEL")"
  [ "$value" = "$BACKUPS_UUID" ] \
    || die "$BACKUPS_SENTINEL does not contain the expected filesystem UUID"
  ok "$BACKUPS_SENTINEL identifies the backup filesystem"
}

assert_backup_jobs_quiesced() {
  local cronjobs active_jobs
  cronjobs="$(kubectl -n monitoring get cronjobs restic-nas-backup restic-b2-backup \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.suspend}{"\n"}{end}')"
  printf '%s\n' "$cronjobs"
  printf '%s\n' "$cronjobs" | grep -qx 'restic-nas-backup=true' \
    || die "restic-nas-backup must be suspended before changing the mountpoint"
  printf '%s\n' "$cronjobs" | grep -qx 'restic-b2-backup=true' \
    || die "restic-b2-backup must be suspended before changing the mountpoint"
  active_jobs="$(kubectl -n monitoring get jobs -o json | jq -r '
    [.items[] |
      select(.metadata.name | startswith("restic-")) |
      select((.status.active // 0) > 0) |
      .metadata.name] | join(" ")
  ')"
  [ -z "$active_jobs" ] || die "active Restic Jobs remain: $active_jobs"
  ok "backup schedules are suspended and no Restic Job is active"
}
