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
_node_cache = {}


class SnapshotNotEligible(RuntimeError):
    """Snapshot is outside the validated set and may be skipped during selection."""

def configure(legacy_module, guard, path_guard, assertion, here, control, freeze_snapshot):
    global legacy, backup_guard, canonical, require, HERE, CONTROL, freeze
    legacy, backup_guard, canonical, require, HERE, CONTROL = legacy_module, guard, path_guard, assertion, here, control
    freeze = freeze_snapshot


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
    repository = getattr(restic, 'repo', None)
    if repository is None:
        # Lightweight test doubles may change their listing between calls and
        # do not identify a persistent repository to cache against.
        return [n for line in restic('ls', '--json', sid).splitlines()
                if (n := json.loads(line)).get('type') and n.get('path')]
    key = (str(repository), sid)
    if key not in _node_cache:
        _node_cache[key] = [n for line in restic('ls', '--json', sid).splitlines()
                            if (n := json.loads(line)).get('type') and n.get('path')]
    return _node_cache[key]


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
    kdbx_requirements = [entry for entry in released['required_content'] if entry['kind'] == 'kdbx']
    require(len(kdbx_requirements) == 1, 'vault contract must declare exactly one KDBX entry')
    kdbx_path = kdbx_requirements[0]['path']
    kdbx_measurements = [entry for entry in measured
                         if entry['kind'] == 'kdbx' and entry['path'] == kdbx_path]
    require(len(kdbx_measurements) == 1, 'vault manifest must contain exactly one KDBX measurement')
    # KDBX is binary; inspect without decoding and without plaintext filesystem scratch.
    with tempfile.TemporaryFile(dir=CONTROL) as out:
        restic('dump', sid, kdbx_path, output=out)
        require(out.tell() == kdbx_measurements[0]['bytes'], 'KDBX size mismatch')
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
    require(not any(n['path'].startswith(prefix) and
                    set(Path(n['path']).parts) & {'token', 'server-token'} for n in listing),
            'server-token artifact forbidden')
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
    # Eligibility is a lineage/hold gate, not a freshness gate. A frozen
    # operation may resume days later, but it must still be an eligible vault
    # lineage and must still pass the content contract.
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
        if dataset == 'vault' and (snapshot['hostname'] != 'minis-vault' or 'vault' not in snapshot.get('tags', [])):
            continue
        if dataset != 'vault' and (snapshot['hostname'] != 'minis' or not {'opt', 'nas'} <= set(snapshot.get('tags', []))):
            continue
        try:
            validate(restic, dataset, snapshot, fresh=True)
        except SnapshotNotEligible:
            continue
        return freeze(snapshot)
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


# Runs inside the pinned RomM MariaDB image as its unprivileged mysql user.
# Restored SQL arrives on stdin, and only the import client reads it.
ROMM_IMPORT = r'''
set -eu
mkdir -m 0700 /work/data /work/tmp /work/files
mariadb-install-db --no-defaults --user=mysql --datadir=/work/data --tmpdir=/work/tmp </dev/null 1>&2
mariadbd --no-defaults --user=mysql --datadir=/work/data --socket=/tmp/mariadb.sock \
  --pid-file=/tmp/mariadb.pid --skip-networking --local-infile=0 \
  --tmpdir=/work/tmp --secure-file-priv=/work/files </dev/null 1>&2 &
server=$!
tries=0
until [ -S /tmp/mariadb.sock ]; do
  if ! kill -0 "$server" 2>/dev/null; then
    echo 'isolated MariaDB exited during startup' >&2
    exit 1
  fi
  tries=$((tries + 1))
  if [ "$tries" -gt 300 ]; then
    echo 'isolated MariaDB startup timed out after 30 seconds' >&2
    exit 1
  fi
  sleep 0.1
done
client='--no-defaults --socket=/tmp/mariadb.sock --user=mysql'
# The client also parses dump commands: refuse shell/file access before reading SQL.
mariadb $client --sandbox 1>&2
count=$(mariadb $client --batch --skip-column-names </dev/null \
  --execute='SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="romm"')
mariadb-check $client --databases romm </dev/null 1>&2
mariadb-admin $client shutdown </dev/null 1>&2
wait "$server"
echo "romm-tables=$count"
'''


# The RomM database is small; a stuck runtime must fail rather than hang enrollment.
ROMM_IMPORT_TIMEOUT = 1800


def release(text):
    return tuple(int(part) for part in text.split('.'))


