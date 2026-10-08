#!/usr/bin/env python3
"""Exercise the deployed RAID check completion and disk-saturation PromQL with promtool."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
source = yaml.safe_load((root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text())
alert = 'RaidCheckNotCompleted'
rule = next(r for g in source['spec']['groups'] for r in g['rules'] if r.get('alert') == alert)
md = '{instance="minis",device="md3"}'
total = 42964213248  # 11 data members of 3905837568 KiB; the idle value of blocks_synced
# Promtool time starts on Thursday 1970-01-01; samples are five minutes apart, so the
# check below runs for six hours on the 4th.
idle_before, window, idle_after = 863, 71, 4000
expected = [{'exp_labels': {'severity': rule['labels']['severity']}, 'exp_annotations': rule['annotations']}]

def case(name, check, synced, firing):
    series = {'node_md_blocks' + md: f'{total}x5000',
              'node_md_raid_disks' + md: '13x5000',
              'node_md_state{instance="minis",device="md3",state="check"}': check,
              'node_md_blocks_synced' + md: synced}
    return {'name': name, 'interval': '5m',
            'input_series': [{'series': k, 'values': v} for k, v in series.items()],
            'alert_rule_test': [{'eval_time': t, 'alertname': alert,
                                 'exp_alerts': expected if t in firing else []}
                                for t in ('10d23h', '11d1h', '14d23h', '15d1h')]}

ran = f'0x{idle_before} 1x{window} 0x{idle_after}'
def progress(step):
    return f'{total}x{idle_before} 0+{step}x{window} {total}x{idle_after}'

tests = [case('completed check stays quiet', ran, progress(55011797), ()),
         case('paused at 84% fires from the 12th through the 15th', ran, progress(46000000), ('11d1h', '14d23h')),
         case('check that never started fires', '0x5000', f'{total}x5000', ('11d1h', '14d23h'))]

saturation = next(r for g in source['spec']['groups'] for r in g['rules'] if r.get('alert') == 'NodeDiskIOSaturation')

def saturation_case(name, check, devices, firing):
    series = {'node_md_state{instance="minis",device="md3",state="check"}': f'{check}x60'}
    # 1200 weighted seconds per minute is a queue depth of 20, above the threshold of 10.
    series.update({f'node_disk_io_time_weighted_seconds_total{{instance="minis",job="node-exporter",device="{d}"}}': '0+1200x60'
                   for d in devices})
    alerts = [{'exp_labels': {'instance': 'minis', 'job': 'node-exporter', 'device': d,
                              'severity': saturation['labels']['severity']},
               'exp_annotations': dict(saturation['annotations'], description=(
                   f'Disk IO queue (aqu-sq) is high on {d} at minis, has been above 10 for the last 30 minutes, '
                   'is currently at 20.00.\nThis symptom might indicate disk saturation.\n'))}
              for d in firing]
    return {'name': name, 'interval': '1m',
            'input_series': [{'series': k, 'values': v} for k, v in series.items()],
            'alert_rule_test': [{'eval_time': '45m', 'alertname': 'NodeDiskIOSaturation', 'exp_alerts': alerts}]}

tests += [saturation_case('member disks are ignored during a check', 1, ('sda', 'sdq'), ()),
          saturation_case('array, LVM, and NVMe devices still fire during a check', 1,
                          ('sda', 'md3', 'dm-10', 'nvme0n1'), ('md3', 'dm-10', 'nvme0n1')),
          saturation_case('member disks fire when no check is running', 0, ('sda', 'md3'), ('sda', 'md3'))]

with tempfile.TemporaryDirectory(prefix='raid-check-alerts-') as directory:
    work = Path(directory)
    work.chmod(0o755)  # Allow the unprivileged promtool container to read fixtures.
    rule_file = work / 'rules.yaml'
    rule_file.write_text(yaml.safe_dump({'groups': [{'name': 'raid-check', 'rules': [rule, saturation]}]}))
    suite = work / 'tests.yaml'
    suite.write_text(yaml.safe_dump({'rule_files': [str(rule_file)], 'evaluation_interval': '1m', 'tests': tests}))
    subprocess.run(shlex.split(os.environ.get('PROMTOOL', 'promtool')) + ['test', 'rules', str(suite)], check=True)
