#!/usr/bin/env python3
"""Create SOPS-only per-host credentials, or export only the client subset."""
import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['create', 'export-client'])
    parser.add_argument('--host', choices=['ryze', 'm5c'], required=True)
    parser.add_argument('--secret', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == 'export-client':
        if not args.output or args.output.exists():
            raise ValueError('provide a new private --output file outside the repository')
        root = Path(__file__).resolve().parents[2]
        if args.output.resolve().is_relative_to(root):
            raise ValueError('client credentials must never be written inside the repository')
        result = subprocess.run(['sops', '--decrypt', '--output-type', 'json', str(args.secret)],
                                check=True, capture_output=True)
        secret = json.loads(result.stdout)
        if secret['metadata']['name'] != 'restic-workstation-' + args.host:
            raise ValueError('host identity mismatch')
        with args.output.open('x') as stream:
            stream.write(secret['stringData']['client.json'] + '\n')
        return
    if not sys.stdin.isatty() or args.secret.exists():
        raise ValueError('credential creation requires an attended terminal and a new secret path')
    endpoint = input(f'{args.host} Tailscale HTTPS FQDN (restic-{args.host}.<tailnet>.ts.net): ').strip()
    if not endpoint.startswith('restic-' + args.host + '.') or not endpoint.endswith('.ts.net') or '/' in endpoint:
        raise ValueError('unexpected Tailscale endpoint')
    repository = input('Dedicated private B2 repository (s3:https://endpoint/bucket/prefix): ').strip()
    if not repository.startswith('s3:https://'):
        raise ValueError('explicit HTTPS S3 endpoint required')
    region = input('B2 S3 region: ').strip()
    key_id = getpass.getpass('Bucket-scoped B2 application key ID: ')
    key = getpass.getpass('Bucket-scoped B2 application key: ')
    if not all((region, key_id, key)):
        raise ValueError('all B2 fields are required')
    nas_password, b2_password, http_password = [secrets.token_urlsafe(48) for _ in range(3)]
    hashed = subprocess.run(['htpasswd', '-niB', args.host], input=(http_password + '\n').encode(),
                            check=True, capture_output=True).stdout.decode()
    if not hashed.startswith(args.host + ':$2'):
        raise ValueError('htpasswd did not produce bcrypt')
    maintenance = {'nas': {'RESTIC_REPOSITORY': '/repo/nas/workstations/' + args.host,
                           'RESTIC_PASSWORD': nas_password},
                   'b2': {'RESTIC_REPOSITORY': repository, 'RESTIC_PASSWORD': b2_password,
                          'AWS_ACCESS_KEY_ID': key_id, 'AWS_SECRET_ACCESS_KEY': key,
                          'AWS_DEFAULT_REGION': region}}
    client = {'RESTIC_REPOSITORY': 'rest:https://' + endpoint + '/', 'RESTIC_PASSWORD': nas_password,
              'RESTIC_REST_USERNAME': args.host, 'RESTIC_REST_PASSWORD': http_password}
    manifest = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {
        'name': 'restic-workstation-' + args.host, 'namespace': 'monitoring'},
        'type': 'Opaque', 'stringData': {'htpasswd': hashed,
            'maintenance.json': json.dumps(maintenance), 'client.json': json.dumps(client)}}
    result = subprocess.run(['sops', '--encrypt', '--input-type', 'json', '--output-type', 'yaml',
        '--filename-override', str(args.secret), '/dev/stdin'],
        input=json.dumps(manifest).encode(), check=True, capture_output=True)
    if b'ENC[AES256_GCM' not in result.stdout or b'sops:' not in result.stdout:
        raise ValueError('encryption output is invalid')
    with args.secret.open('xb') as stream:
        stream.write(result.stdout)
    print('Encrypted operational credentials created; escrow them before initializing repositories.')


if __name__ == '__main__':
    main()
