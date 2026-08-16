#!/usr/bin/env bash
# Archive a completed recovery record after its observation window. Staged data is
# deliberately retained and must be removed separately by the operator.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools date

[ "$(state_value monitoring_validation)" = complete ] \
  || die "monitoring and fresh-backup validation have not completed"

source_name="$(state_value source)"
snapshot="$(state_value snapshot)"
stage="$(state_value stage)"
completed_at="$(state_value recovery_completed_at)"
case "$source_name" in
  nas|b2) ;;
  *) die "recovery record has an invalid source" ;;
esac
[[ "$snapshot" =~ ^[0-9a-f]{64}$ ]] || die "recovery record has no full snapshot ID"
[[ "$stage" = /* ]] || die "recovery record has no absolute staging path"
[[ "$completed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || die "recovery record has an invalid completion timestamp"

archive_stamp="${completed_at//[:]/-}"
archive="$RECOVERY_STATE_DIR/completed-${archive_stamp}-${snapshot:0:12}.state"
sudo test ! -e "$archive" || die "completed recovery archive already exists: $archive"

cat <<EOF

Completed recovery:
  source:    $source_name
  snapshot:  $snapshot
  staging:   $stage
  completed: $completed_at

This archives the active recovery record so a future disaster can select a different
snapshot. It does not delete the staged restore at $stage.
EOF
confirm "The observation window is complete; archive this recovery record?" \
  || die "recovery record remains active"

sudo mv -- "$RECOVERY_STATE_FILE" "$archive"
ok "completed recovery record archived at $archive"
warn "staged data remains at $stage; remove only that exact path when no longer needed"
