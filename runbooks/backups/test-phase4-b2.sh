#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repo_root" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
copy = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-copy-config.yaml').read_text())
prune = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-prune-config.yaml').read_text())
vault = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-config.yaml').read_text())
copy_job = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-copy-cronjob.yaml').read_text())
prune_job = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-prune-cronjob.yaml').read_text())
alerts = (root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text()
kustomization = (root / 'infrastructure/monitoring/kustomization.yaml').read_text()

copy_script = copy['data']['copy-vault.sh']
prune_script = prune['data']['prune-vault.sh']
assert vault['data']['detect-vault-exclusions.jq'] == copy['data']['detect-vault-exclusions.jq'] == prune['data']['detect-vault-exclusions.jq']
retry_wrapper = 'restic() { command restic --retry-lock "$restic_lock_retry" "$@"; }'
assert retry_wrapper in copy_script
assert retry_wrapper in prune_script
assert retry_wrapper in vault['data']['validate-vault-snapshot.sh']
assert retry_wrapper in vault['data']['backup-vault.sh']
restore_script = copy['data']['validate-vault-b2-restore.sh']
destination_resolver = copy['data']['resolve-vault-b2-validation-hold.sh']
resolver_wrapper = (root / 'runbooks/backups/10-resolve-validation-hold.sh').read_text()
assert 'restic copy --from-repo "$source_repo" "$snapshot_id"' in copy_script
assert 'restic stats --json --mode raw-data' in copy_script
assert 'restic stats --json --mode restore-size' not in copy_script
assert '/vault-scripts/validate-vault-snapshot.sh "$destination_id"' in copy_script
assert '/vault-scripts/validate-vault-snapshot.sh "$snapshot_id"' in copy_script
assert 'original // .id' in copy_script and 'validated.jsonl' in copy_script
assert 'RESTIC_FROM_PASSWORD_FILE=/data/vault/.backup-credentials/nas-password' in copy_script
assert 'RESTIC_PASSWORD_FILE=/data/vault/.backup-credentials/nas-password' in copy_script
assert 'vault is locked; skipping B2 replication' in copy_script
assert 'newer eligible lineages were processed' in copy_script
assert '[ "$missing_count" -eq 0 ] || die "$missing_count vault snapshot(s) were not eligible for replication"' not in copy_script
assert 'restic -r "$source_repo" forget --group-by host "${source_candidates[@]}"' in prune_script
assert 'RESTIC_PASSWORD_FILE=/data/vault/.backup-credentials/nas-password' in prune_script
assert 'restic -r "$VAULT_B2_REPOSITORY" forget --group-by host "${destination_candidates[@]}"' in prune_script
assert 'collect_candidates "$source_repo"' in prune_script
assert 'collect_candidates "$VAULT_B2_REPOSITORY"' in prune_script
assert 'if ! RESTIC_PASSWORD_FILE="$password_file" restic -r "$repo" forget --dry-run --json' in prune_script
assert 'if ! jq -s -r' in prune_script
assert 'error("unexpected restic forget JSON shape")' in prune_script
assert 'mapfile -t source_candidates < /work/source-candidates' in prune_script
assert 'mapfile -t destination_candidates < /work/destination-candidates' in prune_script
assert 'mapfile -t source_candidates < <(restic' not in prune_script
assert 'message_type == "forget"' in prune_script
assert 'unreplicated source removal candidate' in prune_script
assert '[ $((now - latest_source_time)) -le 28800 ]' in prune_script
assert 'latest NAS snapshot is older than the eight-hour backup freshness tolerance' in prune_script
assert 'maximum_shrink_percent="$(jq -er' in prune_script
assert 'baseline_files * 80 / 100' not in prune_script and 'baseline_bytes * 80 / 100' not in prune_script
assert 'latest NAS snapshot is below the healthy baseline tolerance' in prune_script
assert 'latest NAS snapshot is absent from the validation ledger' in prune_script
assert '/vault-scripts/validate-vault-snapshot.sh "$latest_source_id"' in prune_script
assert 'vault sentinel UUID mismatch' in prune_script
assert 'vault backup credential directory ownership or mode is invalid' in prune_script
assert '/vault-scripts/validate-vault-snapshot.sh "$RESTORE_SNAPSHOT"' in restore_script
assert 'hold_destination "$destination_id" "$lineage"' in copy_script
assert 'homelab_restic_validation_hold{dataset="vault",destination="b2"}' in copy_script
assert 'the exact B2 hold is absent' in destination_resolver
assert '/vault-scripts/validate-vault-snapshot.sh "$B2_HOLD_SNAPSHOT"' in destination_resolver
assert 'destination_control/validated.jsonl' in destination_resolver
assert 'runbooks/backups/15-resolve-vault-b2-validation-hold.sh' in (root / 'docs/backups.md').read_text()
assert '15-resolve-vault-b2-validation-hold.sh' in (root / 'runbooks/backups/README.md').read_text()
assert 'homelab_restic_validation_hold{dataset="vault"} > 0' in alerts
assert 'copy_cronjob="$(kubectl -n monitoring get cronjob restic-vault-copy' in resolver_wrapper
assert '--ignore-not-found -o name' in resolver_wrapper
assert 'b2_required=1' in resolver_wrapper
assert 'restic-vault-copy.prom' in resolver_wrapper
assert 'vault B2 is enabled but /etc/homelab/vault-b2.conf is absent or unreadable' in resolver_wrapper
assert 'cannot prove destination absence; refusing rejection' in resolver_wrapper
assert '| tee "$destination_listing" >/dev/null' in resolver_wrapper
assert copy_job['spec']['suspend'] is True
assert prune_job['spec']['suspend'] is True
assert copy_job['spec']['schedule'] == '45 4 * * *'
assert prune_job['spec']['schedule'] == '30 1 * * 0'
mounts = prune_job['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['volumeMounts']
assert {m['name'] for m in mounts} >= {'vault-scripts', 'contract'}
assert 'restic-vault-copy-config.yaml' in kustomization
assert 'restic-vault-copy-cronjob.yaml' in kustomization
assert 'restic-vault-prune-config.yaml' in kustomization
assert 'restic-vault-prune-cronjob.yaml' in kustomization
assert 'ResticVaultCopyOverdue' in alerts
assert 'ResticPruneFailed' in alerts
assert 'restic-vault-prune-.*' in alerts
assert 'kube_cronjob_spec_suspend{namespace="monitoring",cronjob="restic-vault-prune"}' in alerts
assert 'kube_cronjob_status_last_schedule_time{namespace="monitoring",cronjob="restic-vault-prune"}' in alerts
assert 'homelab_restic_unreplicated_candidates{dataset="vault",destination="nas"} > 0' in alerts
assert 'ResticVaultCopySuspended' not in alerts
assert 'destination="b2"' in alerts
assert not (root / 'infrastructure/monitoring/restic-vault.sops.yaml').exists()
print('Phase 4 B2 manifest and guard assertions passed')
PY