def romm_mariadb_image(text):
    """Return the digest-pinned MariaDB image of the RomM Deployment manifest."""
    import yaml
    images = [container['image'] for doc in yaml.safe_load_all(text)
              if doc and doc.get('kind') == 'Deployment' and doc['metadata']['name'] == 'romm'
              for container in doc['spec']['template']['spec']['containers'] if container['name'] == 'mariadb']
    if len(images) != 1:
        raise ValueError('RomM MariaDB container not found exactly once')
    match = re.fullmatch(r'mariadb:(\d+\.\d+\.\d+)@(sha256:[0-9a-f]{64})', images[0])
    if match is None:
        raise ValueError('RomM MariaDB image is not an exact version and digest pin')
    # Digest-only references avoid tag@digest parsing differences between runtimes.
    return {'image': f'docker.io/library/mariadb@{match[2]}', 'version': match[1]}


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
    with out.open('rb') as dump:
        require(any(line.startswith(b'CREATE TABLE ') for line in dump), 'RomM dump has no tables')
    image = json.loads((HERE / 'romm-mariadb.json').read_text())
    with out.open('rb') as dump:
        dumped = re.search(rb'^-- Server version\s+(\d+\.\d+\.\d+)', dump.read(4096), re.M)
    require(dumped is not None, 'RomM dump has no server version header')
    require(release(dumped[1].decode()) <= release(image['version']),
            f'RomM dump is from MariaDB {dumped[1].decode()}, newer than verification image {image["version"]}; '
            'reinstall from a reviewed checkout matching production')
    # Import with the digest-pinned image production runs, never host MariaDB,
    # so Renovate updates of RomM's database keep verification in step.
    # SQL is untrusted: the container has no network, a read-only root and no
    # capabilities, and runs as the image's mysql user. Its only writable
    # persistent path is this disposable tree on the verified encrypted vault,
    # whose root-only 0700 ancestors keep the same host UID out.
    sandbox = Path(tempfile.mkdtemp(prefix='offline-mariadb-', dir=scratch))
    log_path = scratch / 'mariadb.log'
    try:
        with out.open('rb') as sql, log_path.open('w') as log:
            try:
                result = subprocess.run(['podman', 'run', '--rm', '--interactive', '--name', sandbox.name,
                                         '--pull=never', '--network=none', '--read-only', '--cap-drop=all',
                                         '--security-opt=no-new-privileges', '--user=mysql',
                                         '--volume', f'{sandbox}:/work:U', '--entrypoint=sh',
                                         image['image'], '-c', ROMM_IMPORT],
                                        stdin=sql, stdout=subprocess.PIPE, stderr=log, text=True,
                                        timeout=ROMM_IMPORT_TIMEOUT)
            except subprocess.TimeoutExpired:
                # The finally below force-removes the container the killed client left behind.
                require(False, f'isolated RomM import timed out after {ROMM_IMPORT_TIMEOUT}s: '
                        + log_path.read_text(errors='replace')[-4000:])
        # The log holds MariaDB diagnostics only, shown on the attended terminal.
        require(result.returncode == 0, f'isolated RomM import failed (status {result.returncode}): '
                + log_path.read_text(errors='replace')[-4000:])
        count = re.fullmatch(r'romm-tables=(\d+)\n', result.stdout)
        require(count is not None and int(count[1]) > 0, 'RomM import empty')
    finally:
        try:
            subprocess.run(['podman', 'rm', '--force', '--ignore', sandbox.name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        finally:
            shutil.rmtree(sandbox)


def verify_all(dest, op, record):
    started = time.monotonic()
    # Check the encrypted scratch mount before starting potentially multi-hour
    # repository reads or attended restore verification.
    scratch = vault_scratch()
    try:
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
    finally:
        # The restored credentials and representative document are plaintext.
        # Keep them only for the attended inspection above, then remove the
        # whole per-run directory on success or failure.
        shutil.rmtree(scratch)
    backup_guard()
    # Appstate restores include Kubernetes Secret values. Keep the complete
    # disposable restore tree on the verified encrypted vault filesystem.
    app = vault_scratch()
    try:
        snapshot = next((s for s in dest['appstate'].snapshots()
                         if s['id'] == op['copies']['appstate']['destination_id']), None)
        require(snapshot is not None, 'appstate destination checkpoint missing; retry after destination sync')
        # The restored k3s database contains Kubernetes Secret values, including
        # flux-system/sops-age. Never leave this plaintext on the unencrypted array.
        verify_appstate(dest['appstate'], snapshot, app)
    finally:
        shutil.rmtree(app)
    scratch = Path(tempfile.mkdtemp(prefix='verify-', dir=CONTROL))
    try:
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
        def archived(*args):
            if args[0] == 'ls':
                path = archive_scratch / ('listing.jsonl' if '--json' in args else 'listing.txt')
                with path.open('w') as out:
                    dest['legacy-rsnapshot'](*args, output=out)
                return path
            return dest['legacy-rsnapshot'](*args)
        legacy.verify_destination(archived, sid, records, accepted, archive_scratch)
        legacy.CONTROL = original_control
        print(f'Inspect representative legacy history in {archive_scratch}; scratch is removed when verification ends.')
        require(input('After inspecting restored historical content, type VERIFIED: ') == 'VERIFIED',
                'legacy manual verification incomplete')
    finally:
        if 'original_control' in locals():
            legacy.CONTROL = original_control
        shutil.rmtree(scratch)

    return {'repositories': checks, 'vault_restore_and_strongbox': 'passed',
            'appstate_exports_and_romm_import': 'passed', 'legacy_evidence_and_manual_inspection': 'passed',
            'elapsed_seconds': time.monotonic() - started}
