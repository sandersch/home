#!/usr/bin/env bash
# Phase 3.5 validation - verify migrated app config before Phase 4.
# shellcheck source=runbooks/phase3.5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools df find sqlite3

step "Verify expected copied files"
assert_phase35_copied_files

step "Plex SQLite access checks"
assert_plex_databases_readable

step "*arr SQLite integrity checks"
assert_integrity_ok "Radarr" "$(phase35_db_path radarr)"
assert_integrity_ok "Sonarr" "$(phase35_db_path sonarr)"
assert_integrity_ok "Prowlarr" "$(phase35_db_path prowlarr)"

step "Verify ownership"
assert_phase35_ownership

step "Final /opt usage"
df -h "$PHASE35_DEST_ROOT"

ok "Phase 3.5 migrated data validation complete"
