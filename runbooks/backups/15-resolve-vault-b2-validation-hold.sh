#!/usr/bin/env bash
# Revalidate one exact B2 snapshot whose destination ledger evidence is missing.
set -Eeuo pipefail
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools jq kubectl yq
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this step on minis"
: "${B2_HOLD_SNAPSHOT:?set B2_HOLD_SNAPSHOT to the full B2 snapshot ID}"
HOLD_OPERATOR="$(id -un)@$(hostname -s)"
[[ "$B2_HOLD_SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] \
  || die "B2_HOLD_SNAPSHOT must be a full 64-character lowercase ID"
[ -t 0 ] || die "B2 hold resolution requires an attended TTY"

sudo /usr/local/sbin/vault-unlock
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"
hold_file="/mnt/backups/.control/vault-b2/holds/$B2_HOLD_SNAPSHOT.json"
sudo test -f "$hold_file" || die "the exact B2 hold is absent"
hold_lineage="$(sudo jq -er '.lineage' "$hold_file")"

cat <<EOF
This will revalidate exactly one B2 snapshot and, only after successful validation,
record its lineage in the destination ledger and remove its hold.

Snapshot: $B2_HOLD_SNAPSHOT
Lineage:  $hold_lineage
EOF
read -r -p 'Type the full B2 snapshot ID to continue: ' confirmation
[ "$confirmation" = "$B2_HOLD_SNAPSHOT" ] || die "snapshot confirmation did not match"

job=restic-vault-b2-validation-hold
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect and remove it deliberately before retrying"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" \
  --from=cronjob/restic-vault-copy \
  --dry-run=client -o yaml >"$manifest"
B2_HOLD_SNAPSHOT="$B2_HOLD_SNAPSHOT" \
HOLD_OPERATOR="$HOLD_OPERATOR" \
yq -y -i '
  .spec.template.spec.containers[0].command =
    ["/bin/bash", "-c", "/guards/assert-backups-mount.sh && exec /scripts/resolve-vault-b2-validation-hold.sh"] |
  .spec.template.spec.containers[0].env += [
    {"name":"B2_HOLD_SNAPSHOT","value":env.B2_HOLD_SNAPSHOT},
    {"name":"HOLD_OPERATOR","value":env.HOLD_OPERATOR}
  ]
' "$manifest"
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=43200s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true
ok "B2 validation hold resolved for $B2_HOLD_SNAPSHOT"
