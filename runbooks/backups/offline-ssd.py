#!/usr/bin/env python3
"""Attended cumulative offline Restic copies. Run on minis; never deletes snapshots."""
import argparse
from contextlib import contextmanager
import datetime as dt
import fcntl
import getpass
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
CONTROL = Path('/mnt/backups/.control/offline')
BACKUPS = Path('/mnt/backups')
MOUNTS = Path('/mnt/offline')
BINARY = HERE / 'restic'
METRICS = Path('/var/lib/node-exporter/textfile/restic-offline.prom')
SOURCES = {'vault': BACKUPS / 'vault', 'appstate': BACKUPS / 'opt',
           'legacy-rsnapshot': BACKUPS / 'legacy-rsnapshot'}
DATASETS = tuple(SOURCES)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


legacy = module('legacy_offline', 'legacy-rsnapshot.py')
require = legacy.require
canonical = legacy.canonical


def run(*args, **kwargs):
    return subprocess.check_output([str(a) for a in args], **kwargs).decode()


def backup_guard():
    legacy.mount_guard()


def secure(path, mode=0o700):
    canonical(path)
    s = path.stat()
    require(s.st_uid == 0 and s.st_gid == 0 and stat.S_IMODE(s.st_mode) == mode,
            f'expected root:root {mode:o}: {path}')


def repository_directory(path, private):
    canonical(path)
    if private:
        secure(path)
    else:
        # Existing NAS repositories were created by jobs with differing umasks.
        # Their encrypted contents can be readable; only root may change them.
        info = path.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'NAS repository must be a root-owned directory without group/other writes')


def read(path):
    backup_guard()
    canonical(path)
    secure(path, 0o600)
    return json.loads(path.read_text())


def save(path, value):
    backup_guard()
    canonical(path)
    secure(path.parent)
    legacy.save(path, value)


def confirm(text, answer):
    require(sys.stdin.isatty() and sys.stdout.isatty(), 'interactive terminal required')
    require(input(f'{text}\nType {answer}: ') == answer, 'confirmation did not match')


def quarter(now=None):
    now = now or dt.datetime.now(ZoneInfo('America/Chicago'))
    return f'{now.year}-Q{(now.month - 1) // 3 + 1}'


def scheduled_drive(q):
    return 'A' if q[-1] in '24' else 'B'


def annual_due(drive, now, last=0):
    """Latest scheduled gate, including missed years, must be covered by verification."""
    year = now.year
    while True:
        if (year % 2 == 0) == (drive == 'A'):
            due = dt.datetime(year, 10 if drive == 'A' else 7, 1,
                              tzinfo=ZoneInfo('America/Chicago'))
            if due <= now:
                return last < due.timestamp()
        year -= 1


def lineage(snapshot):
    value = snapshot.get('original') or snapshot['id']
    require(re.fullmatch('[0-9a-f]{64}', value) is not None, 'invalid lineage')
    return value


def matches(snapshot, frozen, tag=None):
    return (lineage(snapshot) == frozen['lineage']
            and all(snapshot.get(k) == frozen[k] for k in ('time', 'hostname', 'paths', 'tree'))
            and set(frozen['tags']).issubset(snapshot.get('tags') or [])
            and (tag is None or tag in (snapshot.get('tags') or [])))


def resolve(snapshots, frozen, tag=None):
    candidates = [s for s in snapshots if matches(s, frozen, tag)]
    require(len(candidates) == 1, 'missing or ambiguous frozen snapshot; attended retry required')
    return candidates[0]


def source_snapshot(snapshots, frozen, tag):
    # Restic saves a retagged snapshot before removing the old snapshot. A crash
    # can leave both. Prefer the uniquely matching checkpoint, preserving both.
    if tag is not None:
        tagged = [s for s in snapshots if matches(s, frozen, tag)]
        if tagged:
            return resolve(tagged, frozen, tag)
    return resolve(snapshots, frozen)


def verification_complete(op):
    verification = op.get('verification') or {}
    repositories = verification.get('repositories') or {}
    return (set(repositories) == set(DATASETS)
            and all(isinstance(result, dict) and result.get('full_data_check') == 'passed'
                    for result in repositories.values())
            and verification.get('vault_restore_and_strongbox') == 'passed'
            and verification.get('appstate_exports_and_romm_import') == 'passed'
            and verification.get('legacy_evidence_and_manual_inspection') == 'passed')


