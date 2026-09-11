#!/usr/bin/env python3
"""Exercise per-host absence and vault-lock gating using the deployed PromQL."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[2]
groups = yaml.safe_load((ROOT / 'infrastructure/monitoring/workstations/alerts.yaml').read_text())['spec']['groups']
rules = {(r['alert'], r['labels']['host']): r for g in groups for r in g['rules']}
tests = []
for host, other in [('ryze', 'm5c'), ('m5c', 'ryze')]:
    for alert, destination in [('ResticWorkstationBackupStale', 'nas'), ('ResticWorkstationCopyOverdue', 'b2')]:
        rule = rules[alert, host]
        labels = {'dataset': 'workstations', 'host': host, 'destination': destination, 'severity': 'warning'}
        tests.append({'name': f'{host} missing independently, {destination}', 'interval': '1m',
            'input_series': [{'series': f'homelab_workstation_snapshot_timestamp_seconds{{dataset="workstations",host="{other}",destination="{destination}"}}', 'values': '1000x40'}],
            'alert_rule_test': [{'eval_time': '31m', 'alertname': alert,
                'exp_alerts': [{'exp_labels': labels, 'exp_annotations': rule['annotations']}]}]})
    rule = rules['VaultWorkstationDocumentsStale', host]
    tests.append({'name': f'{host} documents missing independently', 'interval': '1m', 'input_series': [
        {'series': 'node_filesystem_size_bytes{device="/dev/mapper/vault",mountpoint="/mnt/vault"}', 'values': '100x40'},
        {'series': f'homelab_vault_ingestion_timestamp_seconds{{kind="documents",host="{other}",stage="promotion"}}', 'values': '1000x40'}],
        'alert_rule_test': [{'eval_time': '31m', 'alertname': 'VaultWorkstationDocumentsStale',
            'exp_alerts': [{'exp_labels': {'host': host, 'dataset': 'workstations', 'kind': 'documents',
                            'stage': 'promotion', 'severity': 'warning'}, 'exp_annotations': rule['annotations']}]}]})
tests.append({'name': 'locked vault defers both document alerts', 'interval': '1m', 'input_series': [],
              'alert_rule_test': [{'eval_time': '31m', 'alertname': 'VaultWorkstationDocumentsStale', 'exp_alerts': []}]})
with tempfile.TemporaryDirectory(prefix='workstation-alerts-') as temporary:
    path = Path(temporary)
    path.chmod(0o755)
    (path / 'rules.yaml').write_text(yaml.safe_dump({'groups': groups}))
    (path / 'tests.yaml').write_text(yaml.safe_dump({'rule_files': [str(path / 'rules.yaml')],
                                                 'evaluation_interval': '1m', 'tests': tests}))
    command = shlex.split(os.environ.get('PROMTOOL', 'promtool'))
    subprocess.run(command + ['check', 'rules', str(path / 'rules.yaml')], check=True)
    subprocess.run(command + ['test', 'rules', str(path / 'tests.yaml')], check=True)
