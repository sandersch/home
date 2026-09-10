#!/usr/bin/env python3
"""Curated workstation scope, enrollment and daily client (Python 3.11+)."""
import argparse
import datetime as dt
import fcntl
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import stat
import subprocess
import sys
import tempfile
import time

MANIFEST = '.workstation-backup-manifest.json'
KDBX = bytes.fromhex('03d9a29a67fb4bb5')


def digest(value):
    return hashlib.sha256(value).hexdigest()


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    return json.loads(Path(path).read_text())


def patterns(path):
    return [s for line in Path(path).read_text().splitlines()
            if (s := line.strip()) and not s.startswith('#')]


def excluded(relative, rules):
    # only-file keeps one exact file within its parent; siblings and their trees
    # are omitted before opening them. Other exclusions still apply to that file.
    for rule in rules:
        if rule.startswith('only-file:'):
            keep = rule.removeprefix('only-file:')
            parent, separator, name = keep.rpartition('/')
            if not separator or not name or any(p in ('', '.', '..') for p in keep.split('/')):
                raise ValueError('only-file requires a canonical home-relative file path')
            if relative.startswith(parent + '/') and relative != keep:
                return True
    rules = [rule for rule in rules if not rule.startswith('only-file:')]
    # A slash anchors a rule to home; a bare glob matches any path component.
    # Match anchored globs component by component so '*' cannot cross '/'.
    parts = relative.split('/')
    return any((len(parts) >= len(rule.split('/')) and
                all(fnmatch.fnmatchcase(part, pattern)
                    for part, pattern in zip(parts, rule.split('/')))) if '/' in rule
               else any(fnmatch.fnmatchcase(p, rule) for p in relative.split('/'))
               for rule in rules)


def inventory(home, rules):
    home = Path(home)
    if home.is_symlink() or not home.is_dir():
        raise ValueError('home must be a real local directory')
    device = home.stat().st_dev
    records, omissions = {}, []

    def walk(directory):
        with os.scandir(directory) as entries:
            for entry in sorted(entries, key=lambda e: e.name):
                path = Path(entry.path)
                relative = path.relative_to(home).as_posix()
                if relative == MANIFEST:
                    continue
                if excluded(relative, rules):
                    omissions.append(str(path))
                    continue
                info = path.lstat()
                if info.st_dev != device or (stat.S_ISDIR(info.st_mode) and os.path.ismount(path)):
                    omissions.append(str(path))
                    continue
                if stat.S_ISDIR(info.st_mode):
                    tag = path / 'CACHEDIR.TAG'
                    if tag.is_file() and not tag.is_symlink():
                        with tag.open('rb') as stream:
                            cached = stream.read(43) == b'Signature: 8a477f597d28d172789f06886806bc55'
                        if cached:
                            omissions.append(str(path))
                            continue
                    records[relative] = {'type': 'dir'}
                    walk(path)
                elif stat.S_ISREG(info.st_mode):
                    # Reading all bytes also detects privacy failures and cloud placeholders
                    # that cannot be materialized. Never advance on an unreadable source.
                    try:
                        with path.open('rb') as stream:
                            while stream.read(1024 * 1024):
                                pass
                    except OSError as error:
                        raise OSError(error.errno,
                                      f'inventory read failed: {error.strerror or str(error)}',
                                      str(path)) from error
                    if path.stat().st_size != info.st_size:
                        raise ValueError(f'file changed during inventory: {path}')
                    records[relative] = {'type': 'file', 'size': info.st_size}
                elif stat.S_ISLNK(info.st_mode):
                    records[relative] = {'type': 'symlink', 'linktarget': os.readlink(path)}
                elif stat.S_ISSOCK(info.st_mode):
                    omissions.append(str(path))
                else:
                    raise ValueError(f'unsupported source type: {path}')
    walk(home)
    documents = home / 'Documents'
    database = home / database_path(records, home)
    if documents.is_symlink() or not documents.is_dir() or os.path.ismount(documents):
        raise ValueError('Documents must be a local directory')
    if database.is_symlink() or not database.is_file():
        raise ValueError('Dropbox/ccs.kdbx must be a local regular file')
    with database.open('rb') as stream:
        if stream.read(8) != KDBX:
            raise ValueError('KDBX signature mismatch')
    if not any(p.startswith('Documents/') and r['type'] == 'file' for p, r in records.items()):
        raise ValueError('Documents must contain at least one included regular file')
    return records, omissions


