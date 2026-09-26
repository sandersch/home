"""Offline eligibility and destination verification against released backup contracts."""
import datetime as dt
import hashlib
import json
import os
import shutil
from pathlib import Path
import re
import sqlite3
import subprocess
import tarfile
import tempfile
import time


VAULT_CONTROL = Path('/mnt/backups/.control/vault')
_validated = set()


class SnapshotNotEligible(RuntimeError):
    """Snapshot is outside the validated set and may be skipped during selection."""

def configure(legacy_module, guard, path_guard, assertion, here):
    global legacy, backup_guard, canonical, require, HERE
    legacy, backup_guard, canonical, require, HERE = legacy_module, guard, path_guard, assertion, here


def stamp(value):
    date = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(date.tzinfo is not None, 'timestamp timezone required')
    return date.timestamp()


def load(path):
    backup_guard()
    canonical(path)
    return json.loads(path.read_text())


def eligibility(snapshot):
    backup_guard()
    root = VAULT_CONTROL
    canonical(root)
    lineage = snapshot.get('lineage') or snapshot.get('original') or snapshot['id']
    ledger = root / 'validated.jsonl'
    canonical(ledger)
    if not any(json.loads(line).get('lineage') == lineage for line in ledger.read_text().splitlines()):
        raise SnapshotNotEligible('vault lineage lacks validation-ledger evidence')
    for base in (root, root.parent / 'vault-b2'):
        for name in ('holds', 'resolutions'):
            directory = base / name
            canonical(directory)
            if not directory.exists():
                continue
            for path in directory.glob('*.json'):
                entry = load(path)
                if name == 'holds':
                    require(re.fullmatch('[0-9a-f]{64}', entry.get('lineage', '')) is not None, 'malformed hold')
                # Fail closed on unresolved resolutions without a lineage field too.
                require(name != 'holds' or entry.get('lineage') != lineage, 'vault lineage has unresolved hold')
                require(name != 'resolutions' or entry.get('stage') in ('accepted', 'pruned'),
                        'vault resolution unfinished; retry after attended resolution')


def nodes(restic, sid):
    # Vault/appstate are bounded relative to the 13-million-entry legacy archive.
    return [n for line in restic('ls', '--json', sid).splitlines()
            if (n := json.loads(line)).get('type') and n.get('path')]


