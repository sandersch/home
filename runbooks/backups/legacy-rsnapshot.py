#!/usr/bin/env python3
"""Attended, exact-ID archive of retired rsnapshot history. No deletion operations."""
import argparse
import base64
import collections
from collections.abc import Mapping
from contextlib import closing
import datetime as dt
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import stat
import subprocess
import tempfile
import time

SOURCE = Path('/mnt/backups/snapshots')
REPO = Path('/mnt/backups/legacy-rsnapshot')
CONTROL = Path('/mnt/backups/.legacy-rsnapshot-control')
MOUNT = Path('/mnt/backups')
UUID = 'cc1cedb8-ef22-44b5-b1d0-5ca020d72669'
DEVICE = Path('/dev/mapper/hoardvg-backuplv')
BINARY = Path('/usr/local/lib/legacy-rsnapshot/restic')


class Inventory(Mapping):
    """Disk-backed mapping: legacy histories can contain millions of directory entries."""
    def __init__(self, path=None):
        if path is None:
            fd, name = tempfile.mkstemp(prefix='inventory-', suffix='.sqlite', dir=CONTROL)
            os.close(fd)
            path = Path(name)
        self.path = Path(path)
        self.db = sqlite3.connect(self.path)
        self.db.execute('CREATE TABLE IF NOT EXISTS entries (path TEXT PRIMARY KEY, record TEXT NOT NULL)')

    def __getitem__(self, key):
        row = self.db.execute('SELECT record FROM entries WHERE path=?', (key,)).fetchone()
        if row is None:
            raise KeyError(key)
        return json.loads(row[0])

    def __setitem__(self, key, value):
        self.db.execute('INSERT INTO entries VALUES (?, ?)', (key, json.dumps(value, sort_keys=True)))

    def __iter__(self):
        return (row[0] for row in self.db.execute('SELECT path FROM entries ORDER BY path'))

    def __len__(self):
        return self.db.execute('SELECT count(*) FROM entries').fetchone()[0]

    def items(self):
        return ((p, json.loads(r)) for p, r in self.db.execute('SELECT path, record FROM entries ORDER BY path'))

    def values(self):
        return (r for _, r in self.items())

    def __eq__(self, other):
        if len(self) != len(other):
            return False
        if isinstance(other, Inventory):
            self.finish()
            other.finish()
            self.db.execute('ATTACH DATABASE ? AS comparison', (str(other.path),))
            try:
                # Older inventories encoded the source root as an empty relative
                # path; current inventories encode it as '.'. Treat those as the
                # same entry while still comparing its complete metadata record.
                roots = self.db.execute("""SELECT
                    (SELECT record FROM entries WHERE path IN ('', '.')),
                    (SELECT record FROM comparison.entries WHERE path IN ('', '.')),
                    (SELECT count(*) FROM entries WHERE path IN ('', '.')),
                    (SELECT count(*) FROM comparison.entries WHERE path IN ('', '.'))""").fetchone()
                if roots[2:] != (1, 1) or roots[0] != roots[1]:
                    return False
                return self.db.execute("""SELECT 1 FROM entries a LEFT JOIN comparison.entries b
                    ON a.path=b.path WHERE a.path NOT IN ('', '.')
                    AND (b.path IS NULL OR a.record != b.record) LIMIT 1""").fetchone() is None
            finally:
                self.db.execute('DETACH DATABASE comparison')
        return all(p in other and r == other[p] for p, r in self.items())

    def finish(self):
        self.db.commit()
        return self

    def __del__(self):
        if hasattr(self, 'db'):
            self.db.close()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*args):
    return subprocess.check_output([str(a) for a in args], text=True)


def canonical(path):
    require(path.is_absolute() and path.resolve() == path, f'symlink/noncanonical path: {path}')


def private(path):
    canonical(path)
    s = path.stat()
    require(s.st_uid == 0 and s.st_gid == 0 and stat.S_IMODE(s.st_mode) == 0o700,
            f'expected root:root 0700: {path}')


