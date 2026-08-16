#!/usr/bin/env bash
# List exact full-state Restic snapshots from the selected recovery repository.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_recovery_preconditions
require_tools base64
if [ "$RECOVERY_SOURCE" = nas ]; then
  assert_direct_mount_layout /mnt/backups /dev/mapper/hoardvg-backuplv \
    cc1cedb8-ef22-44b5-b1d0-5ca020d72669
fi

apply_restic_recovery_secret
contract_version="$(backup_contract_version)"
required_sqlite_b64="$(required_sqlite_databases | base64 -w0)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
manifest="$tmpdir/restic-recovery-list.yaml"

cat >"$manifest" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-recovery-list
  namespace: monitoring
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
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
              REQUIRED_SQLITE_DATABASES="\$(printf '%s' "\$REQUIRED_SQLITE_DATABASES_B64" | base64 -d)"
              export REQUIRED_SQLITE_DATABASES
              snapshot_satisfies_contract() {
                local snapshot_id="\$1" actual_version actual_inventory relative path
                actual_version="\$(restic --no-lock dump "\$snapshot_id" \
                  /work/hot-dumps/contract-version 2>/dev/null)" || return 1
                [ "\$actual_version" = "\$BACKUP_CONTRACT_VERSION" ] || return 1
                actual_inventory="\$(restic --no-lock dump "\$snapshot_id" \
                  /work/hot-dumps/required-sqlite-databases.txt 2>/dev/null)" || return 1
                [ "\$actual_inventory" = "\$REQUIRED_SQLITE_DATABASES" ] || return 1
                while IFS= read -r relative; do
                  [ -n "\$relative" ] || continue
                  path="/work/hot-dumps/sqlite/\${relative}.sqlite-backup"
                  restic --no-lock ls "\$snapshot_id" "\$path" 2>/dev/null \
                    | grep -Fq -- "\$path" || return 1
                done <<<"\$REQUIRED_SQLITE_DATABASES"
                for path in \
                  /work/hot-dumps/home-assistant/home-assistant.tar \
                  /work/hot-dumps/romm/romm.sql \
                  /work/hot-dumps/export-created-at; do
                  restic --no-lock ls "\$snapshot_id" "\$path" 2>/dev/null \
                    | grep -Fq -- "\$path" || return 1
                done
              }

              snapshots="\$(restic --no-lock snapshots --host minis --json)"
              eligible="\$(printf '%s' "\$snapshots" | jq \
                --arg tag '$RECOVERY_SOURCE' '[.[] |
                  select(.hostname == "minis") |
                  select(.tags | index("opt") != null) |
                  select(.tags | index(\$tag) != null) |
                  select(.paths | index("/data/opt") != null) |
                  select(.paths | index("/work/hot-dumps") != null)
                ]')"
              [ "\$(printf '%s' "\$eligible" | jq 'length')" -gt 0 ] \
                || { echo 'no eligible recovery snapshots found' >&2; exit 1; }
              printf 'SNAPSHOT_ID\tTIME\tHOST\tTAGS\tPATHS\n'
              eligible_count=0
              while IFS=\$'\t' read -r snapshot_id snapshot_time snapshot_host snapshot_tags snapshot_paths; do
                if snapshot_satisfies_contract "\$snapshot_id"; then
                  printf '%s\t%s\t%s\t%s\t%s\n' \
                    "\$snapshot_id" "\$snapshot_time" "\$snapshot_host" "\$snapshot_tags" "\$snapshot_paths"
                  eligible_count=\$((eligible_count + 1))
                else
                  echo "EXCLUDED \$snapshot_id: missing or obsolete required-export contract" >&2
                fi
              done < <(printf '%s' "\$eligible" | jq -r '
                sort_by(.time) | reverse | .[] |
                [.id, .time, .hostname, (.tags | join(",")), (.paths | join(","))] |
                @tsv
              ')
              [ "\$eligible_count" -gt 0 ] \
                || { echo 'no full-recovery-eligible snapshots found' >&2; exit 1; }
          env:
$(write_restic_env)
            - name: BACKUP_CONTRACT_VERSION
              value: '$contract_version'
            - name: REQUIRED_SQLITE_DATABASES_B64
              value: '$required_sqlite_b64'
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
          volumeMounts:
$(write_restic_repository_volume)
            - name: tmp
              mountPath: /tmp
      volumes:
$(write_restic_repository_host_volume)
        - name: tmp
          emptyDir: {}
YAML
yq -e '.' "$manifest" >/dev/null || die "generated snapshot-list Job is invalid YAML"

step "List $RECOVERY_SOURCE recovery snapshots"
delete_recovery_job monitoring restic-recovery-list
kubectl apply -f "$manifest" >/dev/null
wait_for_recovery_job monitoring restic-recovery-list 1800s
delete_recovery_job monitoring restic-recovery-list

cat <<'EOF'

Every printed snapshot has `/data/opt`, `/work/hot-dumps`, and the current required
export contract. The restore performs full integrity checks before activation. Copy one
full 64-character ID and run:

  export RECOVERY_SNAPSHOT=<full-id>
  ./runbooks/disaster-recovery/run-restore.sh
EOF
