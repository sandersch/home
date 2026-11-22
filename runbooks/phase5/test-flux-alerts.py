#!/usr/bin/env python3
"""Exercise the deployed Flux reconciliation alerts with promtool."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
source = yaml.safe_load((root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text())
group = next(g for g in source['spec']['groups'] if g['name'] == 'homelab.flux')
rules = {r['alert']: r for r in group['rules']}
assert set(rules) == {'FluxResourceNotReady', 'FluxResourceSuspended', 'FluxResourceMetricsMissing'}, set(rules)

base = {'customresource_group': 'kustomize.toolkit.fluxcd.io', 'customresource_kind': 'Kustomization',
        'customresource_version': 'v1', 'exported_namespace': 'flux-system', 'source_name': 'flux-system',
        'namespace': 'monitoring', 'job': 'kube-state-metrics'}
release = dict(base, customresource_group='helm.toolkit.fluxcd.io', customresource_kind='HelmRelease',
               customresource_version='v2', source_name='metallb', chart_name='metallb')
# Keeps FluxResourceMetricsMissing quiet in the cases that are not about it.
root_ok = dict(base, name='flux-system', ready='True', revision='main@sha1:aaa')


def series(labels, values):
    body = ','.join(f'{k}="{v}"' for k, v in labels.items())
    return {'series': f'gotk_resource_info{{{body}}}', 'values': values}


def expected(alert, labels):
    rule = rules[alert]
    keys = ('customresource_kind', 'exported_namespace', 'name')
    labels = {k: labels[k] for k in keys}
    annotations = {k: re.sub(r'{{ \$labels\.(\w+) }}', lambda m: labels[m.group(1)], v)
                   for k, v in rule['annotations'].items()}
    return {'exp_labels': dict(labels, severity=rule['labels']['severity']), 'exp_annotations': annotations}


def case(name, input_series, checks):
    return {'name': name, 'interval': '1m',
            'input_series': [series(root_ok, '1x3000')] + input_series,
            'alert_rule_test': [{'eval_time': t, 'alertname': a, 'exp_alerts': e} for t, a, e in checks]}


stuck = dict(base, name='infra-controllers', revision='main@sha1:aaa')
metallb = dict(release, name='metallb', revision='0.16.1')
tests = [
    case('ready objects stay quiet',
         [series(dict(stuck, ready='True'), '1x120')],
         [('60m', 'FluxResourceNotReady', [])]),
    case('a not-ready object fires after 30 minutes',
         [series(dict(stuck, ready='False'), '1x120')],
         [('25m', 'FluxResourceNotReady', []),
          ('35m', 'FluxResourceNotReady', [expected('FluxResourceNotReady', stuck)])]),
    # helm-controller moves Ready between Unknown (retrying) and False (failed), and
    # rollbacks change the revision; each change starts a new series.
    case('ready and revision churn does not reset the timer',
         [series(dict(metallb, ready='Unknown'), '1x10 _x10 1x10 _x90'),
          series(dict(metallb, ready='False'), '_x10 1x10 _x10 1x90'),
          series(dict(metallb, ready='False', revision='0.16.2'), '_x25 1x5 _x90')],
         [('35m', 'FluxResourceNotReady', [expected('FluxResourceNotReady', metallb)])]),
    case('an object that never reported Ready fires',
         [series(stuck, '1x120')],
         [('35m', 'FluxResourceNotReady', [expected('FluxResourceNotReady', stuck)])]),
    case('a recovered object resolves',
         [series(dict(stuck, ready='False'), '1x40 _x80'),
          series(dict(stuck, ready='True'), '_x40 1x80')],
         [('35m', 'FluxResourceNotReady', [expected('FluxResourceNotReady', stuck)]),
          ('50m', 'FluxResourceNotReady', [])]),
    case('a suspended object alerts only after a day',
         [series(dict(stuck, ready='False', suspended='true'), '1x1500')],
         [('2h', 'FluxResourceNotReady', []),
          ('23h', 'FluxResourceSuspended', []),
          ('25h', 'FluxResourceSuspended', [expected('FluxResourceSuspended', stuck)])]),
    {'name': 'missing Flux metrics fire after 30 minutes', 'interval': '1m',
     'input_series': [series(dict(stuck, ready='True'), '1x120')],
     'alert_rule_test': [{'eval_time': '25m', 'alertname': 'FluxResourceMetricsMissing', 'exp_alerts': []},
                         {'eval_time': '35m', 'alertname': 'FluxResourceMetricsMissing',
                          # absent() carries the selector's equality matchers as labels.
                          'exp_alerts': [expected('FluxResourceMetricsMissing', root_ok)]}]},
    case('present Flux metrics keep the absence alert quiet', [],
         [('60m', 'FluxResourceMetricsMissing', [])]),
]

with tempfile.TemporaryDirectory(prefix='flux-alerts-') as directory:
    work = Path(directory)
    work.chmod(0o755)  # Allow the unprivileged promtool container to read fixtures.
    rule_file = work / 'rules.yaml'
    rule_file.write_text(yaml.safe_dump({'groups': [{'name': group['name'], 'rules': group['rules']}]}))
    suite = work / 'tests.yaml'
    suite.write_text(yaml.safe_dump({'rule_files': [str(rule_file)], 'evaluation_interval': '1m', 'tests': tests}))
    subprocess.run(shlex.split(os.environ.get('PROMTOOL', 'promtool')) + ['test', 'rules', str(suite)], check=True)