def save(path, value):
    if isinstance(value, Inventory):
        value.finish()
        with closing(sqlite3.connect(path)) as destination:
            value.db.backup(destination)
        os.chmod(path, 0o600)
        return
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.record-')
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, sort_keys=True)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def mount_guard():
    canonical(MOUNT)
    list(MOUNT.iterdir())  # Trigger existing automount before inspecting it.
    rows = json.loads(command('findmnt', '--json', '--real', '--target', MOUNT,
                              '-o', 'TARGET,SOURCE,FSTYPE,UUID,FSROOT'))['filesystems']
    require(len(rows) == 1, 'ambiguous backup mount')
    row = rows[0]
    require(row['target'] == str(MOUNT) and row['fstype'] == 'ext4'
            and row['uuid'] == UUID and row['fsroot'] == '/'
            and Path(row['source']).resolve() == DEVICE.resolve()
            and Path('/dev/disk/by-uuid', UUID).resolve() == DEVICE.resolve(),
            'backup mount identity mismatch')
    sentinel = MOUNT / '.backup-sentinel'
    canonical(sentinel)
    s = sentinel.stat()
    require(stat.S_ISREG(s.st_mode) and (s.st_uid, s.st_gid, stat.S_IMODE(s.st_mode)) == (0, 0, 0o444)
            and sentinel.read_text().splitlines()[0] == UUID, 'backup sentinel mismatch')
    mounts = json.loads(command('findmnt', '--json', '--list', '-o', 'TARGET'))['filesystems']
    for row in mounts:
        target = Path(row['target'])
        require(not target.is_relative_to(MOUNT) or target == MOUNT,
                f'nested mount below backup filesystem: {target}')
    for path in (SOURCE, REPO, CONTROL):
        canonical(path)


def writers():
    # Also catches cron-launched rsnapshot and shell command lines, without matching this helper.
    for proc in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            argv = proc.read_bytes().replace(b'\0', b' ').decode(errors='replace')
        except FileNotFoundError:
            continue
        require(not re.search(r'(?<![\w-])rsnapshot(?:\s|$)', argv), 'rsnapshot process remains active')
    # Conservative: disabled service/config references still require attended review/removal.
    roots = ['/etc/crontab', '/etc/anacrontab', '/var/spool/at', '/etc/cron.d', '/etc/cron.hourly', '/etc/cron.daily',
             '/etc/cron.weekly', '/etc/cron.monthly', '/var/spool/cron',
             '/etc/systemd/system', '/usr/lib/systemd/system', '/usr/local/lib/systemd/system',
             '/run/systemd/system', '/root/.config/systemd/user']
    roots.extend(str(p) for p in Path('/home').glob('*/.config/systemd/user'))
    for root in map(Path, roots):
        paths = [root] if root.is_file() else root.rglob('*') if root.exists() else []
        for path in paths:
            if not path.is_file():
                continue
            for line in path.read_text(errors='replace').splitlines():
                if not line.lstrip().startswith('#'):
                    require(not re.search(r'\brsnapshot\b', line), f'rsnapshot schedule reference: {path}')


def load_resume_inventory(path):
    canonical(path)
    require(path.is_relative_to(CONTROL), 'resume inventory must live under the private control directory')
    metadata = path.stat()
    require(stat.S_ISREG(metadata.st_mode) and (metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) == (0, 0, 0o600),
            'resume inventory must be a root-owned 0600 regular file')
    require(0 <= time.time() - metadata.st_mtime <= 2 * 60 * 60,
            'resume inventory must be less than two hours old')
    require(path.parent.name.startswith('archive-'), 'resume inventory must be from an archive attempt')
    report_path = path.parent / 'preflight.json'
    report_metadata = report_path.stat()
    require((report_metadata.st_uid, report_metadata.st_gid, stat.S_IMODE(report_metadata.st_mode)) == (0, 0, 0o600),
            'resume preflight record must be root-owned 0600')
    report = json.loads(report_path.read_text())
    source = report.get('source', {})
    require(source.get('entries', 0) > 1 and source.get('unique_inode_logical_bytes', 0) > 0,
            'resume preflight record has no source measurements')
    print('Checking the saved source inventory and capacity record...', flush=True)
    records = Inventory(path)
    try:
        sample = json.loads(records.db.execute('SELECT record FROM entries LIMIT 1').fetchone()[0])
    except (sqlite3.DatabaseError, TypeError, json.JSONDecodeError) as exc:
        raise RuntimeError('resume inventory cannot be read') from exc
    require(sample.get('type') in ('dir', 'file', 'symlink', 'fifo', 'chardev', 'dev', 'socket'),
            'resume inventory has an invalid first record')
    print(f'Saved inventory header is readable; {source["entries"]} recorded entries.', flush=True)
    return records, source


