#!/usr/bin/env python3
"""Download Restic 0.19.1, verify upstream SHA256, then install atomically."""
import argparse
import bz2
import hashlib
import os
from pathlib import Path
import platform
import tempfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('/usr/local/bin'))
    args = parser.parse_args()
    system = {'Linux': 'linux', 'Darwin': 'darwin'}[platform.system()]
    architecture = {'x86_64': 'amd64', 'arm64': 'arm64', 'aarch64': 'arm64'}[platform.machine()]
    name = f'restic_0.19.1_{system}_{architecture}.bz2'
    base = 'https://github.com/restic/restic/releases/download/v0.19.1/'
    with urllib.request.urlopen(base + 'SHA256SUMS', timeout=60) as response:
        checksums = dict((fields[1].lstrip('*'), fields[0]) for line in response.read().decode().splitlines()
                         if len(fields := line.split()) == 2)
    with urllib.request.urlopen(base + name, timeout=120) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != checksums[name]:
        raise ValueError('upstream checksum mismatch')
    args.directory.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.restic-', dir=args.directory)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(bz2.decompress(archive))
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o755)
        os.replace(temporary, args.directory / 'restic')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Installed {name}; upstream SHA256 {checksums[name]}')


if __name__ == '__main__':
    main()
