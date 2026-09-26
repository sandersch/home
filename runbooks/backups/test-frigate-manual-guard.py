#!/usr/bin/env python3
"""Exercise the actual manual backup guard against Kubernetes Job fixtures."""
import json
from pathlib import Path
import subprocess
import unittest

script = Path(__file__).with_name('21-run-frigate-vault-backup.sh').read_text()
guard = script[script.index('assert_no_outstanding_backups() {'):script.index('\njob=')]


class GuardTests(unittest.TestCase):
    def run_guard(self, jobs, failure=False):
        result = subprocess.run(['bash', '-c', '''set -Eeuo pipefail
kubectl() {
  [[ "$*" == "-n monitoring get jobs -o json" ]] || exit 99
  ''' + ('return 1' if failure else 'cat') + '''
}
die() { echo "$*" >&2; exit 1; }
''' + guard], input=json.dumps({'items': jobs}), text=True, capture_output=True)
        return result

    def test_outstanding_jobs_block_even_before_pods_start(self):
        for metadata in [
            {'name': 'scheduled-without-label', 'ownerReferences': [
                {'kind': 'CronJob', 'name': 'restic-vault-backup'}]},
            {'name': 'restic-vault-manual-20260921000000'},
            {'name': 'custom-manual', 'labels': {'app.kubernetes.io/name': 'restic-vault-backup'}},
        ]:
            for status in [{}, {'active': 1}, {'active': 0, 'failed': 1}]:
                with self.subTest(metadata=metadata, status=status):
                    result = self.run_guard([{'metadata': metadata, 'status': status}])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(metadata['name'], result.stderr)

    def test_terminal_and_unrelated_jobs_do_not_block(self):
        jobs = [{'metadata': {'name': 'restic-vault-manual-old-' + condition},
                 'status': {'conditions': [{'type': condition, 'status': 'True'}]}}
                for condition in ['Complete', 'Failed']]
        jobs.append({'metadata': {'name': 'unrelated'}, 'status': {'active': 1}})
        self.assertEqual(self.run_guard(jobs).returncode, 0)
        self.assertEqual(self.run_guard([]).returncode, 0)

    def test_api_failure_blocks(self):
        self.assertNotEqual(self.run_guard([], failure=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
