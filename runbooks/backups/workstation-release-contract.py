#!/usr/bin/env python3
"""Release reviewed measured contracts without replacing an existing release."""
import argparse
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host/workstations'))
from workstation import churn_tolerance, digest, read_json


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
    match = re.fullmatch(rf'workstation-{host}-v([1-9][0-9]*)', value['contract'])
    if not match:
        raise ValueError('unexpected contract release name')
    number = int(match[1])
    gates = ['inventory_reviewed', 'capacity_reviewed', 'required_content_readable']
    if host == 'm5c':
        gates += ['fda_launchd_passed', 'icloud_optimize_disabled', 'photos_mail_no_unique_data', 'dropbox_materialized']
    if not all(evidence.get(gate) is True for gate in gates):
        raise ValueError('attended enrollment gates have not passed')
    # Read once: the hashed bytes are exactly the frozen copy written below.
    exclusions = (ROOT / f'host/{host}/etc/workstation-backup/excludes').read_bytes()
    if value['exclusion_sha256'] != digest(exclusions):
        raise ValueError('exclusions changed after measurement')
    directories = [ROOT / f'host/{host}/etc/workstation-backup',
                   ROOT / 'infrastructure/monitoring/workstations/contracts',
                   ROOT / 'runbooks/disaster-recovery/contracts']
    # Versions are contiguous: vN is released only after v(N-1) everywhere.
    previous = f'workstation-{host}-v{number - 1}'
    if number > 1 and not all((d / f'{previous}.json').is_file() and (d / f'{previous}.excludes').is_file()
                              for d in directories):
        raise ValueError(f'{previous} must be released before {value["contract"]}')
    for prefix in ('', 'Documents/'):
        expected = {key: math.ceil(value['measured'][prefix][key] * .8) for key in ('files', 'bytes')}
        if min(expected.values()) < 1 or value['floors'][prefix] != expected:
            raise ValueError('released floors must be exactly 80% of the measured scope, rounded up')
    if value['kdbx_minimum_bytes'] != 102400:
        raise ValueError('the KDBX floor must remain 100 KiB')
    if value.get('churn_tolerance') != churn_tolerance(value['measured']['']['files'], value['kdbx_path']):
        raise ValueError('churn tolerance must be the standard bound protecting required content')
    value['enrollment_status'] = 'released'
    value['enrollment_evidence'] = evidence
    content = json.dumps(value, indent=2, sort_keys=True) + '\n'
    # Each version keeps its own exclusions so historical snapshots stay verifiable.
    outputs = {}
    for directory in directories:
        outputs[directory / f'{value["contract"]}.json'] = content.encode()
        outputs[directory / f'{value["contract"]}.excludes'] = exclusions
    # Resume a partially completed release only if its bytes are identical.
    for target, text in outputs.items():
        if target.exists() and target.read_bytes() != text:
            raise ValueError(f'cannot replace released contract: {target}')
    for target, text in outputs.items():
        if not target.exists():
            with target.open('xb') as output:
                output.write(text)
    print(f'Released immutable contracts. Review and commit them, then add {value["contract"]}.json and '
          f'{value["contract"]}.excludes to the restic-workstation-contracts ConfigMap.')


if __name__ == '__main__':
    main()
