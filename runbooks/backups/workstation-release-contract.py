#!/usr/bin/env python3
"""Release reviewed measured contracts without replacing an existing release."""
import argparse
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host/workstations'))
from workstation import digest, read_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('measurement', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    value = read_json(args.measurement)
    evidence = read_json(args.evidence)
    host = value['hostname']
    if host not in ('ryze', 'm5c') or evidence.get('host') != host:
        raise ValueError('unexpected host identity')
    if value['contract'] != f'workstation-{host}-v1':
        raise ValueError('unexpected contract release name')
    gates = ['inventory_reviewed', 'capacity_reviewed', 'required_content_readable']
    if host == 'm5c':
        gates += ['fda_launchd_passed', 'icloud_optimize_disabled', 'photos_mail_no_unique_data', 'dropbox_materialized']
    if not all(evidence.get(gate) is True for gate in gates):
        raise ValueError('attended enrollment gates have not passed')
    scope = ROOT / f'host/{host}/etc/workstation-backup/excludes'
    if value['exclusion_sha256'] != digest(scope.read_bytes()):
        raise ValueError('exclusions changed after measurement')
    for prefix in ('', 'Documents/'):
        expected = {key: math.ceil(value['measured'][prefix][key] * .8) for key in ('files', 'bytes')}
        if min(expected.values()) < 1 or value['floors'][prefix] != expected:
            raise ValueError('released floors must be exactly 80% of the measured scope, rounded up')
    if value['kdbx_minimum_bytes'] != 102400:
        raise ValueError('the KDBX floor must remain 100 KiB')
    value['enrollment_status'] = 'released'
    value['enrollment_evidence'] = evidence
    targets = [ROOT / f'host/{host}/etc/workstation-backup/{value["contract"]}.json',
               ROOT / f'infrastructure/monitoring/workstations/contracts/{value["contract"]}.json',
               ROOT / f'runbooks/disaster-recovery/contracts/{value["contract"]}.json']
    content = json.dumps(value, indent=2, sort_keys=True) + '\n'
    # Resume a partially completed release only if its bytes are identical.
    for target in targets:
        if target.exists() and target.read_text() != content:
            raise ValueError(f'cannot replace released contract: {target}')
    for target in targets:
        if not target.exists():
            with target.open('x') as output:
                output.write(content)
    print('Released immutable contracts. Review and commit them, then replace the pending ConfigMap mappings.')


if __name__ == '__main__':
    main()
