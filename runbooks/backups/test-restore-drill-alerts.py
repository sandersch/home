#!/usr/bin/env python3
"""Exercise deployed restore-drill PromQL (100d quarterly / 400d annual) with promtool."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
source = yaml.safe_load((root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text())
names = ['ResticQuarterlyRestoreDrillOverdue', 'ResticRestoreDrillOverdue']
rules = {r['alert']: r for g in source['spec']['groups'] for r in g['rules'] if r.get('alert') in names}
assert set(rules) == set(names), set(rules)

nas = '{dataset="vault",destination="nas"}'
b2 = '{dataset="vault",destination="b2"}'
mounted = 'node_filesystem_size_bytes{device="/dev/mapper/vault",fstype="ext4",mountpoint="/mnt/vault"}'

DAY = 86400
# Negative timestamps shift the fixture clock relative to promtool's t=0 epoch.
AGE_5D = -5 * DAY
AGE_101D = -101 * DAY
AGE_150D = -150 * DAY
AGE_401D = -401 * DAY

quarterly_ann = rules['ResticQuarterlyRestoreDrillOverdue']['annotations']


def annual_ann(dataset, destination):
    return {
        'description': f'{dataset}/{destination} has no recorded annual semantic restore drill in 400 days.',
        'summary': rules['ResticRestoreDrillOverdue']['annotations']['summary'],
    }


def make_test(name, series, checks):
    return {
        'name': name,
        'interval': '1m',
        'input_series': [{'series': k, 'values': f'{v}x40'} for k, v in series.items()],
        'alert_rule_test': [
            {'eval_time': t, 'alertname': alert, 'exp_alerts': expected}
            for t, alert, expected in checks
        ],
    }


def exp(alert, labels, annotations):
    return {
        'exp_labels': dict(labels, severity=rules[alert]['labels']['severity']),
        'exp_annotations': annotations,
    }


base = {
    'homelab_backup_repository_enrolled' + nas: 1,
    'homelab_backup_repository_enrolled' + b2: 1,
    mounted: 1,
}

tests = [
    make_test(
        'fresh b2 drill with 150d nas drill satisfies both quarterly and annual gates',
        dict(base, **{
            'homelab_restic_restore_drill_timestamp_seconds' + nas: AGE_150D,
            'homelab_restic_restore_drill_timestamp_seconds' + b2: AGE_5D,
        }),
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('31m', 'ResticRestoreDrillOverdue', []),
        ],
    ),
    make_test(
        'both repos over 100d and under 400d fires only quarterly alert after 30m',
        dict(base, **{
            'homelab_restic_restore_drill_timestamp_seconds' + nas: AGE_150D,
            'homelab_restic_restore_drill_timestamp_seconds' + b2: AGE_101D,
        }),
        [
            ('29m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', [
                exp('ResticQuarterlyRestoreDrillOverdue', {}, quarterly_ann),
            ]),
            ('31m', 'ResticRestoreDrillOverdue', []),
        ],
    ),
    make_test(
        'nas over 400d with fresh b2 fires only annual alert for vault/nas',
        dict(base, **{
            'homelab_restic_restore_drill_timestamp_seconds' + nas: AGE_401D,
            'homelab_restic_restore_drill_timestamp_seconds' + b2: AGE_5D,
        }),
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('29m', 'ResticRestoreDrillOverdue', []),
            ('31m', 'ResticRestoreDrillOverdue', [
                exp('ResticRestoreDrillOverdue', {'dataset': 'vault', 'destination': 'nas'}, annual_ann('vault', 'nas')),
            ]),
        ],
    ),
    make_test(
        'b2 over 400d with fresh nas fires only annual alert for vault/b2',
        dict(base, **{
            'homelab_restic_restore_drill_timestamp_seconds' + nas: AGE_5D,
            'homelab_restic_restore_drill_timestamp_seconds' + b2: AGE_401D,
        }),
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('31m', 'ResticRestoreDrillOverdue', [
                exp('ResticRestoreDrillOverdue', {'dataset': 'vault', 'destination': 'b2'}, annual_ann('vault', 'b2')),
            ]),
        ],
    ),
    make_test(
        'missing b2 metric with fresh nas fires annual alert for vault/b2 only',
        dict(base, **{
            'homelab_restic_restore_drill_timestamp_seconds' + nas: AGE_5D,
        }),
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('31m', 'ResticRestoreDrillOverdue', [
                exp('ResticRestoreDrillOverdue', {'dataset': 'vault', 'destination': 'b2'}, annual_ann('vault', 'b2')),
            ]),
        ],
    ),
    make_test(
        'all restore-drill metrics missing while enrolled and mounted fires both alerts',
        dict(base),
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', [
                exp('ResticQuarterlyRestoreDrillOverdue', {}, quarterly_ann),
            ]),
            ('31m', 'ResticRestoreDrillOverdue', [
                exp('ResticRestoreDrillOverdue', {'dataset': 'vault', 'destination': 'nas'}, annual_ann('vault', 'nas')),
                exp('ResticRestoreDrillOverdue', {'dataset': 'vault', 'destination': 'b2'}, annual_ann('vault', 'b2')),
            ]),
        ],
    ),
    make_test(
        'locked vault suppresses both overdue and missing restore-drill alerts',
        {
            'homelab_backup_repository_enrolled' + nas: 1,
            'homelab_backup_repository_enrolled' + b2: 1,
            'homelab_restic_restore_drill_timestamp_seconds' + nas: AGE_401D,
            'homelab_restic_restore_drill_timestamp_seconds' + b2: AGE_401D,
        },
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('31m', 'ResticRestoreDrillOverdue', []),
        ],
    ),
    make_test(
        'unenrolled repositories suppress both restore-drill alerts',
        {
            'homelab_backup_repository_enrolled' + nas: 0,
            'homelab_backup_repository_enrolled' + b2: 0,
            mounted: 1,
        },
        [
            ('31m', 'ResticQuarterlyRestoreDrillOverdue', []),
            ('31m', 'ResticRestoreDrillOverdue', []),
        ],
    ),
]

with tempfile.TemporaryDirectory(prefix='restore-drill-alerts-') as directory:
    work = Path(directory)
    work.chmod(0o755)
    rule_file = work / 'rules.yaml'
    rule_file.write_text(yaml.safe_dump({'groups': [{'name': 'restore-drill', 'rules': list(rules.values())}]}))
    suite_file = work / 'tests.yaml'
    suite_file.write_text(yaml.safe_dump({
        'rule_files': [str(rule_file)],
        'evaluation_interval': '1m',
        'tests': tests,
    }))
    subprocess.run(
        shlex.split(os.environ.get('PROMTOOL', 'promtool')) + ['test', 'rules', str(suite_file)],
        check=True,
    )
    print('PASS: restore-drill quarterly (100d) and annual (400d) alert rules')
