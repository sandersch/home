#!/usr/bin/env bash
# Restore representative vault content from B2. This intentionally does not alter
# the NAS enrollment baseline or validation ledger.
set -Eeuo pipefail
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_not_root
require_sudo
require_tools jq kubectl yq
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this step on minis"
: "${RESTORE_SNAPSHOT:?set RESTORE_SNAPSHOT to the full B2 snapshot ID}"
[[ "$RESTORE_SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] || die "RESTORE_SNAPSHOT must be a full ID"
sudo test -f /mnt/vault/.vault-sentinel || die "unlock /mnt/vault first"
sudo grep -qxF 'vault-contract-version=2' /mnt/vault/.vault-sentinel \
  || die "vault sentinel contract mismatch"
job="restic-vault-b2-restore-${RESTORE_SNAPSHOT:0:12}"
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect it before retrying"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" --from=cronjob/restic-vault-copy --dry-run=client -o yaml >"$manifest"
RESTORE_SNAPSHOT="$RESTORE_SNAPSHOT" yq -y -i '
  .spec.template.spec.containers[0].command = ["/bin/bash", "-c", "/scripts/validate-vault-b2-restore.sh"] |
  .spec.template.spec.containers[0].env += [{"name":"RESTORE_SNAPSHOT","value":env.RESTORE_SNAPSHOT}]
' "$manifest"
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=43200s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true
ok "B2 restore validation passed for $RESTORE_SNAPSHOT"
