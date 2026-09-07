#!/usr/bin/env bash
# Restore one exact v2 vault snapshot and hash every photo against the live source.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_not_root
require_sudo
require_tools kubectl yq
require_backup_yq
: "${VAULT_SNAPSHOT:?set VAULT_SNAPSHOT to the full v2 snapshot ID}"
[[ "$VAULT_SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] || die "VAULT_SNAPSHOT must be a full ID"
job=restic-vault-photo-restore
kubectl -n monitoring get job "$job" >/dev/null 2>&1 && die "job/$job already exists"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" --from=cronjob/restic-vault-backup --dry-run=client -o yaml >"$manifest"
yq -y -i '.spec.template.spec.containers[0].command = ["/bin/bash", "-c", "/guards/assert-backups-mount.sh && exec /scripts/validate-vault-photos.sh"] | .spec.template.spec.containers[0].env += [{"name":"PHOTO_SNAPSHOT","value":env.VAULT_SNAPSHOT}] | .spec.template.spec.containers[0].securityContext.capabilities.add += ["CHOWN", "FOWNER"]' "$manifest"
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=7200s || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "photo restore failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true
cat <<EOF

Photo restore validation passed. Remove only this exact restore tree after inspection:
  ssh charlie@10.137.20.5 "sudo rm -rf -- '/mnt/vault/.restore-tests/photos-$VAULT_SNAPSHOT'"
EOF
