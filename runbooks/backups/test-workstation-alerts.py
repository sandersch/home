#!/usr/bin/env python3
"""Exercise enrollment gating, per-host absence, and vault-lock gating using the deployed PromQL."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[2]
groups = yaml.safe_load((ROOT / 'infrastructure/monitoring/workstations/alerts.yaml').read_text())['spec']['groups']
rules = {(r['alert'], r['labels']['host']): r for g in groups for r in g['rules']}
alertnames = sorted({alert for alert, _ in rules})
# Enrollment 46 days before the test epoch is beyond every staleness window.
OLD = '-4000000'
VAULT = {'series': 'node_filesystem_size_bytes{device="/dev/mapper/vault",mountpoint="/mnt/vault"}', 'values': '100x200'}


def series(name, host, value, **labels):
    labels = {'dataset': 'workstations', 'host': host, **labels}
    text = ','.join(f'{k}="{v}"' for k, v in labels.items())
    return {'series': f'homelab_workstation_{name}{{{text}}}', 'values': f'{value}x200'}


def enrolled(host, since=OLD):
    return [series('enrolled', host, 1), series('enrollment_timestamp_seconds', host, since)]


def emitted(host, since=OLD, nas=1000, b2=1000, prune=1000, check=1000):
    """Every metric maintenance.py emits for an enrolled host; defaults are fresh."""
    rows = enrolled(host, since) + [series('validation_hold', host, 0), series('prune_success_timestamp_seconds', host, prune)]
    for destination, snapshot in (('nas', nas), ('b2', b2)):
        rows += [series('snapshot_timestamp_seconds', host, snapshot, destination=destination),
                 series('check_success_timestamp_seconds', host, check, destination=destination),
                 series('size_collection_success', host, 1, destination=destination)]
    rows.append({'series': f'homelab_vault_ingestion_timestamp_seconds{{kind="documents",host="{host}",stage="promotion"}}',
                 'values': '1000x200'})
    return rows


def expected(alert, host, **labels):
    return {'exp_labels': {'dataset': 'workstations', 'host': host, 'severity': 'warning', **labels},
            'exp_annotations': rules[alert, host]['annotations']}


def quiet(name, input_series, eval_time='2h', names=alertnames):
    return {'name': name, 'interval': '1m', 'input_series': input_series,
            'alert_rule_test': [{'eval_time': eval_time, 'alertname': n, 'exp_alerts': []} for n in names]}


tests = [
    quiet('nothing enrolled stays quiet while the vault is mounted', [VAULT]),
    # Attended initialization writes metrics before any seed snapshot exists.
    quiet('initialized but unseeded hosts stay quiet', [VAULT] + [
        s for host in ('ryze', 'm5c') for s in [series('enrolled', host, 0), series('enrollment_timestamp_seconds', host, 0),
                                                series('validation_hold', host, 0), series('prune_success_timestamp_seconds', host, 0)]
        + [series(name, host, 0, destination=d) for d in ('nas', 'b2')
           for name in ('snapshot_timestamp_seconds', 'check_success_timestamp_seconds', 'size_collection_success')]]),
]
for host, other in [('ryze', 'm5c'), ('m5c', 'ryze')]:
    # Only the enrollment metrics exist for host; the other host is healthy.
    tests.append({'name': f'{host} enrolled with missing results alerts independently', 'interval': '1m',
        'input_series': [VAULT] + enrolled(host) + emitted(other), 'alert_rule_test': [
            {'eval_time': '2h', 'alertname': 'ResticWorkstationBackupStale',
             'exp_alerts': [expected('ResticWorkstationBackupStale', host, destination='nas')]},
            {'eval_time': '2h', 'alertname': 'ResticWorkstationCopyOverdue',
             'exp_alerts': [expected('ResticWorkstationCopyOverdue', host, destination='b2')]},
            {'eval_time': '2h', 'alertname': 'ResticWorkstationValidationHeld',
             'exp_alerts': [expected('ResticWorkstationValidationHeld', host)]},
            {'eval_time': '2h', 'alertname': 'ResticWorkstationPruneOverdue',
             'exp_alerts': [expected('ResticWorkstationPruneOverdue', host)]},
            {'eval_time': '2h', 'alertname': 'ResticWorkstationCheckOverdue',
             'exp_alerts': [expected('ResticWorkstationCheckOverdue', host, destination=d) for d in ('nas', 'b2')]},
            {'eval_time': '2h', 'alertname': 'ResticWorkstationCapacityUnknown',
             'exp_alerts': [expected('ResticWorkstationCapacityUnknown', host, destination=d) for d in ('nas', 'b2')]},
            {'eval_time': '2h', 'alertname': 'VaultWorkstationDocumentsStale',
             'exp_alerts': [expected('VaultWorkstationDocumentsStale', host, kind='documents', stage='promotion')]},
            {'eval_time': '2h', 'alertname': 'ResticWorkstationEnrollmentLost', 'exp_alerts': []}]})
    # A just-seeded host has zero copy, prune, and check timestamps.
    tests.append(quiet(f'{host} fresh enrollment is within every grace window',
                       [VAULT] + emitted(host, since=0, b2=0, prune=0, check=0)))
    # Real timestamps are positive, so staleness needs an eight-day timeline.
    tests.append({'name': f'{host} stale NAS snapshot alerts', 'interval': '1m',
        'input_series': [{**s, 'values': s['values'].replace('x200', 'x12000')} for s in emitted(host)],
        'alert_rule_test': [{'eval_time': '8d', 'alertname': 'ResticWorkstationBackupStale',
                             'exp_alerts': [expected('ResticWorkstationBackupStale', host, destination='nas')]}]})
    for label, values in [('disappear', '1x30 _x170'), ('revert to zero', '1x30 0x170')]:
        tests.append({'name': f'{host} enrollment metrics {label}', 'interval': '1m', 'input_series': [
            {'series': f'homelab_workstation_enrolled{{dataset="workstations",host="{host}"}}', 'values': values}],
            'alert_rule_test': [{'eval_time': '2h', 'alertname': 'ResticWorkstationEnrollmentLost',
                                 'exp_alerts': [expected('ResticWorkstationEnrollmentLost', host)]}]})
tests.append({'name': 'locked vault defers both document alerts', 'interval': '1m',
              'input_series': enrolled('ryze') + enrolled('m5c'),
              'alert_rule_test': [{'eval_time': '2h', 'alertname': 'VaultWorkstationDocumentsStale', 'exp_alerts': []}]})
with tempfile.TemporaryDirectory(prefix='workstation-alerts-') as temporary:
    path = Path(temporary)
    path.chmod(0o755)
    (path / 'rules.yaml').write_text(yaml.safe_dump({'groups': groups}))
    (path / 'tests.yaml').write_text(yaml.safe_dump({'rule_files': [str(path / 'rules.yaml')],
                                                 'evaluation_interval': '1m', 'tests': tests}))
    command = shlex.split(os.environ.get('PROMTOOL', 'promtool'))
    subprocess.run(command + ['check', 'rules', str(path / 'rules.yaml')], check=True)
    subprocess.run(command + ['test', 'rules', str(path / 'tests.yaml')], check=True)
