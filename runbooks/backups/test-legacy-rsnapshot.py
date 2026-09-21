#!/usr/bin/env python3
"""Disposable real-Restic and failure-injection tests; no production paths accessed."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('legacy', Path(__file__).with_name('legacy-rsnapshot.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'snapshots'
        self.source.mkdir()
        for top in ('daily.0', 'monthly.0'):
            (self.source / top).mkdir()
        file = self.source / 'daily.0/.executable'
        file.write_bytes(b'historical content\n')
        file.chmod(0o751)
        os.utime(file, ns=(1600000000123456789, 1600000000123456789))
        os.setxattr(file, 'user.fixture', b'metadata')
        if os.geteuid() == 0:
            os.chown(file, 12345, 23456)
            file.chmod(0o4751)
        os.link(file, self.source / 'monthly.0/hardlink')
        (self.source / 'daily.0/link').symlink_to('.executable')
        if os.geteuid() == 0:
            os.chown(self.source / 'daily.0/link', 12345, 23456, follow_symlinks=False)
        (self.source / 'monthly.0/[literal]*?').write_text('glob filename')
        with socket.socket(socket.AF_UNIX) as sock:
            sock.bind(str(self.source / 'daily.0/stale.sock'))
        self.repo = self.root / 'repository'
        self.control = self.root / 'control'
        self.control.mkdir()
        self.run = self.control / 'run'
        self.run.mkdir()
        self.password = self.root / 'password'
        self.password.write_text('disposable-test-password\n')
        for name, value in dict(SOURCE=self.source, REPO=self.repo, CONTROL=self.control,
                                MOUNT=self.root, BINARY=Path(shutil.which('restic'))).items():
            p = patch.object(m, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.restic = m.Restic(self.password, log_dir=self.run, guarded=False)
        self.records = m.inventory(self.source)

    def test_inventory_hardlinks_and_capacity(self):
        total = m.totals(self.records)
        self.assertEqual(total['unique_inode_logical_bytes'], len(b'historical content\n') + len('glob filename'))
        with self.assertRaisesRegex(RuntimeError, 'insufficient capacity'):
            m.capacity(self.records, type('Usage', (), dict(f_blocks=100, f_frsize=1, f_bavail=1))())
        with self.assertRaisesRegex(RuntimeError, 'empty'):
            empty = self.root / 'empty'
            empty.mkdir()
            m.inventory(empty)
        alias = self.root / 'alias'
        alias.symlink_to(self.source)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            m.canonical(alias)

    def test_inventory_root_alias_across_saved_versions(self):
        older = m.Inventory()
        listing = m.Inventory()
        for path, record in self.records.items():
            older['' if path == '.' else path] = record
            if record['type'] != 'socket':
                listing[path] = {key: record[key] for key in
                                 ('type', 'mode', 'uid', 'gid', 'size', 'mtime_ns')}
        older.finish()
        self.assertEqual(self.records, older)
        self.assertEqual(older, self.records)
        self.assertNotIn('', m.samples(older))
        self.assertNotIn('.', m.samples(older))
        m.compare_listing(older, listing)

    def test_wrong_mount_identity(self):
        with patch.object(m, 'command', return_value=json.dumps({'filesystems': [dict(target=str(self.root), fstype='ext4', uuid='wrong')]})):
            with self.assertRaisesRegex(RuntimeError, 'mount identity'):
                m.mount_guard()

    def test_nested_mount_and_bad_sentinel(self):
        sentinel = self.root / '.backup-sentinel'
        sentinel.write_text(m.UUID + '\n')
        sentinel.chmod(0o444)
        device = Path('/dev/disk/by-uuid') / m.UUID
        row = dict(target=str(self.root), source=str(device), fstype='ext4', uuid=m.UUID, fsroot='/')
        original_stat = Path.stat
        def stat_fixture(path, *args, **kwargs):
            result = original_stat(path, *args, **kwargs)
            if path == sentinel:
                values = list(result)
                values[4] = values[5] = 0
                return os.stat_result(values)
            return result
        responses = [json.dumps({'filesystems': [row]}),
                     json.dumps({'filesystems': [dict(target=str(self.source / 'nested'))]})]
        with patch.object(m, 'DEVICE', device), patch.object(Path, 'stat', stat_fixture), patch.object(m, 'command', side_effect=responses):
            with self.assertRaisesRegex(RuntimeError, 'nested mount'):
                m.mount_guard()
        sentinel.chmod(0o644)
        with patch.object(m, 'DEVICE', device), patch.object(Path, 'stat', stat_fixture), patch.object(m, 'command', return_value=responses[0]):
            with self.assertRaisesRegex(RuntimeError, 'sentinel'):
                m.mount_guard()


    def test_resume_inventory_is_scoped_fresh_and_root_only(self):
        if os.geteuid() != 0:
            self.skipTest('root ownership is required to test the live resume contract')
        archived = self.control / 'archive-fixture'
        archived.mkdir(mode=0o700)
        inventory = archived / 'inventory.sqlite'
        m.save(inventory, self.records)
        m.save(archived / 'preflight.json', dict(source=m.totals(self.records)))
        records, totals = m.load_resume_inventory(inventory)
        self.assertEqual(totals['entries'], len(records))
        self.assertEqual(records, self.records)
        outside = self.root / 'outside.sqlite'
        shutil.copy2(inventory, outside)
        with self.assertRaisesRegex(RuntimeError, 'private control directory'):
            m.load_resume_inventory(outside)


    def test_unexpected_existing_directory(self):
        self.repo.mkdir()
        with self.assertRaisesRegex(RuntimeError, 'unexpected existing'):
            m.archive(self.restic, self.records, self.run)

    def test_real_archive_verify_and_repeat(self):
        # Production requires root-owned directories; test callers may be unprivileged.
        with patch.object(m, 'private'):
            sid = m.archive(self.restic, self.records, self.run)
            with patch('builtins.input', return_value=sid):
                self.assertEqual(m.verify(self.restic, sid, self.run), sid)
            self.assertTrue((self.control / 'accepted.json').exists())
            accepted = json.loads((self.control / 'accepted.json').read_text())
            self.assertEqual(accepted['omitted_unix_sockets'], 1)
            self.source.rename(self.root / 'source-retained-outside-original-path')
            with patch('builtins.input', return_value=sid):
                self.assertEqual(m.verify(self.restic, sid, self.run), sid)
            with self.assertRaisesRegex(RuntimeError, 'candidate already'):
                m.archive(self.restic, self.records, self.run)
            with self.assertRaisesRegex(RuntimeError, 'recorded full'):
                m.verify(self.restic, 'a' * 64, self.run)
            enrollment = json.loads((self.control / 'enrollment.json').read_text())
            enrollment['repository_id'] = 'b' * 64
            m.save(self.control / 'enrollment.json', enrollment)
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                m.archive(self.restic, self.records, self.run)

    def test_partial_and_interrupted_backup_retry(self):
        for failure in (subprocess.CalledProcessError(3, 'restic'), KeyboardInterrupt()):
            def fail_backup(*args):
                if args[0] == 'backup':
                    raise failure
                return self.restic(*args)
            with patch.object(m, 'private'), self.assertRaises(type(failure)):
                m.archive(fail_backup, self.records, self.run)
            self.assertFalse((self.control / 'candidate.json').exists())
        with patch.object(m, 'private'):
            self.assertRegex(m.archive(self.restic, self.records, self.run), r'^[a-f0-9]{64}$')

    def test_source_change_fails(self):
        def mutate(*args):
            result = self.restic(*args)
            if args[0] == 'backup':
                (self.source / 'new').write_text('changed')
            return result
        with patch.object(m, 'private'), self.assertRaisesRegex(RuntimeError, 'source changed'):
            m.archive(mutate, self.records, self.run)
        self.assertFalse((self.control / 'candidate.json').exists())

    def test_zero_mode_omitted_from_restic_json(self):
        row = dict(struct_type='node', path=str(self.source / 'zero'), type='file',
                   uid=0, gid=0, size=0, mtime='2020-01-01T00:00:00Z')
        listing = m.archived_inventory(json.dumps(row), self.source)
        self.assertEqual(listing['zero']['mode'], 0)


    def test_metadata_mismatch_is_rejected(self):
        with patch.object(m, 'private'):
            sid = m.archive(self.restic, self.records, self.run)
        listing = m.archived_inventory(self.restic('ls', '--json', sid), self.source)
        record = listing['daily.0/.executable']
        record['uid'] += 1
        listing.db.execute('UPDATE entries SET record=? WHERE path=?',
                           (json.dumps(record), 'daily.0/.executable'))
        with self.assertRaisesRegex(RuntimeError, 'metadata mismatch'):
            m.compare_listing(self.records, listing)

    def test_failed_full_check_cannot_accept(self):
        with patch.object(m, 'private'):
            sid = m.archive(self.restic, self.records, self.run)
        def fail_check(*args):
            if args[0] == 'check':
                raise subprocess.CalledProcessError(1, 'restic check')
            return self.restic(*args)
        with self.assertRaises(subprocess.CalledProcessError):
            m.verify(fail_check, sid, self.run)
        self.assertFalse((self.control / 'accepted.json').exists())


    def test_init_interruption_does_not_adopt(self):
        def interrupted(*args):
            result = self.restic(*args)
            if args[0] == 'init':
                raise KeyboardInterrupt()
            return result
        with self.assertRaises(KeyboardInterrupt):
            m.archive(interrupted, self.records, self.run)
        with self.assertRaisesRegex(RuntimeError, 'unexpected existing'):
            m.archive(self.restic, self.records, self.run)


if __name__ == '__main__':
    unittest.main()
