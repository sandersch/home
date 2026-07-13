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
  activeDeadlineSeconds: 900
  template:
    spec:
      restartPolicy: Never
      priorityClassName: homelab-low
      terminationGracePeriodSeconds: 10
      containers:
        - name: restic
          image: ghcr.io/sandersch/restic-backup:0.19.0-1
          command:
            - /bin/bash
            - -ec
            - |
              log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
              run() {
                local seconds="$1"
                shift
                log "running: $*"
                timeout "$seconds" "$@"
              }

              log "RESTIC_REPOSITORY=$RESTIC_REPOSITORY"
              log "checking backup mount"
              id
              df -h /repo/nas || true
              ls -ld /repo/nas || true
              run 30 mkdir -p "$RESTIC_REPOSITORY" "$RESTIC_CACHE_DIR"
              ls -ld "$RESTIC_REPOSITORY"
              run 30 sh -c 'printf "%s\n" "restic init probe $(date -Iseconds)" > "$RESTIC_REPOSITORY/.init-write-test"'
              run 30 rm -f "$RESTIC_REPOSITORY/.init-write-test"
              if timeout 60 restic snapshots; then
                echo "Restic repository already initialized"
              else
                log "Restic repository is not initialized yet; running init"
                run 120 restic init
              fi
              run 120 restic snapshots
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
          securityContext:
            allowPrivilegeEscalation: false
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
