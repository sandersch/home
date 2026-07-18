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
PHASE5_RESTIC_B2_SECRET="$PHASE5_MONITORING_DIR/restic-b2.sops.yaml"
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
    infrastructure/monitoring/restic-b2-cronjob.yaml \
    containers/restic-backup/Containerfile \
    apps/media/romm/mariadb-service.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 5 backup file: $f"
  done
  ok "Phase 5 backup tree is present"
}

assert_phase5_backup_invariants() {
  local rendered="$1"

  kustomize build "$PHASE5_MONITORING_DIR" >"$rendered"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-nas-backup") |
    .spec.schedule == "15 3 * * *" and
    .spec.timeZone == "America/Chicago" and
    .spec.suspend != true and
    .spec.jobTemplate.spec.activeDeadlineSeconds == 3600' "$rendered" >/dev/null \
    || die "NAS CronJob schedule or deadline changed unexpectedly"
  yq -e 'select(.kind == "ConfigMap" and .metadata.name == "restic-nas-config") |
    .data.RESTIC_REPOSITORY == "/repo/nas/opt" and
    .data.RESTIC_TARGET_TAG == "nas" and
    .data.RESTIC_KEEP_DAILY == "14" and
    .data.RESTIC_KEEP_WEEKLY == "8" and
    .data.RESTIC_KEEP_MONTHLY == "12"' "$rendered" >/dev/null \
    || die "NAS repository, tag, or retention policy changed unexpectedly"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-nas-backup") |
    any(.spec.jobTemplate.spec.template.spec.volumes[];
      .name == "backups" and .hostPath.path == "/mnt/backups")' "$rendered" >/dev/null \
    || die "NAS CronJob no longer mounts /mnt/backups"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-b2-backup") |
    .spec.schedule == "30 4 * * 0" and
    .spec.timeZone == "America/Chicago" and
    .spec.suspend == false and
    .spec.concurrencyPolicy == "Forbid" and
    .spec.jobTemplate.spec.backoffLimit == 0 and
    .spec.jobTemplate.spec.activeDeadlineSeconds == 21600 and
    ([.spec.jobTemplate.spec.template.spec.volumes[] | select(has("hostPath")) | .hostPath.path] | index("/mnt/backups") | not)' "$rendered" >/dev/null \
    || die "B2 CronJob schedule, safety settings, or volume independence is incorrect"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-b2-backup") |
    (.spec.jobTemplate.spec.template.spec.containers[0].env |
      from_entries |
      .RESTIC_TARGET_TAG == "b2" and
      .RESTIC_KEEP_DAILY == "" and
      .RESTIC_KEEP_WEEKLY == "8" and
      .RESTIC_KEEP_MONTHLY == "12")' "$rendered" >/dev/null \
    || die "B2 target tag or weekly/monthly retention policy is incorrect"
  grep -Fq -- "--tag \"\$target_tag\"" "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not apply the selected target tag"
  grep -Fq -- "\"\${retention_args[@]}\"" "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not build retention arguments dynamically"
  if grep -Fq -- "-newer \"\$HA_MARKER\"" "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml"; then
    die "shared Restic backup script still uses timestamp-based Home Assistant artifact detection"
  fi
  grep -Fq -- "home_assistant_backup_set_has_new_file \"\$HA_BACKUPS_BEFORE\" \"\$HA_BACKUPS_AFTER\"" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not compare Home Assistant backup filename sets"
  ok "NAS and B2 backup invariants are intact"
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

assert_phase5_restic_b2_secret_present() {
  [ -f "$PHASE5_RESTIC_B2_SECRET" ] \
    || die "missing $PHASE5_RESTIC_B2_SECRET; run runbooks/phase5/06-encrypt-restic-b2-secret.sh"
  grep -q '^sops:' "$PHASE5_RESTIC_B2_SECRET" \
    || die "$PHASE5_RESTIC_B2_SECRET is not SOPS-encrypted"
  grep -q 'restic-b2.sops.yaml' "$PHASE5_MONITORING_DIR/kustomization.yaml" \
    || die "$PHASE5_RESTIC_B2_SECRET is not included in infrastructure/monitoring/kustomization.yaml"
  ok "Restic B2 Secret manifest is SOPS-encrypted and included"
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