def inventory(root):
    require(root.is_dir() and not root.is_symlink(), 'source missing or substituted')
    records = Inventory()
    stack = [root]
    scanned = 0
    device = root.stat().st_dev
    while stack:
        path = stack.pop()
        s = path.lstat()
        require(s.st_dev == device, f'nested filesystem: {path}')
        kind = next((name for test, name in ((stat.S_ISREG, 'file'), (stat.S_ISDIR, 'dir'),
                    (stat.S_ISLNK, 'symlink'), (stat.S_ISFIFO, 'fifo'),
                    (stat.S_ISCHR, 'chardev'), (stat.S_ISBLK, 'dev'), (stat.S_ISSOCK, 'socket'))
                    if test(s.st_mode)), None)
        require(kind is not None, f'unsupported type: {path}')
        record = dict(type=kind, mode=stat.S_IMODE(s.st_mode), uid=s.st_uid, gid=s.st_gid,
                      size=s.st_size if kind == 'file' else 0, mtime_ns=s.st_mtime_ns,
                      ctime_ns=s.st_ctime_ns, inode=s.st_ino, device=s.st_dev,
                      nlink=s.st_nlink, blocks=s.st_blocks, rdev=s.st_rdev,
                      xattrs={n: base64.b64encode(os.getxattr(path, n, follow_symlinks=False)).decode()
                              for n in os.listxattr(path, follow_symlinks=False)})
        if kind == 'symlink':
            record['linktarget'] = os.readlink(path)
        relative = '.' if path == root else str(path)[len(str(root)) + 1:]
        records[relative] = record
        scanned += 1
        if scanned % 100000 == 0:
            records.db.commit()
            print(f'Inventory: {scanned} entries scanned', flush=True)
        if kind == 'dir':
            stack.extend(sorted(path.iterdir(), reverse=True))
    require(len(records) > 1, 'source is empty')
    return records.finish()


def totals(records):
    # SQLite distinct inode accounting avoids a second in-memory inventory.
    if isinstance(records, Inventory):
        records.finish()
        query = """SELECT sum(size), sum(blocks) FROM (
            SELECT json_extract(record, '$.size') AS size,
                   json_extract(record, '$.blocks') * 512 AS blocks
            FROM entries GROUP BY json_extract(record, '$.device'), json_extract(record, '$.inode'))"""
        logical, allocated = records.db.execute(query).fetchone()
        types = dict(records.db.execute("SELECT json_extract(record, '$.type'), count(*) FROM entries GROUP BY 1"))
    else:
        unique = {(r['device'], r['inode']): r for r in records.values()}
        logical = sum(r['size'] for r in unique.values())
        allocated = sum(r['blocks'] * 512 for r in unique.values())
        types = dict(collections.Counter(r['type'] for r in records.values()))
    return dict(entries=len(records), types=types, unique_inode_logical_bytes=logical,
                allocated_bytes=allocated)



def capacity(records, usage, source_logical_bytes=None):
    size = (totals(records)['unique_inode_logical_bytes']
            if source_logical_bytes is None else source_logical_bytes)
    total, free = usage.f_blocks * usage.f_frsize, usage.f_bavail * usage.f_frsize
    required = (size * 12 + 9) // 10 + (total + 9) // 10
    require(free >= required, f'insufficient capacity: available={free}, required={required}')
    return dict(filesystem_bytes=total, available_bytes=free, required_available_bytes=required)


def mtime(value):
    match = re.fullmatch(r'(.+T\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)', value)
    require(match is not None, 'invalid Restic timestamp')
    return int(dt.datetime.fromisoformat(match[1] + match[3].replace('Z', '+00:00')).timestamp()) * 10**9 + int((match[2] or '').ljust(9, '0'))


def archived_inventory(raw, source):
    result = Inventory()
    lines = raw.open() if isinstance(raw, Path) else raw.splitlines()
    for line in lines:
        node = json.loads(line)
        if node.get('struct_type') != 'node':
            continue
        path = Path(node['path'])
        if path != source and path in source.parents:
            require(node['type'] == 'dir', 'invalid ancestor')
            continue
        require(path.is_relative_to(source), 'unexpected archived path')
        mode = node.get('mode', 0) & 0o777
        for bit, permission in ((23, 0o4000), (22, 0o2000), (20, 0o1000)):
            if node.get('mode', 0) & (1 << bit):
                mode |= permission
        result[str(path.relative_to(source))] = dict(type=node['type'], mode=mode,
            uid=node['uid'], gid=node['gid'], size=node.get('size', 0) if node['type'] == 'file' else 0,
            mtime_ns=mtime(node['mtime']))
    if isinstance(raw, Path):
        lines.close()
    return result.finish()


def compare_listing(records, listing):
    # Operator accepted Restic's inherent Unix-socket omission on 2026-09-20.
    expected_count = sum(r['type'] != 'socket' for r in records.values())
    require(expected_count == len(listing), 'archived path count mismatch')
    for path, actual in listing.items():
        # Restic and the two inventory generations spell the source root as
        # '.', while earlier saved inventories used the empty relative path.
        record_path = '' if path == '.' and path not in records and '' in records else path
        require(record_path in records, 'unexpected archived path')
        expected = records[record_path]
        require(all(expected[k] == v for k, v in actual.items()), f'archived metadata mismatch: {path}')


