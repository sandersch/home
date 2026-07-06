#!/usr/bin/env bash
# Phase 5.1 - add and validate the dedicated NAS backup export mount.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc

NFS_LINE="$(grep -E '^[^#]*backups\.nfs\.service\.matrix' "$HOST_ETC/fstab")" \
  || die "could not find the backups NFS line in $HOST_ETC/fstab"
NAS_HOST="backups.nfs.service.matrix"

step "Confirm the NAS backup hostname resolves"
if getent hosts "$NAS_HOST" >/dev/null; then
  ok "$NAS_HOST -> $(getent hosts "$NAS_HOST" | awk '{print $1}' | head -1)"
else
  die "$NAS_HOST does not resolve; create the NAS DNS/export before continuing"
fi

step "Ensure the backup export is in /etc/fstab"
if grep -qxF "$NFS_LINE" /etc/fstab; then
  ok "canonical backups NFS line already in /etc/fstab"
elif grep -Eq "^[[:space:]]*$NAS_HOST:/mnt/backups[[:space:]]+${PHASE5_BACKUP_MOUNT}[[:space:]]+" /etc/fstab; then
  warn "a non-canonical active backups NFS line already exists in /etc/fstab:"
  grep -En "^[[:space:]]*$NAS_HOST:/mnt/backups[[:space:]]+${PHASE5_BACKUP_MOUNT}[[:space:]]+" /etc/fstab >&2
  die "replace that line with the canonical entry from $HOST_ETC/fstab, then re-run"
else
  printf '%s\n' "$NFS_LINE" | sudo tee -a /etc/fstab >/dev/null
  ok "appended canonical backups NFS line to /etc/fstab"
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
  die "$PHASE5_BACKUP_MOUNT did not mount; fix NAS DNS/export/reachability before continuing"
fi

assert_nfs_mount_layout "$PHASE5_BACKUP_MOUNT" "$PHASE5_BACKUP_SOURCE" nfs4

step "Verify the backup export is writable"
probe="$PHASE5_BACKUP_MOUNT/.phase5-write-test"
if printf '%s\n' "phase5 $(date -Iseconds)" | sudo tee "$probe" >/dev/null; then
  sudo rm -f "$probe"
  ok "$PHASE5_BACKUP_MOUNT is writable"
else
  die "$PHASE5_BACKUP_MOUNT is not writable"
fi
