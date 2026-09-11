#!/usr/bin/env python3
"""Restore an exact snapshot into new private scratch and verify file metadata."""
import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


def read_xattr(path, name):
    if sys.platform == 'darwin':
        # Python exposes os.getxattr on Linux, but not on macOS.
        value = subprocess.check_output(['/usr/bin/xattr', '-p', '-x', '-s', name, str(path)])
        return bytes.fromhex(value.decode('ascii'))
    return os.getxattr(path, name, follow_symlinks=False)


def mtime_ns(value):
    """Restic records nanoseconds; datetime keeps only microseconds, so split them off."""
    match = re.fullmatch(r'(.+T\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)', value)
    if not match:
        raise ValueError('unexpected snapshot mtime: ' + value)
    seconds = dt.datetime.fromisoformat(match[1] + match[3].replace('Z', '+00:00'))
    return int(seconds.timestamp()) * 10**9 + int((match[2] or '').ljust(9, '0'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', required=True)
    parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--destination', choices=['nas', 'b2'], required=True)
    parser.add_argument('--scratch-parent', type=Path, required=True)
    parser.add_argument('--metadata-path', action='append', default=[], help='absolute snapshot path whose xattrs must match')
    parser.add_argument('--restic', default='/usr/local/bin/restic')
    args = parser.parse_args()
    os.umask(0o077)
    if not re.fullmatch('[0-9a-f]{64}', args.snapshot):
        raise ValueError('a full exact snapshot ID is required')
    parent = args.scratch_parent
    if parent.is_symlink() or not parent.is_dir() or parent.stat().st_mode & 0o077:
        raise ValueError('scratch parent must be an existing private directory')
    if args.credentials.is_symlink() or args.credentials.stat().st_mode & 0o077:
        raise ValueError('credentials must be private')
    credentials = json.loads(args.credentials.read_text())
    env = {**os.environ, **credentials}
    def restic(*values):
        return subprocess.check_output([args.restic, '--no-cache', *values], env=env)
    rows = json.loads(restic('snapshots', '--json', args.snapshot))
    if len(rows) != 1 or rows[0]['id'] != args.snapshot:
        raise ValueError('exact snapshot not found')
    if len(rows[0]['paths']) != 1:
        raise ValueError('a workstation snapshot must contain one home source root')
    source_root = Path(rows[0]['paths'][0])
    for source in rows[0]['paths']:
        if parent.resolve().is_relative_to(Path(source)) and not {'restore-scratch', '.restore-tests'} & set(parent.parts):
            raise ValueError('scratch inside the backed-up home must use an excluded restore-scratch or .restore-tests directory')
    started = time.time()
    target = Path(tempfile.mkdtemp(prefix='workstation-restore-', dir=parent))
    recovered = target / 'home'
    print(f'Restoring into {recovered}', flush=True)
    subprocess.run([args.restic, '--no-cache', 'restore', args.snapshot + ':' + str(source_root), '--target', str(recovered), '--verify'],
                   env=env, check=True)
    nodes = [json.loads(line) for line in restic('ls', '--json', args.snapshot).splitlines()]
    verified = 0
    for node in nodes:
        if node.get('message_type') != 'node':
            continue
        source_path = Path(node['path'])
        # Subfolder restore materializes home contents beneath a fresh scratch
        # directory; its synthetic root is not the replacement OS's home inode.
        if source_path == source_root:
            continue
        if not source_path.is_relative_to(source_root):
            if node['type'] == 'dir' and source_root.is_relative_to(source_path):
                continue
            raise ValueError('unexpected snapshot path outside home')
        path = recovered / source_path.relative_to(source_root)
        info = path.lstat()
        kind = node['type']
        if kind == 'file':
            if not stat.S_ISREG(info.st_mode) or info.st_size != node['size']:
                raise ValueError('restored file type/size mismatch: ' + node['path'])
        elif kind == 'symlink':
            if not path.is_symlink():
                raise ValueError('restored symlink missing')
            directory, _, name = node['path'].rpartition('/')
            tree = json.loads(restic('cat', 'tree', args.snapshot + ':' + (directory or '/')))
            stored = next(n for n in tree['nodes'] if n['name'] == name)
            if os.readlink(path) != stored['linktarget']:
                raise ValueError('restored symlink target mismatch')
        elif kind != 'dir' or not stat.S_ISDIR(info.st_mode):
            raise ValueError('unsupported restored node type')
        if (info.st_uid, info.st_gid) != (node['uid'], node['gid']):
            raise ValueError('ownership differs; use an attended privileged restore on the matching OS')
        if kind != 'symlink':
            go_mode = node['mode']
            mode = go_mode & 0o777
            for bit, permission in [(23, 0o4000), (22, 0o2000), (20, 0o1000)]:
                if go_mode & (1 << bit):
                    mode |= permission
            if stat.S_IMODE(info.st_mode) != mode:
                raise ValueError('restored mode mismatch: ' + node['path'])
            # Allow filesystems that keep only microseconds, never float rounding.
            if abs(info.st_mtime_ns - mtime_ns(node['mtime'])) >= 1000:
                raise ValueError('restored mtime mismatch: ' + node['path'])
        verified += 1
    for selected in args.metadata_path:
        if not any(n.get('path') == selected for n in nodes):
            raise ValueError('metadata sample not present in snapshot')
        directory, _, name = selected.rpartition('/')
        tree = json.loads(restic('cat', 'tree', args.snapshot + ':' + (directory or '/')))
        stored = next(n for n in tree['nodes'] if n['name'] == name)
        attrs = stored.get('extended_attributes') or []
        if not attrs:
            raise ValueError('metadata sample contains no stored extended attributes')
        for attr in attrs:
            if read_xattr(recovered / Path(selected).relative_to(source_root), attr['name']) != base64.b64decode(attr['value']):
                raise ValueError('extended attribute/resource fork mismatch')
    report = {'snapshot_id': args.snapshot, 'destination': args.destination, 'hostname': rows[0]['hostname'],
              'restored_nodes': verified, 'elapsed_seconds': time.time() - started,
              'scratch': str(target), 'metadata_paths': args.metadata_path, 'kdbx_manually_opened': False}
    (target / 'restore-evidence.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    print('Open the restored KDBX manually and record that result. Scratch is retained for inspection.')


if __name__ == '__main__':
    main()