def compare_symlinks(restic, sid, records):
    # The JSON listing omits link targets in Restic 0.19.1. Its long text listing
    # exposes them without restoring millions of links or using millions of globs.
    expected = 0
    for path, record in records.items():
        if record['type'] == 'symlink':
            expected += 1
            require(' -> ' not in path and all(c.isprintable() for c in path + record['linktarget']),
                    'symlink requires an attended alternative to unambiguous long-list verification')
    raw = restic('ls', '--long', sid)
    lines = raw.open() if isinstance(raw, Path) else raw.splitlines()
    seen = Inventory()
    try:
        for line in lines:
            fields = line.rstrip('\n').split(maxsplit=6)
            if len(fields) != 7 or not fields[0].startswith('L'):
                continue
            path, separator, target = fields[6].partition(' -> ')
            require(bool(separator) and Path(path).is_relative_to(SOURCE), 'invalid archived symlink listing')
            relative = str(Path(path).relative_to(SOURCE))
            record = records[relative]
            require(record['type'] == 'symlink' and record['linktarget'] == target,
                    f'archived symlink target mismatch: {relative}')
            seen[relative] = {'target': target}
    finally:
        if isinstance(raw, Path):
            lines.close()
    seen.finish()
    require(len(seen) == expected, 'archived symlink count mismatch')


def samples(records):
    selected = set()
    categories = set()
    hardlink_key = None
    hardlink_paths = []
    tops = {p.split('/')[0] for p, r in records.items()
            if p not in ('', '.') and r['type'] != 'socket'}
    for path, r in records.items():
        if path in ('', '.') or r['type'] == 'socket':
            continue
        if r['type'] == 'file':
            top = path.split('/')[0]
            if top in tops:
                selected.add(path)
                tops.remove(top)
            for category, present in [('hidden', any(p.startswith('.') for p in Path(path).parts)),
                                      ('executable', bool(r['mode'] & 0o111))]:
                if present and category not in categories:
                    selected.add(path)
                    categories.add(category)
            if r['nlink'] > 1 and len(hardlink_paths) < 2:
                key = (r['device'], r['inode'])
                if hardlink_key is None:
                    hardlink_key = key
                if hardlink_key == key:
                    hardlink_paths.append(path)
        if r['xattrs'] and 'xattr' not in categories:
            selected.add(path)
            categories.add('xattr')
        if r['type'] == 'symlink' and 'symlink' not in categories:
            selected.add(path)
            categories.add('symlink')
    if isinstance(records, Inventory):
        row = records.db.execute("""SELECT json_extract(record, '$.device'), json_extract(record, '$.inode')
            FROM entries WHERE json_extract(record, '$.type') = 'file'
            AND json_extract(record, '$.nlink') > 1 GROUP BY 1, 2 HAVING count(*) > 1 LIMIT 1""").fetchone()
        if row:
            hardlink_paths = [p[0] for p in records.db.execute("""SELECT path FROM entries
                WHERE json_extract(record, '$.device') = ? AND json_extract(record, '$.inode') = ?
                ORDER BY path LIMIT 2""", row)]
    if len(hardlink_paths) == 2:
        selected.update(hardlink_paths)
    selected.update(tops)  # Empty/special-only historical directories still get sampled.
    return sorted(selected)


def restored_sample_checks(records, actual, scratch):
    selected = samples(records)
    groups = {}
    hashes = {}
    previous = json.loads((CONTROL / 'accepted.json').read_text()) if (CONTROL / 'accepted.json').exists() else {}
    for path in selected:
        actual_path = ('.' if path == '' and '.' in actual else
                       '' if path == '.' and '' in actual else path)
        before, after = records[path], actual[actual_path]
        keys = ('type', 'mode', 'uid', 'gid', 'size', 'mtime_ns', 'xattrs', 'linktarget', 'rdev')
        require(all(before.get(k) == after.get(k) for k in keys), f'restored metadata mismatch: {path}')
        if before['type'] == 'file':
            def sha(file):
                with file.open('rb') as stream:
                    return hashlib.file_digest(stream, 'sha256').hexdigest()
            expected = sha(SOURCE / path) if SOURCE.exists() else previous.get('sample_hashes', {}).get(path)
            hashes[path] = sha(scratch / path)
            require(expected == hashes[path], f'restored hash mismatch: {path}')
            key = (before['device'], before['inode'])
            restored_key = (after['device'], after['inode'])
            require(groups.setdefault(key, restored_key) == restored_key, 'hardlink topology mismatch')
    return selected, hashes


