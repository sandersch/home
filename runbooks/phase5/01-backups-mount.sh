#!/usr/bin/env bash
# Phase 5.1 - add and validate the direct-attached backup filesystem mount.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc

MOUNT_LINE="$(awk -v target="$PHASE5_BACKUP_MOUNT" \
  '$1 !~ /^#/ && $2 == target {print; exit}' "$HOST_ETC/fstab")"
[ -n "$MOUNT_LINE" ] || die "could not find $PHASE5_BACKUP_MOUNT in $HOST_ETC/fstab"

step "Ensure the backup filesystem is in /etc/fstab"
if grep -qxF "$MOUNT_LINE" /etc/fstab; then
  ok "canonical backups entry already in /etc/fstab"
elif awk -v target="$PHASE5_BACKUP_MOUNT" '$1 !~ /^#/ && $2 == target {found=1} END {exit !found}' /etc/fstab; then
  warn "a non-canonical active backups entry already exists in /etc/fstab:"
  awk -v target="$PHASE5_BACKUP_MOUNT" '$1 !~ /^#/ && $2 == target {print NR ":" $0}' /etc/fstab >&2
  die "replace it with the canonical entry from $HOST_ETC/fstab, then re-run"
else
  printf '%s\n' "$MOUNT_LINE" | sudo tee -a /etc/fstab >/dev/null
  ok "appended canonical backups entry to /etc/fstab"
fi

step "Mount and verify $PHASE5_BACKUP_MOUNT"
if [ -d "$PHASE5_BACKUP_MOUNT" ]; then
  ok "$PHASE5_BACKUP_MOUNT already exists"
else
  sudo install -d -o root -g root -m 755 "$PHASE5_BACKUP_MOUNT"
  ok "created $PHASE5_BACKUP_MOUNT mountpoint"
fi
if timeout 30 sudo mount "$PHASE5_BACKUP_MOUNT"; then
  ok "mount $PHASE5_BACKUP_MOUNT completed"
else
  die "$PHASE5_BACKUP_MOUNT did not mount; verify md3, hoardvg, and the filesystem"
fi

assert_direct_mount_layout "$PHASE5_BACKUP_MOUNT" "$PHASE5_BACKUP_SOURCE" \
  "$PHASE5_BACKUP_UUID"

step "Verify the backup filesystem is writable as the Restic hostPath owner"
probe="$PHASE5_BACKUP_MOUNT/.phase5-write-test"
if printf '%s\n' "phase5 $(date -Iseconds)" | sudo -u '#65534' tee "$probe" >/dev/null; then
  sudo rm -f "$probe"
  ok "$PHASE5_BACKUP_MOUNT is writable as UID 65534"
else
  die "$PHASE5_BACKUP_MOUNT is not writable as UID 65534"
fi
