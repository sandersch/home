#!/usr/bin/env bash
# Rebuild RomM's MariaDB data directory from the transaction-consistent logical dump
# captured alongside the selected Restic snapshot.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_recovery_preconditions
require_recovery_snapshot
require_tools rsync
assert_safe_stage_root
assert_state_matches_selection
[ "$(state_value activation)" = complete ] \
  || die "02-restore-opt.sh has not completed /opt activation"

# This runbook-owned Job writes only to logical staging, never /opt. Stop a retained
# attempt before inspecting or resetting that staging tree.
delete_recovery_job media romm-database-recovery

stage="$(recovery_stage_dir)"
romm_dump="$stage/work/hot-dumps/romm/romm.sql"
romm_stage="$stage/romm-db-logical"
sudo test -s "$romm_dump" || die "RomM logical dump is missing: $romm_dump"

if [ "$(state_value romm)" = complete ]; then
  sudo test -s /opt/romm/db/ibdata1 \
    || die "recovery state says RomM is complete but /opt/romm/db/ibdata1 is missing"
  ok "RomM logical database restore was already completed"
  exit 0
fi

if [ "$(state_value romm_stage)" != complete ]; then
  sudo install -d -o root -g root -m 0700 "$romm_stage"
  romm_stage_entry="$(sudo find "$romm_stage" -mindepth 1 -maxdepth 1 -print -quit)"
  if [ -n "$romm_stage_entry" ]; then
    if [ "${RECOVERY_RESET_ROMM_STAGE:-0}" = 1 ] \
      && confirm "Delete the failed logical-restore staging tree at $romm_stage and retry?"; then
      sudo find "$romm_stage" -mindepth 1 -delete
      ok "cleared failed RomM staging tree"
    else
      die "$romm_stage is nonempty from an incomplete attempt; inspect it, then rerun with RECOVERY_RESET_ROMM_STAGE=1"
    fi
  fi

  opt_db_entry="$(sudo find /opt/romm/db -mindepth 1 -maxdepth 1 -print -quit)"
  [ -z "$opt_db_entry" ] \
    || die "/opt/romm/db is not empty before logical recovery; refusing to overwrite it"

  apply_sops_secret apps/media/romm/romm.sops.yaml media

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  manifest="$tmpdir/romm-database-recovery.yaml"

  cat >"$manifest" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: romm-database-recovery
  namespace: media
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    spec:
      restartPolicy: Never
      priorityClassName: homelab-low
      nodeSelector:
        kubernetes.io/hostname: minis
      containers:
        - name: mariadb
          image: mariadb:11.4
          command:
            - /bin/bash
            - -ec
            - |
              server_pid=''
              cleanup() {
                if [ -n "\$server_pid" ]; then
                  MYSQL_PWD="\$MARIADB_ROOT_PASSWORD" mariadb-admin \
                    --protocol=tcp --host=127.0.0.1 --user=root shutdown >/dev/null 2>&1 || true
                  wait "\$server_pid" 2>/dev/null || true
                fi
              }
              trap cleanup EXIT

              docker-entrypoint.sh mariadbd --bind-address=127.0.0.1 &
              server_pid=\$!
              ready=0
              for _ in \$(seq 1 120); do
                if MYSQL_PWD="\$MARIADB_ROOT_PASSWORD" mariadb \
                  --protocol=tcp --host=127.0.0.1 --user=root \
                  --batch --skip-column-names --execute='SELECT 1' 2>/dev/null | grep -qx 1; then
                  ready=1
                  break
                fi
                kill -0 "\$server_pid" 2>/dev/null || break
                sleep 2
              done
              [ "\$ready" = 1 ] || { echo 'temporary MariaDB did not become ready' >&2; exit 1; }

              MYSQL_PWD="\$MARIADB_ROOT_PASSWORD" mariadb \
                --protocol=tcp --host=127.0.0.1 --user=root < /recovery/romm.sql
              table_count="\$(MYSQL_PWD="\$MARIADB_ROOT_PASSWORD" mariadb \
                --protocol=tcp --host=127.0.0.1 --user=root \
                --batch --skip-column-names \
                --execute='SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="romm"')"
              [ "\$table_count" -gt 0 ] || { echo 'logical dump restored no RomM tables' >&2; exit 1; }
              MYSQL_PWD="\$MARIADB_ROOT_PASSWORD" mariadb-check \
                --protocol=tcp --host=127.0.0.1 --user=root --databases romm

              MYSQL_PWD="\$MARIADB_ROOT_PASSWORD" mariadb-admin \
                --protocol=tcp --host=127.0.0.1 --user=root shutdown
              wait "\$server_pid"
              server_pid=''
              trap - EXIT
              test -s /var/lib/mysql/ibdata1
              echo "RomM logical database restore completed with \$table_count table(s)"
          env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: romm
                  key: MARIADB_ROOT_PASSWORD
            - name: MARIADB_DATABASE
              value: romm
            - name: MARIADB_USER
              value: romm
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: romm
                  key: MARIADB_PASSWORD
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            privileged: true
          volumeMounts:
            - name: database
              mountPath: /var/lib/mysql
            - name: recovery-dump
              mountPath: /recovery/romm.sql
              readOnly: true
            - name: run
              mountPath: /run/mysqld
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: database
          hostPath:
            path: $romm_stage
            type: Directory
        - name: recovery-dump
          hostPath:
            path: $romm_dump
            type: File
        - name: run
          emptyDir: {}
        - name: tmp
          emptyDir: {}
YAML
  yq -e '.' "$manifest" >/dev/null || die "generated RomM recovery Job is invalid YAML"

  step "Restore RomM MariaDB from its logical dump"
  delete_recovery_job media romm-database-recovery
  kubectl apply -f "$manifest" >/dev/null
  wait_for_recovery_job media romm-database-recovery 3600s
  sudo test -s "$romm_stage/ibdata1" || die "logical restore produced no MariaDB system tablespace"
  set_state_value romm_stage complete
  delete_recovery_job media romm-database-recovery
else
  sudo test -s "$romm_stage/ibdata1" \
    || die "recovery state says RomM staging is complete but $romm_stage/ibdata1 is missing"
  delete_recovery_job media romm-database-recovery
  ok "reusing the completed logical RomM staging tree"
fi

step "Install the logically restored RomM database into /opt"
opt_db_entry="$(sudo find /opt/romm/db -mindepth 1 -maxdepth 1 -print -quit)"
romm_install_state="$(state_value romm_install)"
if [ -n "$opt_db_entry" ] \
  && [ "$romm_install_state" != in-progress ] \
  && [ "$romm_install_state" != complete ]; then
  die "/opt/romm/db is nonempty without a matching logical install state"
fi
set_state_value romm_install in-progress
sudo rsync \
  --archive \
  --hard-links \
  --acls \
  --xattrs \
  --numeric-ids \
  --chown=999:999 \
  "$romm_stage/" /opt/romm/db/

romm_delta="$(sudo rsync \
  --archive \
  --hard-links \
  --acls \
  --xattrs \
  --numeric-ids \
  --chown=999:999 \
  --dry-run \
  --itemize-changes \
  "$romm_stage/" /opt/romm/db/)"
[ -z "$romm_delta" ] || {
  printf '%s\n' "$romm_delta" >&2
  die "post-copy RomM rsync verification found differences"
}
sudo sync -f /opt
set_state_value romm_install complete
set_state_value romm complete
ok "RomM database restored transaction-consistently into /opt/romm/db"