def accept_verification(records, actual, sid, run, scratch, candidate):
    selected, hashes = restored_sample_checks(records, actual, scratch)
    if SOURCE.exists():
        require(inventory(SOURCE) == records, 'source changed since archive')
    report = dict(snapshot_id=sid, repository_id=candidate['repository_id'], restic_version='0.19.1',
                  source=totals(records), omitted_unix_sockets=sum(r['type'] == 'socket' for r in records.values()),
                  repository_allocated_bytes=int(command('du', '-s', '-B1', REPO).split()[0]),
                  selected_entries=len(selected), automated_verification='passed', scratch=str(scratch),
                  sample_hashes=hashes)
    save(run / 'verification.json', report)
    print(json.dumps({k: v for k, v in report.items() if k != 'sample_hashes'}, indent=2), flush=True)
    print(f'Inspect representative historical content in {scratch}. Artifacts are retained.', flush=True)
    require(input('After inspection, type the full snapshot ID to accept: ') == sid, 'manual inspection not confirmed')
    report.update(accepted_at=dt.datetime.now(dt.timezone.utc).isoformat(), manual_inspection='passed')
    save(CONTROL / 'accepted.json', report)
    return sid


def finalize_existing_restore(sid, records, candidate, prior_run, prior_log,
                              scratch, actual_path, run):
    require(sid == candidate['snapshot_id'], 'snapshot must equal recorded full candidate ID')
    enrollment = json.loads((CONTROL / 'enrollment.json').read_text())
    require(candidate['repository_id'] == enrollment['repository_id'], 'candidate/enrollment identity mismatch')
    canonical(prior_run)
    require(prior_run.is_relative_to(CONTROL) and prior_run.name.startswith('verify-'),
            'prior verification run must be under the private control directory')
    private(prior_run)
    for name in ('01-cat', '02-snapshots', '03-check', '04-ls', '05-ls', '06-restore'):
        path = prior_run / f'{name}.json'
        metadata = path.stat()
        require((metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) == (0, 0, 0o600)
                and json.loads(path.read_text()).get('exit_code') == 0,
                f'prior verification command did not succeed: {name}')
    snapshots = json.loads((prior_run / '02-snapshots.stdout').read_text())
    require(len(snapshots) == 1 and snapshots[0]['id'] == sid
            and snapshots[0]['paths'] == [str(SOURCE)] and snapshots[0]['hostname'] == 'minis'
            and snapshots[0].get('tags') == ['legacy-rsnapshot'], 'prior snapshot scope mismatch')
    canonical(prior_log)
    require(prior_log.is_relative_to(CONTROL) and prior_log.stat().st_uid == 0
            and 'KeyError: \'\'' in prior_log.read_text(errors='replace'),
            'prior log does not show the expected root-alias interruption')
    canonical(scratch)
    private(scratch)
    require(scratch.is_relative_to(MOUNT) and not scratch.is_relative_to(SOURCE)
            and not scratch.is_relative_to(REPO) and not scratch.is_relative_to(CONTROL),
            'restore scratch must be outside source, repository, and control directories')
    canonical(actual_path)
    metadata = actual_path.stat()
    require(actual_path.is_relative_to(CONTROL)
            and (metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) == (0, 0, 0o600),
            'restored inventory must be a root-owned 0600 control file')
    actual = Inventory(actual_path)
    require(len(actual) > 1, 'restored inventory is empty')
    return accept_verification(records, actual, sid, run, scratch, candidate)


def accept_saved_verification(sid, report_path):
    candidate = json.loads((CONTROL / 'candidate.json').read_text())
    enrollment = json.loads((CONTROL / 'enrollment.json').read_text())
    require(sid == candidate['snapshot_id'], 'snapshot must equal recorded full candidate ID')
    require(candidate['repository_id'] == enrollment['repository_id'], 'candidate/enrollment identity mismatch')
    canonical(report_path)
    require(report_path.is_relative_to(CONTROL) and report_path.parent.name.startswith('finalize-'),
            'verification report must be in the private finalization directory')
    private(report_path.parent)
    metadata = report_path.stat()
    require((metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) == (0, 0, 0o600),
            'verification report must be root-owned 0600')
    report = json.loads(report_path.read_text())
    require(report.get('snapshot_id') == sid and report.get('repository_id') == candidate['repository_id']
            and report.get('restic_version') == '0.19.1'
            and report.get('automated_verification') == 'passed'
            and report.get('manual_inspection') is None,
            'saved report is not a pending successful verification for this candidate')
    scratch = Path(report['scratch'])
    canonical(scratch)
    private(scratch)
    require(scratch.is_relative_to(MOUNT) and not scratch.is_relative_to(SOURCE)
            and not scratch.is_relative_to(REPO) and not scratch.is_relative_to(CONTROL),
            'restore scratch must be outside source, repository, and control directories')
    print(json.dumps({k: v for k, v in report.items() if k != 'sample_hashes'}, indent=2), flush=True)
    print(f'Inspect representative historical content in {scratch}. Artifacts are retained.', flush=True)
    require(input('After inspection, type the full snapshot ID to accept: ') == sid, 'manual inspection not confirmed')
    report.update(accepted_at=dt.datetime.now(dt.timezone.utc).isoformat(), manual_inspection='passed')
    save(CONTROL / 'accepted.json', report)
    return sid


