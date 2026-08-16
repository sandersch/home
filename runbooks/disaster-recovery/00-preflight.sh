#!/usr/bin/env bash
# Full-state recovery preflight. Read-only except for sudo credential validation.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Verify full-state recovery guards"
assert_recovery_preconditions
assert_git_clean_and_synced

if [ "$RECOVERY_SOURCE" = nas ]; then
  assert_direct_mount_layout /mnt/backups /dev/mapper/hoardvg-backuplv \
    cc1cedb8-ef22-44b5-b1d0-5ca020d72669
fi

step "Verify staging filesystem"
assert_safe_stage_root

ok "disaster-recovery preflight passed; applications and backup schedules remain offline"
