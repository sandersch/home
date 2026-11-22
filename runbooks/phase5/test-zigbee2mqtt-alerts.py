#!/usr/bin/env python3
"""Exercise the deployed Zigbee2MQTT alerts with promtool."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
source = yaml.safe_load((root / 'infrastructure/monitoring/configs/alert-rules.yaml').read_text())
group = next(g for g in source['spec']['groups'] if g['name'] == 'homelab.zigbee2mqtt')
rules = {r['alert']: r for r in group['rules']}
assert set(rules) == {'Zigbee2MQTTBridgeUnhealthy', 'Zigbee2MQTTDevicesUnavailable'}, set(rules)

scrape = {'namespace': 'zigbee2mqtt', 'pod': 'zigbee2mqtt-mqtt-exporter-abc', 'job': 'zigbee2mqtt-mqtt-exporter'}
# The 2026-11-22 entities: six routers, one battery sensor, and one group.
routers = ['Garage Fridge', 'Server Rack', 'Office Desk Light', 'Office Workstation',
           'Office Standing Lamp', 'Office Overhead Light']
battery = 'Office Presence'
group_name = 'Office Lights'


def series(name, labels, values):
    body = ','.join(f'{k}="{v}"' for k, v in dict(scrape, **labels).items())
    return {'series': f'{name}{{{body}}}', 'values': values}


def availability(entity, values):
    return series('mqtt_zigbee_availability', {'topic': f'zigbee2mqtt_{entity}'}, values)


def healthy_bridge(minutes=120):
    # mqtt_response_time is a millisecond timestamp; promtool time starts at 0.
    return [
        series('mqtt_state', {'topic': 'zigbee2mqtt_bridge_state'}, f'1x{minutes}'),
        series('mqtt_mqtt_connected', {'topic': 'zigbee2mqtt_bridge_health'}, f'1x{minutes}'),
        series('mqtt_response_time', {'topic': 'zigbee2mqtt_bridge_health'}, f'0+60000x{minutes}'),
    ]


def exporter_replicas(value, minutes=120):
    return {'series': 'kube_deployment_status_replicas_available{namespace="zigbee2mqtt",'
                      'deployment="zigbee2mqtt-mqtt-exporter",job="kube-state-metrics"}',
            'values': f'{value}x{minutes}'}


def expected(alert):
    rule = rules[alert]
    return {'exp_labels': {'severity': rule['labels']['severity']}, 'exp_annotations': rule['annotations']}


def case(name, input_series, checks):
    return {'name': name, 'interval': '1m', 'input_series': input_series,
            'alert_rule_test': [{'eval_time': t, 'alertname': a, 'exp_alerts': e} for t, a, e in checks]}


all_online = [availability(e, '1x120') for e in routers + [battery, group_name]]
tests = [
    case('all devices online stay quiet',
         healthy_bridge() + [exporter_replicas(1)] + all_online,
         [('60m', 'Zigbee2MQTTDevicesUnavailable', []),
          ('60m', 'Zigbee2MQTTBridgeUnhealthy', [])]),
    case('one device offline stays quiet',
         healthy_bridge() + [exporter_replicas(1)]
         + [availability(routers[0], '0x120')]
         + [availability(e, '1x120') for e in routers[1:] + [battery, group_name]],
         [('60m', 'Zigbee2MQTTDevicesUnavailable', [])]),
    # The bridge stays online and keeps publishing health while every router and
    # the group go offline; the battery sensor's longer timeout keeps it online.
    case('the 2026-11-22 radio failure fires after five minutes while the bridge looks healthy',
         healthy_bridge() + [exporter_replicas(1)]
         + [availability(e, '1x10 0x110') for e in routers + [group_name]]
         + [availability(battery, '1x120')],
         [('14m', 'Zigbee2MQTTDevicesUnavailable', []),
          ('16m', 'Zigbee2MQTTDevicesUnavailable', [expected('Zigbee2MQTTDevicesUnavailable')]),
          ('16m', 'Zigbee2MQTTBridgeUnhealthy', [])]),
    case('recovered devices resolve',
         healthy_bridge() + [exporter_replicas(1)]
         + [availability(e, '1x10 0x30 1x80') for e in routers + [group_name]]
         + [availability(battery, '1x120')],
         [('30m', 'Zigbee2MQTTDevicesUnavailable', [expected('Zigbee2MQTTDevicesUnavailable')]),
          ('45m', 'Zigbee2MQTTDevicesUnavailable', [])]),
    case('missing availability metrics fire while the exporter runs',
         healthy_bridge() + [exporter_replicas(1)],
         [('4m', 'Zigbee2MQTTDevicesUnavailable', []),
          ('6m', 'Zigbee2MQTTDevicesUnavailable', [expected('Zigbee2MQTTDevicesUnavailable')])]),
    case('missing availability metrics stay quiet when the exporter is down',
         healthy_bridge() + [exporter_replicas(0)],
         [('60m', 'Zigbee2MQTTDevicesUnavailable', [])]),
]

with tempfile.TemporaryDirectory(prefix='zigbee2mqtt-alerts-') as directory:
    work = Path(directory)
    work.chmod(0o755)  # Allow the unprivileged promtool container to read fixtures.
    rule_file = work / 'rules.yaml'
    rule_file.write_text(yaml.safe_dump({'groups': [{'name': group['name'], 'rules': group['rules']}]}))
    suite = work / 'tests.yaml'
    suite.write_text(yaml.safe_dump({'rule_files': [str(rule_file)], 'evaluation_interval': '1m', 'tests': tests}))
    subprocess.run(shlex.split(os.environ.get('PROMTOOL', 'promtool')) + ['test', 'rules', str(suite)], check=True)