def database_path(records, home):
    """Resolve only Dropbox's known in-home File Provider alias, never traverse it."""
    path = 'Dropbox/ccs.kdbx'
    dropbox = records.get('Dropbox', {})
    if dropbox.get('type') == 'symlink':
        target = 'Library/CloudStorage/Dropbox'
        if dropbox.get('linktarget') not in (target, str(Path(home) / target)):
            raise ValueError('Dropbox alias must target its in-home CloudStorage directory')
        path = target + '/ccs.kdbx'
    parts = path.split('/')
    for index in range(1, len(parts)):
        if records.get('/'.join(parts[:index]), {}).get('type') != 'dir':
            raise ValueError('KDBX ancestors must be included local directories')
    database = records.get(path, {})
    if database.get('type') != 'file' or database.get('size', 0) < 102400:
        raise ValueError('KDBX missing from scope or below 100 KiB')
    return path


def totals(records, prefix=''):
    files = [r for p, r in records.items() if p.startswith(prefix) and r['type'] == 'file']
    return {'files': len(files), 'bytes': sum(r['size'] for r in files)}


def check_floors(records, contract):
    path = database_path(records, contract['source_roots'][0])
    if path != contract.get('kdbx_path', 'Dropbox/ccs.kdbx'):
        raise ValueError('KDBX path differs from released contract')
    for prefix, floor in contract['floors'].items():
        measured = totals(records, prefix)
        if any(measured[k] < floor[k] for k in ('files', 'bytes')):
            raise ValueError(f'below released floor: {prefix or "home"}')


def restic(*args, env=None):
    command = [os.environ.get('WORKSTATION_RESTIC', '/usr/local/bin/restic'), *map(str, args)]
    return subprocess.run(command, env=env, check=True, stdout=subprocess.PIPE).stdout


