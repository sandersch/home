#!/usr/bin/env python3
"""Behavioral P1 regressions; disposable files and mocked host commands only."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
cm = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-config.yaml').read_text())
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'snapshot-time.jq').write_text(cm['data']['snapshot-time.jq'])
    def epoch(value):
        return subprocess.run(['jq', '-L', directory, '-er', 'include "snapshot-time"; snapshot_epoch'],
                              input=json.dumps(value), text=True, capture_output=True)
    for value in ['2026-09-07T04:00:00Z', '2026-09-07T04:00:00.123456789Z',
                  '2026-09-07T04:00:00.123-05:00', '2026-09-07T04:00:00+05:30']:
        result = epoch(value)
        assert result.returncode == 0, result.stderr
        assert int(result.stdout) == int(datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())
    for value in ['bad', '2026-02-30T04:00:00Z', '2026-09-07T04:00:00+24:00',
                  '2026-09-07T04:00:00+00:60', None]:
        assert epoch(value).returncode != 0, value
    # Exercise ordering by instant, not local wall-clock representation.
    result = subprocess.run(['jq', '-L', directory, '-er',
                             'include "snapshot-time"; max_by(.time | snapshot_epoch) | .id'],
                            input=json.dumps([{'id': 'newer', 'time': '2026-09-07T04:00:00.12-05:00'},
                                              {'id': 'older', 'time': '2026-09-07T08:00:00Z'}]),
                            text=True, capture_output=True, check=True)
    assert result.stdout.strip() == 'newer'
    print('PASS: snapshot timestamps, invalid dates, and offset ordering')

    # Enrollment now runs inside the pinned Restic container. Keep its security
    # contract structural here; the actual Job is exercised by the live gate.
    wrapper = (root / 'runbooks/backups/13-enroll-vault-b2.sh').read_text()
    enrollment = cm = yaml.safe_load(
        (root / 'infrastructure/monitoring/restic-vault-copy-config.yaml').read_text()
    )['data']['enroll-vault-b2.sh']
    assert 'require_tools jq kubectl yq' in wrapper
    assert 'kubectl -n monitoring exec -it' in wrapper
    assert 'require_tools restic' not in wrapper
    assert 'source /etc/homelab/vault-b2.conf' not in wrapper
    assert 'restic --no-cache' in enrollment
    assert 'mktemp -d /dev/shm/vault-b2-enroll.' in enrollment
    assert 'install -m 0600' in enrollment
    assert 'AWS_ACCESS_KEY_ID' in enrollment and 'AWS_SECRET_ACCESS_KEY' in enrollment
    assert 'sudo' not in enrollment
    assert 'vault B2 repository initialized; credentials stored inside the encrypted vault' in enrollment
    print('PASS: container enrollment keeps Restic and credential handling inside the attended Job')

    vault = work / 'vault'
    credentials = vault / '.backup-credentials'
    credentials.mkdir(parents=True, mode=0o700)
    (credentials / 'b2-password').write_text('fixture-password')
    (credentials / 'b2-key-id').write_text('fixture-key-id')
    (credentials / 'b2-application-key').write_text('fixture-key-secret')

    resolver = (root / 'runbooks/backups/10-resolve-validation-hold.sh').read_text()
    block = resolver.split("    sudo bash -c '\n", 1)[1].split("    ' vault-b2-list", 1)[0]
    block = block.replace('/mnt/vault', str(vault))
    for name, value in [('b2-password', 'fixture-password'), ('b2-key-id', 'fixture-key-id'),
                        ('b2-application-key', 'fixture-key-secret')]:
        (credentials / name).write_text(value)
    (work / 'initialized').touch()
    bindir = work / 'bin'
    bindir.mkdir()
    calls = work / 'calls'
    (bindir / 'sudo').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$CALLS"\nexec "$@"\n')
    (bindir / 'sudo').chmod(0o755)
    (bindir / 'restic').write_text('#!/usr/bin/env bash\nprintf "[]\\n"\n')
    (bindir / 'restic').chmod(0o755)
    env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}', CALLS=str(calls))
    result = subprocess.run(['sudo', 'bash', '-c', block, 'vault-b2-list', 's3:fixture'],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == []
    assert 'fixture-key-secret' not in calls.read_text()
    print('PASS: hold resolver loads credentials inside privileged process')
