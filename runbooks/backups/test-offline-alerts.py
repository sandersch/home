#!/usr/bin/env python3
"""PromQL tests for alternation, staleness and both forms of absence."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[2]
groups = yaml.safe_load((ROOT / 'infrastructure/monitoring/offline/alerts.yaml').read_text())['spec']['groups']
rules = {rule['alert']: rule for group in groups for rule in group['rules']}
metric = 'homelab_restic_offline_rotation_timestamp_seconds'
cases = [
    ('90/180 days is normal', {'A': 90, 'B': 180}, False, []),
    ('globally stale', {'A': 121, 'B': 180}, True, []),
    ('one overdue', {'A': 90, 'B': 211}, False, ['B']),
    ('both overdue', {'A': 211, 'B': 220}, True, ['A', 'B']),
    ('surface absent', {}, True, ['A', 'B']),
    ('A absent', {'B': 90}, False, ['A']),
    ('B absent', {'A': 90}, False, ['B']),
]
tests = []
for name, ages, globally_stale, overdue in cases:
    series = [{'series': f'{metric}{{drive="{drive}"}}', 'values': f'{-age * 86400}x60'} for drive, age in ages.items()]
    expected = {'ResticOfflineDriveStale': [{}] if globally_stale else [],
                'ResticOfflineDriveRotationOverdue': [{'drive': d} for d in overdue]}
    tests.append({'name': name, 'interval': '1m', 'input_series': series, 'alert_rule_test': [
        {'eval_time': '30m', 'alertname': alert, 'exp_alerts': [
            {'exp_labels': {'severity': 'warning', **labels}, 'exp_annotations': rules[alert]['annotations']}
            for labels in matches]} for alert, matches in expected.items()]})
with tempfile.TemporaryDirectory(prefix='offline-alerts-', dir='/tmp') as temp:
    path = Path(temp)
    path.chmod(0o755)
    (path / 'rules.yaml').write_text(yaml.safe_dump({'groups': groups}))
    (path / 'tests.yaml').write_text(yaml.safe_dump({'rule_files': [str(path / 'rules.yaml')],
                                                  'evaluation_interval': '1m', 'tests': tests}))
    for file in path.iterdir():
        file.chmod(0o644)
    subprocess.run([*shlex.split(os.environ.get('PROMTOOL', 'promtool')), 'test', 'rules', str(path / 'tests.yaml')], check=True)