def enroll(args):
    records, _ = inventory(args.home, patterns(args.excludes))
    measured = {p: totals(records, p) for p in ('', 'Documents/')}
    value = {'contract': f'workstation-{args.host}-v1', 'hostname': args.host,
             'enrollment_status': 'measured-unreleased',
             'source_roots': [str(Path(args.home).absolute())],
             'exclusion_sha256': digest(Path(args.excludes).read_bytes()),
             'manifest': str(Path(args.home).absolute() / MANIFEST),
             'required_content': ['Documents', 'Dropbox/ccs.kdbx'],
             'kdbx_path': database_path(records, args.home),
             'measured': measured,
             'floors': {p: {k: math.ceil(n * .8) for k, n in m.items()} for p, m in measured.items()},
             'kdbx_minimum_bytes': 102400, 'shrink_baseline_samples': 7,
             'maximum_shrink_percent': 20,
             'measured_at': dt.datetime.now(dt.timezone.utc).isoformat(),
             'platform': platform.system()}
    # O_EXCL protects the proposed immutable release from accidental replacement.
    with open(args.output, 'x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    print(json.dumps(measured))


def backup(config, state):
    contract = read_json(config['contract'])
    if contract.get('enrollment_status') != 'released':
        raise ValueError('client contract has not been released')
    excludes = Path(config['excludes'])
    if digest(excludes.read_bytes()) != contract['exclusion_sha256']:
        raise ValueError('exclusion hash differs from released contract')
    home = Path(contract['source_roots'][0])
    if home != Path.home() or contract['hostname'] != config['host']:
        raise ValueError('client identity differs from released contract')
    if not restic('version').decode().startswith('restic 0.19.1 '):
        raise ValueError('Restic 0.19.1 is required')
    records, omissions = inventory(home, patterns(excludes))
    check_floors(records, contract)
    manifest = {'contract': contract['contract'], 'exclusion_sha256': contract['exclusion_sha256'],
                'records': records, 'measured': totals(records)}
    atomic(home / MANIFEST, manifest)
    env = os.environ.copy()
    credentials = Path(config['credentials'])
    if credentials.stat().st_mode & 0o077:
        raise ValueError('credentials must have mode 0600')
    env.update(read_json(credentials))
    # Restic sees the same exclusions the inventory resolved. Literal paths are
    # escaped for Restic's glob matcher; line breaks fail closed.
    with tempfile.TemporaryDirectory(prefix='workstation-', dir=state) as temporary:
        skip = Path(temporary) / 'excludes'
        escaped = []
        for path in omissions:
            if '\n' in path or '\r' in path:
                raise ValueError('excluded path contains a line break')
            escaped.append(''.join('[' + c + ']' if c in '*?[' else c for c in path))
        skip.write_text('\n'.join(escaped) + '\n')
        output = restic('--retry-lock', '15m', 'backup', '--json', '--host', config['host'],
                        '--one-file-system', '--exclude-file', skip, home, env=env)
    summaries = [json.loads(line) for line in output.splitlines()]
    summary = next(v for v in summaries if v.get('message_type') == 'summary')
    sid = summary['snapshot_id']
    # Restic exit 3 is raised above. Detect files added/removed during the scan too.
    nodes = [json.loads(line) for line in restic('ls', '--json', sid, env=env).splitlines()]
    attach_link_targets(nodes, nodes[0]['tree'], lambda tree: json.loads(restic('cat', 'blob', tree, env=env)))
    actual = snapshot_records(nodes, str(home), str(home / MANIFEST))
    if actual != records:
        raise ValueError(f'snapshot {sid} differs from inventory; success not advanced')
    return sid


def snapshot_records(nodes, home, manifest):
    records = {}
    for node in nodes:
        if node.get('struct_type') != 'node' and node.get('message_type') != 'node':
            continue
        path = node['path']
        if not path.startswith('/') or '..' in PurePosixPath(path).parts or str(PurePosixPath(path)) != path:
            raise ValueError('snapshot contains a noncanonical path')
        if path == manifest:
            continue
        if node['type'] == 'dir' and (path == home or home.startswith(path.rstrip('/') + '/')):
            continue
        if not path.startswith(home + '/'):
            raise ValueError('snapshot contains data outside source root')
        relative = path[len(home) + 1:]
        if relative in records:
            raise ValueError('duplicate snapshot path')
        if node['type'] == 'dir':
            records[relative] = {'type': 'dir'}
        elif node['type'] == 'file':
            records[relative] = {'type': 'file', 'size': node['size']}
        elif node['type'] == 'symlink':
            records[relative] = {'type': 'symlink', 'linktarget': node['linktarget']}
        else:
            raise ValueError('unsupported snapshot node type')
    return records


def attach_link_targets(nodes, root_tree, read_tree):
    """Restic ls omits link targets; obtain them from authenticated tree blobs."""
    cache = {}
    def tree_at(path):
        if path not in cache:
            if path == '/':
                tree_id = root_tree
            else:
                parent, _, name = path.rpartition('/')
                tree_id = next(n['subtree'] for n in tree_at(parent or '/')['nodes'] if n['name'] == name)
            cache[path] = read_tree(tree_id)
        return cache[path]
    for node in nodes:
        if node.get('type') == 'symlink':
            parent, _, name = node['path'].rpartition('/')
            stored = next(n for n in tree_at(parent or '/')['nodes'] if n['name'] == name)
            node['linktarget'] = stored['linktarget']


def daily(args):
    config = read_json(args.config)
    state = Path.home() / '.local/state/workstation-backup'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / 'lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        failed = False
        for task in ('backup', 'documents'):
            marker = state / (task + '.json')
            previous = read_json(marker) if marker.exists() else {'time': 0}
            age = time.time() - previous['time']
            if 0 <= age < 86400:
                continue
            try:
                sid = None
                if task == 'backup':
                    sid = backup(config, state)
                else:
                    subprocess.run(['/usr/local/bin/vault-ingest', 'documents'], check=True)
                atomic(marker, {'time': time.time(), 'snapshot_id': sid})
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                print(f'{task}: {error}', file=sys.stderr)
                failed = True
        if failed:
            raise SystemExit(1)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    measure = sub.add_parser('measure')
    measure.add_argument('--host', choices=['ryze', 'm5c'], required=True)
    measure.add_argument('--home', default=str(Path.home()))
    measure.add_argument('--excludes', required=True)
    measure.add_argument('--output', required=True)
    run = sub.add_parser('daily')
    run.add_argument('--config', default=str(Path.home() / '.config/workstation-backup/config.json'))
    args = parser.parse_args()
    enroll(args) if args.action == 'measure' else daily(args)


if __name__ == '__main__':
    main()
