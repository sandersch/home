#!/usr/bin/env bash
# Enroll the encrypted vault repository in its dedicated B2 destination.
# The attended operation runs inside the pinned Restic container on minis; no
# host Restic installation is required. Credentials are entered through an
# interactive kubectl exec and never enter a Secret, manifest, argv, or history.
set -Eeuo pipefail
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools jq kubectl yq
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this step on minis"
sudo test -f /etc/homelab/vault-b2.conf \
  || die "install /etc/homelab/vault-b2.conf with VAULT_B2_REPOSITORY first"
source /etc/homelab/vault-b2.conf
: "${VAULT_B2_REPOSITORY:?VAULT_B2_REPOSITORY is required}"
sudo test -f /mnt/vault/.vault-sentinel \
  || die "unlock and mount /mnt/vault before enrollment"
sudo grep -qxF 'vault-contract-version=2' /mnt/vault/.vault-sentinel \
  || die "vault sentinel contract mismatch"
sudo test -f /mnt/backups/vault/config || die "vault NAS repository is not initialized"

for cronjob in restic-vault-copy restic-vault-prune; do
  suspend="$(kubectl -n monitoring get cronjob "$cronjob" -o jsonpath='{.spec.suspend}')" \
    || die "cannot inspect $cronjob"
  [ "$suspend" = true ] || die "$cronjob must remain suspended during enrollment"
done

job=restic-vault-b2-enroll
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect it before retrying"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" --from=cronjob/restic-vault-copy \
  --dry-run=client -o yaml >"$manifest"
yq -y -i '
  .spec.backoffLimit = 0 |
  .spec.activeDeadlineSeconds = 3600 |
  .spec.template.spec.containers[0].command = ["/bin/bash", "-c", "sleep 3600"] |
  .spec.template.spec.containers[0].volumeMounts |= map(
    if .name == "vault" or .name == "host-config" then .readOnly = false else . end
  )
' "$manifest"
kubectl apply -f "$manifest" >/dev/null

deadline=$((SECONDS + 180))
while :; do
  pod="$(kubectl -n monitoring get pods -l job-name="$job" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$pod" ]; then break; fi
  [ "$SECONDS" -lt "$deadline" ] || die "enrollment pod did not start"
  sleep 2
done
kubectl -n monitoring wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null \
  || die "enrollment pod did not become ready; inspect pod/$pod"

set +e
kubectl -n monitoring exec -it "$pod" -- /bin/bash /scripts/enroll-vault-b2.sh
result=$?
set -e
if [ "$result" -ne 0 ]; then
  kubectl -n monitoring logs "$pod" --all-containers=true || true
  die "container enrollment failed; job/$job was retained for inspection"
fi

kubectl -n monitoring delete job "$job" --wait=true >/dev/null
ok "vault B2 repository initialized inside the pinned Restic container; leave recurring schedules suspended until seed and restore gates pass"
