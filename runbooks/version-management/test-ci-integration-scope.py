#!/usr/bin/env python3
"""Guard against accidentally skipping a changed integration dependency."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'scope', Path(__file__).with_name('ci-integration-scope.py'))
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def test_unrelated_changes_keep_only_fast_checks(self):
        self.assertFalse(scope.integration_required([
            'docs/backups.md', 'AGENTS.md', 'README.md', 'renovate.json5',
            'apps/media/plex/deployment.yaml', 'apps/home-assistant/deployment.yaml']))

    def test_dependencies_and_unknown_paths_require_integrations(self):
        for path in (
            '.github/workflows/image-policy.yaml',
            'runbooks/version-management/ci-integration-scope.py',
            'runbooks/backups/offline-contracts.py',
            'runbooks/backups/fixtures/workstation-repositories/nas/config',
            'runbooks/backups/evidence/legacy-rsnapshot-20260920.json',
            'runbooks/disaster-recovery/contracts/workstation-ryze-v3.json',
            'runbooks/phase5/test-raid-check-alerts.py',
            'host/workstations/workstation.py',
            'host/m5c/etc/workstation-backup/excludes',
            'infrastructure/monitoring/configs/alert-rules.yaml',
            'infrastructure/monitoring/workstations/alerts.yaml',
            'infrastructure/monitoring/offline/alerts.yaml',
            'apps/media/romm/deployment.yaml',
            'containers/restic-backup/Containerfile', 'new-dependency.py',
        ):
            with self.subTest(path=path):
                self.assertTrue(scope.integration_required(['docs/backups.md', path]))

    def test_main_and_missing_base_always_run_full_suite(self):
        with patch.object(scope.subprocess, 'run') as run:
            for event, base in [('push', 'base'), ('workflow_dispatch', ''),
                                ('schedule', ''), ('pull_request', '')]:
                self.assertTrue(scope.select(event, base))
            run.assert_not_called()

    def test_diff_errors_and_empty_diffs_run_full_suite(self):
        with patch.object(scope.subprocess, 'run',
                          side_effect=subprocess.CalledProcessError(128, 'git')):
            self.assertTrue(scope.select('pull_request', 'missing'))
        with patch.object(scope.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 0, stdout=b'')):
            self.assertTrue(scope.select('pull_request', 'base'))

    def test_renames_deletions_and_unusual_names(self):
        for paths, expected in [
            (b'docs/name with spaces.md\0docs/name\nwith newline.md\0', False),
            (b'runbooks/backups/deleted.py\0', True),
            (b'host/workstations/workstation.py\0docs/moved.md\0', True),
        ]:
            with self.subTest(paths=paths), patch.object(scope.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], 0, stdout=paths)) as run:
                self.assertEqual(scope.select('pull_request', 'base'), expected)
                self.assertEqual(run.call_args.args[0], [
                    'git', 'diff', '--no-renames', '--name-only', '-z', 'base', 'HEAD', '--'])


if __name__ == '__main__':
    unittest.main()
