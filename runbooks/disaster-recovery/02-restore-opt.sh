#!/usr/bin/env bash
# Restore one exact Restic snapshot into staging, overlay SQLite hot backups, and
# copy the validated application tree into an empty /opt. RomM's live-captured
# MariaDB files are deliberately excluded; 03 restores its logical dump.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_recovery_preconditions
require_recovery_snapshot
require_tools df du rsync sqlite3 stat tar
assert_safe_stage_root
assert_state_matches_selection

if [ "$RECOVERY_SOURCE" = nas ]; then
  assert_direct_mount_layout /mnt/backups /dev/mapper/hoardvg-backuplv \
    cc1cedb8-ef22-44b5-b1d0-5ca020d72669
fi

# Prior runbook-owned Jobs never mount /opt, so preflight may safely allow them. Stop
# them before inspecting or resetting either staging tree.
delete_recovery_job monitoring restic-full-recovery
delete_recovery_job media romm-database-recovery

stage="$(recovery_stage_dir)"
stage_opt="$stage/data/opt"
hot_dumps="$stage/work/hot-dumps"
sqlite_dumps="$hot_dumps/sqlite"

record_recovery_selection
sudo install -d -o root -g root -m 0700 "$(dirname "$stage")"
if ! sudo test -d "$stage"; then
  sudo install -d -o root -g root -m 0700 "$stage"
fi

stage_first_entry="$(sudo find "$stage" -mindepth 1 -maxdepth 1 -print -quit)"
if [ -n "$stage_first_entry" ] && [ "$(state_value restic_restore)" != complete ]; then
  [ -z "$(state_value activation)" ] \
    || die "cannot reset Restic staging after /opt activation has started"
  if [ "${RECOVERY_RESET_RESTIC_STAGE:-0}" = 1 ] \
    && confirm "Delete the incomplete Restic staging tree at $stage and retry?"; then
    delete_recovery_job monitoring restic-full-recovery
    sudo find "$stage" -mindepth 1 -delete
    stage_first_entry=''
    ok "cleared incomplete Restic staging tree"
  else
    die "$stage contains an incomplete Restic attempt; inspect it, then rerun with RECOVERY_RESET_RESTIC_STAGE=1"
  fi
fi

if [ -n "$stage_first_entry" ]; then
  sudo test -d "$stage_opt" \
    || die "$stage is nonempty but does not contain a completed /data/opt restore"
  sudo test -d "$hot_dumps" \
    || die "$stage is nonempty but does not contain /work/hot-dumps"
  delete_recovery_job monitoring restic-full-recovery
  ok "reusing the recorded recovery staging tree at $stage"
else
  apply_restic_recovery_secret
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  manifest="$tmpdir/restic-full-recovery.yaml"

  cat >"$manifest" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-full-recovery
  namespace: monitoring
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 21600
  template:
    spec:
      restartPolicy: Never
      priorityClassName: homelab-low
      nodeSelector:
        kubernetes.io/hostname: minis
      containers:
        - name: restic
          image: $RECOVERY_IMAGE
          command:
            - /bin/bash
            - -ec
            - |
              mkdir -p "\$RESTIC_CACHE_DIR"
              metadata="\$(restic --no-lock snapshots '$RECOVERY_SNAPSHOT' --host minis --json)"
              printf '%s' "\$metadata" | jq -e \
                --arg id '$RECOVERY_SNAPSHOT' \
                --arg tag '$RECOVERY_SOURCE' '
                  length == 1 and
                  .[0].id == \$id and
                  .[0].hostname == "minis" and
                  (.[0].tags | index("opt") != null) and
                  (.[0].tags | index(\$tag) != null) and
                  (.[0].paths | index("/data/opt") != null) and
                  (.[0].paths | index("/work/hot-dumps") != null)
                '
              restic --no-lock check
              restic --no-lock restore '$RECOVERY_SNAPSHOT' \
                --target /restore \
                --exclude /data/opt/romm/db
              test -d /restore/data/opt
              test -d /restore/work/hot-dumps/sqlite
              test -s /restore/work/hot-dumps/romm/romm.sql
              test ! -e /restore/data/opt/romm/db/ibdata1
          env:
$(write_restic_env)
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 2Gi
          securityContext:
            privileged: true
          volumeMounts:
$(write_restic_repository_volume)
            - name: restore
              mountPath: /restore
            - name: tmp
              mountPath: /tmp
      volumes:
$(write_restic_repository_host_volume)
        - name: restore
          hostPath:
            path: $stage
            type: Directory
        - name: tmp
          emptyDir: {}
YAML
  yq -e '.' "$manifest" >/dev/null || die "generated full-restore Job is invalid YAML"

  step "Restore snapshot $RECOVERY_SNAPSHOT from $RECOVERY_SOURCE into staging"
  delete_recovery_job monitoring restic-full-recovery
  kubectl apply -f "$manifest" >/dev/null
  wait_for_recovery_job monitoring restic-full-recovery 21600s
  set_state_value restic_restore complete
  delete_recovery_job monitoring restic-full-recovery
