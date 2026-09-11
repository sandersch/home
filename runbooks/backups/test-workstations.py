#!/usr/bin/env python3
"""Workstation safety fixtures; uses real disposable Restic repositories."""
import copy
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'host/workstations'), str(ROOT / 'infrastructure/monitoring/workstations')]
import workstation as client
import maintenance as server

RESTIC = os.environ.get('WORKSTATION_RESTIC', '/tmp/workstation-restic-tools/restic')
REPOSITORIES = ROOT / 'runbooks/backups/fixtures/workstation-repositories'
READ_ONLY = {'cat', 'dump', 'ls', 'snapshots'}


class FixtureManager(server.Manager):
    def __init__(self, fixture):
        self.host = 'ryze'
        self.contract = fixture.contract
        self.rules = ['.cache']
        self.contracts = {fixture.contract['contract']: (fixture.contract, self.rules, 'fixture')}
        self.state = {'accepted': {}, 'rejected': {}, 'holds': {}, 'copies': {}, 'pending': [],
                      'generation': 1, 'baseline': [], 'highwater': 0, 'prune_success': 0,
                      'copy_success': 0, 'check_success': {}, 'validation_success': 0}
        self.control = fixture.base / 'control'
        self.control.mkdir()
        self.file = self.control / 'state.json'
        self.commands = []
        self.credentials = {d: {'RESTIC_REPOSITORY': str(fixture.base / d),
                               'RESTIC_PASSWORD': 'disposable-test-password'} for d in ('nas', 'b2')}

    def run(self, destination, *args, raw=False, extra_env=None):
        self.commands.append((destination, args))
        env = {**os.environ, **self.credentials[destination], **(extra_env or {})}
        # Locking waits 200ms per command; fixtures never run commands concurrently.
        lock = ['--no-lock'] if args[0] in READ_ONLY else []
        result = subprocess.run([RESTIC, '--no-cache', *lock, *map(str, args)], env=env,
                                capture_output=True)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, args, stderr=result.stderr)
        return result.stdout if raw else json.loads(result.stdout or b'null')

    def restart(self):
        self.commands.append(('server', ('restart',)))


