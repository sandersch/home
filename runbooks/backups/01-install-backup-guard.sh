#!/usr/bin/env bash
# Install the sentinel and harden only the uncovered /mnt/backups mountpoint.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools chattr find findmnt jq kubectl lsattr mountpoint stat systemctl

sentinel_tmp=""
automount_stopped=0
# Recover service availability after ordinary failures, but never hide data that
# the guard found on the uncovered root-filesystem mountpoint.
cleanup() {
  local status="$1" uncovered_entry=""
  trap - EXIT
  rm -f "$sentinel_tmp"
  if [ "$automount_stopped" -eq 1 ]; then
    if ! mountpoint -q "$BACKUPS_MOUNT" && sudo test -d "$BACKUPS_MOUNT"; then
      uncovered_entry="$(sudo find "$BACKUPS_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    fi
    if ! mountpoint -q "$BACKUPS_MOUNT" && [ -n "$uncovered_entry" ]; then
      warn "leaving mnt-backups.automount stopped because the uncovered mountpoint contains data"
      warn "inspect $BACKUPS_MOUNT and recover the mount deliberately"
    else
      warn "restarting mnt-backups.automount after an interrupted mountpoint-hardening step"
      sudo systemctl start mnt-backups.automount \
        || warn "could not restart mnt-backups.automount; recover it manually"
    fi
  fi
  exit "$status"
}
trap 'cleanup $?' EXIT

assert_backup_jobs_quiesced
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"

step "Install the backup-filesystem sentinel"
sentinel_tmp="$(mktemp)"
printf '%s\n' "$BACKUPS_UUID" >"$sentinel_tmp"
if sudo test -f "$BACKUPS_SENTINEL" \
  && sudo cmp -s "$sentinel_tmp" "$BACKUPS_SENTINEL"; then
  ok "$BACKUPS_SENTINEL already has the expected value"
else
  sudo install -o root -g root -m 0444 "$sentinel_tmp" "$BACKUPS_SENTINEL"
  ok "installed $BACKUPS_SENTINEL"
fi
sudo chown root:root "$BACKUPS_SENTINEL"
sudo chmod 0444 "$BACKUPS_SENTINEL"
assert_backup_sentinel

step "Install the canonical mountpoint guard"
sudo install -D -o root -g root -m 0755 \
  "$BACKUPS_GUARD_SCRIPT" /usr/local/sbin/backups-mountpoint-guard
sudo install -D -o root -g root -m 0644 \
  "$BACKUPS_GUARD_UNIT" /etc/systemd/system/backups-mountpoint-guard.service
sudo systemctl daemon-reload
sudo systemd-tmpfiles --create \
  "$REPO_ROOT/host/minis/etc/tmpfiles.d/homelab-backup-metrics.conf"
metrics_metadata="$(sudo stat -c '%U:%G:%a' /var/lib/node-exporter/textfile)"
[ "$metrics_metadata" = root:nogroup:750 ] \
  || die "textfile directory is $metrics_metadata, expected root:nogroup:750"
ok "node-exporter textfile directory is present on /var"

if ! confirm "Temporarily unmount $BACKUPS_MOUNT and harden its underlying directory?"; then
  die "mountpoint hardening was not confirmed"
fi

step "Expose and harden the underlying mountpoint"
sudo systemctl stop mnt-backups.automount
automount_stopped=1
# Stopping the automount can already detach the filesystem above it.
if mountpoint -q "$BACKUPS_MOUNT"; then
  sudo umount "$BACKUPS_MOUNT"
fi
! mountpoint -q "$BACKUPS_MOUNT" || die "$BACKUPS_MOUNT is still mounted"
sudo systemctl enable backups-mountpoint-guard.service >/dev/null
sudo systemctl restart backups-mountpoint-guard.service
sudo systemctl start mnt-backups.automount
automount_stopped=0

step "Remount and revalidate the backup filesystem"
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"
assert_backup_sentinel
ok "the backup mountpoint now fails closed when its filesystem is absent"
