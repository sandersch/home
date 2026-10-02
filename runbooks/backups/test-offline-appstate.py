#!/usr/bin/env python3
"""Disposable SQLite, HA archive and real pinned-container MariaDB restore validation."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import tarfile
import tempfile
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('contracts', HERE / 'offline-contracts.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


require(os.geteuid() == 0, 'run in a disposable root test environment with podman')
image = c.romm_mariadb_image((HERE.parent.parent / 'apps/media/romm/deployment.yaml').read_text())
subprocess.run(['podman', 'pull', '--quiet', image['image']], check=True, stdout=subprocess.DEVNULL)
with tempfile.TemporaryDirectory(prefix='offline-appstate-', dir='/tmp') as temp:
    root = Path(temp)
    c.configure(None, lambda: None, lambda p: require(p.resolve() == p, 'symlink'), require, root, root, None)
    (root / 'appstate-contract.json').write_text(json.dumps({'version': '3', 'required': ['app/state.db']}))
    (root / 'romm-mariadb.json').write_text(json.dumps(image))
    source = root / 'source'
    source.mkdir()
    database = source / 'test.sqlite'
    with sqlite3.connect(database) as db:
        db.execute('CREATE TABLE kine (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)')
        db.execute("INSERT INTO kine (name) VALUES ('fixture')")
    archive = source / 'home-assistant.tar'
    with tarfile.open(archive, 'w') as tar:
        content = b'disposable Home Assistant archive fixture'
        info = tarfile.TarInfo('backup.json')
        info.size = len(content)
        tar.addfile(info, io.BytesIO(content))
    blobs = {
        'contract-version': b'3\n',
        'required-sqlite-databases.txt': b'app/state.db\n',
        'export-created-at': b'2026-09-26T12:00:00Z\n',
        'sqlite/app/state.db.sqlite-backup': database.read_bytes(),
        'k3s/state.db.sqlite-backup': database.read_bytes(),
        'home-assistant/home-assistant.tar': archive.read_bytes(),
        'romm/romm.sql': f'-- Server version\t{image["version"]}-MariaDB\n'.encode() + b'CREATE DATABASE romm;\nUSE romm;\nCREATE TABLE fixture (id INT PRIMARY KEY);\nINSERT INTO fixture VALUES (1);\n',
    }
    def restic(*args, output=None):
        if args[0] == 'ls':
            return '\n'.join(json.dumps(dict(path='/work/hot-dumps/' + p, type='file', size=len(b))) for p, b in blobs.items())
        assert args[0] == 'dump'
        data = blobs[args[2].removeprefix('/work/hot-dumps/')]
        if output is not None:
            output.write(data)
        else:
            return data.decode()
    snapshot = dict(id='a' * 64, hostname='minis', tags=['opt', 'nas'],
                    paths=['/data/opt', '/work/hot-dumps'], time='2026-09-26T12:01:00Z')
    # Like the vault restore tree, every scratch ancestor is root-only 0700.
    require(root.stat().st_uid == 0 and stat.S_IMODE(root.stat().st_mode) == 0o700,
            'test scratch must have root-only 0700 ancestors')
    setup_failure = root / 'setup-failure'
    setup_failure.mkdir(mode=0o700)
    real_mkdtemp = tempfile.mkdtemp
    sandbox_dirs = []
    def track_sandbox(*args, **kwargs):
        if kwargs.get('prefix') == 'offline-mariadb-':
            sandbox_dirs.append(Path(kwargs['dir']))
            require(Path(kwargs['dir']) == setup_failure, 'MariaDB scratch escaped the appstate restore tree')
        return real_mkdtemp(*args, **kwargs)
    with patch.object(c.tempfile, 'mkdtemp', side_effect=track_sandbox), \
            patch.object(c.subprocess, 'run', side_effect=FileNotFoundError('injected setup failure')):
        try:
            c.verify_appstate(restic, snapshot, setup_failure)
            raise AssertionError('injected MariaDB setup failure was ignored')
        except FileNotFoundError as error:
            require('injected setup failure' in str(error), 'unexpected setup failure')
    require(sandbox_dirs == [setup_failure] and not list(setup_failure.glob('offline-mariadb-*')),
            'MariaDB setup failure left plaintext scratch behind')
    scratch = root / 'restored'
    scratch.mkdir(mode=0o700)
    c.verify_appstate(restic, snapshot, scratch)
    require(not list(scratch.glob('offline-mariadb-*')), 'MariaDB sandbox left behind after success')
    # Client commands must be refused before they execute. Shell output would
    # reach the client's log; the marker text appears only if a shell ran.
    clean_dump = blobs['romm/romm.sql']
    header, body = clean_dump.split(b'\n', 1)
    for index, command in enumerate(('\\!', 'system')):
        blobs['romm/romm.sql'] = header + f"\n{command} printf 'CLIENT-%s\\n' SHELL-EXECUTED\n".encode() + body
        rejected = root / f'client-command-{index}'
        rejected.mkdir(mode=0o700)
        try:
            c.verify_appstate(restic, snapshot, rejected)
            raise AssertionError('unsafe client command accepted')
        except RuntimeError as error:
            require('isolated RomM import failed' in str(error), 'failure was not from the import')
            require('not allowed in the sandbox mode' in str(error).lower(), 'import failed without a sandbox diagnostic')
            log = (rejected / 'mariadb.log').read_text()
            require('CLIENT-SHELL-EXECUTED' not in log, 'dump executed a shell command')
        require(not list(rejected.glob('offline-mariadb-*')), 'MariaDB sandbox left behind after import failure')
    # A dump from a newer server than the pinned image is refused before import.
    blobs['romm/romm.sql'] = b'-- Server version\t99.0.0-MariaDB\n' + body
    newer = root / 'newer-dump'
    newer.mkdir(mode=0o700)
    try:
        c.verify_appstate(restic, snapshot, newer)
        raise AssertionError('dump from a newer MariaDB accepted')
    except RuntimeError as error:
        require('newer than verification image' in str(error), 'unexpected newer-dump failure')
    require(not list(newer.glob('offline-mariadb-*')), 'newer dump started an import')
    blobs['romm/romm.sql'] = clean_dump
    # Corruption fails before any successful annual record can be produced.
    blobs['k3s/state.db.sqlite-backup'] = b'corrupt database'
    failed = root / 'bad'
    failed.mkdir(mode=0o700)
    try:
        c.verify_appstate(restic, snapshot, failed)
        raise AssertionError('corrupt datastore accepted')
    except sqlite3.DatabaseError:
        pass
    print('PASS: SQLite/k3s schema and integrity, HA archive, pinned-container RomM import/check, client shell command refusal, newer-dump refusal, corrupted datastore refusal')