def freeze(snapshot):
    require(re.fullmatch('[0-9a-f]{64}', snapshot['id']) is not None, 'full snapshot ID required')
    return {**{k: snapshot[k] for k in ('id', 'time', 'hostname', 'paths', 'tree')},
            'tags': snapshot.get('tags') or [], 'lineage': lineage(snapshot)}


def capacity(usage, logical):
    free = usage.f_bavail * usage.f_frsize
    reserve = usage.f_blocks * usage.f_frsize // 10
    require(free > logical * 1.2 + reserve, 'insufficient SSD capacity; operator action required, no pruning')
    return {'free_bytes': free, 'filesystem_bytes': usage.f_blocks * usage.f_frsize,
            'selected_logical_bytes': logical, 'reserve_bytes': reserve}


def restic_failure(result, args, passwords):
    detail = result.stderr.decode(errors='replace').strip()
    for password_file in passwords:
        try:
            secret = password_file.read_text().rstrip('\r\n')
        except OSError:
            continue
        if secret:
            detail = detail.replace(secret, '[redacted]')
    detail = ''.join(c if c in '\n\t' or ord(c) >= 32 else ' ' for c in detail)
    detail = detail.strip()
    message = f'Restic {args[0]} failed ({result.returncode})'
    return message + (f':\n{detail[:3000]}' if detail else '')


def tree_nodes(tree):
    yield tree
    for child in tree.get('children', []):
        yield from tree_nodes(child)


def disk(device, *, inspection=False):
    require(device.parent == Path('/dev/disk/by-id') and device.is_symlink(),
            'a stable /dev/disk/by-id whole-device symlink is required')
    target = device.resolve(strict=True)
    require(stat.S_ISBLK(target.stat().st_mode), 'not a block device')
    rows = json.loads(run('lsblk', '--json', '--tree', '--bytes', '--paths', '-o',
        'PATH,TYPE,SIZE,MODEL,SERIAL,WWN,TRAN,RO,FSTYPE,UUID,PARTUUID,LABEL,MOUNTPOINTS', target))['blockdevices']
    require(len(rows) == 1 and rows[0]['type'] == 'disk', 'whole physical disk required')
    row = rows[0]
    if not inspection:
        require(row['tran'] == 'usb' and not row['ro'], 'writable USB disk required')
    require(bool(row.get('serial')) or bool(row.get('wwn')), 'hardware identity unavailable')
    return row


def hardware(row):
    return {k: row.get(k) for k in ('size', 'model', 'serial', 'wwn', 'tran')}


def inactive(row):
    swaps = run('swapon', '--show', '--raw', '--noheadings', '--output', 'NAME').splitlines()
    swap_paths = {str(Path(name).resolve()) for name in swaps}
    for node in tree_nodes(row):
        require(node['type'] in ('disk', 'part'), 'system/array/mapped device refused')
        require(not any(node.get('mountpoints') or []), 'mounted device or child refused')
        require(node['path'] not in swap_paths, 'swap device refused')
        holders = Path('/sys/class/block', Path(node['path']).name, 'holders')
        require(not list(holders.iterdir()), 'active holders refused')
        signatures = json.loads(run('wipefs', '--no-act', '--json', node['path'])).get('signatures', [])
        require(not any(s.get('type') in ('linux_raid_member', 'LVM2_member', 'crypto_LUKS', 'swap', 'zfs_member')
                        for s in signatures), 'array/system signature refused')
        require(node.get('fstype') not in ('linux_raid_member', 'LVM2_member', 'crypto_LUKS', 'swap', 'zfs_member'),
                'array/system signature refused')


def device_identity(record):
    row = disk(Path(record['device']))
    require(hardware(row) == record['hardware'], 'hardware identity changed')
    parts = row.get('children', [])
    require(len(parts) == 1 and parts[0]['type'] == 'part', 'partition layout changed')
    part = parts[0]
    require(all(part.get(k) == record[k] for k in ('uuid', 'partuuid', 'label'))
            and part['fstype'] == 'ext4', 'filesystem/partition UUID or label changed')
    require(Path('/dev/disk/by-uuid', record['uuid']).resolve() == Path(part['path']), 'UUID substitution')
    return row, part


