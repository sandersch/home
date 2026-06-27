#!/usr/bin/env bash
# Phase 3.5 helpers.
#
# Phase 3.5 copies stopped-host application config from the NAS archive into
# local /opt on minis. It does not deploy workloads or change Kubernetes state.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

PHASE35_SRC="${PHASE35_SRC:-/mnt/media/to_archive/config}"
PHASE35_DEST_ROOT="${PHASE35_DEST_ROOT:-/opt}"
PHASE35_OWNER="${PHASE35_OWNER:-1000:1000}"
PHASE35_FREE_MARGIN_KIB="${PHASE35_FREE_MARGIN_KIB:-1048576}" # 1 GiB
PHASE35_APPS=(plex radarr sonarr prowlarr)

assert_hostname_minis() {
  local hn
  hn="$(hostname)"
  [ "$hn" = "minis" ] || die "hostname is '$hn', expected 'minis'"
  ok "hostname is minis"
}

phase35_source_dir() {
  case "$1" in
    plex) printf '%s/plex-config\n' "$PHASE35_SRC" ;;
    radarr) printf '%s/radarr-config\n' "$PHASE35_SRC" ;;
    sonarr) printf '%s/sonarr-config\n' "$PHASE35_SRC" ;;
    prowlarr) printf '%s/prowlarr-config\n' "$PHASE35_SRC" ;;
    *) die "unknown Phase 3.5 app: $1" ;;
  esac
}

phase35_dest_dir() {
  printf '%s/%s/config\n' "$PHASE35_DEST_ROOT" "$1"
}

phase35_source_owner() {
  stat -c '%u:%g' "$(phase35_source_dir "$1")"
}

phase35_readable_as_source_owner() {
  local app="$1" owner uid gid src
  owner="$(phase35_source_owner "$app")"
  uid="${owner%%:*}"
  gid="${owner##*:}"
  src="$(phase35_source_dir "$app")"

  sudo setpriv --reuid "$uid" --regid "$gid" --clear-groups \
    test -r "$src"
}

phase35_plex_db_dir() {
  printf '%s/Library/Application Support/Plex Media Server/Plug-in Support/Databases\n' "$1"
}

phase35_db_path() {
  local app="$1" base
  base="$(phase35_dest_dir "$app")"
  case "$app" in
    plex-library)
      printf '%s/com.plexapp.plugins.library.db\n' "$(phase35_plex_db_dir "$(phase35_dest_dir plex)")"
      ;;
    plex-blobs)
      printf '%s/com.plexapp.plugins.library.blobs.db\n' "$(phase35_plex_db_dir "$(phase35_dest_dir plex)")"
      ;;
    radarr) printf '%s/radarr.db\n' "$base" ;;
    sonarr) printf '%s/sonarr.db\n' "$base" ;;
    prowlarr) printf '%s/prowlarr.db\n' "$base" ;;
    *) die "unknown DB selector: $app" ;;
  esac
}

assert_nas_archive_mounted() {
  local fstype
  [ -d "$PHASE35_SRC" ] || die "archive source missing: $PHASE35_SRC"
  timeout 20 ls -la "$PHASE35_SRC" >/dev/null \
    || die "$PHASE35_SRC is not readable; fix the NAS mount before continuing"

  fstype="$(findmnt -rn --real -o FSTYPE --target "$PHASE35_SRC" 2>/dev/null | tail -1 || true)"
  [ -n "$fstype" ] || die "$PHASE35_SRC is not on a mounted filesystem"
  [[ "$fstype" == nfs* ]] || die "$PHASE35_SRC is on filesystem type '$fstype', expected NFS"
  ok "$PHASE35_SRC is readable on $fstype"
}

assert_phase35_sources_present() {
  local app src file
  for app in "${PHASE35_APPS[@]}"; do
    src="$(phase35_source_dir "$app")"
    [ -d "$src" ] || die "missing source directory: $src"
    ok "$src present"
    phase35_readable_as_source_owner "$app" \
      || die "$src is not readable as its archive owner $(phase35_source_owner "$app")"
    ok "$src is readable as archive owner $(phase35_source_owner "$app")"
  done

  for file in \
    "$(phase35_plex_db_dir "$(phase35_source_dir plex)")/com.plexapp.plugins.library.db" \
    "$(phase35_plex_db_dir "$(phase35_source_dir plex)")/com.plexapp.plugins.library.blobs.db" \
    "$(phase35_source_dir radarr)/config.xml" \
    "$(phase35_source_dir radarr)/radarr.db" \
    "$(phase35_source_dir sonarr)/config.xml" \
    "$(phase35_source_dir sonarr)/sonarr.db" \
    "$(phase35_source_dir prowlarr)/config.xml" \
    "$(phase35_source_dir prowlarr)/prowlarr.db"; do
    [ -f "$file" ] || die "missing required source file: $file"
  done
  ok "required Plex/*arr DB and config files exist"
}

phase35_source_size_kib() {
  du -sk --exclude=lost+found --exclude=Shaders \
    "$(phase35_source_dir plex)" \
    "$(phase35_source_dir radarr)" \
    "$(phase35_source_dir sonarr)" \
    "$(phase35_source_dir prowlarr)" \
    | awk '{sum += $1} END {print sum + 0}'
}

