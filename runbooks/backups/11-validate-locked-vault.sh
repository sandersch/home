#!/usr/bin/env bash
# Prove locked-vault skips, ingestion failure, and appstate independence before activation.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools cryptsetup jq kubectl lsattr mountpoint systemctl
[ "$(hostname -s)" = minis ] || die "run this step on minis"
[ -t 0 ] || die "the locked-vault drill requires an attended TTY"

sudo /usr/local/sbin/vault-unlock
assert_direct_mount_layout "$BACKUPS_MOUNT" "$BACKUPS_SOURCE" "$BACKUPS_UUID"
sudo grep -qx 'homelab_backup_repository_enrolled{dataset="vault",destination="nas"} 1' \
  /var/lib/node-exporter/textfile/restic-vault.prom \
  || die "complete vault enrollment and restore validation first"

for cronjob in restic-vault-backup restic-verify; do
  [ "$(kubectl -n monitoring get cronjob "$cronjob" -o jsonpath='{.spec.suspend}')" = true ] \
    || die "$cronjob must still be suspended for this pre-activation drill"
done
active_jobs="$(kubectl -n monitoring get jobs -o json | jq -r '
  [.items[] | select((.status.active // 0) > 0) | .metadata.name] | join(" ")
')"
[ -z "$active_jobs" ] || die "active monitoring Jobs remain: $active_jobs"

create_drill_job() {
  local name="$1" source_cronjob="$2"
  # These are durable validation records. Remove the CronJob owner reference so
  # successfulJobsHistoryLimit cannot delete the earlier locked-vault record
  # when the later post-unlock record completes.
  kubectl -n monitoring create job "$name" \
    --from="cronjob/$source_cronjob" \
    --dry-run=client -o json \
    | jq 'del(.metadata.ownerReferences)' \
    | kubectl apply -f - >/dev/null
}

cat <<'EOF'
This drill deliberately unmounts and closes /mnt/vault. The existing appstate backup
will run while it is locked, and the vault job must skip cleanly without writing to
the uncovered mountpoint. The drill unlocks the vault again before it completes.
EOF
confirm "Run the attended locked-vault drill now?" || die "drill was not confirmed"

for job in restic-vault-locked-drill restic-appstate-vault-locked-drill \
  restic-vault-post-lock-drill; do
  kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
    && die "job/$job already exists; inspect and remove it deliberately before retrying"
done

step "Lock the vault and validate the uncovered mountpoint"
sudo systemctl stop vault-ingest-promote.path
sudo umount /mnt/vault
sudo cryptsetup close vault
sudo /usr/local/sbin/vault-mountpoint-guard
[ "$(sudo stat -c '%U:%G:%a' /mnt/vault)" = root:root:555 ] \
  || die "uncovered vault mountpoint metadata is invalid"
sudo lsattr -d /mnt/vault | awk '{print $1}' | grep -q i \
  || die "uncovered vault mountpoint is not immutable"
[ -z "$(sudo find /mnt/vault -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || die "uncovered vault mountpoint contains data"

step "Prove the vault backup skips without touching a credential or repository"
create_drill_job restic-vault-locked-drill restic-vault-backup
kubectl -n monitoring wait --for=condition=complete \
  job/restic-vault-locked-drill --timeout=600s \
  || { kubectl -n monitoring logs job/restic-vault-locked-drill --all-containers=true || true; die "locked vault job failed"; }
kubectl -n monitoring logs job/restic-vault-locked-drill --all-containers=true \
  | grep -q 'vault is locked; skipping' \
  || die "vault job did not report its locked skip"
sudo grep -qx 'homelab_vault_backup_locked 1' \
  /var/lib/node-exporter/textfile/restic-vault.prom \
  || die "locked-vault metric was not exported"
[ -z "$(sudo find /mnt/vault -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || die "the locked vault job wrote below the bare mountpoint"

cat <<'EOF'
On ryze, run this now and confirm it fails rather than uploading:

  systemctl --user start vault-ingest-kdbx.service
  systemctl --user --no-pager --full status vault-ingest-kdbx.service
EOF
confirm "Did the ryze upload fail while the vault was locked?" \
  || die "locked ingestion rejection was not confirmed"
[ -z "$(sudo find /mnt/vault -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || die "the rejected upload wrote below the bare mountpoint"

step "Prove the production appstate pipeline remains independent"
create_drill_job restic-appstate-vault-locked-drill restic-nas-backup
kubectl -n monitoring wait --for=condition=complete \
  job/restic-appstate-vault-locked-drill --timeout=7200s \
  || { kubectl -n monitoring logs job/restic-appstate-vault-locked-drill --all-containers=true || true; die "appstate backup failed while vault was locked"; }
kubectl -n monitoring logs job/restic-appstate-vault-locked-drill --all-containers=true

step "Unlock and prove the next vault backup resumes normally"
sudo /usr/local/sbin/vault-unlock
create_drill_job restic-vault-post-lock-drill restic-vault-backup
kubectl -n monitoring wait --for=condition=complete \
  job/restic-vault-post-lock-drill --timeout=7200s \
  || { kubectl -n monitoring logs job/restic-vault-post-lock-drill --all-containers=true || true; die "post-unlock vault backup failed"; }
kubectl -n monitoring logs job/restic-vault-post-lock-drill --all-containers=true
sudo grep -qx 'homelab_vault_backup_locked 0' \
  /var/lib/node-exporter/textfile/restic-vault.prom \
  || die "post-unlock vault metric did not recover"
ok "locked-vault degradation and both independent backup paths passed"
