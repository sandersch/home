#!/usr/bin/env bash
# Phase 5.5 - validate that the latest direct-array Restic snapshot is restorable.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

assert_phase5_restic_secret_present

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/restic-nas-restore-validate.yaml" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-nas-restore-validate
  namespace: monitoring
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    spec:
      restartPolicy: Never
      priorityClassName: homelab-low
      containers:
        - name: restic
          image: ghcr.io/sandersch/restic-backup:0.19.0-1
          command:
            - /bin/bash
            - -ec
            - |
              wait_for_mariadb() {
                for _ in $(seq 1 120); do
                  if mariadb --protocol=tcp --host=127.0.0.1 --user=root \
                    --batch --skip-column-names --execute='SELECT 1' 2>/dev/null | grep -qx 1; then
                    return 0
                  fi
                  sleep 2
                done
                echo 'temporary MariaDB did not become ready' >&2
                return 1
              }
              stop_mariadb() {
                mariadb-admin --protocol=tcp --host=127.0.0.1 --user=root shutdown >/dev/null 2>&1
              }

              mkdir -p "$RESTIC_CACHE_DIR"
              wait_for_mariadb
              trap 'stop_mariadb || true' EXIT

              snapshots="$(restic snapshots --host "$RESTIC_HOST" --tag nas --json)"
              snapshot_id="$(printf '%s' "$snapshots" | jq -er 'sort_by(.time) | last | .id')"
              printf '%s' "$snapshots" | jq -e --arg id "$snapshot_id" '
                first(.[] | select(.id == $id)) |
                .hostname == "minis" and
                (.tags | index("opt") != null) and
                (.tags | index("nas") != null) and
                (.paths | index("/data/opt") != null) and
                (.paths | index("/work/hot-dumps") != null)
              '
              restic check --read-data-subset=1/100
              restic ls "$snapshot_id" /data/opt >/tmp/restic-opt-ls.txt
              test -s /tmp/restic-opt-ls.txt
              restic ls "$snapshot_id" /work/hot-dumps >/tmp/restic-hot-dumps-ls.txt
              test -s /tmp/restic-hot-dumps-ls.txt

              contract_version="$(restic dump "$snapshot_id" /work/hot-dumps/contract-version)"
              test "$contract_version" = "$BACKUP_CONTRACT_VERSION"
              restored_inventory="$(restic dump "$snapshot_id" /work/hot-dumps/required-sqlite-databases.txt)"
              expected_inventory="$(printf '%s\n' "$REQUIRED_SQLITE_DATABASES" | sed '/^[[:space:]]*$/d')"
              test "$restored_inventory" = "$expected_inventory"
              created_at="$(restic dump "$snapshot_id" /work/hot-dumps/export-created-at)"
              [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]

              required_count=0
              while IFS= read -r rel; do
                test -n "$rel" || continue
                path="/work/hot-dumps/sqlite/${rel}.sqlite-backup"
                output="/tmp/required-${required_count}.sqlite"
                restic dump "$snapshot_id" "$path" >"$output"
                test -s "$output"
                case "$rel" in
                  plex/config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/com.plexapp.plugins.library*.db)
                    sqlite3 -readonly "$output" \
                      'PRAGMA schema_version; SELECT count(*) FROM sqlite_master;' >/dev/null
                    ;;
                  *)
                    sqlite3 -readonly "$output" 'PRAGMA integrity_check;' | grep -qx ok
                    ;;
                esac
                required_count=$((required_count + 1))
              done <<EOF
              $REQUIRED_SQLITE_DATABASES
              EOF
              test "$required_count" -gt 0

              restic dump "$snapshot_id" /work/hot-dumps/home-assistant/home-assistant.tar \
                >/tmp/home-assistant.tar
              test -s /tmp/home-assistant.tar
              tar -tf /tmp/home-assistant.tar >/dev/null

              restic dump "$snapshot_id" /work/hot-dumps/romm/romm.sql >/tmp/romm.sql
              test -s /tmp/romm.sql
              grep -Eq '^CREATE TABLE ' /tmp/romm.sql
              mariadb --protocol=tcp --host=127.0.0.1 --user=root </tmp/romm.sql
              table_count="$(mariadb --protocol=tcp --host=127.0.0.1 --user=root \
                --batch --skip-column-names \
                --execute='SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="romm"')"
              test "$table_count" -gt 0
              mariadb-check --protocol=tcp --host=127.0.0.1 --user=root --databases romm

              stop_mariadb
              trap - EXIT
              echo "NAS snapshot $snapshot_id satisfies backup contract $contract_version with $required_count required SQLite exports and $table_count RomM tables"
          envFrom:
            - configMapRef:
                name: restic-nas-config
          env:
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-nas
                  key: RESTIC_PASSWORD
            - name: RESTIC_CACHE_DIR
              value: /work/restic-cache
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: backups
              mountPath: /repo/nas
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
        - name: mariadb
          image: mariadb:11.4
          command:
            - /bin/bash
            - -ec
            - exec docker-entrypoint.sh mariadbd --bind-address=127.0.0.1
          env:
            - name: MARIADB_ALLOW_EMPTY_ROOT_PASSWORD
              value: "1"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: mariadb-data
              mountPath: /var/lib/mysql
            - name: mariadb-run
              mountPath: /run/mysqld
            - name: mariadb-tmp
              mountPath: /tmp
      volumes:
        - name: backups
          hostPath:
            path: /mnt/backups
            type: Directory
        - name: work
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        - name: mariadb-data
          emptyDir: {}
        - name: mariadb-run
          emptyDir: {}
        - name: mariadb-tmp
          emptyDir: {}
YAML

step "Run restore validation job"
kubectl -n monitoring delete job restic-nas-restore-validate --ignore-not-found=true
kubectl apply -f "$tmpdir/restic-nas-restore-validate.yaml"
wait_for_job monitoring restic-nas-restore-validate 3600s