def vault(restic, snapshot):
    sid = snapshot['id']
    require(snapshot['hostname'] == 'minis-vault' and sorted(snapshot['paths']) ==
            ['/data/vault', '/work/backup-manifest.json'] and 'vault' in snapshot.get('tags', []), 'vault scope mismatch')
    manifest = json.loads(restic('dump', sid, '/work/backup-manifest.json'))
    name = manifest['contract']
    require(re.fullmatch(r'vault-v[0-9]+', name) is not None, 'invalid vault contract')
    path = HERE / 'contracts' / (name + '.json')
    exclusion = path.with_suffix('.excludes')
    released = json.loads(path.read_text())
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    require(name == released['contract'] and manifest['contract_sha256'] == digest(path) and
            manifest['exclusion_sha256'] == released['exclusion_sha256'] == digest(exclusion), 'unreleased contract hash')
    listing = nodes(restic, sid)
    excluded = [line.strip() for line in exclusion.read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#')]
    require(not any(n['path'] == p or n['path'].startswith(p + '/') for n in listing for p in excluded),
            'excluded vault content leaked')
    measured = []
    for required in released['required_content']:
        root = required['path']
        roots = [n for n in listing if n['path'] == root]
        require(len(roots) == 1 and roots[0]['type'] == ('file' if required['kind'] == 'kdbx' else 'dir'),
                'vault required root missing/wrong type')
        files = [n for n in listing if n['type'] == 'file' and (n['path'] == root or n['path'].startswith(root + '/'))]
        measure = dict(path=root, kind=required['kind'], files=len(files), bytes=sum(n['size'] for n in files))
        require(measure['files'] >= required['minimum_files'] and measure['bytes'] >= required['minimum_bytes'],
                'vault minimum content failed')
        measured.append(measure)
    require(manifest['measurements'] == measured and manifest['total_files'] == sum(m['files'] for m in measured)
            and manifest['total_bytes'] == sum(m['bytes'] for m in measured), 'vault manifest measurements mismatch')
    require(stamp(manifest['generated_at']) <= time.time() + 300, 'future vault manifest')
    sentinel = restic('dump', sid, '/data/vault/.vault-sentinel').splitlines()
    require(f'vault-contract-version={name.removeprefix("vault-v")}' in sentinel
            and f'filesystem-uuid={manifest["filesystem_uuid"]}' in sentinel, 'vault sentinel mismatch')
    # KDBX is binary; inspect without decoding and without plaintext filesystem scratch.
    with tempfile.TemporaryFile(dir=restic.workspace) as out:
        restic('dump', sid, '/data/vault/credentials/strongbox/ccs.kdbx', output=out)
        require(out.tell() == measured[0]['bytes'], 'KDBX size mismatch')
        out.seek(0)
        require(out.read(8).hex() == '03d9a29a67fb4bb5', 'invalid KDBX header')
    return manifest


def appstate(restic, snapshot):
    require(snapshot['hostname'] == 'minis' and set(snapshot['paths']) == {'/data/opt', '/work/hot-dumps'}
            and {'opt', 'nas'} <= set(snapshot.get('tags', [])), 'appstate scope mismatch')
    config = json.loads((HERE / 'appstate-contract.json').read_text())
    sid = snapshot['id']
    prefix = '/work/hot-dumps/'
    require(restic('dump', sid, prefix + 'contract-version').strip() == config['version'], 'appstate contract version mismatch')
    require(restic('dump', sid, prefix + 'required-sqlite-databases.txt').strip().splitlines() == config['required'],
            'appstate required export inventory mismatch')
    created = restic('dump', sid, prefix + 'export-created-at').strip()
    require(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', created) is not None
            and 0 <= stamp(snapshot['time']) - stamp(created) <= 3600, 'appstate export timestamp invalid/stale')
    listing = nodes(restic, sid)
    require(not any(set(Path(n['path']).parts) & {'token', 'server-token'} for n in listing), 'server-token artifact forbidden')
    required = ['contract-version', 'required-sqlite-databases.txt', 'export-created-at',
                'k3s/state.db.sqlite-backup', 'home-assistant/home-assistant.tar', 'romm/romm.sql']
    required += ['sqlite/' + rel + '.sqlite-backup' for rel in config['required']]
    for path in required:
        matches = [n for n in listing if n['path'] == prefix + path]
        require(len(matches) == 1 and matches[0]['type'] == 'file' and matches[0]['size'] > 0,
                'appstate required export absent/empty')
    return config


def validate(restic, dataset, snapshot, fresh):
    if fresh:
        age = time.time() - stamp(snapshot['time'])
        require(-300 <= age <= (8 if dataset == 'vault' else 30) * 3600, 'source snapshot stale/future')
        if dataset == 'vault':
            eligibility(snapshot)
    key = (id(restic), snapshot['id'])
    if key in _validated:
        return None
    result = vault(restic, snapshot) if dataset == 'vault' else appstate(restic, snapshot)
    _validated.add(key)
    return result


def select(restic, dataset):
    snapshots = sorted(restic.snapshots(), key=lambda s: stamp(s['time']), reverse=True)
    for snapshot in snapshots:
        # Only scope/ledger-ineligible snapshots may be skipped. A broken contract
        # in the newest eligible lineage stops selection rather than hiding damage.
        if dataset == 'vault':
            if snapshot['hostname'] != 'minis-vault' or 'vault' not in snapshot.get('tags', []):
                continue
            try:
                eligibility(snapshot)
            except SnapshotNotEligible:
                continue
        elif snapshot['hostname'] != 'minis' or not {'opt', 'nas'} <= set(snapshot.get('tags', [])):
            continue
        validate(restic, dataset, snapshot, fresh=True)
        return {**{k: snapshot[k] for k in ('id', 'time', 'hostname', 'paths', 'tree')},
                'tags': snapshot.get('tags') or [], 'lineage': snapshot.get('original') or snapshot['id']}
    raise RuntimeError(f'no eligible {dataset} snapshot')


def legacy_acceptance():
    accepted = load(legacy.CONTROL / 'accepted.json')
    require(accepted.get('automated_verification') == accepted.get('manual_inspection') == 'passed'
            and accepted.get('sample_hashes'), 'legacy archive lacks accepted restore evidence')
    return accepted


def vault_scratch():
    root = Path('/mnt/vault')
    canonical(root)
    config = dict(line.replace('export ', '').split('=', 1) for line in
                  Path('/etc/homelab/vault.conf').read_text().splitlines() if line and not line.startswith('#'))
    rows = json.loads(subprocess.check_output(['findmnt', '--json', '--real', '--target', str(root),
                     '-o', 'TARGET,SOURCE,FSTYPE,UUID,FSROOT'], text=True))['filesystems']
    require(len(rows) == 1 and rows[0]['target'] == str(root) and rows[0]['fsroot'] == '/'
            and rows[0]['fstype'] == 'ext4' and rows[0]['uuid'] == config['VAULT_FS_UUID']
            and Path(rows[0]['source']).resolve() == Path('/dev/mapper/vault').resolve(), 'encrypted vault mount unavailable')
    status = subprocess.check_output(['cryptsetup', 'status', 'vault'], text=True)
    match = re.search(r'^\s*device:\s*(\S+)', status, re.M)
    require(match is not None and subprocess.check_output(['cryptsetup', 'luksUUID', match[1]], text=True).strip()
            == config['VAULT_LUKS_UUID'], 'vault LUKS identity mismatch')
    all_mounts = json.loads(subprocess.check_output(['findmnt', '--json', '--list', '-o', 'TARGET'], text=True))['filesystems']
    require(not any(Path(r['target']).is_relative_to(root) and Path(r['target']) != root for r in all_mounts),
            'nested vault mount refused')
    sentinel = root / '.vault-sentinel'
    canonical(sentinel)
    require(f'filesystem-uuid={config["VAULT_FS_UUID"]}' in sentinel.read_text().splitlines(), 'vault sentinel mismatch')
    scratch = root / '.restore-tests'
    canonical(scratch)
    scratch.mkdir(mode=0o700, exist_ok=True)
    legacy.private(scratch)
    return Path(tempfile.mkdtemp(prefix='offline-', dir=scratch))


def dump_file(restic, sid, archived, target):
    canonical(target)
    require(not target.exists(), 'restore target already exists')
    with target.open('xb') as stream:
        restic('dump', sid, archived, output=stream)
    require(target.stat().st_size > 0, 'empty restored artifact')


def verify_appstate(restic, snapshot, scratch):
    config = appstate(restic, snapshot)
    sid = snapshot['id']
    prefix = '/work/hot-dumps/'
    for name in ('contract-version', 'required-sqlite-databases.txt', 'export-created-at'):
        dump_file(restic, sid, prefix + name, scratch / name)
    for i, rel in enumerate(['k3s/state.db'] + ['sqlite/' + p for p in config['required']]):
        out = scratch / f'database-{i}.sqlite'
        dump_file(restic, sid, prefix + rel + '.sqlite-backup', out)
        with sqlite3.connect(f'file:{out}?mode=ro', uri=True) as db:
            require(db.execute('SELECT count(*) FROM sqlite_master').fetchone()[0] > 0, 'empty SQLite schema')
            if not rel.startswith('sqlite/plex/'):
                require(db.execute('PRAGMA integrity_check').fetchall() == [('ok',)], 'SQLite integrity failure')
            if i == 0:
                require(db.execute("SELECT count(*) FROM sqlite_master WHERE name IN ('kine','sqlite_sequence')").fetchone()[0] == 2
                        and db.execute('SELECT count(*) FROM kine').fetchone()[0] > 0, 'k3s schema/data missing')
    out = scratch / 'home-assistant.tar'
    dump_file(restic, sid, prefix + 'home-assistant/home-assistant.tar', out)
    with tarfile.open(out) as archive:
        require(bool(archive.getmembers()), 'empty Home Assistant archive')
    out = scratch / 'romm.sql'
    dump_file(restic, sid, prefix + 'romm/romm.sql', out)
    require(any(line.startswith('CREATE TABLE ') for line in out.open()), 'RomM dump has no tables')
    # An isolated local server imports untrusted restored SQL without network access.
    dbdir = scratch / 'mariadb'
    subprocess.run(['mariadb-install-db', '--no-defaults', '--datadir=' + str(dbdir), '--user=root'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    socket = scratch / 'mariadb.sock'
    sql_files = scratch / 'sql-files'
    sql_files.mkdir(mode=0o700)
    with (scratch / 'mariadb.log').open('w') as log:
        server = subprocess.Popen(['mariadbd', '--no-defaults', '--user=root', '--datadir=' + str(dbdir),
                   '--socket=' + str(socket), '--pid-file=' + str(scratch / 'mariadb.pid'),
                   '--skip-networking', '--local-infile=0', '--tmpdir=' + str(sql_files),
                   '--secure-file-priv=' + str(sql_files)], stdout=log, stderr=log)
        try:
            ready = False
            for _ in range(100):
                if socket.exists():
                    ready = True
                    break
                status = server.poll()
                require(status is None,
                        f'isolated MariaDB exited during startup (status {status}); inspect private mariadb.log')
                time.sleep(.1)
            require(ready, 'isolated MariaDB startup timed out after 10 seconds; inspect private mariadb.log')
            with out.open('rb') as sql:
                subprocess.run(['mariadb', '--no-defaults', '--socket=' + str(socket), '--user=root'],
                               stdin=sql, stdout=log, stderr=log, check=True)
            count = subprocess.check_output(['mariadb', '--no-defaults', '--socket=' + str(socket), '--user=root',
                '--batch', '--skip-column-names', '--execute=SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="romm"'], text=True)
            require(int(count) > 0, 'RomM import empty')
            subprocess.run(['mariadb-check', '--no-defaults', '--socket=' + str(socket), '--user=root', '--databases', 'romm'],
                           check=True, stdout=log, stderr=log)
        finally:
            server.terminate()
            try:
                server.wait(timeout=30)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


def verify_all(dest, op, record, work):
    started = time.monotonic()
    # Check the encrypted scratch mount before starting potentially multi-hour
    # repository reads or attended restore verification.
    scratch = vault_scratch()
    checks = {}
    for name, restic in dest.items():
        check_started = time.monotonic()
        restic('check', '--read-data')
        checks[name] = {'full_data_check': 'passed', 'check_seconds': time.monotonic() - check_started}
    vault_repo = dest['vault']
    sid = op['copies']['vault']['destination_id']
    # Pin the encrypted filesystem while dumping and prevent a concurrent normal unmount.
    fd = os.open(scratch, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        require(os.fstat(fd).st_dev == Path('/dev/mapper/vault').stat().st_rdev, 'vault scratch lost encrypted device')
        pinned = Path(f'/proc/self/fd/{fd}')
        # dump_file's canonical check is for ordinary targets; inherited fd is held
        # by this process, and opening its files pins the encrypted filesystem too.
        for archived, name in [('/data/vault/credentials/strongbox/ccs.kdbx', 'ccs.kdbx')]:
            with (pinned / name).open('xb') as out:
                vault_repo('dump', sid, archived, output=out)
        document = next((n for n in nodes(vault_repo, sid) if n['type'] == 'file'
                         and n['path'].startswith('/data/vault/documents/') and n.get('size', 0) > 0), None)
        require(document is not None, 'no representative vault document')
        with (pinned / 'representative-document').open('xb') as out:
            vault_repo('dump', sid, document['path'], output=out)
        print(f'Inspect document and open ccs.kdbx in Strongbox from {scratch}. Do not enter its master password here.')
        require(input('After successful content inspection and Strongbox open, type VERIFIED: ') == 'VERIFIED',
                'vault manual verification incomplete')
    finally:
        os.close(fd)
    backup_guard()
    scratch = Path(tempfile.mkdtemp(prefix='verify-', dir=Path('/mnt/backups/.control/offline')))
    app = scratch / 'appstate'
    app.mkdir(mode=0o700)
    snapshot = next(s for s in dest['appstate'].snapshots() if s['id'] == op['copies']['appstate']['destination_id'])
    # The restored k3s database contains Kubernetes Secret values, including
    # flux-system/sops-age. Never leave this plaintext on the unencrypted array.
    try:
        verify_appstate(dest['appstate'], snapshot, app)
    finally:
        shutil.rmtree(app)
    accepted = legacy_acceptance()
    candidate = load(legacy.CONTROL / 'candidate.json')
    require(candidate['snapshot_id'] == accepted['snapshot_id'] and candidate['repository_id'] == accepted['repository_id'],
            'legacy acceptance/candidate mismatch')
    canonical(Path(candidate['inventory']))
    records = legacy.Inventory(candidate['inventory'])
    expected = op['copies'].get('legacy-rsnapshot', record.get('legacy'))
    require(expected is not None, 'legacy destination identity missing')
    sid = expected['destination_id']
    matches = [s for s in dest['legacy-rsnapshot'].snapshots() if s['id'] == sid]
    require(len(matches) == 1 and (matches[0].get('original') or sid) == expected['lineage'], 'legacy checkpoint substituted')
    archive_scratch = scratch / 'legacy'
    archive_scratch.mkdir(mode=0o700)
    # Inventory scratch belongs to this operation, never the accepted NAS archive.
    original_control = legacy.CONTROL
    legacy.CONTROL = archive_scratch
    try:
        def archived(*args):
            if args[0] == 'ls':
                path = archive_scratch / ('listing.jsonl' if '--json' in args else 'listing.txt')
                with path.open('w') as out:
                    dest['legacy-rsnapshot'](*args, output=out)
                return path
            return dest['legacy-rsnapshot'](*args)
        legacy.verify_destination(archived, sid, records, accepted, archive_scratch)
    finally:
        legacy.CONTROL = original_control
    print(f'Inspect representative legacy history in {archive_scratch}; scratch is retained for attended cleanup.')
    require(input('After inspecting restored historical content, type VERIFIED: ') == 'VERIFIED',
            'legacy manual verification incomplete')

    return {'repositories': checks, 'vault_restore_and_strongbox': 'passed',
            'appstate_exports_and_romm_import': 'passed', 'legacy_evidence_and_manual_inspection': 'passed',
            'elapsed_seconds': time.monotonic() - started}
