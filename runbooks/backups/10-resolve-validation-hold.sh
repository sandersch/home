#!/usr/bin/env bash
# Resolve one vault shrink hold using an exact snapshot ID and an attended decision.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools jq kubectl yq restic
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
  hold_file="/mnt/backups/.control/vault/holds/$HOLD_SNAPSHOT.json"
  [ -f "$hold_file" ] || die "the exact hold is absent"
  hold_lineage="$(sudo jq -er '.lineage' "$hold_file")"
  b2_required=0
  copy_cronjob="$(kubectl -n monitoring get cronjob restic-vault-copy \
    --ignore-not-found -o name)" \
    || die "cannot determine whether the vault B2 copy CronJob exists"
  [ -n "$copy_cronjob" ] && b2_required=1
  if sudo grep -qx 'homelab_backup_repository_enrolled{dataset="vault",destination="b2"} 1' \
    /var/lib/node-exporter/textfile/restic-vault-copy.prom 2>/dev/null; then
    b2_required=1
  fi
  if [ "$b2_required" -eq 1 ]; then
    [ -r /etc/homelab/vault-b2.conf ] \
      || die "vault B2 is enabled but /etc/homelab/vault-b2.conf is absent or unreadable"
    for credential in b2-password b2-key-id b2-application-key; do
      sudo test -s "/mnt/vault/.backup-credentials/$credential" \
        || die "vault B2 is enabled but $credential is absent or unreadable"
    done
    # Prove the held lineage is absent from the destination before allowing the
    # exact source snapshot to be rejected. The in-cluster resolver repeats all
    # source checks; this destination check closes the Phase 4 race explicitly.
    source /etc/homelab/vault-b2.conf
    : "${VAULT_B2_REPOSITORY:?VAULT_B2_REPOSITORY is required}"
    destination_listing="$(mktemp)"
    trap 'rm -f "$destination_listing"' EXIT
    sudo bash -c '
      set -Eeuo pipefail
      AWS_ACCESS_KEY_ID="$(cat /mnt/vault/.backup-credentials/b2-key-id)"
      AWS_SECRET_ACCESS_KEY="$(cat /mnt/vault/.backup-credentials/b2-application-key)"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      export RESTIC_PASSWORD_FILE=/mnt/vault/.backup-credentials/b2-password
      exec restic --no-cache -r "$1" snapshots --json
    ' vault-b2-list "$VAULT_B2_REPOSITORY" \
      | tee "$destination_listing" >/dev/null \
      || die "cannot prove destination absence; refusing rejection"
    if jq -e --arg lineage "$hold_lineage" 'any(.[]; (.original // .id) == $lineage)' "$destination_listing" >/dev/null; then
      die "held lineage exists in B2; refusing rejection"
    else
      [ "$?" -eq 1 ] || die "B2 snapshot listing could not be evaluated"
    fi
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
