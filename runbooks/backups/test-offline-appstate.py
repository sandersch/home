#!/usr/bin/env python3
"""Disposable SQLite, HA archive and real isolated MariaDB restore validation."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('contracts', HERE / 'offline-contracts.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


require(os.geteuid() == 0, 'run in a disposable root test environment with MariaDB tools')
with tempfile.TemporaryDirectory(prefix='offline-appstate-', dir='/tmp') as temp:
    root = Path(temp)
    c.configure(None, lambda: None, lambda p: require(p.resolve() == p, 'symlink'), require, root)
    (root / 'appstate-contract.json').write_text(json.dumps({'version': '3', 'required': ['app/state.db']}))
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
        'romm/romm.sql': b'CREATE DATABASE romm;\nUSE romm;\nCREATE TABLE fixture (id INT PRIMARY KEY);\nINSERT INTO fixture VALUES (1);\n',
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
    scratch = root / 'restored'
    scratch.mkdir(mode=0o700)
    c.verify_appstate(restic, snapshot, scratch)
    # Corruption fails before any successful annual record can be produced.
    blobs['k3s/state.db.sqlite-backup'] = b'corrupt database'
    failed = root / 'bad'
    failed.mkdir(mode=0o700)
    try:
        c.verify_appstate(restic, snapshot, failed)
        raise AssertionError('corrupt datastore accepted')
    except sqlite3.DatabaseError:
        pass
    print('PASS: SQLite/k3s schema and integrity, HA archive, real isolated RomM import/check, corrupted datastore refusal')
