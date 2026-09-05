#!/usr/bin/env bash
# Restore one exact vault enrollment candidate and establish baseline generation 1.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools kubectl yq
require_backup_yq
: "${VAULT_SNAPSHOT:?set VAULT_SNAPSHOT to the full ID printed by 05-init-and-backup-vault.sh}"
[[ "$VAULT_SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] \
  || die "VAULT_SNAPSHOT must be a full 64-character lowercase Restic ID"

job=restic-vault-restore
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect and remove it deliberately before retrying"

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" \
  --from=cronjob/restic-vault-backup \
  --dry-run=client -o yaml >"$manifest"
yq -y -i '
  .spec.template.spec.containers[0].command =
    ["/bin/bash", "-c", "/guards/assert-backups-mount.sh && exec /scripts/validate-vault-restore.sh"] |
  .spec.template.spec.containers[0].env +=
    [{"name": "RESTORE_SNAPSHOT", "value": env.VAULT_SNAPSHOT}] |
  (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "vault")).readOnly = false
' "$manifest"
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=7200s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true

cat <<EOF

Automated restore validation passed. From ryze, stream the restored KDBX into a
memory-backed file, open it in Strongbox with the master password, then remove it:

  restored=/run/user/\$(id -u)/ccs-restored-$VAULT_SNAPSHOT.kdbx
  ssh charlie@10.137.20.5 "sudo cat '/mnt/vault/.restore-tests/$VAULT_SNAPSHOT/data/vault/credentials/strongbox/ccs.kdbx'" >"\$restored"
  # Open \$restored in Strongbox, then:
  rm -f "\$restored"

After that manual semantic check, remove only the named restore tree and completed Jobs.
Do not enable the recurring CronJob until the break-glass records are also verified.
EOF