fi

step "Validate staged application state"
for expected in \
  plex/config \
  sabnzbd/config \
  qbittorrent/config \
  prowlarr/config \
  radarr/config \
  sonarr/config \
  seerr/config \
  romm \
  frigate/config \
  home-assistant/config \
  zwave-js-ui/store \
  mosquitto/data; do
  sudo test -d "$stage_opt/$expected" \
    || die "selected snapshot is missing /data/opt/$expected"
done
sudo test ! -e "$stage_opt/romm/db/ibdata1" \
  || die "staging unexpectedly contains the live-captured RomM database"
assert_hot_dump_contract "$hot_dumps"
ha_backup="$(sudo find "$stage_opt/home-assistant/config/backups" \
  -maxdepth 1 -type f -name '*.tar' -size +0c -print -quit 2>/dev/null || true)"
[ -n "$ha_backup" ] || die "selected snapshot has no Home Assistant managed backup artifact"
sudo tar -tf "$ha_backup" >/dev/null \
  || die "restored Home Assistant backup artifact is not a readable tar file: $ha_backup"
ok "staged tree contains core app state and satisfies the required export contract"

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

if [ "$(state_value sqlite_overlay)" != complete ]; then
  step "Validate and overlay SQLite hot backups in staging"
  mapfile -d '' sqlite_backups < <(sudo find "$sqlite_dumps" -type f -name '*.sqlite-backup' -print0)
  [ "${#sqlite_backups[@]}" -gt 0 ] || die "selected snapshot contains no SQLite hot backups"
  for backup in "${sqlite_backups[@]}"; do
    relative="${backup#"$sqlite_dumps/"}"
    relative="${relative%.sqlite-backup}"
    target="$stage_opt/$relative"
    sudo test -f "$target" || die "SQLite hot backup has no matching restored DB: $relative"
    validate_sqlite "$backup" "$relative"
    before_meta="$(sudo stat -c '%u:%g:%a' "$target")"
    sudo cp -- "$backup" "$target"
    after_meta="$(sudo stat -c '%u:%g:%a' "$target")"
    [ "$before_meta" = "$after_meta" ] \
      || die "SQLite overlay changed owner/group/mode for $relative"
    sudo rm -f -- "${target}-wal" "${target}-shm"
    validate_sqlite "$target" "$relative"
  done
  set_state_value sqlite_overlay complete
  ok "validated and applied ${#sqlite_backups[@]} SQLite hot backup(s)"
else
  ok "SQLite hot-backup overlay was already completed for this recovery"
fi

activation_state="$(state_value activation)"
if [ "$activation_state" = complete ]; then
  ok "/opt activation was already completed for this recorded recovery"
  exit 0
fi

opt_first_entry="$(sudo find /opt -mindepth 1 -maxdepth 1 -print -quit)"
if [ -n "$opt_first_entry" ] && [ "$activation_state" != in-progress ]; then
  die "/opt is nonempty without a matching in-progress recovery; refusing to merge or overwrite it"
fi

source_kb="$(sudo du -sk --one-file-system "$stage_opt" | awk '{print $1}')"
available_kb="$(df -Pk /opt | awk 'NR == 2 {print $4}')"
target_kb="$(sudo du -sk --one-file-system /opt | awk '{print $1}')"
recoverable_kb=$((available_kb + target_kb))
[ "$recoverable_kb" -gt "$source_kb" ] \
  || die "/opt has ${available_kb} KiB free plus ${target_kb} KiB from this resumable target, but the staged tree needs at least ${source_kb} KiB"

cat <<EOF

Recovery activation is ready:
  source:   $RECOVERY_SOURCE
  snapshot: $RECOVERY_SNAPSHOT
  staging:  $stage
  target:   /opt on /dev/mapper/vg0-opt

The live-captured romm/db directory will be excluded. Its validated logical dump is
restored by 03-restore-romm.sh before applications resume.
EOF
confirm "Copy this staged recovery into /opt now?" || die "recovery activation aborted"

set_state_value activation in-progress
step "Copy staged state into /opt with numeric ownership, ACLs, xattrs, and hard links"
sudo rsync \
  --archive \
  --hard-links \
  --acls \
  --xattrs \
  --numeric-ids \
  --one-file-system \
  --exclude='/romm/db/***' \
  "$stage_opt/" /opt/

rsync_delta="$(sudo rsync \
  --archive \
  --hard-links \
  --acls \
  --xattrs \
  --numeric-ids \
  --one-file-system \
  --exclude='/romm/db/***' \
  --dry-run \
  --itemize-changes \
  "$stage_opt/" /opt/)"
[ -z "$rsync_delta" ] || {
  printf '%s\n' "$rsync_delta" >&2
  die "post-copy rsync verification found differences"
}

sudo install -d -o 999 -g 999 -m 0755 /opt/romm/db
sudo sync -f /opt
set_state_value activation complete
ok "full staged /opt tree copied; RomM database directory remains empty for logical restore"
