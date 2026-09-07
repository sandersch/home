#!/usr/bin/env bash
# Seed every validated NAS vault lineage into the newly enrolled B2 repository.
# Keep the recurring copy CronJob suspended until the seed and restore gates pass.
set -Eeuo pipefail
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools jq kubectl yq
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this step on minis"

sudo /usr/local/sbin/vault-unlock
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"
sudo test -f /mnt/vault/.vault-sentinel || die "vault sentinel is absent"
sudo grep -qxF 'vault-contract-version=2' /mnt/vault/.vault-sentinel \
  || die "vault sentinel contract mismatch"

suspend="$(kubectl -n monitoring get cronjob restic-vault-copy -o jsonpath='{.spec.suspend}')" \
  || die "cannot inspect restic-vault-copy"
[ "$suspend" = true ] || die "restic-vault-copy must remain suspended during the attended seed"

job=restic-vault-b2-seed
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect it before retrying"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" \
  --from=cronjob/restic-vault-copy \
  --dry-run=client -o yaml >"$manifest"
yq -y -i '
  .spec.backoffLimit = 0 |
  .spec.activeDeadlineSeconds = 86400 |
  .spec.template.spec.containers[0].env |= map(
    if .name == "RESTIC_LOCK_RETRY" then .value = "12h" else . end
  )
' "$manifest"
kubectl apply -f "$manifest" >/dev/null
deadline=$((SECONDS + 90000))
while :; do
  status="$(kubectl -n monitoring get job "$job" -o json)" || die "cannot inspect $job"
  if jq -e '(.status.failed // 0) > 0' <<<"$status" >/dev/null; then
    kubectl -n monitoring logs "job/$job" --all-containers=true || true
    die "$job failed"
  fi
  if jq -e '(.status.succeeded // 0) > 0' <<<"$status" >/dev/null; then break; fi
  [ "$SECONDS" -lt "$deadline" ] || die "$job did not reach a terminal state before the timeout"
  sleep 10
done
kubectl -n monitoring logs "job/$job" --all-containers=true
ok "B2 vault seed completed; validate a destination snapshot before activation"