class Restic:
    def __init__(self, password, log_dir=None, guarded=True):
        self.guarded = guarded
        self.log_dir = log_dir
        self.sequence = 0
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('RESTIC_')}
        self.env.update(RESTIC_PASSWORD_FILE=str(password), GOMAXPROCS='2')

    def __call__(self, *args):
        if self.guarded:
            mount_guard()
            if REPO.exists():
                private(REPO)
        argv = ['ionice', '-c', '3', 'nice', '-n', '19', str(BINARY),
                '--repo', str(REPO), '--no-cache', '--compression', 'auto', *map(str, args)]
        if self.log_dir is None:
            return subprocess.check_output(argv, env=self.env, text=True)
        self.sequence += 1
        name = self.log_dir / f'{self.sequence:02d}-{args[0]}'
        started = time.monotonic()
        with name.with_suffix('.stdout').open('w') as out, name.with_suffix('.stderr').open('w') as err:
            result = subprocess.run(argv, env=self.env, stdout=out, stderr=err)
        save(name.with_suffix('.json'), dict(exit_code=result.returncode,
                                             elapsed_seconds=time.monotonic() - started))
        result.check_returncode()
        return name.with_suffix('.stdout') if args[0] == 'ls' else name.with_suffix('.stdout').read_text()



def identity(restic, record):
    config = json.loads(restic('cat', 'config'))
    require(config['id'] == record['repository_id'] and config['version'] == 2,
            'repository identity/version mismatch')


def archive(restic, records, run, baseline_path=None, source_logical_bytes=None):
    capacity(records, os.statvfs(MOUNT), source_logical_bytes)
    enrollment = CONTROL / 'enrollment.json'
    if not enrollment.exists():
        require(not REPO.exists(), 'unexpected existing repository; attended recovery required')
        REPO.mkdir(mode=0o700)
        # Interruption before enrollment leaves an untrusted directory: never adopt automatically.
        restic('init', '--repository-version', '2')
        config = json.loads(restic('cat', 'config'))
        save(enrollment, dict(repository_id=config['id'], version=2,
                              password_manager_copy_confirmed=True,
                              enrolled_at=dt.datetime.now(dt.timezone.utc).isoformat()))
    record = json.loads(enrollment.read_text())
    private(REPO)
    identity(restic, record)
    require(not (CONTROL / 'candidate.json').exists(), 'candidate already recorded; use verify')
    if baseline_path is None:
        baseline_path = run / 'before.sqlite'
        save(baseline_path, records)
    output = restic('backup', '--json', '--host', 'minis', '--tag', 'legacy-rsnapshot', SOURCE)
    save(run / 'backup-output.json', output)
    summaries = [json.loads(line) for line in output.splitlines() if json.loads(line).get('message_type') == 'summary']
    require(len(summaries) == 1 and re.fullmatch('[a-f0-9]{64}', summaries[0].get('snapshot_id', '')),
            'missing full snapshot ID')
    sid = summaries[0]['snapshot_id']
    after = inventory(SOURCE)
    save(run / 'after.sqlite', after)
    require(records == after, 'source changed during backup; candidate not accepted')
    save(CONTROL / 'candidate.json', dict(snapshot_id=sid, inventory=str(baseline_path),
                                        repository_id=record['repository_id']))
    return sid


