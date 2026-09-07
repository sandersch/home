#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repo_root" <<'PY'
import json
import pathlib
import subprocess
import tempfile
import re
import sys
import yaml

root = pathlib.Path(sys.argv[1])
copy = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-copy-config.yaml').read_text())
prune = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-prune-config.yaml').read_text())
vault = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-config.yaml').read_text())
verify = yaml.safe_load((root / 'infrastructure/monitoring/restic-verify-config.yaml').read_text())
backup_job = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-cronjob.yaml').read_text())
copy_job = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-copy-cronjob.yaml').read_text())
prune_job = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-prune-cronjob.yaml').read_text())
verify_job = yaml.safe_load((root / 'infrastructure/monitoring/restic-verify-cronjob.yaml').read_text())
alerts = (root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text()
kustomization = (root / 'infrastructure/monitoring/kustomization.yaml').read_text()

copy_script = copy['data']['copy-vault.sh']
prune_script = prune['data']['prune-vault.sh']
assert vault['data']['detect-vault-exclusions.jq'] == copy['data']['detect-vault-exclusions.jq'] == prune['data']['detect-vault-exclusions.jq']
retry_wrapper = 'restic() { command restic --retry-lock "$restic_lock_retry" "$@"; }'
retry_default = 'restic_lock_retry="${RESTIC_LOCK_RETRY:-30m}"'
for cm in (vault, copy, prune, verify):
    for key, body in cm['data'].items():
        if key.endswith('.sh') and 'restic ' in body:
            assert retry_wrapper in body, key
            assert retry_default in body, key

def env_of(job, name):
    for container in job['spec']['jobTemplate']['spec']['template']['spec']['containers']:
        for env in container.get('env', []):
            if env['name'] == name:
                return env['value']
    raise AssertionError(f'{job["metadata"]["name"]} has no {name} environment variable')

def parse_duration(value):
    match = re.fullmatch(r'(\d+)([smhd])', value)
    assert match, value
    amount, unit = match.groups()
    return int(amount) * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[unit]

for job in (backup_job, copy_job, prune_job, verify_job):
    spec = job['spec']['jobTemplate']['spec']
    retry = parse_duration(env_of(job, 'RESTIC_LOCK_RETRY'))
    assert retry < spec['activeDeadlineSeconds'], job['metadata']['name']
restore_script = copy['data']['validate-vault-b2-restore.sh']
destination_resolver = copy['data']['resolve-vault-b2-validation-hold.sh']
resolver_wrapper = (root / 'runbooks/backups/10-resolve-validation-hold.sh').read_text()
assert 'restic copy --from-repo "$source_repo" "$snapshot_id"' in copy_script
assert 'restic stats --json --mode raw-data' in copy_script
assert 'restic stats --json --mode restore-size' not in copy_script
assert 'homelab_restic_replication_skipped_consecutive' not in copy_script
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
assert 'local skipped="$1" candidates="$2" reason="${3:-none}"' in prune_script
assert 'reason="%s"} %s\\n' in prune_script
for reason in ('hold', 'destination-ledger', 'stale-source', 'source-ledger', 'source-validation', 'source-manifest', 'baseline', 'contract', 'baseline-tolerance', 'empty-destination', 'stale-destination', 'unreplicated', 'destination-unvalidated'):
    assert f'write_metrics 1' in prune_script
    assert reason in prune_script
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
assert prune_job['spec']['schedule'] == '30 23 * * 6'
mounts = prune_job['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['volumeMounts']
assert {m['name'] for m in mounts} >= {'vault-scripts', 'contract'}
assert 'restic-vault-copy-config.yaml' in kustomization
assert 'restic-vault-copy-cronjob.yaml' in kustomization
assert 'restic-vault-prune-config.yaml' in kustomization
assert 'restic-vault-prune-cronjob.yaml' in kustomization
assert 'ResticVaultCopyOverdue' in alerts
assert 'ResticPruneFailed' in alerts
assert 'ResticBackupFailed' in alerts
assert '0 * kube_cronjob_created{namespace="monitoring",cronjob=~"restic-(nas-backup|b2-backup|vault-backup|vault-copy)"}' in alerts
assert 'restic-vault-prune-.*' in alerts
assert 'kube_cronjob_spec_suspend{namespace="monitoring",cronjob="restic-vault-prune"}' in alerts
assert 'homelab_backup_repository_enrollment_timestamp_seconds{dataset="vault",destination="b2"}' in alerts
assert 'homelab_restic_unreplicated_candidates{dataset="vault",destination="nas"} > 0' in alerts
assert 'unless on() (homelab_restic_replication_missing_snapshots{dataset="vault",destination="b2"} == 0)' in alerts
assert 'ResticVaultCopySuspended' not in alerts
assert 'ResticVaultCopyNearCeiling' not in alerts
assert 'A vault snapshot failed validation and is held outside the {{ $labels.destination }} validation ledger.' in alerts
assert '        - alert: ResticRepoNearCeiling' in alerts
assert 'homelab_restic_repository_size_bytes\n            / homelab_restic_repository_ceiling_bytes > 0.80' in alerts
assert 'The {{ $labels.dataset }} repository on {{ $labels.destination }} is above 80 percent of its policy ceiling.' in alerts
assert '{{ $labels.dataset }}/{{ $labels.destination }} has no recorded semantic restore drill in 100 days.' in alerts
assert 'destination="b2"' in alerts
assert not (root / 'infrastructure/monitoring/restic-vault.sops.yaml').exists()
assert 'repository_ceiling_bytes{dataset="vault",destination="b2"} 100000000000' in copy_script
assert '107374182400' not in copy_script
# Execute the deployed selection assignments under the same shell error policy.
# Large listings used to SIGPIPE jq when head closed the pipe after its first line.
selection = '\n'.join(line for line in restore_script.splitlines()
                      if line.startswith(('document=', 'photo=', '[ -n "$document" ]')))
assert len(selection.splitlines()) == 3
with tempfile.TemporaryDirectory() as directory:
    listing = pathlib.Path(directory) / 'listing.jsonl'
    nodes = [{'message_type': 'node', 'type': 'file',
              'path': f'/data/vault/{category}/file {number:05d}.dat'}
             for category in ('documents', 'photos') for number in range(10000)]
    def select_files(records):
        listing.write_text(''.join(json.dumps(record) + '\n' for record in records))
        return subprocess.run(
            ['bash', '-c', 'set -Eeuo pipefail\ndie() { exit 1; }\nlisting="$1"\n' +
             selection + '\nprintf "%s\\n" "$document" "$photo"', 'restore-selection', str(listing)],
            text=True, capture_output=True)
    result = select_files(nodes)
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert result.stdout.splitlines() == ['/data/vault/documents/file 00000.dat',
                                          '/data/vault/photos/file 00000.dat']
    assert select_files(nodes[:10000]).returncode != 0, 'missing photo was accepted'
    assert select_files(nodes[10000:]).returncode != 0, 'missing document was accepted'
    assert select_files([]).returncode != 0, 'empty listing was accepted'
print('PASS: restore selection handles large listings and rejects missing content')
print('Phase 4 B2 manifest and guard assertions passed')
PY

seed="$repo_root/runbooks/backups/16-seed-vault-b2.sh"
grep -q 'activeDeadlineSeconds = 86400' "$seed"
grep -q 'RESTIC_LOCK_RETRY.*12h' "$seed"
grep -q 'restic-vault-copy must remain suspended' "$seed"
grep -q -- '--from=cronjob/restic-vault-copy' "$seed"
grep -q 'job=restic-vault-b2-seed' "$seed"

python3 "$repo_root/runbooks/backups/test-phase4-p1.py"

python3 "$repo_root/runbooks/backups/test-b2-retention.py"
