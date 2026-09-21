#!/usr/bin/env bash
# Initialize the local vault repository and create one enrollment candidate.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools flock jq kubectl yq
require_backup_yq
exec 9>/tmp/restic-vault-manual-backup.lock
flock -n 9 || die "another attended manual vault backup is running"
cronjob_state="$(kubectl -n monitoring get cronjob restic-vault-backup -o json)"
jq -e '.spec.suspend == true' <<<"$cronjob_state" >/dev/null \
  || die "suspend restic-vault-backup in Flux and reconcile before manual repository work"
if kubectl -n monitoring get jobs -o json | jq -e '
  any(.items[]; (.status.active // 0) > 0 and
    any(.metadata.ownerReferences[]?; .kind == "CronJob" and .name == "restic-vault-backup"))
' >/dev/null; then
  die "a scheduled vault backup is still active"
fi
sudo /usr/local/sbin/vault-unlock
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"

run_job() {
  local name="$1" mode_name="$2"
  local manifest
  manifest="$(mktemp)"
  trap 'rm -f "$manifest"' RETURN
  kubectl -n monitoring create job "$name" \
    --from=cronjob/restic-vault-backup \
    --dry-run=client -o yaml >"$manifest"
  yq -y -i ".spec.template.spec.containers[0].env += [{\"name\": \"$mode_name\", \"value\": \"1\"}]" "$manifest"
  kubectl apply -f "$manifest" >/dev/null
  kubectl -n monitoring wait --for=condition=complete "job/$name" --timeout=7200s \
    || { kubectl -n monitoring logs "job/$name" --all-containers=true || true; die "$name failed"; }
  kubectl -n monitoring logs "job/$name" --all-containers=true
}

for job in restic-vault-init restic-vault-enrollment; do
  kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
    && die "job/$job already exists; inspect and remove it deliberately before retrying"
done

step "Initialize the local vault repository"
run_job restic-vault-init INITIALIZE_REPOSITORY

step "Create the first enrollment candidate"
run_job restic-vault-enrollment INITIAL_ENROLLMENT

snapshot_id="$(kubectl -n monitoring logs job/restic-vault-enrollment | sed -n 's/.*created enrollment candidate \([0-9a-f]\{64\}\).*/\1/p' | tail -n 1)"
[[ "$snapshot_id" =~ ^[0-9a-f]{64}$ ]] || die "could not extract the enrollment snapshot ID"

cat <<EOF

Enrollment candidate: $snapshot_id

Validate that exact snapshot next:
  VAULT_SNAPSHOT=$snapshot_id ./runbooks/backups/06-validate-vault-restore.sh

The CronJob must remain suspended until that restore succeeds.
EOF
