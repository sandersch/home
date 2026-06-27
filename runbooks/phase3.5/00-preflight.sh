#!/usr/bin/env bash
# Phase 3.5 preflight - read-only checks before app-data migration.
# shellcheck source=runbooks/phase3.5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools awk du df find findmnt grep rsync setpriv sqlite3 stat tail timeout

step "Verify target host and mounts"
assert_hostname_minis
assert_nas_archive_mounted

step "Verify archive contents"
assert_phase35_sources_present

step "Verify destination capacity and safety"
assert_opt_capacity
assert_destinations_safe

ok "Phase 3.5 preflight complete"
