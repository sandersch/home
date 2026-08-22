#!/usr/bin/env bash
# Phase 5.9 - validate that the latest B2 snapshot is independently restorable.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

assert_phase5_restic_b2_secret_present

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/restic-b2-restore-validate.yaml" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-b2-restore-validate
  namespace: monitoring
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 21600
  template:
    spec:
      restartPolicy: Never
      priorityClassName: homelab-low
      automountServiceAccountToken: false
      containers:
        - name: restic
          # renovate: datasource=docker depName=ghcr.io/sandersch/restic-backup
          image: ghcr.io/sandersch/restic-backup:0.19.1-1@sha256:58cddae970e91cb4f8f18db69d9d7d526d1e1d803193a65afb2f7f3a43aa9097
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

              mkdir -p "$RESTIC_CACHE_DIR" /restore
              wait_for_mariadb
              trap 'stop_mariadb || true' EXIT

              snapshots="$(restic snapshots --host "$RESTIC_HOST" --tag b2 --json)"
              snapshot_id="$(printf '%s' "$snapshots" | jq -er 'sort_by(.time) | last | .id')"
              printf '%s' "$snapshots" | jq -e --arg id "$snapshot_id" '
                first(.[] | select(.id == $id)) |
                .hostname == "minis" and
                (.tags | index("opt") != null) and
                (.tags | index("b2") != null) and
                (.paths | index("/data/opt") != null) and
                (.paths | index("/work/hot-dumps") != null)
              '

              restic check --read-data-subset=1/100

              contract_path=/work/hot-dumps/contract-version
              inventory_path=/work/hot-dumps/required-sqlite-databases.txt
              created_at_path=/work/hot-dumps/export-created-at
              ha_path=/work/hot-dumps/home-assistant/home-assistant.tar
              romm_path=/work/hot-dumps/romm/romm.sql
              k3s_path=/work/hot-dumps/k3s/state.db.sqlite-backup
              include_args=(
                --include "$contract_path"
                --include "$inventory_path"
                --include "$created_at_path"
                --include "$ha_path"
                --include "$romm_path"
                --include "$k3s_path"
              )
              required_count=0
              while IFS= read -r rel; do
                test -n "$rel" || continue
                include_args+=(--include "/work/hot-dumps/sqlite/${rel}.sqlite-backup")
                required_count=$((required_count + 1))
              done <<EOF
              $REQUIRED_SQLITE_DATABASES
              EOF
              test "$required_count" -gt 0

              restic restore "$snapshot_id" \
                --target /restore \
                "${include_args[@]}"

              test "$(cat "/restore$contract_path")" = "$BACKUP_CONTRACT_VERSION"
              restored_inventory="$(cat "/restore$inventory_path")"
              expected_inventory="$(printf '%s\n' "$REQUIRED_SQLITE_DATABASES" | sed '/^[[:space:]]*$/d')"
              test "$restored_inventory" = "$expected_inventory"
              created_at="$(cat "/restore$created_at_path")"
              [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
              test -s "/restore$romm_path"
              test -s "/restore$ha_path"
              tar -tf "/restore$ha_path" >/dev/null
              test -s "/restore$k3s_path"
              sqlite3 -readonly "/restore$k3s_path" 'PRAGMA integrity_check;' | grep -qx ok
              test "$(sqlite3 -readonly "/restore$k3s_path" \
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('kine','sqlite_sequence');")" = 2
              kine_rows="$(sqlite3 -readonly "/restore$k3s_path" 'SELECT count(*) FROM kine;')"
              test "$kine_rows" -gt 0

              validated_count=0
              while IFS= read -r rel; do
                test -n "$rel" || continue
                path="/restore/work/hot-dumps/sqlite/${rel}.sqlite-backup"
                test -s "$path"
                case "$rel" in
                  plex/config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/com.plexapp.plugins.library*.db)
                    sqlite3 -readonly "$path" \
                      'PRAGMA schema_version; SELECT count(*) FROM sqlite_master;' >/dev/null
                    ;;
                  *)
                    sqlite3 -readonly "$path" 'PRAGMA integrity_check;' | grep -qx ok
                    ;;
                esac
                validated_count=$((validated_count + 1))
              done <<EOF
              $REQUIRED_SQLITE_DATABASES
              EOF
              test "$validated_count" = "$required_count"

              grep -Eq '^CREATE TABLE ' "/restore$romm_path"
              mariadb --protocol=tcp --host=127.0.0.1 --user=root <"/restore$romm_path"
              table_count="$(mariadb --protocol=tcp --host=127.0.0.1 --user=root \
                --batch --skip-column-names \
                --execute='SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="romm"')"
              test "$table_count" -gt 0
              mariadb-check --protocol=tcp --host=127.0.0.1 --user=root --databases romm

              stop_mariadb
              trap - EXIT
              echo "B2 snapshot $snapshot_id satisfies backup contract $BACKUP_CONTRACT_VERSION with $validated_count required app SQLite exports, $kine_rows k3s kine rows, and $table_count RomM tables"
          env:
            - name: RESTIC_REPOSITORY
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: RESTIC_REPOSITORY
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: RESTIC_PASSWORD
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: AWS_SECRET_ACCESS_KEY
            - name: RESTIC_HOST
              value: minis
            - name: RESTIC_CACHE_DIR
              value: /work/restic-cache
            - name: BACKUP_CONTRACT_VERSION
              valueFrom:
                configMapKeyRef:
                  name: restic-nas-config
                  key: BACKUP_CONTRACT_VERSION
            - name: REQUIRED_SQLITE_DATABASES
              valueFrom:
                configMapKeyRef:
                  name: restic-nas-config
                  key: REQUIRED_SQLITE_DATABASES
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: work
              mountPath: /work
            - name: restore
              mountPath: /restore
            - name: tmp
              mountPath: /tmp
        - name: mariadb
          # renovate: datasource=docker depName=mariadb
          image: mariadb:12.3.2@sha256:a02fe89cb597d4375812b2eac90cf9d0775d4686daa7f7cc750ebbcad7525bbc
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
        - name: work
          emptyDir: {}
        - name: restore
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

if grep -q '/mnt/backups\|name: backups' "$tmpdir/restic-b2-restore-validate.yaml"; then
  die "B2 restore validation Job must not depend on the local backup volume"
fi

step "Run independent B2 restore validation job"
kubectl -n monitoring delete job restic-b2-restore-validate --ignore-not-found=true
kubectl apply -f "$tmpdir/restic-b2-restore-validate.yaml"
wait_for_job monitoring restic-b2-restore-validate 21600s
