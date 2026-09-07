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

    # Run the actual enrollment script with host paths redirected into the fixture.
    # sudo is a boundary spy, not privilege escalation; restic insists on that boundary.
    bindir = work / 'bin'
    bindir.mkdir()
    calls = work / 'calls'
    def executable(name, body):
        path = bindir / name
        path.write_text('#!/usr/bin/env bash\nset -Eeuo pipefail\n' + body)
        path.chmod(0o755)
    executable('sudo', 'printf "%s\\n" "$*" >>"$CALLS"\nexport PRIVILEGED=1\nexec "$@"\n')
    executable('hostname', 'echo minis\n')
    executable('stat', 'echo "${FIXTURE_FS:-tmpfs}"\n')
    executable('install', 'cp -- "${@: -2:1}" "${@: -1}"\n')
    executable('restic', '''
[ "${PRIVILEGED:-0}" = 1 ]
[ "$1" = --no-cache ]
[ "$AWS_ACCESS_KEY_ID" = fixture-key-id ]
[ "$AWS_SECRET_ACCESS_KEY" = fixture-key-secret ]
[ "$(cat "$RESTIC_PASSWORD_FILE")" = fixture-password ]
if [[ " $* " == *" init "* ]]; then
  [ "$(cat "$RESTIC_FROM_PASSWORD_FILE")" = nas-fixture ]
  touch "$INITIALIZED"
else
  [ -f "$INITIALIZED" ] || exit "${OPEN_FAILURE:-10}"
  echo '[]'
fi
''')
    vault = work / 'vault'
    credentials = vault / '.backup-credentials'
    credentials.mkdir(parents=True, mode=0o700)
    (credentials / 'nas-password').write_text('nas-fixture')
    (credentials / 'nas-password').chmod(0o600)
    (vault / '.vault-sentinel').write_text('vault-contract-version=2\n')
    backups = work / 'backups'
    backups.mkdir()
    (backups / 'config').touch()
    config = work / 'vault-b2.conf'
    config.write_text('VAULT_B2_REPOSITORY=s3:fixture\n')
    staging = work / 'shm'
    staging.mkdir()
    original = (root / 'runbooks/backups/13-enroll-vault-b2.sh').read_text()
    script = original.replace('source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '''
require_not_root() { :; }
require_sudo() { :; }
require_tools() { :; }
die() { echo "$*" >&2; exit 1; }
ok() { :; }
''').replace('/mnt/vault', str(vault)).replace('/mnt/backups/vault', str(backups))
    script = script.replace('/etc/homelab/vault-b2.enrolled', str(work / 'b2.enrolled'))
    script = script.replace('/etc/homelab/vault-b2.conf', str(config)).replace('/dev/shm', str(staging))
    script_path = work / 'enroll.sh'
    script_path.write_text(script)
    env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}', CALLS=str(calls), INITIALIZED=str(work / 'initialized'))
    answers = 'fixture-password\nfixture-password\nfixture-key-id\nfixture-key-secret\n'
    result = subprocess.run(['bash', str(script_path)], input=answers, env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert (credentials / 'b2-password').read_text().strip() == 'fixture-password'
    assert not list(staging.iterdir()), 'credential staging was not cleaned'
    for secret in ['fixture-password', 'fixture-key-id', 'fixture-key-secret']:
        assert secret not in calls.read_text(), 'credential crossed sudo argv boundary'
    result = subprocess.run(['bash', str(script_path)], input=answers, env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert 'already initialized' in result.stdout
    assert not list(staging.iterdir())
    print('PASS: fresh and existing enrollment cross privilege boundary without secret arguments')
    (work / 'initialized').unlink()
    for path in credentials.glob('b2-*'):
        path.unlink()
    result = subprocess.run(['bash', str(script_path)], input=answers, env=dict(env, OPEN_FAILURE='12'), text=True, capture_output=True)
    assert result.returncode != 0
    assert not (work / 'initialized').exists(), 'wrong password triggered init'
    assert not list(credentials.glob('b2-*')), 'failed enrollment persisted credentials'
    assert not list(staging.iterdir())
    result = subprocess.run(['bash', str(script_path)], input=answers, env=dict(env, FIXTURE_FS='ext2/ext3'), text=True, capture_output=True)
    assert result.returncode != 0
    assert not list(staging.iterdir())
    print('PASS: enrollment fails closed on repository errors and non-tmpfs staging')

    resolver = (root / 'runbooks/backups/10-resolve-validation-hold.sh').read_text()
    block = resolver.split("    sudo bash -c '\n", 1)[1].split("    ' vault-b2-list", 1)[0]
    block = block.replace('/mnt/vault', str(vault))
    for name, value in [('b2-password', 'fixture-password'), ('b2-key-id', 'fixture-key-id'),
                        ('b2-application-key', 'fixture-key-secret')]:
        (credentials / name).write_text(value)
    (work / 'initialized').touch()
    result = subprocess.run(['sudo', 'bash', '-c', block, 'vault-b2-list', 's3:fixture'],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == []
    assert 'fixture-key-secret' not in calls.read_text()
    print('PASS: hold resolver loads credentials inside privileged process')
