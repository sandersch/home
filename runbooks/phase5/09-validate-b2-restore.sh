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
      containers:
        - name: restic
          image: ghcr.io/sandersch/restic-backup:0.19.0-1
          command:
            - /bin/bash
            - -ec
            - |
              mkdir -p "$RESTIC_CACHE_DIR" /restore
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

              sqlite_path="$(restic find --snapshot "$snapshot_id" --json '*.sqlite-backup' |
                jq -er '[.[].matches[]? | select(.type == "file")][0].path')"
              ha_path="$(restic find --snapshot "$snapshot_id" --json '/data/opt/home-assistant/config/backups/*' |
                jq -er '[.[].matches[]? | select(.type == "file")][0].path')"
              romm_path=/work/hot-dumps/romm/romm.sql

              restic restore "$snapshot_id" \
                --target /restore \
                --include "$sqlite_path" \
                --include "$romm_path" \
                --include "$ha_path"

              test -s "/restore$romm_path"
              test -s "/restore$ha_path"
              test -s "/restore$sqlite_path"
              sqlite3 -readonly "/restore$sqlite_path" 'PRAGMA integrity_check;' | grep -qx ok
              echo "B2 snapshot metadata and representative restored artifacts are valid"
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
      volumes:
        - name: work
          emptyDir: {}
        - name: restore
          emptyDir: {}
        - name: tmp
          emptyDir: {}
YAML

if grep -q '/mnt/backups\|name: backups' "$tmpdir/restic-b2-restore-validate.yaml"; then
  die "B2 restore validation Job must not depend on the NAS backup volume"
fi

step "Run independent B2 restore validation job"
kubectl -n monitoring delete job restic-b2-restore-validate --ignore-not-found=true
kubectl apply -f "$tmpdir/restic-b2-restore-validate.yaml"
wait_for_job monitoring restic-b2-restore-validate 21600s