assert_opt_capacity() {
  local source_kib needed_kib avail_kib
  [ -d "$PHASE35_DEST_ROOT" ] || die "destination root missing: $PHASE35_DEST_ROOT"
  findmnt --target "$PHASE35_DEST_ROOT" >/dev/null \
    || die "$PHASE35_DEST_ROOT is not mounted"

  source_kib="$(phase35_source_size_kib)" \
    || die "could not estimate source size under $PHASE35_SRC"
  # Require the source size plus 20 percent plus a fixed 1 GiB working margin.
  needed_kib=$(( source_kib + (source_kib / 5) + PHASE35_FREE_MARGIN_KIB ))
  avail_kib="$(df -Pk "$PHASE35_DEST_ROOT" | awk 'NR == 2 {print $4}')"

  [ "$avail_kib" -ge "$needed_kib" ] \
    || die "$PHASE35_DEST_ROOT has ${avail_kib} KiB free, need at least ${needed_kib} KiB"
  ok "$PHASE35_DEST_ROOT has enough free space for migrated configs"
}

assert_destinations_safe() {
  local app dest
  if [ "${PHASE35_ALLOW_EXISTING_DEST:-0}" = "1" ]; then
    warn "PHASE35_ALLOW_EXISTING_DEST=1; existing destination contents may be replaced"
    return 0
  fi

  for app in "${PHASE35_APPS[@]}"; do
    dest="$(phase35_dest_dir "$app")"
    if [ -d "$dest" ] && find "$dest" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      die "$dest already contains data; snapshot/move it first or set PHASE35_ALLOW_EXISTING_DEST=1"
    fi
    ok "$dest is absent or empty"
  done
}

create_phase35_destinations() {
  local app
  for app in "${PHASE35_APPS[@]}"; do
    sudo install -d -m 0755 "$(phase35_dest_dir "$app")"
  done
  ok "destination directories exist under $PHASE35_DEST_ROOT"
}

rsync_phase35_app() {
  local app="$1" src dest owner uid gid
  src="$(phase35_source_dir "$app")"
  dest="$(phase35_dest_dir "$app")"
  owner="$(phase35_source_owner "$app")"
  uid="${owner%%:*}"
  gid="${owner##*:}"

  # NFS exports commonly use root-squash. Reading as the archive owner avoids
  # permission denied on 0600/0660 files while the final chown below normalizes
  # everything for the target LinuxServer containers.
  sudo chown -R "$owner" "$PHASE35_DEST_ROOT/$app"

  if [ "$app" = "plex" ]; then
    sudo setpriv --reuid "$uid" --regid "$gid" --clear-groups \
      rsync -aHAX --numeric-ids --info=progress2 --delete \
      --exclude=lost+found \
      --exclude='Library/Application Support/Plex Media Server/Cache/Shaders' \
      "$src/" "$dest/"
  else
    sudo setpriv --reuid "$uid" --regid "$gid" --clear-groups \
      rsync -aHAX --numeric-ids --info=progress2 --delete \
      "$src/" "$dest/"
  fi
  ok "copied $app config as archive owner $owner"
}

chown_phase35_destinations() {
  sudo chown -R "$PHASE35_OWNER" \
    "$PHASE35_DEST_ROOT/plex" \
    "$PHASE35_DEST_ROOT/radarr" \
    "$PHASE35_DEST_ROOT/sonarr" \
    "$PHASE35_DEST_ROOT/prowlarr"
  ok "set migrated ownership to $PHASE35_OWNER"
}

assert_integrity_ok() {
  local label="$1" db="$2" result
  [ -f "$db" ] || die "missing copied DB: $db"
  result="$(sudo sqlite3 "$db" 'PRAGMA integrity_check;')" \
    || die "$label integrity check failed to run"
  [ "$result" = "ok" ] || die "$label integrity check returned: $result"
  ok "$label SQLite integrity_check"
}

assert_sqlite_query_ok() {
  local label="$1" db="$2" sql="$3"
  [ -f "$db" ] || die "missing copied DB: $db"
  sudo sqlite3 "$db" "$sql" >/dev/null \
    || die "$label SQLite validation query failed"
  ok "$label SQLite opens and expected schema is readable"
}

assert_plex_databases_readable() {
  # Plex's library DB can define a custom FTS tokenizer named "collating". The
  # system sqlite3 binary does not have that tokenizer, so PRAGMA integrity_check
  # may fail at schema-prepare time even when Plex itself can read the DB.
  assert_sqlite_query_ok "Plex library" "$(phase35_db_path plex-library)" \
    'PRAGMA schema_version; SELECT count(*) FROM sqlite_master; SELECT count(*) FROM metadata_items;'
  assert_sqlite_query_ok "Plex blobs" "$(phase35_db_path plex-blobs)" \
    'PRAGMA schema_version; SELECT count(*) FROM sqlite_master;'
}

assert_phase35_copied_files() {
  local file
  for file in \
    "$(phase35_db_path plex-library)" \
    "$(phase35_db_path plex-blobs)" \
    "$(phase35_dest_dir radarr)/config.xml" \
    "$(phase35_db_path radarr)" \
    "$(phase35_dest_dir sonarr)/config.xml" \
    "$(phase35_db_path sonarr)" \
    "$(phase35_dest_dir prowlarr)/config.xml" \
    "$(phase35_db_path prowlarr)"; do
    [ -f "$file" ] || die "missing copied file: $file"
  done
  ok "required copied files exist"
}

assert_phase35_ownership() {
  local drift
  drift="$(sudo find \
    "$PHASE35_DEST_ROOT/plex" \
    "$PHASE35_DEST_ROOT/radarr" \
    "$PHASE35_DEST_ROOT/sonarr" \
    "$PHASE35_DEST_ROOT/prowlarr" \
    \( -not -user "${PHASE35_OWNER%%:*}" -o -not -group "${PHASE35_OWNER##*:}" \) \
    -print -quit)"
  [ -z "$drift" ] || die "ownership drift under migrated configs, first mismatch: $drift"
  ok "migrated files are owned by $PHASE35_OWNER"
}
