#!/usr/bin/env python3
"""Attended installation; schedules remain disabled unless --enable is supplied."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host/workstations'))
from workstation import atomic, digest, read_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', choices=['ryze', 'm5c'], required=True)
    parser.add_argument('--contract', type=Path, required=True)
    parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--enable', action='store_true')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    if os.geteuid() == 0 or not sys.stdin.isatty():
        raise ValueError('run as the attended desktop user, with sudo available')
    expected = {'ryze': 'Linux', 'm5c': 'Darwin'}[args.host]
    if platform.system() != expected:
        raise ValueError('platform does not match host')
    home = Path.home()
    contract = read_json(args.contract)
    scope = ROOT / f'host/{args.host}/etc/workstation-backup/{contract["contract"]}.excludes'
    if (contract.get('enrollment_status') != 'released' or contract['hostname'] != args.host or
            contract['source_roots'] != [str(home)] or contract['exclusion_sha256'] != digest(scope.read_bytes())):
        raise ValueError('released contract, home, host and exclusion hash must match')
    credentials = read_json(args.credentials)
    allowed = {'RESTIC_REPOSITORY', 'RESTIC_PASSWORD', 'RESTIC_REST_USERNAME', 'RESTIC_REST_PASSWORD'}
    if set(credentials) != allowed or credentials['RESTIC_REST_USERNAME'] != args.host:
        raise ValueError('client may receive only its own NAS credentials')
    if not subprocess.check_output(['/usr/local/bin/restic', 'version']).startswith(b'restic 0.19.1 '):
        raise ValueError('install checksum-verified Restic 0.19.1 first')
    library = Path('/usr/local/lib/workstation-backup')
    subprocess.run(['sudo', 'install', '-d', '-m', '0755', str(library)], check=True)
    for name in ('workstation.py', 'documents.py'):
        subprocess.run(['sudo', 'install', '-m', '0755', str(ROOT / 'host/workstations' / name), str(library / name)], check=True)
    subprocess.run(['sudo', 'install', '-m', '0755',
                    str(ROOT / f'host/{args.host}/usr/local/bin/vault-ingest'), '/usr/local/bin/vault-ingest'], check=True)
    config = home / '.config/workstation-backup'
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic(config / 'contract.json', contract)
    atomic(config / 'credentials.json', credentials)
    shutil.copyfile(scope, config / 'excludes')
    atomic(config / 'config.json', {'host': args.host, 'contract': str(config / 'contract.json'),
                                  'excludes': str(config / 'excludes'), 'credentials': str(config / 'credentials.json')})
    if args.host == 'ryze':
        directory = home / '.config/systemd/user'
        directory.mkdir(parents=True, exist_ok=True)
        for name in ('workstation-backup.service', 'workstation-backup.timer'):
            shutil.copyfile(ROOT / 'host/ryze/etc/systemd/user' / name, directory / name)
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
    else:
        if not Path('/opt/homebrew/bin/python3').is_file():
            raise ValueError('the launchd Python path must exist; install Python 3.11+ via Homebrew')
        directory = home / 'Library/LaunchAgents'
        directory.mkdir(parents=True, exist_ok=True)
        plist = plistlib.loads((ROOT / 'host/m5c/Library/LaunchAgents/run.worm.workstation-backup.plist').read_bytes())
        state = home / '.local/state/workstation-backup'
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        plist['StandardOutPath'] = str(state / 'launchd.out.log')
        plist['StandardErrorPath'] = str(state / 'launchd.err.log')
        (directory / 'run.worm.workstation-backup.plist').write_bytes(plistlib.dumps(plist))
    if args.enable:
        evidence = read_json(args.evidence) if args.evidence else {}
        required = ['nas_restore_passed', 'b2_restore_passed', 'kdbx_opened', 'append_only_passed',
                    'network_retry_passed', 'documents_promoted', 'vault_lock_independence_passed']
        if args.host == 'm5c':
            required += ['fda_launchd_passed', 'icloud_optimize_disabled', 'photos_mail_no_unique_data',
                         'filevault_enabled', 'dropbox_materialized', 'metadata_restore_passed']
        if evidence.get('host') != args.host or not all(evidence.get(k) is True for k in required):
            raise ValueError('activation evidence is incomplete; schedules remain disabled')
        if args.host == 'ryze':
            subprocess.run(['systemctl', '--user', 'enable', '--now', 'workstation-backup.timer'], check=True)
        else:
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}',
                            str(directory / 'run.worm.workstation-backup.plist')], check=True)
    print('Client installed; ' + ('schedule enabled.' if args.enable else 'schedule not enabled.'))


if __name__ == '__main__':
    main()