@unittest.skipUnless(Path(RESTIC).is_file(), 'set WORKSTATION_RESTIC to checksum-verified Restic 0.19.1')
class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='workstation-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home = self.base / 'home'
        (self.home / 'Documents').mkdir(parents=True)
        (self.home / 'Dropbox').mkdir()
        (self.home / 'Documents/report').write_bytes(b'a' * 4096)
        (self.home / 'Documents/report').chmod(0o750)
        (self.home / 'Dropbox/ccs.kdbx').write_bytes(client.KDBX + b'\0' * 102400)
        (self.home / '.hidden').write_text('state')
        (self.home / 'link').symlink_to('Documents/report')
        self.contract = {'hostname': 'ryze', 'contract': 'workstation-ryze-v1',
                         'source_roots': [str(self.home)], 'manifest': str(self.home / client.MANIFEST),
                         'exclusion_sha256': 'fixture', 'floors': {'': {'files': 3, 'bytes': 100000},
                         'Documents/': {'files': 1, 'bytes': 1}}, 'kdbx_minimum_bytes': 102400}
        self.manager = FixtureManager(self)
        # Empty NAS/B2 pair with low-cost scrypt keys; see fixtures/make-workstation-repositories.py.
        for destination in ('nas', 'b2'):
            shutil.copytree(REPOSITORIES / destination, self.base / destination)

    def snapshot(self, when=None, omit=None, churn=None):
        records, _ = client.inventory(self.home, ['.cache'])
        client.atomic(self.home / client.MANIFEST, {'contract': self.contract['contract'],
            'exclusion_sha256': 'fixture', 'records': records, 'measured': client.totals(records)})
        if churn:
            churn()
        args = ['backup', '--json', '--host', 'ryze']
        if when:
            args += ['--time', when]
        if omit:
            args += ['--exclude', str(self.home / omit)]
        output = self.manager.run('nas', *args, self.home, raw=True)
        return next(json.loads(line)['snapshot_id'] for line in output.splitlines()
                    if json.loads(line).get('message_type') == 'summary')

    def test_file_provider_dropbox_is_validated_and_copied(self):
        target = self.home / 'Library/CloudStorage/Dropbox'
        target.parent.mkdir(parents=True)
        (self.home / 'Dropbox').rename(target)
        (self.home / 'Dropbox').symlink_to(target)
        self.contract['kdbx_path'] = 'Library/CloudStorage/Dropbox/ccs.kdbx'
        sid = self.snapshot()
        self.manager.copy()
        self.assertIn(sid, self.manager.state['copies'])
        self.contract['kdbx_path'] = 'Dropbox/ccs.kdbx'
        with self.assertRaisesRegex(ValueError, 'path differs'):
            records, _ = client.inventory(self.home, [])
            client.check_floors(records, self.contract)
        with self.assertRaisesRegex(ValueError, 'missing from scope'):
            client.inventory(self.home, ['Library/CloudStorage/Dropbox/ccs.kdbx'])

    def test_round_trip_copy_exact_ids(self):
        attribute = 'user.workstation-test' if sys.platform != 'darwin' else 'com.worm.workstation-test'
        os.setxattr(self.home / '.hidden', attribute, b'metadata fixture')
        sid = self.snapshot()
        self.manager.copy()
        self.assertIn(sid, self.manager.state['accepted'])
        target = self.manager.state['copies'][sid]
        self.assertIn(target, self.manager.listing('b2'))
        self.assertEqual(self.manager.state['holds'], {})
        output = self.manager.run('b2', 'dump', target, str(self.home / '.hidden'), raw=True)
        self.assertEqual(output, b'state')
        restored = self.base / 'restore-scratch'
        restored.mkdir(mode=0o700)
        credentials = self.base / 'recovery-credentials.json'
        credentials.write_text(json.dumps(self.manager.credentials['b2']))
        credentials.chmod(0o600)
        result = subprocess.run([sys.executable, str(ROOT / 'runbooks/backups/workstation-restore.py'),
            '--snapshot', target, '--destination', 'b2', '--credentials', str(credentials),
            '--scratch-parent', str(restored), '--restic', RESTIC,
            '--metadata-path', str(self.home / '.hidden')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        restored_home = next(restored.glob('workstation-restore-*/home'))
        self.assertEqual((restored_home / '.hidden').read_text(), 'state')
        self.assertEqual(os.readlink(restored_home / 'link'), 'Documents/report')
        self.assertEqual((restored_home / 'Documents/report').stat().st_mode & 0o777, 0o750)
        self.assertEqual((restored_home / 'Documents/report').stat().st_mtime_ns,
                         (self.home / 'Documents/report').stat().st_mtime_ns)

    def test_omitted_file_is_held(self):
        sid = self.snapshot(omit='.hidden')
        self.manager.validate()
        self.assertNotIn(sid, self.manager.state['accepted'])
        self.assertIn('nas:' + sid, self.manager.state['holds'])

    def test_enrollment_metrics_begin_at_first_seed(self):
        metrics = self.base / 'metrics'
        metrics.mkdir()
        self.manager.root = self.base
        def emitted():
            with patch.object(server, 'Path', lambda p: metrics if p == '/metrics' else Path(p)):
                self.manager.metrics()
            rows = (metrics / 'restic-workstation-ryze.prom').read_text().splitlines()
            return {row.split('{')[0]: float(row.split()[-1]) for row in rows if 'destination' not in row}
        unseeded = emitted()
        self.assertEqual(unseeded['homelab_workstation_enrolled'], 0)
        self.assertEqual(unseeded['homelab_workstation_enrollment_timestamp_seconds'], 0)
        held = self.snapshot(omit='.hidden')
        self.manager.validate()
        self.assertIn('nas:' + held, self.manager.state['holds'])
        self.assertEqual(emitted()['homelab_workstation_enrolled'], 1)
        self.manager.reject(held, 'fixture omitted a required file', 'nas')
        sid = self.snapshot()
        self.manager.validate()
        seeded = emitted()
        self.assertEqual(seeded['homelab_workstation_enrolled'], 1)
        self.assertEqual(seeded['homelab_workstation_enrollment_timestamp_seconds'],
                         self.manager.state['accepted'][sid]['time'])

    def test_contract_drift_is_held(self):
        sid = self.snapshot()
        self.manager.contracts['workstation-ryze-v1'] = ({**self.contract, 'exclusion_sha256': 'changed'}, ['.cache'], 'fixture')
        self.manager.validate()
        self.assertNotIn(sid, self.manager.state['accepted'])

    def tolerate(self, maximum):
        self.contract['churn_tolerance'] = {'maximum_paths': maximum,
                                            'protected_paths': ['Documents', 'Dropbox/ccs.kdbx']}

    def receipt(self, sid, payload=None, when=None):
        row = self.manager.listing('nas')[sid]
        payload = payload or client.completion_receipt(sid, row['tree'], self.contract)
        args = ['backup', '--json', '--host', 'ryze', '--stdin',
                '--stdin-filename', f'{client.RECEIPT_ROOT}/{sid}.json']
        if when:
            args += ['--time', when]
        output = subprocess.check_output([RESTIC, '--no-cache', *args],
            input=json.dumps(payload).encode(), env={**os.environ, **self.manager.credentials['nas']})
        return next(json.loads(line)['snapshot_id'] for line in output.splitlines()
                    if json.loads(line).get('message_type') == 'summary')

    def test_strict_contract_holds_any_churn(self):
        sid = self.snapshot(churn=lambda: (self.home / '.hidden').write_text('changed state'))
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'],
                         'manifest does not match actual snapshot listing')

    def test_tolerant_contract_accepts_bounded_churn_with_actual_totals(self):
        self.tolerate(2)
        def churn():
            (self.home / '.hidden').write_text('changed state')
            (self.home / 'new-during-backup').write_text('x' * 10)
        sid = self.snapshot(churn=churn)
        self.receipt(sid)
        self.manager.validate()
        self.assertIn(sid, self.manager.state['accepted'])
        # Measurements come from the snapshot, not the stale manifest.
        records, _ = client.inventory(self.home, ['.cache'])
        self.assertEqual(self.manager.state['accepted'][sid]['measured'][''], client.totals(records))

    def test_tolerant_contract_bounds_count_and_protects_required_content(self):
        self.tolerate(1)
        for reason, churn in (
                ('manifest drift exceeds contract tolerance',
                 lambda: [(self.home / name).write_text('x') for name in ('one', 'two')]),
                ('required content changed during backup',
                 lambda: (self.home / 'Documents/new').write_text('x')),
                ('required content changed during backup',
                 lambda: (self.home / 'Dropbox/ccs.kdbx').write_bytes(client.KDBX + b'\0' * 102500))):
            with self.subTest(reason=reason):
                sid = self.snapshot(churn=churn)
                self.receipt(sid)
                self.manager.validate()
                self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], reason)
                self.manager.reject(sid, 'fixture churn', 'nas')

    def test_manifest_totals_must_match_its_records(self):
        self.tolerate(5)
        def forge():
            manifest = client.read_json(self.home / client.MANIFEST)
            manifest['measured']['files'] += 1
            client.atomic(self.home / client.MANIFEST, manifest)
        sid = self.snapshot(churn=forge)
        self.receipt(sid)
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'manifest totals are inconsistent')

    def client_backup(self, during_backup):
        excludes = self.base / 'excludes'
        excludes.write_text('.cache\n')
        credentials = self.base / 'client-credentials.json'
        credentials.write_text(json.dumps(self.manager.credentials['nas']))
        credentials.chmod(0o600)
        # The fixture manager validates against this same contract object.
        self.contract.update(enrollment_status='released', exclusion_sha256=client.digest(excludes.read_bytes()))
        contract = self.base / 'contract.json'
        contract.write_text(json.dumps(self.contract))
        config = {'host': 'ryze', 'contract': str(contract), 'excludes': str(excludes),
                  'credentials': str(credentials)}
        real = client.restic
        def restic(*args, env=None, input_bytes=None):
            if args and args[0] == '--retry-lock' and '--stdin' not in args:
                args = during_backup(list(args))
            return real(*args, env=env, input_bytes=input_bytes)
        state = self.base / 'client-state'
        state.mkdir()
        with patch.object(Path, 'home', return_value=self.home), patch.object(client, 'restic', restic), \
                patch.dict(os.environ, {'WORKSTATION_RESTIC': RESTIC}), patch.object(client, 'CLOCK_SLACK', 0):
            return client.backup(config, state)

    def test_client_accepts_explained_churn(self):
        self.tolerate(5)
        def during_backup(args):
            time.sleep(0.05)
            (self.home / '.hidden').write_text('changed during backup')
            (self.home / 'link').unlink()
            return args
        sid = self.client_backup(during_backup)
        self.manager.validate()
        self.assertIn(sid, self.manager.state['accepted'])

    def test_client_rejects_unexplained_omission(self):
        self.tolerate(5)
        (self.home / 'spare').write_text('keeps actual totals above the released floor')
        time.sleep(0.05)
        def during_backup(args):
            # Restic silently skips an unchanged file: the manifest has it, the snapshot does not.
            return args[:-1] + ['--exclude', str(self.home / '.hidden'), args[-1]]
        with self.assertRaisesRegex(ValueError, "1 paths not changed during backup, first '.hidden'"):
            self.client_backup(during_backup)
        sid, = self.manager.listing('nas')
        # This passes independent content checks; the missing completion is the
        # only reason the server must not accept/copy it or advance freshness.
        self.manager.content('nas', self.manager.listing('nas')[sid])
        self.assertEqual(self.manager.receipts, {})
        for operation in (self.manager.copy, self.manager.prune, self.manager.check):
            with self.assertRaisesRegex(ValueError, 'unresolved validation holds'):
                operation()
        self.assertEqual(self.manager.state['accepted'], {})
        self.assertEqual(self.manager.state['copies'], {})
        self.assertEqual(self.manager.state['highwater'], 0)
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'client-validation-incomplete')

    def test_receipt_required_even_without_drift_and_late_completion_recovers(self):
        self.tolerate(5)
        sid = self.snapshot()
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'client-validation-incomplete')
        receipt = self.receipt(sid)
        self.manager.copy()
        self.assertFalse(self.manager.state['holds'])
        self.assertEqual(set(self.manager.state['accepted']), {sid})
        self.assertEqual(self.manager.state['accepted'][sid]['client_completion']['receipt_ids'], [receipt])
        self.assertEqual(len(self.manager.listing('b2')), 1)

    def test_receipt_identity_cannot_be_replayed(self):
        self.tolerate(5)
        sid = self.snapshot()
        row = self.manager.listing('nas')[sid]
        for field, value in [('snapshot_id', 'a' * 64), ('tree', 'b' * 64),
                             ('contract', 'workstation-ryze-v999'), ('exclusion_sha256', 'wrong'),
                             ('client_validation', 'failed')]:
            with self.subTest(field=field):
                payload = client.completion_receipt(sid, row['tree'], self.contract)
                payload[field] = value
                receipt = self.receipt(sid, payload)
                self.manager.validate()
                self.assertNotIn(sid, self.manager.state['accepted'])
                self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'],
                                 'client completion receipt identity mismatch')
                self.manager.run('nas', 'forget', receipt, raw=True)

    def test_receipt_upload_failure_does_not_complete_backup(self):
        self.tolerate(5)
        with patch.object(client, 'publish_receipt', side_effect=subprocess.CalledProcessError(1, 'receipt')):
            with self.assertRaises(subprocess.CalledProcessError):
                self.client_backup(lambda args: args)
        self.manager.validate()
        self.assertFalse(self.manager.state['accepted'])
        self.assertEqual(next(iter(self.manager.state['holds'].values()))['reason'],
                         'client-validation-incomplete')

    def test_oversized_receipt_is_not_dumped_or_accepted(self):
        self.tolerate(5)
        sid = self.snapshot()
        receipt = self.receipt(sid, {'padding': 'x' * 4096})
        self.manager.commands.clear()
        self.manager.validate()
        self.assertFalse(self.manager.state['accepted'])
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'],
                         'invalid client completion receipt')
        self.assertFalse(any(args[:2] == ('dump', receipt) for _, args in self.manager.commands))

    def test_receipts_do_not_anchor_retention_and_cleanup_is_resumable(self):
        self.tolerate(5)
        sid = self.snapshot()
        before = self.manager.candidates('nas')
        receipt = self.receipt(sid, when='2099-01-01 12:00:00')
        self.assertEqual(self.manager.candidates('nas'), before)
        self.manager.copy()
        self.assertEqual(set(self.manager.state['accepted']), {sid})
        self.assertNotIn(receipt, self.manager.listing('nas'))
        original_run = self.manager.run
        def interrupt_cleanup(destination, *args, **kwargs):
            if args[0] == 'forget' and args[-1] == receipt:
                raise ValueError('interrupted receipt cleanup')
            return original_run(destination, *args, **kwargs)
        with patch.object(server, 'mount_guard'), patch.object(self.manager, 'candidates',
                side_effect=lambda destination: [sid] if destination == 'nas' else []), \
                patch.object(self.manager, 'run', side_effect=interrupt_cleanup):
            with self.assertRaisesRegex(ValueError, 'interrupted receipt cleanup'):
                self.manager.prune()
        self.assertNotIn(sid, self.manager.listing('nas'))
        self.assertTrue(self.manager.state['recount_required'])
        with patch.object(server, 'mount_guard'), patch.object(self.manager, 'candidates', return_value=[]):
            self.manager.prune()
        all_nas = self.manager.run('nas', 'snapshots', '--json')
        self.assertNotIn(receipt, {row['id'] for row in all_nas})
        self.assertTrue(self.manager.listing('b2'))
        self.assertFalse(self.manager.state['recount_required'])

    def test_unreleased_contract_name_is_held(self):
        self.contract['contract'] = 'workstation-ryze-v2'
        sid = self.snapshot()
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'manifest contract drift')

    def add_version(self, number, rules=('.cache',)):
        contract = {**self.contract, 'contract': f'workstation-ryze-v{number}'}
        self.manager.contracts[contract['contract']] = (contract, list(rules), 'fixture')
        return contract

    def test_contract_upgrade_starts_baseline_and_downgrade_is_held(self):
        first = self.snapshot()
        self.manager.state['baseline'] = [{'': {'files': 100, 'bytes': 10000000},
                                          'Documents/': {'files': 10, 'bytes': 40000}}] * 7
        self.manager.validate()
        self.manager.reject(first, 'fixture shrink against synthetic baseline', 'nas')
        self.contract = self.add_version(2)
        upgraded = self.snapshot()
        self.manager.validate()
        # The same smaller scope is not a shrink under a newly released version.
        self.assertIn(upgraded, self.manager.state['accepted'])
        self.assertEqual(self.manager.state['accepted'][upgraded]['contract'], 'workstation-ryze-v2')
        self.assertEqual(self.manager.state['contract'], 'workstation-ryze-v2')
        self.assertEqual(self.manager.state['generation'], 2)
        self.assertEqual(len(self.manager.state['baseline']), 1)
        self.assertEqual(self.manager.state['resolutions'][upgraded]['action'], 'contract-transition')
        self.contract = self.manager.contracts['workstation-ryze-v1'][0]
        downgraded = self.snapshot()
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + downgraded]['reason'], 'contract-downgrade')
        self.assertEqual(self.manager.state['contract'], 'workstation-ryze-v2')

    def test_each_version_applies_its_own_exclusions(self):
        (self.home / 'volatile').mkdir()
        (self.home / 'volatile/state').write_text('churn')
        v1 = self.snapshot()
        self.manager.validate()
        self.assertIn(v1, self.manager.state['accepted'])
        # v2 excludes the path v1 kept; a v2-labelled snapshot that still carries it leaks.
        self.contract = self.add_version(2, ('.cache', 'volatile'))
        leaked = self.snapshot()
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + leaked]['reason'],
                         'excluded content leaked into snapshot')

    def test_future_clock_is_held(self):
        sid = self.snapshot('2099-01-01 12:00:00')
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'snapshot-time-invalid')
        self.assertEqual(self.manager.state['highwater'], 0)

    def test_backdated_clock_is_held(self):
        sid = self.snapshot('2020-01-01 12:00:00')
        self.manager.state['highwater'] = time.time()
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'snapshot-time-invalid')

    def test_shrink_acceptance_starts_new_generation(self):
        sid = self.snapshot()
        self.manager.state['baseline'] = [{'': {'files': 100, 'bytes': 10000000},
                                          'Documents/': {'files': 10, 'bytes': 40000}}] * 7
        self.manager.validate()
        self.assertEqual(self.manager.state['holds']['nas:' + sid]['reason'], 'shrink')
        self.manager.validate(accept_shrink=sid)
        self.assertIn(sid, self.manager.state['accepted'])
        self.assertEqual(self.manager.state['generation'], 2)
        self.assertEqual(len(self.manager.state['baseline']), 1)

    def test_interrupted_copy_recovers_from_content(self):
        sid = self.snapshot()
        self.manager.validate()
        self.manager.state['pending'] = [sid]
        self.manager.run('b2', 'copy', '--from-repo', self.base / 'nas', sid, raw=True,
                         extra_env={'RESTIC_FROM_PASSWORD': 'disposable-test-password'})
        self.manager.copy()
        self.assertEqual(self.manager.state['pending'], [])
        self.assertIn(sid, self.manager.state['copies'])

    def test_forged_original_is_not_authority(self):
        source = {'tree': 'a', 'hostname': 'ryze', 'paths': ['/home/c'], 'time': 'today', 'id': 'source'}
        forged = {**source, 'tree': 'different', 'original': 'source'}
        self.assertFalse(self.manager.same_snapshot(source, forged))

    def test_hold_rejection_is_resumable(self):
        sid = self.snapshot(omit='.hidden')
        self.manager.validate()
        self.manager.reject(sid, 'fixture omission', 'nas')
        self.manager.reject(sid, 'fixture retry', 'nas')
        self.assertNotIn(sid, self.manager.listing('nas'))
        self.assertFalse(self.manager.state['holds'])
        for destination, args in self.manager.commands:
            if args and args[0] == 'forget':
                self.assertEqual(args[-1], sid)

    def test_b2_rejection_cannot_reject_same_id_in_nas(self):
        sid = self.snapshot()
        self.manager.state['rejected']['b2:' + sid] = {'reason': 'destination-only fixture'}
        self.manager.validate()
        self.assertIn(sid, self.manager.state['accepted'])

    def test_missing_b2_blocks_nas_deletion(self):
        sid = self.snapshot()
        self.manager.validate()
        with patch.object(self.manager, 'candidates', return_value=[sid]):
            with self.assertRaisesRegex(ValueError, 'physically present'):
                self.manager.prune()
        self.assertIn(sid, self.manager.listing('nas'))

    def test_restart_failure_does_not_advance_prune_success(self):
        self.snapshot()
        self.manager.copy()
        with patch.object(self.manager, 'restart', side_effect=ValueError('restart fixture')):
            with self.assertRaisesRegex(ValueError, 'restart fixture'):
                self.manager.prune()
        self.assertEqual(self.manager.state['prune_success'], 0)
        self.assertTrue(self.manager.state['recount_required'])

    def test_permission_error_aborts_inventory(self):
        with patch('os.scandir', side_effect=PermissionError('fixture')):
            with self.assertRaises(PermissionError):
                client.inventory(self.home, [])


