#!/usr/bin/env python3
"""Exercise metric recovery, empty-source retention, and independent B2 checks."""
from pathlib import Path
import os
import subprocess
import tempfile
import yaml

root = Path(__file__).resolve().parents[2]
def script(name, key):
    return yaml.safe_load((root / 'infrastructure/monitoring' / name).read_text())['data'][key]

copy = script('restic-vault-copy-config.yaml', 'copy-vault.sh')
prune = script('restic-vault-prune-config.yaml', 'prune-vault.sh')
verify = script('restic-verify-config.yaml', 'verify.sh')
with tempfile.TemporaryDirectory(prefix='backup-review-') as directory:
    work = Path(directory)
    metric = work / 'metrics.prom'
    for source, end, call in [(copy, 'ledger_has()', 'write_metrics 1'),
                              (prune, 'assert_no_destination_holds()', 'write_metrics 1 0 empty-source')]:
        functions = source[source.index('write_metrics() {'):source.index(end)]
        for prior in ['', 'unrelated_metric 1\n']:
            metric.write_text(prior)
            result = subprocess.run(['bash', '-c', 'set -Eeuo pipefail\n' + functions +
                '\nmetrics="$1/metrics.prom"\ndestination_control="$1/control"\n' + call,
                'fixture', directory], capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            for line in metric.read_text().splitlines():
                assert len(line.split()) == 2, line
                float(line.split()[-1])
    # Execute the actual source guard through newest-ID selection. No Restic call
    # is allowed; an empty source must exit successfully with a skip metric.
    (work / 'source.json').write_text('[]')
    flow = prune[prune.index('[ "$(jq \'length\' "$source_listing")" -gt 0 ]'):
                 prune.index('latest_source_lineage=')]
    result = subprocess.run(['bash', '-c', 'set -Eeuo pipefail\n' +
        'source_listing="$1/source.json"\nlog() { :; }\nwrite_metrics() { echo "$*"; }\n' +
        flow, 'fixture', directory], capture_output=True, text=True)
    assert result.returncode == 0 and result.stdout.strip() == '1 0 empty-source', result

    # Substitute only external paths and command boundaries. Run the complete
    # verifier, including real sentinel checks and timestamp-file writes.
    for folder in ['guards', 'metrics', 'work', 'etc/homelab', 'data/vault/.backup-credentials', 'bin']:
        (work / folder).mkdir(parents=True, exist_ok=True)
    guard = work / 'guards/assert-backups-mount.sh'
    guard.write_text('#!/bin/sh\nexit "${NAS_STATUS}"\n')
    guard.chmod(0o755)
    (work / 'etc/homelab/vault.conf').write_text('VAULT_FS_UUID=fixture\n')
    (work / 'etc/homelab/vault-b2.conf').write_text('VAULT_B2_REPOSITORY=vault-b2\n')
    sentinel = work / 'data/vault/.vault-sentinel'
    sentinel.write_text('vault-contract-version=2\nfilesystem-uuid=fixture\n')
    for key in ['nas-password', 'b2-password', 'b2-key-id', 'b2-application-key']:
        (work / 'data/vault/.backup-credentials' / key).write_text('fixture')
    restic = work / 'bin/restic'
    restic.write_text('#!/bin/sh\nprintf "%s\\n" "$RESTIC_REPOSITORY" >>"$CALLS"\n')
    restic.chmod(0o755)
    fixture = verify
    for path in ['/guards/', '/metrics/', '/work/', '/etc/homelab/', '/data/vault/']:
        fixture = fixture.replace(path, directory + path)
    fixture = fixture.replace('/proc/self/mountinfo', str(work / 'mountinfo'))
    env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'],
               APPSTATE_NAS_PASSWORD='fixture', APPSTATE_B2_PASSWORD='fixture',
               APPSTATE_B2_REPOSITORY='appstate-b2', CALLS=str(work / 'calls'))
    for nas_status, locked, valid in [('1', False, True), ('0', False, True),
                                      ('1', True, True), ('1', False, False)]:
        env['NAS_STATUS'] = nas_status
        (work / 'calls').write_text('')
        for old in (work / 'metrics').glob('*.prom'):
            old.unlink()
        sentinel.write_text('vault-contract-version=2\nfilesystem-uuid=' +
                            ('fixture' if valid else 'wrong') + '\n')
        source = '/dev/mapper/vg0-root' if locked else '/dev/mapper/vault'
        mount_root = '/mnt/vault' if locked else '/'
        (work / 'mountinfo').write_text(
            f'1 0 0:1 {mount_root} /data/vault rw - ext4 {source} rw\n')
        result = subprocess.run(['bash', '-c', fixture], env=env, capture_output=True, text=True)
        calls = (work / 'calls').read_text().splitlines()
        assert calls.count('appstate-b2') == 2, result
        assert calls.count('vault-b2') == (2 if not locked and valid else 0), result
        assert calls.count('/repo/nas/vault') == (2 if nas_status == '0' and valid else 0), result
        assert result.returncode == (0 if nas_status == '0' and valid else 1), result
        assert (work / 'metrics/restic-check-vault-b2.prom').exists() == (not locked and valid)
print('PASS: missing metric fields, empty source, and independent B2 verification')
