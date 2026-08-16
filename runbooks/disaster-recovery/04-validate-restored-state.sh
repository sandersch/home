#!/usr/bin/env bash
# Final offline validation gate before the apps rebuild guard is removed in git.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_recovery_preconditions
require_recovery_snapshot
require_tools sqlite3 tar
assert_safe_stage_root
assert_state_matches_selection
[ "$(state_value activation)" = complete ] || die "/opt activation is incomplete"
[ "$(state_value sqlite_overlay)" = complete ] || die "SQLite hot-backup overlay is incomplete"
[ "$(state_value romm)" = complete ] || die "RomM logical database recovery is incomplete"

stage="$(recovery_stage_dir)"
hot_dumps="$stage/work/hot-dumps"
sqlite_dumps="$stage/work/hot-dumps/sqlite"

step "Validate required database export contract"
assert_hot_dump_contract "$hot_dumps"

step "Validate restored /opt application directories"
for expected in \
  plex/config \
  sabnzbd/config \
  qbittorrent/config \
  prowlarr/config \
  radarr/config \
  sonarr/config \
  seerr/config \
  romm/db \
  frigate/config \
  home-assistant/config \
  zwave-js-ui/store \
  mosquitto/data; do
  sudo test -d "/opt/$expected" || die "restored /opt is missing $expected"
done
sudo test -s /opt/romm/db/ibdata1 || die "restored RomM database has no ibdata1"
romm_owner="$(sudo stat -c '%u:%g' /opt/romm/db)"
[ "$romm_owner" = 999:999 ] || die "/opt/romm/db is owned by $romm_owner, expected 999:999"
ok "core application directories and logical RomM database are present"

validate_sqlite() {
  local path="$1" relative="$2" result
  case "$relative" in
    plex/config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/com.plexapp.plugins.library*.db)
      sudo sqlite3 -readonly "$path" \
        'PRAGMA schema_version; SELECT count(*) FROM sqlite_master;' >/dev/null
      ;;
    *)
      result="$(sudo sqlite3 -readonly "$path" 'PRAGMA integrity_check;')"
      [ "$result" = ok ] || die "SQLite integrity check failed for $path: $result"
      ;;
  esac
}

step "Validate every restored SQLite database that has a hot backup"
mapfile -d '' sqlite_backups < <(sudo find "$sqlite_dumps" -type f -name '*.sqlite-backup' -print0)
[ "${#sqlite_backups[@]}" -gt 0 ] || die "recovery stage contains no SQLite hot backups"
for backup in "${sqlite_backups[@]}"; do
  relative="${backup#"$sqlite_dumps/"}"
  relative="${relative%.sqlite-backup}"
  target="/opt/$relative"
  sudo test -f "$target" || die "restored SQLite target is missing: $target"
  sudo test ! -e "${target}-wal" || die "stale SQLite WAL was restored beside $target"
  sudo test ! -e "${target}-shm" || die "stale SQLite SHM was restored beside $target"
  validate_sqlite "$target" "$relative"
done
ok "${#sqlite_backups[@]} restored SQLite database(s) passed offline integrity checks"

step "Validate a Home Assistant managed backup artifact"
ha_backup="$(sudo find /opt/home-assistant/config/backups \
  -maxdepth 1 -type f -name '*.tar' -size +0c -print -quit 2>/dev/null || true)"
[ -n "$ha_backup" ] || die "restored state has no Home Assistant backup archive"
sudo tar -tf "$ha_backup" >/dev/null \
  || die "Home Assistant backup archive is not a readable tar file: $ha_backup"
ok "Home Assistant managed backup archive is readable"

if sudo test -s /opt/zigbee2mqtt/data/configuration.yaml; then
  ok "Zigbee2MQTT retained state is present"
else
  warn "the selected snapshot predates any retained Zigbee2MQTT state"
  confirm "No established Zigbee network is expected from this snapshot" \
    || die "select a snapshot containing /data/opt/zigbee2mqtt before applications resume"
fi

assert_no_stateful_workloads
set_state_value offline_validation complete
set_state_value validated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat <<EOF

Offline recovery gate passed.

  source:     $RECOVERY_SOURCE
  snapshot:   $RECOVERY_SNAPSHOT
  staging:    $stage
  state file: $RECOVERY_STATE_FILE

Next, remove spec.suspend from clusters/minis/apps.yaml only, commit and push that
change, then run 05-resume-apps.sh. Leave monitoring suspended until application
validation passes.
EOF
