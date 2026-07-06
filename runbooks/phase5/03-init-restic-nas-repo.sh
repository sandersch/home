#!/usr/bin/env bash
# Phase 5.3 - initialize the NAS Restic repository once.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl
require_flux_cli

assert_phase5_restic_secret_present

step "Reconcile monitoring before initializing the repository"
flux reconcile kustomization monitoring --with-source

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/restic-nas-init.yaml" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-nas-init
  namespace: monitoring
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
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
              mkdir -p "$RESTIC_REPOSITORY" "$RESTIC_CACHE_DIR"
              if restic snapshots >/dev/null 2>&1; then
                echo "Restic repository already initialized"
              else
                restic init
              fi
              restic snapshots
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
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
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

step "Run one-shot Restic repository init job"
kubectl -n monitoring delete job restic-nas-init --ignore-not-found=true
kubectl apply -f "$tmpdir/restic-nas-init.yaml"
wait_for_job monitoring restic-nas-init 300s