def mount_guard(record):
    _, part = device_identity(record)
    mount = MOUNTS / record['drive']
    canonical(mount)
    rows = json.loads(run('findmnt', '--json', '--list', '-o',
                         'TARGET,SOURCE,FSTYPE,UUID,FSROOT,OPTIONS'))['filesystems']
    own = [r for r in rows if r['target'] == str(mount)]
    require(len(own) == 1, 'SSD mount lost')
    r = own[0]
    require(r['uuid'] == record['uuid'] and r['fstype'] == 'ext4' and r['fsroot'] == '/'
            and Path(r['source']).resolve() == Path(part['path']), 'SSD mount substituted')
    options = set(r['options'].split(','))
    require({'rw', 'nodev', 'nosuid', 'noexec'} <= options and 'ro' not in options, 'unsafe/read-only mount')
    require(not any(Path(r['target']).is_relative_to(mount) and Path(r['target']) != mount for r in rows),
            'nested SSD mount refused')
    require(not os.statvfs(mount).f_flag & os.ST_RDONLY, 'read-only filesystem')
    for child in mount.iterdir():
        canonical(child)
        require(child.name in {*DATASETS, 'lost+found'}, 'unexpected SSD content')
        if child.name == 'lost+found':
            require(child.is_dir() and not list(child.iterdir()), 'unexpected recovered filesystem content')
    return mount


def attach(record):
    row, part = device_identity(record)
    mount = MOUNTS / record['drive']
    canonical(MOUNTS)
    secure(MOUNTS)
    canonical(mount)
    if subprocess.run(['mountpoint', '-q', str(mount)]).returncode == 0:
        mount_guard(record)
        return
    inactive(row)
    require(mount.is_dir() and not list(mount.iterdir()), 'uncovered mountpoint contains data')
    # The immutable underlying directory blocks writes if a device disappears.
    require('i' in run('lsattr', '-d', mount).split()[0], 'uncovered mountpoint must be immutable')
    run('mount', '-t', 'ext4', '-o', 'noauto,nodev,nosuid,noexec', part['path'], mount)
    mount_guard(record)


@contextmanager
def ram_workspace():
    root = Path('/run')
    canonical(root)
    require(json.loads(run('findmnt', '--json', '--target', root, '-o', 'FSTYPE'))['filesystems'][0]['fstype'] == 'tmpfs',
            '/run must be RAM-backed tmpfs')
    with tempfile.TemporaryDirectory(prefix='offline-ssd-', dir=root) as temp:
        path = Path(temp)
        secure(path)
        yield path