class ScopeTests(unittest.TestCase):
    def test_mac_excludes_mobile_documents_but_preserves_required_scope(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Mobile Documents'
        for path in (root, root + '/com~apple~notes/Documents',
                     root + '/com~apple~Keynote/presentation.key',
                     root + '/com~apple~mail/Data/signatures'):
            self.assertTrue(client.excluded(path, mac))
        for path in ('Documents/report', 'Library/CloudStorage/Dropbox/ccs.kdbx',
                     'Library/Safari/Bookmarks.plist',
                     'Library/Preferences/com.apple.Safari.plist',
                     'Library/Mobile Documents-other/data'):
            self.assertFalse(client.excluded(path, mac))

    def test_directory_eintr_retries_open_and_iteration(self):
        from contextlib import contextmanager
        @contextmanager
        def interrupted_listing():
            def entries():
                yield SimpleNamespace(name='partial')
                raise InterruptedError(4, 'interrupted')
            yield entries()
        @contextmanager
        def good_listing():
            yield [SimpleNamespace(name='complete')]
        with patch.object(client.os, 'scandir', side_effect=[
                InterruptedError(4, 'interrupted'), interrupted_listing(), good_listing()]) as scan, \
                patch.object(client.time, 'sleep') as sleep:
            with client.directory_entries('/fixture') as entries:
                self.assertEqual([entry.name for entry in entries], ['complete'])
            self.assertEqual(scan.call_count, 3)
            self.assertEqual(sleep.call_count, 2)

    def test_directory_retry_exhaustion_and_other_errors_fail_closed(self):
        for error, attempts in ((InterruptedError(4, 'interrupted'), 3),
                                (PermissionError(13, 'denied'), 1),
                                (OSError(11, 'deadlock'), 1)):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                excludes = home / 'excludes'
                excludes.write_text('')
                output = home / 'measurement.json'
                with patch.object(client.os, 'scandir', side_effect=error) as scan, \
                        patch.object(client.time, 'sleep'):
                    with self.assertRaises(OSError) as caught:
                        client.enroll(SimpleNamespace(home=home, excludes=excludes,
                                                      output=output, host='m5c'))
                self.assertEqual(scan.call_count, attempts)
                self.assertEqual(caught.exception.errno, error.errno)
                if attempts == 3:
                    self.assertEqual(caught.exception.filename, str(home))
                self.assertFalse(output.exists())

    def test_mac_excludes_only_approved_control_center_preferences(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Group Containers/group.com.apple.secure-control-center-preferences/Library/Preferences/'
        self.assertTrue(client.excluded(root + 'group.com.apple.secure-control-center-preferences.av.plist', mac))
        self.assertFalse(client.excluded(root + 'other.plist', mac))

    def test_mac_excludes_corespeech_compilation_cache_only(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Group Containers/group.com.apple.CoreSpeech/'
        self.assertTrue(client.excluded(root + 'Caches/onDeviceCompilationCaches', mac))
        self.assertTrue(client.excluded(root + 'Caches/onDeviceCompilationCaches/secondPassChecker/model.bnnsir', mac))
        self.assertFalse(client.excluded(root + 'Library/Preferences/settings.plist', mac))
        self.assertFalse(client.excluded('Library/Group Containers/other/data', mac))

    def test_mac_excludes_only_reviewed_google_updater_statistics(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Google/GoogleSoftwareUpdate/Stats/'
        self.assertTrue(client.excluded(root + 'Keystone.stats', mac))
        self.assertFalse(client.excluded(root + 'other', mac))
        self.assertFalse(client.excluded('Library/Application Support/Google/Chrome/Default/Bookmarks', mac))

    def test_mac_google_drive_is_delegated_to_ryze(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        linux = client.patterns(ROOT / 'host/ryze/etc/workstation-backup/excludes')
        root = 'Library/CloudStorage/GoogleDrive-sanderscharlie@gmail.com'
        for path in (root, root + '/.Encrypted', root + '/Documents/report'):
            self.assertTrue(client.excluded(path, mac))
            self.assertFalse(client.excluded(path, linux))
        self.assertFalse(client.excluded('Library/CloudStorage/GoogleDrive-other@example.com/file', mac))
        self.assertFalse(client.excluded('Documents/report', mac))

    def test_mac_dropbox_only_keeps_database(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        linux = client.patterns(ROOT / 'host/ryze/etc/workstation-backup/excludes')
        for root in ('Dropbox', 'Library/CloudStorage/Dropbox'):
            self.assertFalse(client.excluded(root, mac))
            self.assertFalse(client.excluded(root + '/ccs.kdbx', mac))
            self.assertTrue(client.excluded(root + '/other.txt', mac))
            self.assertTrue(client.excluded(root + '/Documents', mac))
            self.assertTrue(client.excluded(root + '/Documents/report', mac))
        self.assertFalse(client.excluded('Dropbox/other.txt', linux))
        self.assertFalse(client.excluded('Documents/report', mac))
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'Documents').mkdir()
            (home / 'Documents/report').write_text('keep')
            target = home / 'Library/CloudStorage/Dropbox'
            target.mkdir(parents=True)
            (home / 'Dropbox').symlink_to(target)
            (target / 'ccs.kdbx').write_bytes(client.KDBX + b'0' * 102400)
            os.mkfifo(target / 'excluded-runtime')
            records, omissions = client.inventory(home, mac)
            self.assertIn('Library/CloudStorage/Dropbox/ccs.kdbx', records)
            self.assertIn(str(target / 'excluded-runtime'), omissions)
            self.assertEqual(records['Dropbox']['type'], 'symlink')

    def test_read_error_names_file_and_does_not_write_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'home'
            home.mkdir()
            source = home / 'unreadable'
            source.touch()
            excludes = Path(directory) / 'excludes'
            excludes.write_text('')
            output = Path(directory) / 'measurement.json'
            failure = OSError(11, 'Resource deadlock avoided')
            real_open = Path.open

            def failing_open(path, *args, **kwargs):
                if path == source:
                    class Unreadable(io.BytesIO):
                        def read(self, *args):
                            raise failure
                    return Unreadable()
                return real_open(path, *args, **kwargs)

            with patch.object(Path, 'open', failing_open):
                with self.assertRaises(OSError) as caught:
                    client.enroll(SimpleNamespace(home=home, excludes=excludes,
                                                  output=output, host='m5c'))
            self.assertEqual(caught.exception.errno, 11)
            self.assertEqual(caught.exception.filename, str(source))
            self.assertIn('Resource deadlock avoided', str(caught.exception))
            self.assertIs(caught.exception.__cause__, failure)
            self.assertFalse(output.exists())

    def test_dropbox_alias_cannot_escape_or_use_symlink_ancestors(self):
        records = {'Dropbox': {'type': 'symlink', 'linktarget': '/outside/Dropbox'}}
        with self.assertRaisesRegex(ValueError, 'in-home'):
            client.database_path(records, '/Users/test')
        records['Dropbox']['linktarget'] = '/Users/test/Library/CloudStorage/Dropbox'
        records['Library'] = {'type': 'symlink', 'linktarget': '/outside'}
        with self.assertRaisesRegex(ValueError, 'ancestors'):
            client.database_path(records, '/Users/test')

    def test_released_contracts_are_immutable_and_mirrored(self):
        base = os.environ.get('PR_BASE_SHA') or 'HEAD^'
        if subprocess.run(['git', 'rev-parse', '--verify', base], cwd=ROOT, capture_output=True).returncode == 0:
            changes = subprocess.check_output(['git', 'diff', '--name-only', '--diff-filter=DMRT', base, '--',
                ':(glob)host/*/etc/workstation-backup/workstation-*-v*.*',
                ':(glob)infrastructure/monitoring/workstations/contracts/workstation-*-v*.*',
                ':(glob)runbooks/disaster-recovery/contracts/workstation-*-v*.*'], cwd=ROOT)
            self.assertFalse(changes.strip(), 'released workstation contracts cannot be altered or removed')
        for host in ('ryze', 'm5c'):
            for contract in (ROOT / f'host/{host}/etc/workstation-backup').glob('workstation-*-v*.json'):
                self.assertEqual(contract.read_bytes(), (ROOT / 'infrastructure/monitoring/workstations/contracts' / contract.name).read_bytes())
                self.assertEqual(contract.read_bytes(), (ROOT / 'runbooks/disaster-recovery/contracts' / contract.name).read_bytes())

    def test_partial_backup_does_not_advance_success_and_documents_retry_independently(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'config.json'
            config.write_text('{"host":"ryze"}')
            with patch.object(Path, 'home', return_value=home), \
                    patch.object(client, 'backup', side_effect=subprocess.CalledProcessError(3, 'restic')), \
                    patch.object(client.subprocess, 'run') as upload:
                with self.assertRaises(SystemExit):
                    client.daily(SimpleNamespace(config=config))
                upload.assert_called_once()
            state = home / '.local/state/workstation-backup'
            self.assertFalse((state / 'backup.json').exists())
            self.assertTrue((state / 'documents.json').exists())
            with patch.object(Path, 'home', return_value=home), \
                    patch.object(client, 'backup', return_value='a' * 64), \
                    patch.object(client.subprocess, 'run') as upload:
                client.daily(SimpleNamespace(config=config))
                upload.assert_not_called()
            self.assertEqual(client.read_json(state / 'backup.json')['snapshot_id'], 'a' * 64)

    def test_cluster_mirrors_match_canonical_sources(self):
        self.assertEqual((ROOT / 'host/workstations/workstation.py').read_bytes(),
                         (ROOT / 'infrastructure/monitoring/workstations/workstation.py').read_bytes())
        cluster = ROOT / 'infrastructure/monitoring/workstations/contracts'
        mapped = (ROOT / 'infrastructure/monitoring/workstations/kustomization.yaml').read_text()
        for host in ('ryze', 'm5c'):
            released = server.load_contracts(host, cluster)
            for name in released:
                for suffix in ('.json', '.excludes'):
                    self.assertIn(f'{name}{suffix}=contracts/{name}{suffix}', mapped)
                    self.assertEqual((ROOT / f'host/{host}/etc/workstation-backup' / (name + suffix)).read_bytes(),
                                     (cluster / (name + suffix)).read_bytes())
            self.assertEqual(released, server.load_contracts(host, ROOT / f'host/{host}/etc/workstation-backup'))
            self.assertEqual(released, server.load_contracts(host, ROOT / 'runbooks/disaster-recovery/contracts'))

    def test_contract_versions_are_pinned_contiguous_and_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            def release(number, rules, name=None):
                name = name or f'workstation-ryze-v{number}'
                (directory / f'workstation-ryze-v{number}.excludes').write_text(rules)
                (directory / f'workstation-ryze-v{number}.json').write_text(json.dumps({
                    'contract': name, 'hostname': 'ryze', 'enrollment_status': 'released',
                    'source_roots': ['/home/test'], 'manifest': '/home/test/' + client.MANIFEST,
                    'exclusion_sha256': client.digest(rules.encode())}))
            release(1, '.cache\n')
            legacy = {'contract_sha256': server.load_contracts('ryze', directory)['workstation-ryze-v1'][2]}
            release(2, '.cache\nvolatile\n')
            contracts = server.load_contracts('ryze', directory)
            self.assertEqual(contracts['workstation-ryze-v2'][1], ['.cache', 'volatile'])
            server.pin_contracts(legacy, 'ryze', contracts)
            self.assertEqual(set(legacy['contracts']), {'workstation-ryze-v1', 'workstation-ryze-v2'})
            self.assertNotIn('contract_sha256', legacy)
            with self.assertRaisesRegex(ValueError, 'missing'):
                server.pin_contracts(copy.deepcopy(legacy), 'ryze',
                                     {k: v for k, v in contracts.items() if k.endswith('v1')})
            second = directory / 'workstation-ryze-v2.json'
            second.write_text(second.read_text() + ' ')
            with self.assertRaisesRegex(ValueError, 'differs from trusted'):
                server.pin_contracts(legacy, 'ryze', server.load_contracts('ryze', directory))
            (directory / 'workstation-ryze-v2.excludes').write_text('changed\n')
            with self.assertRaisesRegex(ValueError, 'exclusion identity'):
                server.load_contracts('ryze', directory)
            release(2, '.cache\n', name='workstation-ryze-v3')
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                server.load_contracts('ryze', directory)
            for suffix in ('.json', '.excludes'):
                (directory / f'workstation-ryze-v2{suffix}').unlink()
            release(3, '.cache\n')
            with self.assertRaisesRegex(ValueError, 'contiguous'):
                server.load_contracts('ryze', directory)

    def test_release_requires_previous_version_and_writes_versioned_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ('runbooks/backups/workstation-release-contract.py', 'host/workstations/workstation.py'):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / relative, root / relative)
            directories = [root / 'host/ryze/etc/workstation-backup',
                           root / 'infrastructure/monitoring/workstations/contracts',
                           root / 'runbooks/disaster-recovery/contracts']
            for path in directories:
                path.mkdir(parents=True)
            (directories[0] / 'excludes').write_text('.cache\n')
            evidence = root / 'evidence.json'
            evidence.write_text(json.dumps({'host': 'ryze', 'inventory_reviewed': True,
                'capacity_reviewed': True, 'required_content_readable': True}))
            def measurement(number):
                path = root / f'v{number}.measured.json'
                measured = {'': {'files': 10, 'bytes': 1000}, 'Documents/': {'files': 2, 'bytes': 100}}
                path.write_text(json.dumps({'contract': f'workstation-ryze-v{number}', 'hostname': 'ryze',
                    'exclusion_sha256': client.digest(b'.cache\n'), 'measured': measured,
                    'kdbx_path': 'Dropbox/ccs.kdbx', 'churn_tolerance': client.churn_tolerance(10, 'Dropbox/ccs.kdbx'),
                    'floors': {'': {'files': 8, 'bytes': 800}, 'Documents/': {'files': 2, 'bytes': 80}},
                    'kdbx_minimum_bytes': 102400}))
                return path
            def release(number):
                return subprocess.run([sys.executable, str(root / 'runbooks/backups/workstation-release-contract.py'),
                    str(measurement(number)), '--evidence', str(evidence)], capture_output=True, text=True)
            result = release(2)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('workstation-ryze-v1 must be released', result.stderr)
            self.assertEqual(release(1).returncode, 0)
            self.assertEqual(release(1).returncode, 0, 'identical partial releases resume')
            self.assertEqual(release(2).returncode, 0)
            for path in directories:
                self.assertEqual((path / 'workstation-ryze-v2.excludes').read_bytes(), b'.cache\n')
                self.assertEqual(json.loads((path / 'workstation-ryze-v2.json').read_text())['enrollment_status'], 'released')

    def test_exclusions_preserve_application_state(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        tombstone = 'Library/Application Support/FileProvider/54FCDE27-7E3C-4C5D-8D61-FF6DD8DF79F8/wharf/tombstone/'
        self.assertTrue(client.excluded(tombstone + 'a', mac))
        second = tombstone.replace('54FCDE27-7E3C-4C5D-8D61-FF6DD8DF79F8', '91648096-DD36-4235-A042-266128DB70C5')
        self.assertTrue(client.excluded(second + 'a', mac))
        self.assertFalse(client.excluded(second + 'b', mac))
        self.assertFalse(client.excluded(second.replace('/wharf/', '/extra/wharf/') + 'a', mac))
        self.assertFalse(client.excluded(second.replace('91648096-DD36-4235-A042-266128DB70C5', 'user-data') + 'a', mac))
        self.assertFalse(client.excluded(tombstone + 'other', mac))
        self.assertFalse(client.excluded('Library/CloudStorage/Dropbox/ccs.kdbx', mac))
        nordvpn = 'Library/Application Support/com.nordvpn.macos/default.encrypted_v2.realm'
        self.assertTrue(client.excluded(nordvpn + '.management/access_control.new_commit.cv', mac))
        self.assertTrue(client.excluded(nordvpn + '.management/access_control.pick_writer.cv', mac))
        for name in ('control', 'versions', 'write'):
            self.assertFalse(client.excluded(nordvpn + '.management/access_control.' + name + '.mx', mac))
        self.assertFalse(client.excluded(nordvpn, mac))
        self.assertTrue(client.excluded(nordvpn + '.note', mac))
        self.assertFalse(client.excluded(nordvpn + '.lock', mac))
        self.assertFalse(client.excluded(nordvpn + '.management/other', mac))
        self.assertTrue(client.excluded('project/node_modules/package/file', mac))
        self.assertTrue(client.excluded('Library/Caches/cache', mac))
        self.assertTrue(client.excluded('.config/workstation-backup/credentials.json', mac))
        self.assertFalse(client.excluded('Library/Application Support/app/state', mac))
        self.assertFalse(client.excluded('Dropbox/ccs.kdbx', mac))
        self.assertFalse(client.excluded('Documents/report', mac))

    def test_ryze_excludes_volatile_state_but_keeps_memory_and_profiles(self):
        linux = client.patterns(ROOT / 'host/ryze/etc/workstation-backup/excludes')
        session = '6a20c8b6-6e95-472b-a31e-99aad6c6baf6'
        for path in ('.local/share/klipper/data/history', '.kube/cache/discovery/api.json',
                     '.dropbox/metrics/store.bin', '.config/google-chrome/Safe Browsing/UrlSoceng.store',
                     '.config/google-chrome/segmentation_platform/ukm.db',
                     '.config/discord/Cache/data_0', '.config/discord/GPUCache/data_1',
                     '.config/discord/Code Cache/js/index', '.config/discord/DawnWebGPUCache/data',
                     '.config/discord/logs/renderer.log',
                     f'.claude/projects/-home-charlie-src-home/{session}.jsonl',
                     f'.claude/projects/-home-charlie-src-home/{session}/tool-results/out.txt',
                     f'.claude/projects/-home-charlie-src-home/{session}/subagents/agent.jsonl',
                     '.claude/backups/.claude.json.backup.1', '.claude/file-history/x/y',
                     '.claude/plugins/marketplaces/official/README.md', '.claude/shell-snapshots/s.sh',
                     '.codex/sessions/2026/09/10/rollout.jsonl', '.codex/logs_2.sqlite',
                     '.codex/logs_2.sqlite-wal', '.codex/state_5.sqlite', '.codex/thread_history_1.sqlite',
                     '.codex/cache/remote_plugin_catalog/x', '.codex/plugins/cache/p', '.codex/models_cache.json'):
            self.assertTrue(client.excluded(path, linux), path)
        for path in ('.claude/projects/-home-charlie-src-home/memory/MEMORY.md', '.claude/settings.json',
                     '.claude/plans/plan.md', '.claude/plugins/installed_plugins.json', '.claude.json',
                     '.codex/memories_1.sqlite', '.codex/config.toml', '.codex/rules/default.rules',
                     '.codex/skills/x/SKILL.md', '.config/google-chrome/Default/Bookmarks',
                     '.config/discord/settings.json', '.config/discord/Local Storage/leveldb/000003.log',
                     'src/home/runbooks/backups/workstations.md', 'Documents/report', 'Dropbox/ccs.kdbx',
                     'GDrive/report'):
            self.assertFalse(client.excluded(path, linux), path)

    def test_plist_has_hourly_awake_schedule(self):
        path = ROOT / 'host/m5c/Library/LaunchAgents/run.worm.workstation-backup.plist'
        config = plistlib.loads(path.read_bytes())
        self.assertEqual(config['StartInterval'], 3600)
        self.assertTrue(config['RunAtLoad'])
        self.assertNotIn('StartCalendarInterval', config)

    def test_churn_tolerance_is_bounded_and_protects_required_content(self):
        self.assertEqual(client.churn_tolerance(525593, 'Dropbox/ccs.kdbx'),
                         {'maximum_paths': 1000, 'protected_paths': ['Documents', 'Dropbox/ccs.kdbx']})
        self.assertEqual(client.churn_tolerance(10000, 'x')['maximum_paths'], 50)
        self.assertEqual(client.drift({'a': {'type': 'dir'}, 'b': {'type': 'file', 'size': 1}},
                                      {'b': {'type': 'file', 'size': 2}, 'c': {'type': 'dir'}}), ['a', 'b', 'c'])
        client.check_drift([], {})
        with self.assertRaisesRegex(ValueError, 'does not match'):
            client.check_drift(['a'], {})
        contract = {'churn_tolerance': client.churn_tolerance(400, 'Dropbox/ccs.kdbx')}
        client.check_drift(['.config/app', 'Documents-other/x'], contract)
        with self.assertRaisesRegex(ValueError, 'exceeds'):
            client.check_drift(['a', 'b', 'c'], contract)
        for path in ('Documents', 'Documents/report', 'Dropbox/ccs.kdbx'):
            with self.assertRaisesRegex(ValueError, 'required content'):
                client.check_drift([path], contract)

    def test_unexplained_uses_live_ctime_and_surviving_ancestors(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(client, 'CLOCK_SLACK', 0):
            home = Path(directory)
            (home / 'dir').mkdir()
            (home / 'dir/file').write_text('x')
            paths = ['dir/file', 'dir/vanished', 'gone/deeper/file']
            self.assertEqual(client.unexplained(paths, home, time.time() - 60), [])
            self.assertEqual(client.unexplained(paths, home, time.time() + 60), paths)

    def test_manifest_detects_missing_file(self):
        records = client.snapshot_records([{'message_type': 'node', 'path': '/home/test/a',
                    'type': 'file', 'size': 3}], '/home/test', '/home/test/manifest')
        self.assertEqual(records, {'a': {'type': 'file', 'size': 3}})
        with self.assertRaises(ValueError):
            client.snapshot_records([{'message_type': 'node', 'path': '/home/test/../outside',
                'type': 'file', 'size': 3}], '/home/test', '/home/test/manifest')

    def test_mount_rejects_root_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            mountinfo = Path(directory) / 'mountinfo'
            mountinfo.write_text('1 2 3:4 / /repo/nas rw - ext4 /dev/mapper/vg0-root rw\n')
            with self.assertRaisesRegex(ValueError, 'identity'):
                server.mount_guard(mountinfo=str(mountinfo))

    def test_archive_rejects_paths_and_types(self):
        loader = importlib.machinery.SourceFileLoader('archive_validator',
            str(ROOT / 'host/minis/usr/local/libexec/validate-document-archive'))
        specification = importlib.util.spec_from_loader(loader.name, loader)
        validator = importlib.util.module_from_spec(specification)
        loader.exec_module(validator)
        for name, kind in [('../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('link', tarfile.SYMTYPE), ('fifo', tarfile.FIFOTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'archive.tar'
                with tarfile.open(path, 'w') as archive:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    archive.addfile(entry)
                with self.assertRaises(ValueError):
                    validator.validate(path)


if __name__ == '__main__':
    unittest.main()
