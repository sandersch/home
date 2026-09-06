#!/usr/bin/env bash
# Resolve one vault shrink hold using an exact snapshot ID and an attended decision.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools jq kubectl yq
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this step on minis"
: "${HOLD_SNAPSHOT:?set HOLD_SNAPSHOT to the full held Restic ID}"
: "${HOLD_ACTION:?set HOLD_ACTION to reject or accept}"
[[ "$HOLD_SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] \
  || die "HOLD_SNAPSHOT must be a full 64-character lowercase Restic ID"
[ "$HOLD_ACTION" = reject ] || [ "$HOLD_ACTION" = accept ] \
  || die "HOLD_ACTION must be reject or accept"

sudo /usr/local/sbin/vault-unlock
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"

if [ "$HOLD_ACTION" = reject ]; then
  if kubectl -n monitoring get cronjob restic-vault-copy >/dev/null 2>&1; then
    die "vault B2 replication exists; this Phase 1 resolver cannot prove destination absence"
  fi
  resolution_reason="rejected"
else
  read -r -p 'Why is this shrink intentional? ' resolution_reason
  [ -n "$resolution_reason" ] || die "an acceptance reason is required"
fi

cat <<EOF
Action:   $HOLD_ACTION
Snapshot: $HOLD_SNAPSHOT
Reason:   $resolution_reason

Reject forgets only this exact local snapshot and prunes its now-unreferenced data.
Accept revalidates the exact snapshot and starts a new baseline generation.
EOF
read -r -p 'Type the full snapshot ID to continue: ' confirmation
[ "$confirmation" = "$HOLD_SNAPSHOT" ] || die "snapshot confirmation did not match"

job="restic-vault-hold-${HOLD_ACTION}-${HOLD_SNAPSHOT:0:12}"
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect and remove it deliberately before retrying"

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" \
  --from=cronjob/restic-vault-backup \
  --dry-run=client -o yaml >"$manifest"
HOLD_SNAPSHOT="$HOLD_SNAPSHOT" \
HOLD_ACTION="$HOLD_ACTION" \
HOLD_OPERATOR="$(id -un)@$(hostname -s)" \
HOLD_REASON="$resolution_reason" \
yq -y -i '
  .spec.template.spec.containers[0].command =
    ["/bin/bash", "-c", "/guards/assert-backups-mount.sh && exec /scripts/resolve-validation-hold.sh"] |
  .spec.template.spec.containers[0].env += [
    {"name": "HOLD_SNAPSHOT", "value": env.HOLD_SNAPSHOT},
    {"name": "HOLD_ACTION", "value": env.HOLD_ACTION},
    {"name": "HOLD_OPERATOR", "value": env.HOLD_OPERATOR},
    {"name": "HOLD_REASON", "value": env.HOLD_REASON}
  ]
' "$manifest"
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=43200s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true
ok "hold $HOLD_SNAPSHOT was resolved as $HOLD_ACTION"