class Restic:
    """Only an allowlist of operations; mount fds pin paths during each subprocess."""
    ALLOWED = {'cat', 'snapshots', 'ls', 'dump', 'stats', 'init', 'tag', 'copy', 'check', 'restore'}

    def __init__(self, dataset, password, workspace, record=None, expected=None, source=None):
        self.dataset, self.password, self.workspace = dataset, password, workspace
        self.record, self.expected, self.source = record, expected, source

    @property
    def repo(self):
        return MOUNTS / self.record['drive'] / self.dataset if self.record else SOURCES[self.dataset]

    def __call__(self, *args, output=None):
        require(args and args[0] in self.ALLOWED, 'Restic operation is not allowed')
        require(not self.record or args[0] != 'tag', 'destination tagging forbidden')
        backup_guard()
        if self.record:
            mount_guard(self.record)
        canonical(self.repo)
        if self.repo.exists():
            repository_directory(self.repo, private=self.record is not None)
            require({p.name for p in self.repo.iterdir()} <= {'config', 'data', 'index', 'keys', 'locks', 'snapshots'},
                    'unexpected repository content')
            # Restic owns the repository layout. Inspect only its top level here;
            # recursively walking `data/` makes every call scale with archive size.
            for child in self.repo.iterdir():
                info = child.lstat()
                require(not stat.S_ISLNK(info.st_mode), 'repository symlink substitution')
        env = {k: v for k, v in os.environ.items() if not k.startswith('RESTIC_')}
        env.update(RESTIC_PASSWORD_FILE=str(self.password), RESTIC_CACHE_DIR=str(self.workspace / 'cache'),
                   TMPDIR=str(self.workspace), GOMAXPROCS='2')
        fds = []
        try:
            def pinned(path):
                fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                fds.append(fd)
                return f'/proc/self/fd/{fd}/{path.name}'
            argv = ['ionice', '-c', '3', 'nice', '-n', '19', str(BINARY), '--retry-lock', '2m',
                    '--repo', pinned(self.repo)]
            identity_argv = list(argv)
            if args[0] in ('init', 'copy'):
                require(self.source is not None, 'copy source required')
                self.source.config()
                canonical(self.source.repo)
                repository_directory(self.source.repo, private=False)
                argv += ['--from-repo', pinned(self.source.repo), '--from-password-file', str(self.source.password)]
            if self.expected and args[:2] != ('cat', 'config'):
                config = json.loads(run(*identity_argv, 'cat', 'config', env=env, pass_fds=fds, stderr=subprocess.PIPE))
                require(config['id'] == self.expected and config['version'] == 2, 'repository identity substituted')
            # Avoid buffering large dumps/listings in RAM when a caller supplies a file.
            result = subprocess.run([*argv, *map(str, args)], env=env, pass_fds=fds,
                                    stdout=output or subprocess.PIPE, stderr=subprocess.PIPE)
            require(result.returncode == 0,
                    restic_failure(result, args, [self.password] + ([self.source.password] if self.source else [])))
            return result.stdout.decode() if output is None else None
        finally:
            for fd in fds:
                os.close(fd)

    def snapshots(self):
        return json.loads(self('snapshots', '--json'))

    def config(self):
        result = json.loads(self('cat', 'config'))
        require(result['version'] == 2 and (not self.expected or result['id'] == self.expected),
                'repository ID/format changed')
        return result


def password(work, label, *, confirm=False):
    value = getpass.getpass(f'{label} password: ')
    require(bool(value), 'empty password refused')
    if confirm:
        repeated = getpass.getpass(f'{label} password again: ')
        require(value == repeated, 'password entries did not match')
    path = work / label.replace(' ', '-')
    path.write_text(value + '\n')
    path.chmod(0o600)
    return path


def provision(args):
    path = CONTROL / f'{args.drive}.json'
    require(not path.exists(), 'drive identifier already provisioned/enrolled')
    row = disk(args.device)
    inactive(row)
    for other in CONTROL.glob('[AB].json'):
        require(read(other)['hardware'] != hardware(row), 'hardware already enrolled')
    confirm('This erases the selected SSD. Check inspect output and the physical label.', str(args.device))
    # Persist intent first. A crash never permits an automatic second format.
    record = {'drive': args.drive, 'device': str(args.device), 'hardware': hardware(row), 'stage': 'provisioning'}
    save(path, record)
    row2 = disk(args.device)
    require(hardware(row2) == record['hardware'], 'device changed during confirmation')
    inactive(row2)
    run('sfdisk', '--wipe', 'always', '--wipe-partitions', 'always', row2['path'],
        input=b'label: gpt\n, , L\n')
    run('udevadm', 'settle')
    partitioned = disk(args.device)
    require(hardware(partitioned) == record['hardware'], 'device changed after partitioning')
    inactive(partitioned)
    parts = partitioned.get('children', [])
    require(len(parts) == 1, 'partition creation incomplete; manual recovery required')
    label = f'OFFLINE-{args.drive}'
    run('mkfs.ext4', '-L', label, parts[0]['path'])
    run('udevadm', 'settle')
    formatted = disk(args.device)
    require(hardware(formatted) == record['hardware'], 'device changed after formatting')
    part = formatted['children'][0]
    require(part['fstype'] == 'ext4' and part['label'] == label and part['uuid'] and part['partuuid'],
            'format postcondition failed')
    record.update({k: part[k] for k in ('uuid', 'partuuid', 'label')})
    record.update(stage='provisioned', repositories={})
    save(path, record)
    print(json.dumps(record, indent=2))


