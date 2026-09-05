#!/usr/bin/env bash

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

export BACKUPS_MOUNT=/mnt/backups
export BACKUPS_SOURCE=/dev/mapper/hoardvg-backuplv
export BACKUPS_UUID=cc1cedb8-ef22-44b5-b1d0-5ca020d72669
export BACKUPS_SENTINEL="$BACKUPS_MOUNT/.backup-sentinel"
export BACKUPS_GUARD_SCRIPT="$REPO_ROOT/host/minis/usr/local/sbin/backups-mountpoint-guard"
export BACKUPS_GUARD_UNIT="$REPO_ROOT/host/minis/etc/systemd/system/backups-mountpoint-guard.service"

require_backup_yq() {
  local probe
  probe="$(mktemp)"
  printf 'value: old\n' >"$probe"
  if ! BACKUP_YQ_PROBE=new yq -y -i '.value = env.BACKUP_YQ_PROBE' "$probe" \
      >/dev/null 2>&1 \
    || [ "$(yq -r '.value' "$probe" 2>/dev/null)" != new ]; then
    rm -f "$probe"
    die "yq must be the Python jq wrapper with working -y -i and jq env support"
  fi
  rm -f "$probe"
}

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

# Work only on staged copies. Preserve unrelated entries and reject duplicates or
# conflicting definitions instead of replacing an operator's mount configuration.
ensure_mount_table_entry() {
  local file="$1" key_field="$2" key="$3" expected="$4" entries normalized
  entries="$(awk -v field="$key_field" -v key="$key" \
    '$1 !~ /^#/ && $field == key {$1=$1; print}' "$file")"
  normalized="$(awk '{$1=$1; print}' <<<"$expected")"
  if [ -n "$entries" ]; then
    [ "$entries" = "$normalized" ] \
      || die "$file contains conflicting or duplicate entries for $key; reconcile them before retrying"
  else
    # A preceding newline also handles a source file without a final newline.
    printf '\n%s\n' "$expected" >>"$file"
  fi
}
