#!/usr/bin/env bash
# Phase 3.5 copy - migrate stopped-host app config into /opt.
# shellcheck source=runbooks/phase3.5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools awk du df find findmnt grep install rsync setpriv sqlite3 stat tail timeout

step "Verify Phase 3.5 copy prerequisites"
assert_hostname_minis
assert_nas_archive_mounted
assert_phase35_sources_present
assert_opt_capacity
assert_destinations_safe

cat <<EOF
This will copy stopped-host config from:
  $PHASE35_SRC

into:
  $PHASE35_DEST_ROOT/{plex,radarr,sonarr,prowlarr}/config

The rsync commands use --delete, so each destination config directory will be made
to match the corresponding archive source.
EOF

if [ "${PHASE35_ASSUME_YES:-0}" != "1" ]; then
  confirm "Copy Phase 3.5 app configs now?" || die "aborted"
fi

step "Create destination directories"
create_phase35_destinations

step "Copy Plex"
rsync_phase35_app plex

step "Copy Radarr"
rsync_phase35_app radarr

step "Copy Sonarr"
rsync_phase35_app sonarr

step "Copy Prowlarr"
rsync_phase35_app prowlarr

step "Normalize ownership"
chown_phase35_destinations

ok "Phase 3.5 app-data copy complete"