def publish():
    backup_guard()
    canonical(METRICS.parent)
    info = METRICS.parent.stat()
    require(info.st_uid == 0 and not info.st_mode & 0o022, 'unsafe metrics directory')
    lines = ['# TYPE homelab_restic_offline_rotation_timestamp_seconds gauge']
    for drive in ('A', 'B'):
        latest = max((op['success_at'] for op in successful(drive)), default=0)
        lines.append(f'homelab_restic_offline_rotation_timestamp_seconds{{drive="{drive}"}} {latest}')
    fd, name = tempfile.mkstemp(prefix='.offline-', dir=METRICS.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write('\n'.join(lines) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o644)
        backup_guard()
        os.replace(name, METRICS)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def successful(drive):
    backup_guard()
    for path in CONTROL.glob(f'{drive}-*.json'):
        op = read(path)
        if op.get('success_at') and op.get('clean_unmount') and op.get('stage') == 'complete':
            yield op


def evidence(op):
    return {k: op[k] for k in ('drive', 'quarter', 'kind', 'stage', 'started_at', 'success_at',
            'elapsed_seconds', 'clean_unmount', 'annual_verified_at', 'verification', 'copies', 'capacity', 'usage') if k in op}


def complete(op, path, record):
    mount = mount_guard(record)
    run('sync', '-f', mount)
    op['stage'] = 'synced'
    save(path, op)
    # A crash here leaves a pending operation. Retry remounts, verifies and repeats sync/unmount.
    run('umount', mount)
    require(subprocess.run(['mountpoint', '-q', str(mount)]).returncode != 0, 'unmount postcondition failed')
    op.update(clean_unmount=True, stage='complete', success_at=time.time(),
              elapsed_seconds=time.time() - op['started_at'])
    save(path, op)
    publish()
    print(json.dumps(evidence(op), indent=2))


def operate(args):
    record_path = CONTROL / f'{args.drive}.json'
    record = read(record_path)
    require(record['stage'] in ('provisioned', 'enrolling', 'enrolled'), 'incomplete provisioning requires manual recovery')
    now = dt.datetime.now(ZoneInfo('America/Chicago'))
    q = quarter(now)
    kind = 'enroll' if args.command == 'enroll' else 'rotate'
    pending = [read(p) for p in CONTROL.glob(f'{args.drive}-*.json') if read(p).get('stage') != 'complete']
    require(len(pending) <= 1, 'multiple unfinished operations require inspection')
    if pending:
        op = pending[0]
        require(op['kind'] == kind, 'resume the unfinished operation using its original command')
    else:
        prior = [op for op in successful(args.drive) if op['kind'] == kind and (kind == 'enroll' or op['quarter'] == q)]
        if prior:
            if kind == 'enroll' and record['stage'] != 'enrolled':
                record.update(stage='enrolled', legacy=prior[-1]['copies']['legacy-rsnapshot'], credentials_stored=True)
                save(record_path, record)
            publish()
            print(json.dumps(evidence(prior[-1]), indent=2))
            return
        if kind == 'rotate':
            require(record['stage'] == 'enrolled', 'initial enrollment incomplete')
            require(all(any(o['kind'] == 'enroll' for o in successful(d)) for d in ('A', 'B')),
                    'both physical enrollments must succeed before normal rotations')
            require(q >= '2026-Q4' and scheduled_drive(q) == args.drive, 'wrong drive for this quarter')
        op = {'drive': args.drive, 'quarter': q, 'kind': kind, 'started_at': time.time(),
              'stage': 'selecting', 'selected': {}, 'copies': {}}
    path = CONTROL / f"{args.drive}-{op['kind']}-{op['quarter']}.json"
    other = 'B' if args.drive == 'A' else 'A'
    confirm('Confirm the other SSD remains off-site; return this drive before retrieving it.', f'{other} OFF-SITE')
    attach(record)
    save(path, op)
    with ram_workspace() as work:
        source, dest = {}, {}
        required = DATASETS if kind == 'enroll' or annual_due(args.drive, now,
                    max((o.get('annual_verified_at', 0) for o in successful(args.drive)), default=0)) else DATASETS[:2]
        # Legacy credentials are needed for destination identity even on ordinary rotations.
        for dataset in DATASETS:
            if dataset != 'legacy-rsnapshot' or kind == 'enroll':
                source[dataset] = Restic(dataset, password(work, f'NAS {dataset}'), work)
                config = source[dataset].config()
                source[dataset].expected = config['id']
            saved = record['repositories'].get(dataset)
            if saved and dataset in source:
                require(saved['source_id'] == source[dataset].expected, 'NAS repository substituted')
            dest[dataset] = Restic(dataset, password(work, f'SSD {args.drive} {dataset}',
                                   confirm=(kind == 'enroll')), work,
                                   record, saved['destination_id'] if saved else None, source.get(dataset))
        secrets = [d.password.read_text() for d in dest.values()]
        require(len(set(secrets)) == 3 and not set(secrets) & {s.password.read_text() for s in source.values()},
                'destination passwords must differ from each other and NAS passwords')
        if kind == 'enroll':
            if (CONTROL / f'{other}.json').exists() and read(CONTROL / f'{other}.json').get('repositories'):
                other_passwords = [password(work, f'SSD {other} {d}').read_text() for d in DATASETS]
                require(len(set(other_passwords + secrets)) == 6, 'all six SSD passwords must be distinct')
            confirm('Save these three unique passwords in the password manager AND BOTH separately stored cards. '
                    'They must differ from all three passwords on the other SSD.', 'CREDENTIALS STORED')
        for dataset, d in dest.items():
            if dataset not in record['repositories']:
                require(kind == 'enroll' and not d.repo.exists(),
                        'unidentified repository exists; never adopt it automatically')
                d('init', '--repository-version', '2', '--copy-chunker-params')
                c = d.config()
                require(c['id'] != source[dataset].expected and c['chunker_polynomial'] == source[dataset].config()['chunker_polynomial'],
                        'independent repository/chunker initialization failed')
                record['repositories'][dataset] = {'source_id': source[dataset].expected, 'destination_id': c['id']}
                record['stage'] = 'enrolling'
                save(record_path, record)  # Persist each ID immediately; no automatic adoption on a gap.
                d.expected = c['id']
            d.config()
        require(len({d.expected for d in dest.values()}) == 3, 'destination repository IDs must be distinct')
        contracts = module('offline_contracts', 'offline-contracts.py')
        contracts.configure(legacy, backup_guard, canonical, require, HERE)
        # Fail before any multi-hour copy/read work if the encrypted restore
        # scratch filesystem is not available.
        contracts.vault_scratch()
        if not op['selected']:
            for dataset in DATASETS[:2]:
                op['selected'][dataset] = contracts.select(source[dataset], dataset)
            if kind == 'enroll':
                accepted = contracts.legacy_acceptance()
                snapshots = source['legacy-rsnapshot'].snapshots()
                selected = [s for s in snapshots if s['id'] == accepted['snapshot_id']]
                require(len(selected) == 1 and accepted['repository_id'] == source['legacy-rsnapshot'].expected,
                        'accepted exact legacy source ID missing/substituted')
                require(selected[0]['hostname'] == 'minis' and selected[0]['paths'] == [str(legacy.SOURCE)]
                        and selected[0].get('tags') == ['legacy-rsnapshot'], 'legacy snapshot scope mismatch')
                op['selected']['legacy-rsnapshot'] = freeze(selected[0])
            op['stage'] = 'selected'
            save(path, op)
        tag = 'offline-checkpoint-' + op['quarter']
        remaining = 0
        for dataset, frozen in op['selected'].items():
            checkpoint = None if dataset == 'legacy-rsnapshot' else tag
            existing = [s for s in dest[dataset].snapshots() if matches(s, frozen, checkpoint)]
            if not existing:
                current = source_snapshot(source[dataset].snapshots(), frozen, checkpoint)
                if dataset != 'legacy-rsnapshot':
                    contracts.validate(source[dataset], dataset, current, fresh=True)
                remaining += json.loads(source[dataset]('stats', current['id'], '--mode', 'restore-size', '--json'))['total_size']
            else:
                require(len(existing) == 1, 'ambiguous destination checkpoint')
        op['capacity'] = capacity(os.statvfs(mount_guard(record)), remaining)
        save(path, op)
        for dataset, frozen in op['selected'].items():
            d = dest[dataset]
            checkpoint = None if dataset == 'legacy-rsnapshot' else tag
            existing = [s for s in d.snapshots() if matches(s, frozen, checkpoint)]
            if not existing:
                s = source[dataset]
                current = source_snapshot(s.snapshots(), frozen, checkpoint)
                if checkpoint:
                    contracts.validate(s, dataset, current, fresh=True)
                    s('tag', '--add', checkpoint, current['id'])
                    current = resolve(s.snapshots(), frozen, checkpoint)
                    contracts.validate(s, dataset, current, fresh=True)
                    op['selected'][dataset]['tagged_id'] = current['id']
                    save(path, op)
                d('copy', current['id'])
            copied = resolve(d.snapshots(), frozen, checkpoint)
            if checkpoint:
                # Recheck eligibility even when resuming a completed copy; no stale success from a hold.
                if dataset == 'vault':
                    contracts.eligibility(frozen)
                contracts.validate(d, dataset, copied, fresh=False)
            op['copies'][dataset] = {'source_id': frozen.get('tagged_id', frozen['id']),
                'destination_id': copied['id'], 'lineage': frozen['lineage'], 'tag': checkpoint,
                'snapshot_time': copied['time']}
            save(path, op)
        if (kind == 'enroll' or len(required) == 3) and not verification_complete(op):
            op['verification'] = contracts.verify_all(dest, op, record, work)
            op['annual_verified_at'] = time.time()
            save(path, op)
        mount_guard(record)
        op['usage'] = {name: int(run('du', '-s', '-B1', d.repo).split()[0]) for name, d in dest.items()}
        op['capacity']['free_after_bytes'] = os.statvfs(mount_guard(record)).f_bavail * os.statvfs(MOUNTS / args.drive).f_frsize
        save(path, op)
        complete(op, path, record)
        if kind == 'enroll':
            record.update(stage='enrolled', legacy=op['copies']['legacy-rsnapshot'], credentials_stored=True)
            save(record_path, record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('inspect', 'provision', 'enroll', 'rotate', 'status'):
        command = sub.add_parser(name)
        command.add_argument('--drive', choices=('A', 'B'), required=name != 'status')
        if name in ('inspect', 'provision'):
            command.add_argument('--device', type=Path, required=True)
        if name == 'status':
            command.add_argument('--rebuild-metrics', action='store_true')
    args = parser.parse_args()
    require(os.geteuid() == 0, 'run as root on minis')
    os.umask(0o077)
    os.nice(19)
    run('ionice', '-c', '3', '-p', os.getpid())
    # A local process lock also covers provisioning before control records exist.
    canonical(Path('/run/lock'))
    fd = os.open('/run/lock/offline-ssd.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        secure(Path('/run/lock/offline-ssd.lock'), 0o600)
        require(os.fstat(lock.fileno()).st_ino == Path('/run/lock/offline-ssd.lock').stat().st_ino, 'process lock substituted')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        backup_guard()
        canonical(CONTROL)
        if args.command not in ('inspect', 'status'):
            CONTROL.mkdir(mode=0o700, exist_ok=True)
        if CONTROL.exists():
            secure(CONTROL)
        if args.command == 'inspect':
            row = disk(args.device, inspection=True)
            print(json.dumps({'device': str(args.device), 'lsblk': row,
                'signatures': [json.loads(run('wipefs', '--no-act', '--json', n['path'])) for n in tree_nodes(row)],
                'enrollment': read(CONTROL / f'{args.drive}.json') if (CONTROL / f'{args.drive}.json').exists() else None}, indent=2))
        elif args.command == 'status':
            for drive in ([args.drive] if args.drive else ('A', 'B')):
                print(json.dumps({'drive': drive, 'successful_operations': [evidence(o) for o in successful(drive)],
                    'pending_operations': [evidence(read(p)) for p in CONTROL.glob(f'{drive}-*.json')
                                           if read(p).get('stage') != 'complete']}, indent=2))
            if args.rebuild_metrics:
                publish()
        elif args.command == 'provision':
            provision(args)
        else:
            require(run(BINARY, 'version').startswith('restic 0.19.1 '), 'Restic 0.19.1 required')
            operate(args)


if __name__ == '__main__':
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'Offline operation stopped: {error}. Inspect status and retry the same command; an error never implies a successful checkpoint.', file=sys.stderr)
        sys.exit(1)
