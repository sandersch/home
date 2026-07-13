#!/usr/bin/env bash
# Phase 5 helpers.
#
# Phase 5 starts with backups, then adds observability.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# shellcheck disable=SC2034
PHASE5_MONITORING_DIR="$REPO_ROOT/infrastructure/monitoring"
# shellcheck disable=SC2034
PHASE5_RESTIC_SECRET="$PHASE5_MONITORING_DIR/restic-nas.sops.yaml"
# shellcheck disable=SC2034
PHASE5_ROMM_SECRET="$REPO_ROOT/apps/media/romm/romm.sops.yaml"
# shellcheck disable=SC2034
PHASE5_BACKUP_MOUNT="/mnt/backups"
# shellcheck disable=SC2034
PHASE5_BACKUP_SOURCE="backups.nfs.service.matrix:/mnt/backups"

require_flux_cli() {
  if command -v flux >/dev/null; then
    ok "flux CLI present"
    return 0
  fi
  die "flux CLI is required for Phase 5 validation"
}

assert_phase5_backup_tree() {
  local f
  for f in \
    clusters/minis/monitoring.yaml \
    infrastructure/monitoring/kustomization.yaml \
    infrastructure/monitoring/namespace.yaml \
    infrastructure/monitoring/restic-nas-config.yaml \
    infrastructure/monitoring/restic-nas-cronjob.yaml \
    containers/restic-backup/Containerfile \
    apps/media/romm/mariadb-service.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 5 backup file: $f"
  done
  ok "Phase 5 backup tree is present"
}

assert_phase5_kustomize_builds() {
  local target
  for target in \
    infrastructure/monitoring \
    apps \
    clusters/minis; do
    kustomize build "$REPO_ROOT/$target" >/dev/null
    ok "kustomize build $target"
  done
}

assert_phase5_restic_secret_present() {
  [ -f "$PHASE5_RESTIC_SECRET" ] \
    || die "missing $PHASE5_RESTIC_SECRET; run runbooks/phase5/02-encrypt-restic-secret.sh"
  grep -q '^sops:' "$PHASE5_RESTIC_SECRET" \
    || die "$PHASE5_RESTIC_SECRET is not SOPS-encrypted"
  grep -q 'restic-nas.sops.yaml' "$PHASE5_MONITORING_DIR/kustomization.yaml" \
    || die "$PHASE5_RESTIC_SECRET is not included in infrastructure/monitoring/kustomization.yaml"
  ok "Restic NAS Secret manifest is SOPS-encrypted and included"
}

wait_for_job() {
  local namespace="$1" job="$2" timeout="${3:-3600s}"
  local timeout_seconds deadline complete failed

  timeout_seconds="${timeout%s}"
  [ "$timeout_seconds" != "$timeout" ] || die "wait_for_job timeout must be in seconds, got: $timeout"
  deadline=$((SECONDS + timeout_seconds))

  while [ "$SECONDS" -lt "$deadline" ]; do
    complete="$(kubectl -n "$namespace" get "job/$job" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed="$(kubectl -n "$namespace" get "job/$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [ "$complete" = "True" ]; then
      ok "job/$job completed"
      kubectl -n "$namespace" logs "job/$job" --all-containers=true --tail=120
      return 0
    fi
    if [ "$failed" = "True" ]; then
      warn "job/$job failed; recent logs follow"
      kubectl -n "$namespace" logs "job/$job" --all-containers=true --tail=200 || true
      kubectl -n "$namespace" describe "job/$job" || true
      return 1
    fi
    sleep 5
  done

  warn "job/$job did not complete before $timeout; recent logs follow"
  kubectl -n "$namespace" logs "job/$job" --all-containers=true --tail=200 || true
  kubectl -n "$namespace" describe pod -l "job-name=$job" || true
  kubectl -n "$namespace" describe "job/$job" || true
  return 1
}
