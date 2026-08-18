#!/usr/bin/env bash
# Phase 5.7 - initialize the Backblaze B2 Restic repository idempotently.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl
require_flux_cli

assert_phase5_restic_secret_present
assert_phase5_restic_b2_secret_present

step "Reconcile monitoring before initializing the B2 repository"
flux reconcile kustomization monitoring --with-source

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/restic-b2-init.yaml" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-b2-init
  namespace: monitoring
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    spec:
      restartPolicy: Never
      priorityClassName: homelab-low
      terminationGracePeriodSeconds: 10
      containers:
        - name: restic
          # renovate: datasource=docker depName=ghcr.io/sandersch/restic-backup
          image: ghcr.io/sandersch/restic-backup:0.19.0-1@sha256:2b10954ca8edd402c3168ad052a526ef559dafe4c61ad569902036021e08ca7a
          command:
            - /bin/bash
            - -ec
            - |
              mkdir -p "$RESTIC_CACHE_DIR"
              if restic snapshots; then
                echo "Restic B2 repository already initialized"
              else
                echo "Restic B2 repository is not initialized yet; running init"
                restic init
              fi
              restic snapshots
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
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: work
          emptyDir: {}
        - name: tmp
          emptyDir: {}
YAML

step "Run one-shot Restic B2 repository init job"
kubectl -n monitoring delete job restic-b2-init --ignore-not-found=true
kubectl apply -f "$tmpdir/restic-b2-init.yaml"
wait_for_job monitoring restic-b2-init 3600s
