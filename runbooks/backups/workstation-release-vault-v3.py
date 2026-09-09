#!/usr/bin/env python3
"""Attended v3 release after m5c document promotion; does not activate it."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys


def main():
    if os.geteuid() != 0 or not sys.stdin.isatty():
        raise ValueError('run attended as root on minis after checking the promoted Mac seed')
    root = Path(__file__).resolve().parents[2]
    vault = Path('/mnt/vault')
    source = vault / 'documents/m5c'
    subprocess.run(['mountpoint', '-q', str(vault)], check=True)
    if subprocess.check_output(['findmnt', '-n', '-o', 'SOURCE', '--target', str(vault)]).strip() != b'/dev/mapper/vault':
        raise ValueError('unexpected vault mount')
    completion = vault / '.restore-tests/ingestion-m5c.complete'
    if not completion.is_file() or completion.is_symlink() or completion.stat().st_uid != 0:
        raise ValueError('trusted m5c promotion completion marker is absent')
    files = size = 0
    def fail(error):
        raise error
    for base, directories, names in os.walk(source, onerror=fail, followlinks=False):
        for name in directories + names:
            path = Path(base) / name
            if path.is_symlink() or path.stat().st_dev != vault.stat().st_dev:
                raise ValueError('promoted documents contain a link or mount')
            if path.is_file():
                with path.open('rb') as stream:
                    while stream.read(1024 * 1024):
                        pass
                files += 1
                size += path.stat().st_size
    if files < 1 or size < 1:
        raise ValueError('Mac seed is empty')
    value = json.loads((root / 'infrastructure/monitoring/contracts/vault-v2.json').read_text())
    value['contract'] = 'vault-v3'
    value['required_content'].append({'path': '/data/vault/documents/m5c', 'kind': 'directory',
                                    'minimum_files': math.ceil(files * .8), 'minimum_bytes': math.ceil(size * .8)})
    content = json.dumps(value, indent=2) + '\n'
    exclusions = (root / 'infrastructure/monitoring/contracts/vault-v2.excludes').read_text()
    outputs = {}
    for directory in ('infrastructure/monitoring/contracts', 'runbooks/disaster-recovery/contracts'):
        outputs[root / directory / 'vault-v3.json'] = content
        outputs[root / directory / 'vault-v3.excludes'] = exclusions
    for path, text in outputs.items():
        if path.exists() and path.read_text() != text:
            raise ValueError('cannot replace an immutable v3 release')
    for path, text in outputs.items():
        if not path.exists():
            with path.open('x') as stream:
                stream.write(text)
    print(f'Released v3 from {files} files / {size} bytes. Sentinel and active version remain unchanged.')


if __name__ == '__main__':
    main()
