#!/usr/bin/env bash
# Phase 5.5 - validate that the latest NAS Restic snapshot is restorable.
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
              mkdir -p "$RESTIC_CACHE_DIR"
              restic snapshots --host "$RESTIC_HOST"
              restic check --read-data-subset=1/100
              restic ls latest /data/opt >/tmp/restic-opt-ls.txt
              test -s /tmp/restic-opt-ls.txt
              restic ls latest /work/hot-dumps >/tmp/restic-hot-dumps-ls.txt
              test -s /tmp/restic-hot-dumps-ls.txt
              restic dump latest /work/hot-dumps/romm/romm.sql >/tmp/romm.sql
              test -s /tmp/romm.sql
              sqlite_path="$(restic find --json '*.sqlite-backup' | jq -r '.[].matches[]?.path' | head -1)"
              test -n "$sqlite_path"
              restic dump latest "$sqlite_path" >/tmp/sample.sqlite
              sqlite3 /tmp/sample.sqlite 'PRAGMA integrity_check;' | grep -qx ok
              restic ls latest /data/opt/home-assistant/config/backups >/tmp/home-assistant-backups.txt
              test -s /tmp/home-assistant-backups.txt
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
      volumes:
        - name: backups
          hostPath:
            path: /mnt/backups
            type: Directory
        - name: work
          emptyDir: {}
YAML

step "Run restore validation job"
kubectl -n monitoring delete job restic-nas-restore-validate --ignore-not-found=true
kubectl apply -f "$tmpdir/restic-nas-restore-validate.yaml"
wait_for_job monitoring restic-nas-restore-validate 3600s
