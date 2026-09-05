#!/usr/bin/env bash
# Verify the production prerequisites for the staged backup-system rollout.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools awk chattr cryptsetup findmnt flux jq kubectl lsattr lvs mountpoint readlink stat systemctl vgs yq

step "Verify the direct backup filesystem"
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"
df -h "$BACKUPS_MOUNT"
if sudo test -f "$BACKUPS_SENTINEL"; then
  assert_backup_sentinel
else
  warn "$BACKUPS_SENTINEL is not installed yet"
fi

step "Verify capacity for the encrypted vault"
free_bytes="$(sudo vgs --noheadings --units b --nosuffix -o vg_free hoardvg | awk '{printf "%.0f", $1}')"
[ "$free_bytes" -ge 214748364800 ] \
  || die "hoardvg has less than the required 200 GiB free"
ok "hoardvg has capacity for a 200 GiB vault LV"

step "Verify reserved interfaces"
sudo ss -ltn '( sport = :2222 )' | awk 'NR > 1 {found=1} END {exit found ? 0 : 1}' \
  && die "TCP port 2222 is already in use" || true
getent passwd 2100 >/dev/null && die "UID 2100 is already assigned" || true
getent group 2100 >/dev/null && die "GID 2100 is already assigned" || true
ok "TCP 2222 and UID/GID 2100 are available"

step "Verify current backup schedules"
kubectl -n monitoring get cronjobs restic-nas-backup restic-b2-backup -o wide

cat <<'EOF'

Preflight passed. The next attended step temporarily unmounts /mnt/backups.
Before running 01-install-backup-guard.sh:
  1. ensure this implementation is not yet on Flux's watched main branch
  2. suspend monitoring, monitoring-controllers, and monitoring-configs
  3. suspend restic-nas-backup and restic-b2-backup
  4. wait for every active Restic Job to finish
EOF
