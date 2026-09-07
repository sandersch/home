#!/usr/bin/env python3
"""Exercise deployed prune PromQL with promtool, plus enrollment metric persistence."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
source = yaml.safe_load((root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text())
names = ['ResticPruneFailed', 'ResticVaultPruneOverdue']
rules = {r['alert']: r for g in source['spec']['groups'] for r in g['rules'] if r.get('alert') in names}
cron = '{namespace="monitoring",cronjob="restic-vault-prune"}'
nas = '{dataset="vault",destination="nas"}'
b2 = '{dataset="vault",destination="b2"}'
mounted = 'node_filesystem_size_bytes{device="/dev/mapper/vault",fstype="ext4",mountpoint="/mnt/vault"}'

def case(name, series, alert, labels=None, evaluations=('31m',)):
    return {'name': name, 'interval': '1m',
            'input_series': [{'series': k, 'values': f'{v}x40'} for k, v in series.items()],
            'alert_rule_test': [{'eval_time': t, 'alertname': alert,
                                 'exp_alerts': [] if labels is None else [
                                     {'exp_labels': dict(labels, severity='warning'),
                                      'exp_annotations': rules[alert]['annotations']}]} for t in evaluations]}

failed = {
    'kube_job_created{namespace="monitoring",job_name="restic-vault-prune-1"}': 20,
    'kube_job_status_failed{namespace="monitoring",job_name="restic-vault-prune-1"}': 1,
    'kube_job_owner{namespace="monitoring",job_name="restic-vault-prune-1",owner_kind="CronJob",owner_is_controller="true",owner_name="restic-vault-prune"}': 1,
    'kube_cronjob_created' + cron: 1,
}
failed_labels = {'namespace': 'monitoring', 'owner_name': 'restic-vault-prune'}
tests = [case('first failure', failed, names[0], failed_labels),
         case('failure waits 15 minutes', failed, names[0], evaluations=('14m',)),
         case('failure after prior success', dict(failed, **{'kube_cronjob_status_last_successful_time' + cron: 10}), names[0], failed_labels),
         case('later success clears failure', dict(failed, **{'kube_cronjob_status_last_successful_time' + cron: 30}), names[0])]
base = {'kube_cronjob_spec_suspend' + cron: 0,
        'homelab_backup_repository_enrolled' + b2: 1,
        'homelab_backup_repository_enrollment_timestamp_seconds' + b2: 1,
        mounted: 1,
        # Continually refreshed schedule times must not reset enrollment age.
        'kube_cronjob_status_last_schedule_time' + cron: 950400}
# Shift the fixture's absolute clock by using a negative enrollment age; this
# works with older promtool releases without start_timestamp support.
base['homelab_backup_repository_enrollment_timestamp_seconds' + b2] = -950400
for success in (None, 0):
    series = dict(base)
    if success is not None:
        series['homelab_restic_prune_success_timestamp_seconds' + nas] = success
    tests.append(case(f'never succeeded, metric {success}', series, names[1], {'dataset': 'vault', 'destination': 'nas'}))
for name, changes in [
    ('initial grace period', {'homelab_backup_repository_enrollment_timestamp_seconds' + b2: 1}),
    ('suspended', {'kube_cronjob_spec_suspend' + cron: 1}),
    ('not enrolled', {'homelab_backup_repository_enrolled' + b2: 0}),
    ('recent success', {'homelab_restic_prune_success_timestamp_seconds' + nas: 10}),
]:
    tests.append(case(name, dict(base, **changes), names[1]))
locked = dict(base)
del locked[mounted]
tests.append(case('vault locked', locked, names[1]))
# For established success, use an evaluation more than ten days after a positive
# timestamp. Keep samples fresh between evaluations throughout the interval.
stale = case('established success overdue', dict(base, **{'homelab_restic_prune_success_timestamp_seconds' + nas: 1}), names[1], {'dataset': 'vault', 'destination': 'nas'}, ('265h',))
stale['interval'] = '1m'
for series in stale['input_series']:
    series['values'] = series['values'].replace('x40', 'x15900')
tests.append(stale)

with tempfile.TemporaryDirectory(prefix='prune-alerts-') as directory:
    work = Path(directory)
    work.chmod(0o755)  # Allow the unprivileged promtool container to read fixtures.
    rule_file = work / 'rules.yaml'
    rule_file.write_text(yaml.safe_dump({'groups': [{'name': 'prune', 'rules': list(rules.values())}]}))
    suite = work / 'tests.yaml'
    suite.write_text(yaml.safe_dump({'rule_files': [str(rule_file)], 'evaluation_interval': '1m', 'tests': tests}))
    subprocess.run(shlex.split(os.environ.get('PROMTOOL', 'promtool')) + ['test', 'rules', str(suite)], check=True)

    copy = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-copy-config.yaml').read_text())['data']['copy-vault.sh']
    writer = copy.split('write_metrics() {', 1)[1].split('\nledger_has()', 1)[0]
    script = 'set -Eeuo pipefail\nwrite_metrics() {' + writer
    script += '\nmetrics="$1/metrics.prom"\ndestination_control="$1/control"\n'
    script += 'date() { echo "$NOW"; }\nNOW=100\nwrite_metrics 0 50 1 0 100\n'
    script += 'NOW=200\nwrite_metrics 0 150 1 0 100\nNOW=300\nwrite_metrics 1\n'
    subprocess.run(['bash', '-c', script, 'metric-fixture', directory], check=True)
    metric = (work / 'metrics.prom').read_text()
    assert 'homelab_backup_repository_enrollment_timestamp_seconds' + b2 + ' 100\n' in metric
    print('PASS: enrollment timestamp survives later copies and locked skips')
