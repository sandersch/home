#!/usr/bin/env bash
# Run the first monthly verification and enable the validated recurring schedules in git.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools flux kubectl yq
[ "$(hostname -s)" = minis ] || die "run this step on minis"
sudo /usr/local/sbin/vault-unlock

vault_metrics=/var/lib/node-exporter/textfile/restic-vault.prom
ingest_metrics=/var/lib/node-exporter/textfile/vault-ingestion.prom
sudo grep -qx 'homelab_backup_repository_enrolled{dataset="vault",destination="nas"} 1' "$vault_metrics" \
  || die "vault repository enrollment metric is not present"
sudo grep -q 'homelab_vault_ingestion_timestamp_seconds{kind="strongbox",host="ryze",stage="promotion"} [1-9]' "$ingest_metrics" \
  || die "Strongbox promotion has not succeeded"
sudo grep -q 'homelab_vault_ingestion_timestamp_seconds{kind="documents",host="ryze",stage="promotion"} [1-9]' "$ingest_metrics" \
  || die "the attended ryze documents seed has not succeeded"

for drill_job in restic-vault-locked-drill restic-appstate-vault-locked-drill \
  restic-vault-post-lock-drill; do
  [ "$(kubectl -n monitoring get job "$drill_job" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] \
    || die "job/$drill_job has not completed successfully"
done

confirm "Are both sealed break-glass records complete, verified, and in their two locations?" \
  || die "break-glass completion is an activation gate"
confirm "Did the restored KDBX open successfully in Strongbox with its master password?" \
  || die "the semantic Strongbox restore is an activation gate"

job=restic-verify-enrollment
kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
  && die "job/$job already exists; inspect and remove it deliberately before retrying"
kubectl -n monitoring create job "$job" --from=cronjob/restic-verify >/dev/null
kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=43200s \
  || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
kubectl -n monitoring logs "job/$job" --all-containers=true

for metric in \
  restic-check-appstate-nas.prom \
  restic-check-appstate-b2.prom \
  restic-check-vault-nas.prom; do
  sudo test -s "/var/lib/node-exporter/textfile/$metric" \
    || die "monthly verification did not produce $metric"
done

yq -i '.spec.suspend = false' \
  "$REPO_ROOT/infrastructure/monitoring/restic-vault-cronjob.yaml" \
  "$REPO_ROOT/infrastructure/monitoring/restic-verify-cronjob.yaml"

cat <<'EOF'

The recurring vault backup and monthly verification schedules are enabled in the
working tree. Review, commit, and push this activation change, then run:

  flux resume kustomization monitoring-controllers
  flux resume kustomization monitoring-configs
  flux resume kustomization monitoring
  flux reconcile kustomization monitoring-controllers --with-source
  flux reconcile kustomization monitoring-configs --with-source
  flux reconcile kustomization monitoring --with-source

Confirm both CronJobs are unsuspended and Flux reports no drift.
EOF
