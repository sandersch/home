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
[ -t 0 ] || die "semantic restore validation requires an attended TTY"
sudo /usr/local/sbin/vault-unlock
sudo test -f /mnt/vault/.vault-sentinel || die "unlock /mnt/vault first"
sudo grep -qxF 'vault-contract-version=2' /mnt/vault/.vault-sentinel \
  || die "vault sentinel contract mismatch"
job="restic-vault-b2-restore-${RESTORE_SNAPSHOT:0:12}"
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect it before retrying"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" --from=cronjob/restic-vault-copy --dry-run=client -o yaml >"$manifest"
RESTORE_SNAPSHOT="$RESTORE_SNAPSHOT" \
RESTORE_DOCUMENT_PATH="${RESTORE_DOCUMENT_PATH:-}" \
RESTORE_PHOTO_PATH="${RESTORE_PHOTO_PATH:-}" yq -y -i '
  del(.metadata.ownerReferences) |
  .spec.activeDeadlineSeconds = 86400 |
  (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "vault")).readOnly = false |
  .spec.template.spec.containers[0].command = ["/bin/bash", "-c", "/scripts/validate-vault-b2-restore.sh"] |
  .spec.template.spec.containers[0].env += [{"name":"RESTORE_SNAPSHOT","value":env.RESTORE_SNAPSHOT},
    {"name":"RESTORE_DOCUMENT_PATH","value":env.RESTORE_DOCUMENT_PATH},
    {"name":"RESTORE_PHOTO_PATH","value":env.RESTORE_PHOTO_PATH}]
' "$manifest"
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=90000s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true
cat <<EOF
The full B2 data check passed. Restored artifacts remain in the encrypted scratch
path printed above. Open the restored KDBX in Strongbox, open and inspect the
restored document, and decode/view the restored photo. Verify expected content.
Do not confirm if any artifact is unusable. No semantic success is recorded yet.
EOF
read -r -p 'After inspecting all three artifacts, type the full snapshot ID: ' confirmation
[ "$confirmation" = "$RESTORE_SNAPSHOT" ] || die "inspection not confirmed; artifacts retained without advancing success"
sudo bash -s <<'ROOT'
set -Eeuo pipefail
metric=/var/lib/node-exporter/textfile/restic-vault-b2-restore.prom
tmp="$(mktemp "${metric}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf 'homelab_restic_restore_drill_timestamp_seconds{dataset="vault",destination="b2"} %s\n' "$(date +%s)" >"$tmp"
chown root:65534 "$tmp"
chmod 0640 "$tmp"
mv -f "$tmp" "$metric"
ROOT
ok "B2 semantic restore confirmed for $RESTORE_SNAPSHOT; retain artifacts until validation evidence is recorded"
printf '%s\n' "The separate off-host restore using only the break-glass card is still required for Phase 4 activation."
