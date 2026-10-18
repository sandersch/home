#!/usr/bin/env python3
"""Exercise the deployed homelab.disks SMART alert PromQL with promtool."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
source = yaml.safe_load((root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text())
group = next(g for g in source['spec']['groups'] if g['name'] == 'homelab.disks')
rules = {r['alert']: r for r in group['rules']}
EXPECTED_DEVICES = 18  # 17 disks behind the HBA plus the NVMe

def series(name, pod='p1', **labels):
    labels = {'namespace': 'monitoring', 'pod': pod, 'instance': 'minis', 'job': 'smartctl-exporter', **labels}
    return name + '{' + ','.join(f'{k}="{v}"' for k, v in labels.items()) + '}'

def info(device, serial, pod='p1', model='WDC WD40EFRX-68WT0N0'):
    return series('smartctl_device', pod, device=device, model_name=model, serial_number=serial)

def raw(attribute, device, pod='p1'):
    return series('smartctl_device_attribute', pod, device=device, attribute_name=attribute, attribute_value_type='raw')

def render(template, labels, value):
    text = re.sub(r'\{\{ \$labels\.(\w+) \}\}', lambda m: labels[m.group(1)], template)
    return text.replace('{{ $value }}', '%g' % value)

def alert(name, value, **labels):
    rule = rules[name]
    return {'exp_labels': {**labels, 'severity': rule['labels']['severity']},
            'exp_annotations': {k: render(v, labels, value) for k, v in rule['annotations'].items()}}

def disk(device, serial, model='WDC WD40EFRX-68WT0N0', **extra):
    return {'instance': 'minis', 'device': device, 'model_name': model, 'serial_number': serial, **extra}

def case(name, values, checks):
    return {'name': name, 'interval': '5m',
            'input_series': [{'series': k, 'values': v} for k, v in values.items()],
            'alert_rule_test': [{'eval_time': t, 'alertname': a, 'exp_alerts': e} for t, a, e in checks]}

# 300 samples at five-minute spacing is 25 hours, one hour past the 24-hour window.
tests = [
    case('high but flat raw counters stay quiet',
         {info('sda', 'S1'): '1x900', raw('Reallocated_Sector_Ct', 'sda'): '8x900'},
         [('2d', 'DiskSectorsDegrading', [])]),
    case('a reallocated-sector increase fires until it leaves the 24-hour window',
         {info('sda', 'S1'): '1x900', raw('Reallocated_Sector_Ct', 'sda'): '8x300 9x600'},
         [('25h10m', 'DiskSectorsDegrading',
           [alert('DiskSectorsDegrading', 1, **disk('sda', 'S1', attribute_name='Reallocated_Sector_Ct'))]),
          ('50h', 'DiskSectorsDegrading', [])]),
    case('a pending-sector decrease is not growth, but remaining pending sectors still page',
         {info('sda', 'S1'): '1x600', raw('Current_Pending_Sector', 'sda'): '5x300 2x300'},
         [('25h10m', 'DiskSectorsDegrading', []),
          ('25h10m', 'DiskPendingSectors', [alert('DiskPendingSectors', 2, **disk('sda', 'S1'))])]),
    # After a reboot the kernel names swap: sda is now the disk that already had 8.
    case('a kernel-name swap across an exporter restart stays quiet',
         {info('sda', 'S1'): '1x300', info('sdb', 'S2'): '1x300',
          raw('Reallocated_Sector_Ct', 'sda'): '0x300', raw('Reallocated_Sector_Ct', 'sdb'): '8x300',
          info('sda', 'S2', pod='p2'): '_x301 1x300', info('sdb', 'S1', pod='p2'): '_x301 1x300',
          raw('Reallocated_Sector_Ct', 'sda', pod='p2'): '_x301 8x300',
          raw('Reallocated_Sector_Ct', 'sdb', pod='p2'): '_x301 0x300'},
         [('25h30m', 'DiskSectorsDegrading', []), ('30h', 'DiskSectorsDegrading', [])]),
    case('a failed SMART self-assessment fires after ten minutes',
         {info('sda', 'S1'): '1x20', series('smartctl_device_smart_status', device='sda'): '1x2 0x18'},
         [('15m', 'DiskSmartHealthFailed', []),
          ('25m', 'DiskSmartHealthFailed', [alert('DiskSmartHealthFailed', 0, **disk('sda', 'S1'))])]),
    case('SAS grown defects fire with the counter that grew',
         {info('sdm', 'ZC1', model='SEAGATE ST4000NM0095'): '1x600',
          series('smartctl_scsi_grown_defect_list', device='sdm'): '0x300 3x300',
          series('smartctl_read_total_uncorrected_errors', device='sdm'): '0x600',
          series('smartctl_write_total_uncorrected_errors', device='sdm'): '0x600'},
         [('24h', 'SASDiskDefectsIncreasing', []),
          ('25h10m', 'SASDiskDefectsIncreasing',
           [alert('SASDiskDefectsIncreasing', 3,
                  **disk('sdm', 'ZC1', model='SEAGATE ST4000NM0095', counter='grown_defect_list'))])]),
    case('an HBA disk above 50 C for 30 minutes fires; 50 C and a 60 C NVMe stay quiet',
         {info('sda', 'S1'): '1x12', info('sdb', 'S2'): '1x12', info('nvme0', 'N1', model='KINGSTON'): '1x12',
          series('smartctl_device_temperature', device='sda', temperature_type='current'): '51x12',
          series('smartctl_device_temperature', device='sdb', temperature_type='current'): '50x12',
          series('smartctl_device_temperature', device='nvme0', temperature_type='current'): '60x12'},
         [('25m', 'DiskTemperatureHigh', []),
          ('35m', 'DiskTemperatureHigh', [alert('DiskTemperatureHigh', 51, **disk('sda', 'S1'))])]),
    case('an NVMe above 70 C fires',
         {info('nvme0', 'N1', model='KINGSTON'): '1x12',
          series('smartctl_device_temperature', device='nvme0', temperature_type='current'): '71x12'},
         [('35m', 'DiskTemperatureHigh', [alert('DiskTemperatureHigh', 71, **disk('nvme0', 'N1', model='KINGSTON'))])]),
    case('NVMe wear, critical warnings, and new media errors fire',
         {series('smartctl_device_percentage_used', device='nvme0'): '81x300',
          series('smartctl_device_critical_warning', device='nvme0'): '0x2 4x298',
          series('smartctl_device_media_errors', device='nvme0'): '0x290 2x10'},
         [('70m', 'NVMeWearHigh', [alert('NVMeWearHigh', 81, instance='minis', device='nvme0')]),
          ('25m', 'NVMeCriticalWarning', [alert('NVMeCriticalWarning', 4, instance='minis', device='nvme0')]),
          ('24h15m', 'NVMeMediaErrorsIncreasing',
           [alert('NVMeMediaErrorsIncreasing', 2, instance='minis', device='nvme0')])]),
]

def fleet(count, up):
    values = {series('up'): f'{up}x12'} if up is not None else {}
    values.update({series('smartctl_device_smart_status', device=f'd{i}'): '1x12' for i in range(count)})
    return values

missing = alert('SmartctlDeviceMissing', 0)
tests += [
    case(f'{EXPECTED_DEVICES} reporting devices stay quiet', fleet(EXPECTED_DEVICES, 1),
         [('40m', 'SmartctlDeviceMissing', [])]),
    case('one missing device fires', fleet(EXPECTED_DEVICES - 1, 1),
         [('25m', 'SmartctlDeviceMissing', []), ('40m', 'SmartctlDeviceMissing', [missing])]),
    case('a failing scrape is left to TargetDown', fleet(0, 0),
         [('40m', 'SmartctlDeviceMissing', [])]),
    case('a vanished exporter target fires', fleet(0, None),
         [('40m', 'SmartctlDeviceMissing', [{**missing, 'exp_labels': {**missing['exp_labels'], 'job': 'smartctl-exporter'}}])]),
]

with tempfile.TemporaryDirectory(prefix='disk-health-alerts-') as directory:
    work = Path(directory)
    work.chmod(0o755)  # Allow the unprivileged promtool container to read fixtures.
    rule_file = work / 'rules.yaml'
    rule_file.write_text(yaml.safe_dump({'groups': [{'name': group['name'], 'rules': group['rules']}]}))
    suite = work / 'tests.yaml'
    suite.write_text(yaml.safe_dump({'rule_files': [str(rule_file)], 'evaluation_interval': '1m', 'tests': tests}))
    subprocess.run(shlex.split(os.environ.get('PROMTOOL', 'promtool')) + ['test', 'rules', str(suite)], check=True)