def verify(restic, sid, run, records=None):
    candidate = json.loads((CONTROL / 'candidate.json').read_text())
    require(sid == candidate['snapshot_id'], 'snapshot must equal recorded full candidate ID')
    enrollment = json.loads((CONTROL / 'enrollment.json').read_text())
    require(candidate['repository_id'] == enrollment['repository_id'], 'candidate/enrollment identity mismatch')
    identity(restic, enrollment)
    if records is None:
        records = Inventory(candidate['inventory'])
    snapshots = json.loads(restic('snapshots', '--json', sid))
    require(len(snapshots) == 1 and snapshots[0]['id'] == sid
            and snapshots[0]['paths'] == [str(SOURCE)] and snapshots[0]['hostname'] == 'minis'
            and snapshots[0].get('tags') == ['legacy-rsnapshot'], 'snapshot scope mismatch')
    restic('check', '--read-data')
    listing = restic('ls', '--json', sid)
    compare_listing(records, archived_inventory(listing, SOURCE))
    compare_symlinks(restic, sid, records)
    selected = samples(records)
    # Literal Restic glob patterns, one per line; reject filenames that cannot be represented.
    includes = run / 'includes.txt'
    with includes.open('w') as out:
        for relative in selected:
            path = '/' + relative
            require('\n' not in path and '\r' not in path, 'sample contains newline; attended recovery required')
            out.write(''.join('\\' + c if c in '\\*?[' else c for c in path) + '\n')
    # Include descendants of selected directories and metadata space for their ancestors.
    chosen = set(selected)
    directories = {p for p in selected if records[p]['type'] == 'dir'}
    ancestors = {str(parent) for p in selected for parent in Path(p).parents}
    expected_bytes = 0
    for path, record in records.items():
        if path in chosen or path in ancestors or any(str(p) in directories for p in Path(path).parents):
            expected_bytes += record['size'] + 4096
    usage = os.statvfs(MOUNT)
    require(usage.f_bavail * usage.f_frsize > expected_bytes * 1.2 + usage.f_blocks * usage.f_frsize * .1,
            'insufficient restore scratch space')
    scratch_parent = Path(tempfile.mkdtemp(prefix='.legacy-rsnapshot-restore-', dir=MOUNT))
    scratch = scratch_parent / 'tree'
    scratch.mkdir(mode=0o700)
    restic('restore', sid + ':' + str(SOURCE), '--target', scratch, '--include-file', includes)
    restored = scratch
    actual = inventory(restored)
    groups = {}
    hashes = {}
    previous = json.loads((CONTROL / 'accepted.json').read_text()) if (CONTROL / 'accepted.json').exists() else {}
    for path in selected:
        actual_path = ('.' if path == '' and '.' in actual else
                       '' if path == '.' and '' in actual else path)
        before, after = records[path], actual[actual_path]
        keys = ('type', 'mode', 'uid', 'gid', 'size', 'mtime_ns', 'xattrs', 'linktarget', 'rdev')
        require(all(before.get(k) == after.get(k) for k in keys), f'restored metadata mismatch: {path}')
        if before['type'] == 'file':
            def sha(file):
                with file.open('rb') as stream:
                    return hashlib.file_digest(stream, 'sha256').hexdigest()
            expected = sha(SOURCE / path) if SOURCE.exists() else previous.get('sample_hashes', {}).get(path)
            hashes[path] = sha(restored / path)
            require(expected == hashes[path], f'restored hash mismatch: {path}')
            key = (before['device'], before['inode'])
            restored_key = (after['device'], after['inode'])
            require(groups.setdefault(key, restored_key) == restored_key, 'hardlink topology mismatch')
    if SOURCE.exists():
        require(inventory(SOURCE) == records, 'source changed since archive')
    report = dict(snapshot_id=sid, repository_id=candidate['repository_id'], restic_version='0.19.1',
                  source=totals(records), omitted_unix_sockets=sum(r['type'] == 'socket' for r in records.values()),
                  repository_allocated_bytes=int(command('du', '-s', '-B1', REPO).split()[0]),
                  selected_entries=len(selected), automated_verification='passed', scratch=str(scratch),
                  sample_hashes=hashes)
    save(run / 'verification.json', report)
    print(json.dumps({k: v for k, v in report.items() if k != 'sample_hashes'}, indent=2))
    print(f'Inspect representative historical content in {scratch}. Artifacts are retained.')
    require(input('After inspection, type the full snapshot ID to accept: ') == sid, 'manual inspection not confirmed')
    report.update(accepted_at=dt.datetime.now(dt.timezone.utc).isoformat(), manual_inspection='passed')
    save(CONTROL / 'accepted.json', report)
    return sid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['preflight', 'archive', 'verify', 'finalize', 'accept'])
    parser.add_argument('--snapshot')
    parser.add_argument('--resume-inventory', type=Path,
                        help='reuse a root-owned completed archive inventory from the past 2 hours')
    parser.add_argument('--prior-run', type=Path)
    parser.add_argument('--prior-log', type=Path)
    parser.add_argument('--scratch', type=Path)
    parser.add_argument('--restored-inventory', type=Path)
    parser.add_argument('--verification-report', type=Path)
    args = parser.parse_args()
    require(args.resume_inventory is None or args.operation == 'archive', '--resume-inventory is only valid with archive')
    finalize_args = (args.prior_run, args.prior_log, args.scratch, args.restored_inventory)
    require(all(value is not None for value in finalize_args) if args.operation == 'finalize'
            else all(value is None for value in finalize_args),
            'prior-run, prior-log, scratch, and restored-inventory are only valid together with finalize')
    require((args.verification_report is not None) if args.operation == 'accept'
            else (args.verification_report is None),
            '--verification-report is only valid with accept')
    os.umask(0o077)
    require(os.geteuid() == 0 and socket.gethostname().split('.')[0] == 'minis', 'run as root on minis')
    mount_guard()
    if not CONTROL.exists():
        CONTROL.mkdir(mode=0o700)
    private(CONTROL)
    with (CONTROL / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = time.monotonic()
        run = Path(tempfile.mkdtemp(prefix=args.operation + '-', dir=CONTROL))
        if args.operation == 'accept':
            require(args.snapshot is not None and re.fullmatch('[a-f0-9]{64}', args.snapshot),
                    'full --snapshot required')
            require(os.isatty(0), 'interactive terminal required')
            return accept_saved_verification(args.snapshot, args.verification_report)
        if args.operation != 'verify':
            writers()
        baseline_path = None
        cached_source_totals = None
        if args.operation == 'verify':
            require(SOURCE.exists() or (CONTROL / 'accepted.json').exists(), 'source missing before acceptance')
            candidate = json.loads((CONTROL / 'candidate.json').read_text())
            records = Inventory(candidate['inventory'])
        elif args.operation == 'finalize':
            require(args.snapshot is not None and re.fullmatch('[a-f0-9]{64}', args.snapshot),
                    'full --snapshot required')
            candidate = json.loads((CONTROL / 'candidate.json').read_text())
            records = Inventory(candidate['inventory'])
        elif args.operation == 'archive' and args.resume_inventory:
            baseline_path = args.resume_inventory
            require(SOURCE.is_dir() and not SOURCE.is_symlink(), 'source is missing or substituted')
            records, cached_source_totals = load_resume_inventory(baseline_path)
        else:
            require(args.resume_inventory is None, '--resume-inventory is only valid with archive')
            records = inventory(SOURCE)
        usage = os.statvfs(MOUNT)
        source_totals = cached_source_totals or totals(records)
        report = dict(source=source_totals, capacity=(capacity(records, usage,
            source_totals['unique_inode_logical_bytes']) if args.operation != 'verify' else dict(filesystem_bytes=usage.f_blocks * usage.f_frsize,
                                                    available_bytes=usage.f_bavail * usage.f_frsize)))
        report['elapsed_seconds'] = time.monotonic() - started
        save(run / 'preflight.json', report)
        print(json.dumps(report, indent=2), flush=True)
        if args.operation == 'preflight':
            return
        require(os.isatty(0), 'interactive terminal required')
        if args.operation == 'finalize':
            finalize_existing_restore(args.snapshot, records, candidate, args.prior_run,
                                      args.prior_log, args.scratch, args.restored_inventory, run)
            return
        require(command(BINARY, 'version').startswith('restic 0.19.1 '), 'Restic 0.19.1 required')
        if args.operation == 'archive':
            require(input('Confirm retired source, no writers/schedules (including other hosts), and low-I/O window: type RETIRED: ') == 'RETIRED', 'retirement not confirmed')
        require(input('Confirm independent password-manager copy saved: type SAVED: ') == 'SAVED', 'credential not enrolled')
        password = getpass.getpass('Archive repository password: ')
        require(bool(password) and '\n' not in password and '\r' not in password and password == getpass.getpass('Repeat password: '), 'password mismatch/empty')
        require(command('findmnt', '-n', '-o', 'FSTYPE', '--target', '/run').strip() == 'tmpfs', '/run must be tmpfs')
        fd, filename = tempfile.mkstemp(prefix='legacy-rsnapshot-password-', dir='/run')
        try:
            with os.fdopen(fd, 'w') as out:
                out.write(password + '\n')
            del password
            restic = Restic(filename, run)
            if args.operation == 'archive':
                sid = archive(restic, records, run, baseline_path,
                              report['source']['unique_inode_logical_bytes'])
            else:
                private(REPO)
                require(args.snapshot is not None and re.fullmatch('[a-f0-9]{64}', args.snapshot), 'full --snapshot required')
                sid = verify(restic, args.snapshot, run, records)
            save(run / 'completion.json', dict(snapshot_id=sid, elapsed_seconds=time.monotonic() - started))
            print(f'Completed {args.operation}: {sid}; local evidence: {run}')
        finally:
            os.unlink(filename)


if __name__ == '__main__':
    main()
