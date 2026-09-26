#!/usr/bin/env python3
"""Disposable real-Restic copies and fail-closed orchestration tests; no production access."""
import argparse
import datetime as dt
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch, Mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('offline', HERE / 'offline-ssd.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
c = m.module('contracts_test', 'offline-contracts.py')
c.configure(m.legacy, lambda: None, m.canonical, m.require, HERE)


class PolicyTests(unittest.TestCase):
    def test_new_ssd_password_must_be_entered_twice(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(m.getpass, 'getpass',
                side_effect=['typo', 'intended']):
            with self.assertRaisesRegex(RuntimeError, 'did not match'):
                m.password(Path(temp), 'SSD A vault', confirm=True)
            self.assertFalse((Path(temp) / 'SSD-A-vault').exists())
        with tempfile.TemporaryDirectory() as temp, patch.object(m.getpass, 'getpass',
                side_effect=['correct horse', 'correct horse']):
            path = m.password(Path(temp), 'SSD A vault', confirm=True)
            self.assertEqual(path.read_text(), 'correct horse\n')

    def test_annual_schedule_and_missed_runs(self):
        def date(y, mo, day=1):
            return dt.datetime(y, mo, day, tzinfo=m.ZoneInfo('America/Chicago'))
        self.assertFalse(m.annual_due('A', date(2026, 9), date(2026, 9).timestamp()))
        self.assertTrue(m.annual_due('A', date(2026, 10), date(2026, 9).timestamp()))
        self.assertFalse(m.annual_due('A', date(2027, 4), date(2026, 10).timestamp()))
        self.assertTrue(m.annual_due('A', date(2027, 4), date(2026, 9).timestamp()))
        self.assertTrue(m.annual_due('B', date(2028, 1), date(2027, 6).timestamp()))
        self.assertFalse(m.annual_due('B', date(2028, 1), date(2027, 7).timestamp()))
        self.assertTrue(m.annual_due('B', date(2029, 7), date(2027, 7).timestamp()))
        self.assertEqual([m.scheduled_drive(f'2026-Q{i}') for i in range(1, 5)], ['B', 'A', 'B', 'A'])

    def test_capacity_and_no_destructive_restic_commands(self):
        usage = types.SimpleNamespace(f_bavail=100, f_blocks=1000, f_frsize=1)
        with self.assertRaisesRegex(RuntimeError, 'capacity'):
            m.capacity(usage, 1)
        r = m.Restic('vault', Path('/unused'), Path('/unused'))
        for command in ('forget', 'prune', 'unlock', 'backup', 'repair', 'mkfs.ext4'):
            with self.assertRaisesRegex(RuntimeError, 'not allowed'):
                r(command)

    def test_lineage_requires_metadata_and_unique_match(self):
        s = dict(id='a' * 64, hostname='minis', paths=['/opt'], tree='d' * 64, time='2026-10-01T00:00:00Z', tags=['nas'])
        frozen = m.freeze(s)
        retagged = {**s, 'id': 'b' * 64, 'original': s['id'], 'tags': ['nas', 'checkpoint']}
        self.assertEqual(m.resolve([retagged], frozen, 'checkpoint'), retagged)
        self.assertEqual(m.source_snapshot([s, retagged], frozen, 'checkpoint'), retagged)
        with self.assertRaises(RuntimeError):
            m.source_snapshot([s, retagged, retagged], frozen, 'checkpoint')
        for candidates in ([], [s], [retagged, retagged], [{**retagged, 'tree': 'e' * 64}]):
            with self.assertRaises(RuntimeError):
                m.resolve(candidates, frozen, 'checkpoint')

    def test_active_devices(self):
        base = dict(type='disk', path='/dev/test', mountpoints=[], fstype=None)
        with patch.object(m, 'run', return_value='{}'), patch.object(Path, 'iterdir', return_value=iter([])):
            for changes in ({'mountpoints': ['/']}, {'type': 'lvm'}, {'fstype': 'linux_raid_member'}, {'fstype': 'LVM2_member'}):
                with self.assertRaises(RuntimeError):
                    m.inactive({**base, **changes})
        with patch.object(m, 'run', return_value='/dev/test\n'):
            with self.assertRaisesRegex(RuntimeError, 'swap'):
                m.inactive(base)
        with patch.object(m, 'run', return_value='{}'), patch.object(Path, 'iterdir', return_value=iter([Path('holder')])):
            with self.assertRaisesRegex(RuntimeError, 'holders'):
                m.inactive(base)

    def test_stale_and_bad_contracts(self):
        with self.assertRaisesRegex(RuntimeError, 'stale'):
            c.validate(None, 'appstate', {'time': '2000-01-01T00:00:00Z'}, fresh=True)
        with self.assertRaisesRegex(RuntimeError, 'scope'):
            c.appstate(None, {'hostname': 'wrong'})
        with self.assertRaisesRegex(RuntimeError, 'scope'):
            c.vault(None, {'id': 'a' * 64, 'hostname': 'wrong'})


class MetricsTests(unittest.TestCase):
    def test_only_clean_successes_publish_and_missing_state_is_zero(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            control = root / 'control'
            control.mkdir()
            metrics = root / 'metrics'
            metrics.mkdir(mode=0o700)
            original_stat = Path.stat
            def stat(path, **kwargs):
                result = original_stat(path, **kwargs)
                if path == metrics:
                    return types.SimpleNamespace(st_uid=0, st_mode=result.st_mode)
                return result
            with patch.object(m, 'CONTROL', control), patch.object(m, 'METRICS', metrics / 'offline.prom'), \
                 patch.object(m, 'backup_guard', lambda: None), patch.object(m, 'secure', lambda *a: None), \
                 patch.object(Path, 'stat', stat):
                m.publish()
                self.assertIn('{drive="A"} 0', m.METRICS.read_text())
                self.assertIn('{drive="B"} 0', m.METRICS.read_text())
                success = {'success_at': 123, 'stage': 'complete', 'clean_unmount': True}
                m.legacy.save(control / 'A-enroll-2026-Q3.json', success)
                m.legacy.save(control / 'B-enroll-2026-Q3.json', {**success, 'clean_unmount': False})
                m.publish()
                self.assertIn('{drive="A"} 123', m.METRICS.read_text())
                self.assertIn('{drive="B"} 0', m.METRICS.read_text())
                m.legacy.save(control / 'A-rotate-2026-Q4.json', {'stage': 'synced'})
                m.publish()
                self.assertIn('{drive="A"} 123', m.METRICS.read_text())



class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ledger_root = self.root / 'vault'
        self.ledger_root.mkdir()
        self.lineage = 'a' * 64
        (self.ledger_root / 'validated.jsonl').write_text(json.dumps({'lineage': self.lineage}) + '\n')
        for name, value in [('VAULT_CONTROL', self.ledger_root), ('HERE', self.root)]:
            p = patch.object(c, name, value)
            p.start(); self.addCleanup(p.stop)
        self.snapshot = dict(id=self.lineage, hostname='minis', paths=['/data/opt', '/work/hot-dumps'],
                             time='2026-09-26T12:01:00Z', tags=['nas', 'opt'])
        (self.root / 'appstate-contract.json').write_text(json.dumps({'version': '3', 'required': ['app/state.db']}))
        self.dumps = {'contract-version': '3\n', 'required-sqlite-databases.txt': 'app/state.db\n',
                      'export-created-at': '2026-09-26T12:00:00Z'}
        self.paths = [*self.dumps, 'k3s/state.db.sqlite-backup', 'home-assistant/home-assistant.tar',
                      'romm/romm.sql', 'sqlite/app/state.db.sqlite-backup']
        self.listing = [dict(path='/work/hot-dumps/' + p, type='file', size=10) for p in self.paths]
        def restic(*args):
            if args[0] == 'dump':
                return self.dumps[args[2].removeprefix('/work/hot-dumps/')]
            return '\n'.join(json.dumps(n) for n in self.listing)
        self.restic = restic

    def test_ledger_holds_and_unfinished_resolutions(self):
        c.eligibility(self.snapshot)
        with self.assertRaisesRegex(RuntimeError, 'ledger'):
            c.eligibility({**self.snapshot, 'id': 'b' * 64})
        for base in (self.ledger_root, self.root / 'vault-b2'):
            base.mkdir(exist_ok=True)
            holds = base / 'holds'
            holds.mkdir()
            held = holds / 'held.json'
            held.write_text(json.dumps({'lineage': self.lineage}))
            with self.assertRaisesRegex(RuntimeError, 'hold'):
                c.eligibility(self.snapshot)
            held.unlink()
            resolutions = base / 'resolutions'
            resolutions.mkdir()
            resolution = resolutions / 'resolving.json'
            resolution.write_text(json.dumps({'stage': 'started'}))
            with self.assertRaisesRegex(RuntimeError, 'unfinished'):
                c.eligibility(self.snapshot)
            resolution.write_text(json.dumps({'stage': 'accepted'}))
            c.eligibility(self.snapshot)

    def test_appstate_markers_inventory_timestamp_and_required_files(self):
        c.appstate(self.restic, self.snapshot)
        for name, bad in [('contract-version', '2'), ('required-sqlite-databases.txt', 'other'),
                          ('export-created-at', '2000-01-01T00:00:00Z')]:
            previous = self.dumps[name]
            self.dumps[name] = bad
            with self.assertRaises(RuntimeError):
                c.appstate(self.restic, self.snapshot)
            self.dumps[name] = previous
        missing = self.listing.pop()
        with self.assertRaisesRegex(RuntimeError, 'absent'):
            c.appstate(self.restic, self.snapshot)
        self.listing.append(missing)
        self.listing.append(dict(path='/work/hot-dumps/server-token', type='file', size=1))
        with self.assertRaisesRegex(RuntimeError, 'token'):
            c.appstate(self.restic, self.snapshot)

    def test_vault_contract_measurement_exclusion_and_header_validation(self):
        contracts = self.root / 'contracts'
        contracts.mkdir()
        name = 'vault-v3'
        exclusion = contracts / (name + '.excludes')
        exclusion.write_text('released exclusion fixture\n')
        roots = ['/data/vault/credentials/strongbox/ccs.kdbx', '/data/vault/documents/fixture']
        release = dict(contract=name, exclusion_sha256=hashlib.sha256(exclusion.read_bytes()).hexdigest(),
            required_content=[dict(path=roots[0], kind='kdbx', minimum_files=1, minimum_bytes=8),
                              dict(path=roots[1], kind='directory', minimum_files=1, minimum_bytes=1)])
        released_path = contracts / (name + '.json')
        released_path.write_text(json.dumps(release))
        manifest = dict(contract=name, contract_sha256=hashlib.sha256(released_path.read_bytes()).hexdigest(),
            exclusion_sha256=release['exclusion_sha256'], filesystem_uuid='fixture-uuid',
            generated_at='2026-01-01T00:00:00Z', total_files=2, total_bytes=9,
            measurements=[dict(path=roots[0], kind='kdbx', files=1, bytes=8),
                          dict(path=roots[1], kind='directory', files=1, bytes=1)])
        listing = [dict(path=roots[0], type='file', size=8), dict(path=roots[1], type='dir'),
                   dict(path=roots[1] + '/document', type='file', size=1)]
        header = bytes.fromhex('03d9a29a67fb4bb5')
        root = self.root
        class R:
            workspace = root
            def __call__(self, *args, output=None):
                if args[0] == 'ls':
                    return '\n'.join(json.dumps(n) for n in listing)
                if args[-1] == '/work/backup-manifest.json':
                    return json.dumps(manifest)
                if args[-1] == '/data/vault/.vault-sentinel':
                    return 'vault-contract-version=3\nfilesystem-uuid=fixture-uuid\n'
                output.write(header)
        snapshot = dict(id='a' * 64, hostname='minis-vault', paths=['/data/vault', '/work/backup-manifest.json'], tags=['vault'])
        c.vault(R(), snapshot)
        manifest['total_bytes'] += 1
        with self.assertRaisesRegex(RuntimeError, 'measurements'):
            c.vault(R(), snapshot)
        manifest['total_bytes'] -= 1
        listing.append(dict(path='/data/vault/inbox/leak', type='file', size=1))
        with self.assertRaisesRegex(RuntimeError, 'leaked'):
            c.vault(R(), snapshot)
        listing.pop()
        header = b'bad kdbx'
        with self.assertRaisesRegex(RuntimeError, 'header'):
            c.vault(R(), snapshot)

    def test_selection_freshness_boundary(self):
        now = c.stamp(self.snapshot['time'])
        r = Mock()
        r.snapshots.return_value = [self.snapshot]
        with patch.object(c, 'appstate', return_value={}), patch.object(c.time, 'time', return_value=now + 30 * 3600):
            # Add the tree field required by frozen identity.
            self.snapshot['tree'] = 'f' * 64
            self.assertEqual(c.select(r, 'appstate')['id'], self.lineage)
        with patch.object(c.time, 'time', return_value=now + 30 * 3600 + 1):
            with self.assertRaisesRegex(RuntimeError, 'stale'):
                c.select(r, 'appstate')



class RealResticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'work'
        self.work.mkdir()
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'document').write_text('exact snapshot content\n' * 100)
        sources = {d: self.root / ('nas-' + d) for d in m.DATASETS}
        mounts = self.root / 'mounts'
        (mounts / 'A').mkdir(parents=True)
        self.record = {'drive': 'A'}
        for name, value in dict(SOURCES=sources, MOUNTS=mounts,
                BINARY=Path(os.environ.get('WORKSTATION_RESTIC', shutil.which('restic')))).items():
            self.patch(name, value)
        self.patch('backup_guard', lambda: None)
        self.patch('mount_guard', lambda record: mounts / record['drive'])
        self.patch('secure', lambda path, mode=0o700: m.canonical(path))
        self.patch('repository_directory', lambda path, private: m.canonical(path))
        self.passwords = []
        for name in ('nas', 'dest'):
            path = self.work / name
            path.write_text(name + '-independent-password\n')
            self.passwords.append(path)
        self.s = m.Restic('vault', self.passwords[0], self.work)
        self.raw('init', '--repository-version', '2')
        self.s.expected = self.s.config()['id']
        self.raw('backup', '--host', 'fixture', '--tag', 'vault', str(self.source))
        self.snapshot = self.s.snapshots()[0]
        self.d = m.Restic('vault', self.passwords[1], self.work, self.record, source=self.s)

    def patch(self, name, value):
        p = patch.object(m, name, value)
        p.start()
        self.addCleanup(p.stop)

    def raw(self, *args):
        return subprocess.check_output([str(m.BINARY), '-r', str(self.s.repo), '--password-file', str(self.passwords[0]),
                                        '--no-cache', *args], stderr=subprocess.PIPE)

    def initialize(self):
        self.d('init', '--repository-version', '2', '--copy-chunker-params')
        self.d.expected = self.d.config()['id']

    def test_exact_copy_retag_retry_and_cumulative_history(self):
        self.initialize()
        self.assertNotEqual(self.s.expected, self.d.expected)
        self.assertEqual(self.s.config()['chunker_polynomial'], self.d.config()['chunker_polynomial'])
        frozen = m.freeze(self.snapshot)
        tag = 'offline-checkpoint-2026-Q4'
        self.s('tag', '--add', tag, self.snapshot['id'])
        tagged = m.resolve(self.s.snapshots(), frozen, tag)
        self.assertNotEqual(tagged['id'], self.snapshot['id'])
        self.d('copy', tagged['id'])
        self.d('copy', tagged['id'])
        copied = m.resolve(self.d.snapshots(), frozen, tag)
        self.assertEqual(len(self.d.snapshots()), 1)
        self.assertEqual(m.lineage(copied), frozen['lineage'])
        # A later snapshot doesn't silently replace the recorded checkpoint.
        (self.source / 'document').write_text('newer content')
        self.raw('backup', '--host', 'fixture', '--tag', 'vault', str(self.source))
        self.assertEqual(m.resolve(self.d.snapshots(), frozen, tag)['id'], copied['id'])
        newer = max(self.s.snapshots(), key=lambda s: s['time'])
        self.d('copy', newer['id'])
        self.assertEqual(len(self.d.snapshots()), 2)
        self.d('check', '--read-data')
        # A different destination password cannot open the source.
        wrong = m.Restic('vault', self.passwords[1], self.work)
        with self.assertRaisesRegex(RuntimeError, 'failed'):
            wrong.config()

    def test_repo_substitution_mount_loss_and_symlinks(self):
        self.initialize()
        self.d.expected = '0' * 64
        with self.assertRaisesRegex(RuntimeError, 'substituted'):
            self.d.snapshots()
        self.d.expected = None
        with patch.object(m, 'mount_guard', side_effect=RuntimeError('SSD mount lost')):
            with self.assertRaisesRegex(RuntimeError, 'mount lost'):
                self.d('copy', self.snapshot['id'])
        (self.d.repo / 'locks').rename(self.root / 'old-locks')
        (self.d.repo / 'locks').symlink_to(self.root / 'old-locks')
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            self.d.snapshots()

    def test_legacy_copy_verifies_without_source_and_rejects_bad_evidence(self):
        legacy = m.legacy
        old_control = self.root / 'legacy-control'
        old_control.mkdir()
        with patch.object(legacy, 'CONTROL', old_control), patch.object(legacy, 'SOURCE', self.source):
            file = self.source / 'document'
            os.setxattr(file, 'user.offline', b'archived')
            os.link(file, self.source / 'hardlink')
            (self.source / 'link').symlink_to('document')
            records = legacy.inventory(self.source)
            self.raw('backup', '--host', 'fixture', str(self.source))
            snapshot = max(self.s.snapshots(), key=lambda s: s['time'])
            accepted = {'sample_hashes': {p: hashlib.sha256((self.source / p).read_bytes()).hexdigest()
                        for p in legacy.samples(records) if records[p]['type'] == 'file'}}
            self.initialize()
            self.d('copy', snapshot['id'])
            copied = m.resolve(self.d.snapshots(), m.freeze(snapshot))
            shutil.rmtree(self.source)
            run = old_control / 'verification'
            run.mkdir()
            legacy.verify_destination(self.d, copied['id'], records, accepted, run)
            self.assertFalse((old_control / 'accepted.json').exists())
            bad = old_control / 'bad'
            bad.mkdir()
            with self.assertRaisesRegex(RuntimeError, 'hash mismatch'):
                legacy.verify_destination(self.d, copied['id'], records, {'sample_hashes': {}}, bad)


class OperationTests(unittest.TestCase):
    """Crash every durable boundary with deterministic repositories and real JSON state."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.control = self.root / 'control'
        self.control.mkdir()
        self.mount = self.root / 'mount'
        self.mount.mkdir()
        self.work = self.root / 'work'
        self.work.mkdir()
        output = patch('builtins.print')
        output.start(); self.addCleanup(output.stop)
        self.records = {'drive': 'A', 'stage': 'provisioned', 'repositories': {}}
        self.path = self.control / 'A.json'
        self.path.write_text(json.dumps(self.records))
        self.snapshots = {}
        self.calls = []
        self.failed = False
        self.fail_at = None
        self.save_count = 0
        self.counter = 0
        self.inject_command = None
        fixture = self
        class FakeRestic:
            def __init__(self, dataset, password, workspace, record=None, expected=None, source=None):
                self.dataset, self.password, self.workspace = dataset, password, workspace
                self.record, self.expected, self.source = record, expected, source
                self.key = ('dst' if record else 'src', dataset)
                self.repo = fixture.mount / dataset if record else fixture.root / ('src-' + dataset)
                fixture.snapshots.setdefault(self.key, [])
                if not record and not fixture.snapshots[self.key]:
                    self.repo.mkdir(exist_ok=True)
                    ident = str(m.DATASETS.index(dataset) + 1) * 64
                    fixture.snapshots[self.key].append(dict(id=ident, tree='a' * 64, time='2026-10-01T00:00:00Z',
                        hostname='minis' if dataset == 'legacy-rsnapshot' else 'fixture',
                        paths=[str(m.legacy.SOURCE)] if dataset == 'legacy-rsnapshot' else ['/fixture'],
                        tags=['legacy-rsnapshot'] if dataset == 'legacy-rsnapshot' else ['original']))
            def __call__(self, *args, **kwargs):
                fixture.calls.append((self.key, args))
                if args[0] == 'init':
                    self.repo.mkdir()
                if args[0] == 'stats':
                    return '{"total_size": 10}'
                if args[0] == 'tag':
                    snapshot = next(s for s in fixture.snapshots[self.key] if s['id'] == args[-1])
                    snapshot.update(original=snapshot.get('original', snapshot['id']), id='f' + snapshot['id'][1:],
                                    tags=[*snapshot['tags'], args[2]])
                if args[0] == 'copy':
                    snapshot = next(s for s in fixture.snapshots[self.source.key] if s['id'] == args[1])
                    fixture.snapshots[self.key].append({**snapshot})
                if fixture.inject_command == (self.dataset, args[0]) and not fixture.failed:
                    fixture.failed = True
                    raise RuntimeError('injected interruption')
                return ''
            def config(self):
                return {'id': ('d' if self.record else 'a') + str(m.DATASETS.index(self.dataset)) * 63,
                        'version': 2, 'chunker_polynomial': 'same'}
            def snapshots(self):
                return list(fixture.snapshots[self.key])
        self.FakeRestic = FakeRestic
        from contextlib import contextmanager
        @contextmanager
        def workspace():
            yield self.work
        def save(path, value):
            self.save_count += 1
            if self.fail_at == self.save_count:
                raise RuntimeError('injected write interruption')
            m.legacy.save(path, value)
        def run(*args, **kwargs):
            if self.inject_command == args[0] and not self.failed:
                self.failed = True
                raise RuntimeError('injected interruption')
            return '1 path' if args[0] == 'du' else ''
        def password(work, label, **kwargs):
            path = work / label
            path.write_text(label)
            return path
        complete_verification = {'repositories': {d: {'full_data_check': 'passed'} for d in m.DATASETS},
            'vault_restore_and_strongbox': 'passed', 'appstate_exports_and_romm_import': 'passed',
            'legacy_evidence_and_manual_inspection': 'passed'}
        contracts = types.SimpleNamespace(
            configure=lambda *a: None, select=lambda r, d: m.freeze(r.snapshots()[0]), validate=lambda *a, **k: None,
            eligibility=lambda *a: None, vault_scratch=lambda: self.root,
            verify_all=lambda *a: complete_verification,
            legacy_acceptance=lambda: {'snapshot_id': '3' * 64, 'repository_id': 'a' + '2' * 63})
        for name, value in dict(CONTROL=self.control, MOUNTS=self.root, Restic=FakeRestic,
            confirm=lambda *a: None, attach=lambda *a: None, ram_workspace=workspace,
            password=password, secure=lambda *a: None, backup_guard=lambda: None,
            mount_guard=lambda *a: self.mount, save=save, publish=lambda: None,
            run=run, module=lambda *a: contracts).items():
            p = patch.object(m, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(m.subprocess, 'run', return_value=types.SimpleNamespace(returncode=1))
        p.start(); self.addCleanup(p.stop)
        (self.root / 'A').symlink_to(self.mount, target_is_directory=True)
        self.args = argparse.Namespace(command='enroll', drive='A')

    def pending(self):
        paths = list(self.control.glob('A-enroll-*.json'))
        return json.loads(paths[0].read_text()) if paths else {}

    def assert_no_success(self):
        self.assertFalse(self.pending().get('success_at'))
        self.assertEqual(list(m.successful('A')), [])

    def test_success_and_same_quarter_rerun(self):
        m.operate(self.args)
        previous = self.pending()
        self.assertTrue(previous['clean_unmount'])
        self.assertEqual(len(previous['copies']), 3)
        self.assertEqual(m.read(self.path)['stage'], 'enrolled')
        calls = len(self.calls)
        m.operate(self.args)
        self.assertEqual(len(self.calls), calls)
        self.assertEqual(self.pending()['success_at'], previous['success_at'])

    def test_copy_and_tag_interruptions_resume_existing_checkpoints(self):
        for dataset, command in [('vault', 'tag'), ('vault', 'copy'), ('appstate', 'copy'), ('legacy-rsnapshot', 'copy')]:
            with self.subTest(dataset=dataset, command=command):
                # Each scenario needs independent state; subtest fixture created explicitly.
                test = OperationTests()
                test.setUp()
                try:
                    test.inject_command = (dataset, command)
                    with self.assertRaisesRegex(RuntimeError, 'injected'):
                        m.operate(test.args)
                    test.assert_no_success()
                    m.operate(test.args)
                    self.assertTrue(test.pending()['success_at'])
                    self.assertTrue(all(len(test.snapshots['dst', d]) == 1 for d in m.DATASETS))
                finally:
                    test.doCleanups()

    def test_sync_unmount_and_evidence_interruptions(self):
        for event in ('sync', 'umount'):
            test = OperationTests(); test.setUp()
            try:
                test.inject_command = event
                with self.assertRaisesRegex(RuntimeError, 'injected'):
                    m.operate(test.args)
                test.assert_no_success()
                m.operate(test.args)
                self.assertTrue(test.pending()['success_at'])
            finally:
                test.doCleanups()
        # Cover each record write after initialization through finalization.
        for boundary in range(5, 16):
            test = OperationTests(); test.setUp()
            try:
                test.fail_at = boundary
                try:
                    m.operate(test.args)
                except RuntimeError:
                    if not test.pending().get('success_at'):
                        test.assert_no_success()
                    test.fail_at = None
                    m.operate(test.args)
                    self.assertTrue(test.pending()['success_at'])
            finally:
                test.doCleanups()

    def test_failed_annual_validation_cannot_advance_success(self):
        contracts = m.module('fixture', 'fixture')
        contracts.verify_all = Mock(side_effect=RuntimeError('annual check failed'))
        with self.assertRaisesRegex(RuntimeError, 'annual'):
            m.operate(self.args)
        self.assert_no_success()
        self.assertEqual(len(self.pending()['copies']), 3)
        contracts.verify_all = lambda *a: {'repositories': {d: {'full_data_check': 'passed'} for d in m.DATASETS},
            'vault_restore_and_strongbox': 'passed', 'appstate_exports_and_romm_import': 'passed',
            'legacy_evidence_and_manual_inspection': 'passed'}
        m.operate(self.args)
        self.assertTrue(self.pending()['annual_verified_at'])

    def test_resume_skips_persisted_full_verification(self):
        contracts = m.module('fixture', 'fixture')
        complete = contracts.verify_all
        contracts.verify_all = Mock(side_effect=complete)
        self.inject_command = 'du'
        with self.assertRaisesRegex(RuntimeError, 'injected'):
            m.operate(self.args)
        self.assertTrue(m.verification_complete(self.pending()))
        self.inject_command = None
        m.operate(self.args)
        contracts.verify_all.assert_called_once()

    def test_resume_with_existing_copies_does_not_require_fresh_source(self):
        contracts = m.module('fixture', 'fixture')
        contracts.verify_all = Mock(side_effect=RuntimeError('annual check failed'))
        with self.assertRaisesRegex(RuntimeError, 'annual'):
            m.operate(self.args)
        self.assertEqual(len(self.pending()['copies']), 3)

        # Simulate a long interruption after copying: retention may age the NAS
        # checkpoints, while the destination copies remain present and exact.
        for dataset in m.DATASETS:
            self.snapshots['src', dataset][0]['time'] = '2000-01-01T00:00:00Z'
        fresh_checks = []
        def validate(_restic, _dataset, _snapshot, fresh):
            fresh_checks.append(fresh)
            if fresh:
                raise RuntimeError('source snapshot stale')
        contracts.validate = validate
        contracts.verify_all = lambda *a: {'full_data_check': 'passed'}
        m.operate(self.args)
        self.assertTrue(self.pending()['success_at'])
        self.assertNotIn(True, fresh_checks)

    def test_interrupted_initialization_is_not_adopted(self):
        self.inject_command = ('vault', 'init')
        with self.assertRaisesRegex(RuntimeError, 'injected'):
            m.operate(self.args)
        self.assert_no_success()
        with self.assertRaisesRegex(RuntimeError, 'unidentified'):
            m.operate(self.args)


if __name__ == '__main__':
    unittest.main()
