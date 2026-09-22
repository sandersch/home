#!/usr/bin/env bash
# Run one serialized vault backup including the Frigate ingestion init container.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_not_root
require_sudo
require_tools flock jq kubectl
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this manual backup on minis"
[ -t 0 ] || die "manual vault backup requires an attended TTY"
exec 9>/tmp/restic-vault-manual-backup.lock
flock -n 9 || die "another attended manual vault backup is running"

cronjob="$(kubectl -n monitoring get cronjob restic-vault-backup -o json)" \
  || die "cannot inspect the vault backup CronJob"
jq -e '.spec.suspend == true' <<<"$cronjob" >/dev/null \
  || die "suspend restic-vault-backup in Git and reconcile before this manual run"
# Scheduled Jobs need not inherit CronJob/Pod labels. Also recognize manual
# Jobs from earlier versions of this runbook by their stable name prefix.
assert_no_outstanding_backups() {
  local outstanding
  outstanding="$(kubectl -n monitoring get jobs -o json | jq -r '
    [.items[]
     | select(any(.metadata.ownerReferences[]?;
         .kind == "CronJob" and .name == "restic-vault-backup")
       or (.metadata.name | startswith("restic-vault-manual-"))
       or .metadata.labels["app.kubernetes.io/name"] == "restic-vault-backup")
     | select(any(.status.conditions[]?;
         (.type == "Complete" or .type == "Failed") and .status == "True") | not)
     | .metadata.name] | join(" ")')" \
    || die "cannot inspect outstanding vault backup Jobs"
  [ -z "$outstanding" ] || die "vault backup Jobs are still outstanding: $outstanding"
}
assert_no_outstanding_backups

job="restic-vault-manual-$(date -u +%Y%m%d%H%M%S)"
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; choose another attended run ID"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl -n monitoring create job "$job" --from=cronjob/restic-vault-backup \
  --dry-run=client -o yaml >"$manifest"
yq -y -i 'del(.metadata.ownerReferences)' "$manifest"
cat <<EOF
Job: $job
This run retains the ingestion init container and read-only Frigate source mount.
EOF
read -r -p 'Type RUN-VAULT-BACKUP to continue: ' confirmation
[ "$confirmation" = RUN-VAULT-BACKUP ] || die "confirmation did not match"
sudo /usr/local/sbin/vault-unlock
assert_no_outstanding_backups
kubectl apply -f "$manifest" >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=7200s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true
ok "manual vault backup completed with Frigate ingestion"
