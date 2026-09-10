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


class FixtureManager(server.Manager):
    def __init__(self, fixture):
        self.host = 'ryze'
        self.contract = fixture.contract
        self.rules = ['.cache']
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
        result = subprocess.run([RESTIC, '--no-cache', *map(str, args)], env=env,
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
        self.manager.run('nas', 'init', raw=True)
        self.manager.run('b2', 'init', '--from-repo', self.base / 'nas', '--copy-chunker-params', raw=True,
                         extra_env={'RESTIC_FROM_PASSWORD': 'disposable-test-password'})

    def snapshot(self, when=None, omit=None):
        records, _ = client.inventory(self.home, ['.cache'])
        client.atomic(self.home / client.MANIFEST, {'contract': self.contract['contract'],
            'exclusion_sha256': 'fixture', 'records': records, 'measured': client.totals(records)})
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

    def test_contract_drift_is_held(self):
        sid = self.snapshot()
        self.manager.contract = {**self.contract, 'exclusion_sha256': 'changed'}
        self.manager.validate()
        self.assertNotIn(sid, self.manager.state['accepted'])

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
    def test_mac_excludes_only_approved_textinput_dictionaries(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Mobile Documents/com~apple~TextInput/Dictionaries/'
        self.assertTrue(client.excluded(root.rstrip('/'), mac))
        self.assertTrue(client.excluded(root + '.baseline', mac))
        self.assertTrue(client.excluded(root + '.baseline/UserDictionary/id/baseline.zip', mac))
        self.assertTrue(client.excluded(root + 'UserDictionary/data', mac))
        self.assertTrue(client.excluded(root + 'charlie/id/receipt.0.cdt', mac))
        self.assertFalse(client.excluded('Library/Mobile Documents/com~apple~TextInput/other/data', mac))
        self.assertFalse(client.excluded('Library/Mobile Documents/com~apple~TextInput/Dictionaries-other/data', mac))

    def test_mac_excludes_only_approved_safari_cloud_history(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Mobile Documents/com~apple~SafariShared~History'
        self.assertTrue(client.excluded(root, mac))
        self.assertTrue(client.excluded(root + '/Documents/history', mac))
        self.assertFalse(client.excluded('Library/Safari/Bookmarks.plist', mac))
        self.assertFalse(client.excluded('Library/Preferences/com.apple.Safari.plist', mac))
        self.assertFalse(client.excluded(root + 'Other/Documents', mac))

    def test_mac_excludes_only_approved_keynote_placeholder(self):
        mac = client.patterns(ROOT / 'host/m5c/etc/workstation-backup/excludes')
        root = 'Library/Mobile Documents/com~apple~Keynote/'
        self.assertTrue(client.excluded(root + '.ginger', mac))
        self.assertFalse(client.excluded(root + 'presentation.key', mac))
        self.assertFalse(client.excluded(root + 'nested/.ginger', mac))
        self.assertFalse(client.excluded('Library/Mobile Documents/other/.ginger', mac))

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
                ':(glob)host/*/etc/workstation-backup/workstation-*-v*.json',
                ':(glob)infrastructure/monitoring/workstations/contracts/workstation-*-v*.json',
                ':(glob)runbooks/disaster-recovery/contracts/workstation-*-v*.json'], cwd=ROOT)
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
        for host in ('ryze', 'm5c'):
            self.assertEqual((ROOT / f'host/{host}/etc/workstation-backup/excludes').read_bytes(),
                             (ROOT / f'infrastructure/monitoring/workstations/contracts/{host}.excludes').read_bytes())

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

    def test_plist_has_hourly_awake_schedule(self):
        path = ROOT / 'host/m5c/Library/LaunchAgents/run.worm.workstation-backup.plist'
        config = plistlib.loads(path.read_bytes())
        self.assertEqual(config['StartInterval'], 3600)
        self.assertTrue(config['RunAtLoad'])
        self.assertNotIn('StartCalendarInterval', config)

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
