#!/usr/bin/env python3
"""Run copy, rollout-state, and restore gates against disposable command fixtures."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import yaml

root = Path(__file__).resolve().parents[2]
def config(name):
    return yaml.safe_load((root / 'infrastructure/monitoring' / name).read_text())['data']
copy = config('restic-vault-copy-config.yaml')
source = copy['copy-vault.sh']
sid, did = 'a' * 64, 'b' * 64
with tempfile.TemporaryDirectory(prefix='phase4-interruptions-') as directory:
    work = Path(directory)
    for folder in ['control/holds', 'control/resolutions', 'destination_control/holds', 'vault-scripts']:
        (work / folder).mkdir(parents=True)
    (work / 'source.json').write_text(json.dumps([{'id': sid, 'hostname': 'minis-vault', 'time': '2026-09-07T00:00:00Z'}]))
    (work / 'copied.json').write_text(json.dumps([{'id': did, 'original': sid, 'time': '2026-09-07T00:00:00Z'}]))
    (work / 'control/validated.jsonl').write_text(json.dumps({'lineage': sid}) + '\n')
    (work / 'vault-scripts/snapshot-time.jq').write_text(config('restic-vault-config.yaml')['snapshot-time.jq'])
    validator = work / 'vault-scripts/validate-vault-snapshot.sh'
    validator.write_text('#!/bin/bash\nexit 0\n')
    validator.chmod(0o755)
    functions = source[source.index('ledger_has() {'):source.index('hold_destination() {')]
    loop = source[source.index('source_count=0'):source.index('[ "$source_count" -gt 0 ]')]
    setup = '''set -Eeuo pipefail
source_repo=fixture-nas
control="$FIXTURE/control"
destination_control="$FIXTURE/destination_control"
source_listing="$FIXTURE/source.json"
destination_listing="$FIXTURE/destination.json"
VAULT_B2_REPOSITORY=fixture-b2
log() { :; }
die() { echo "$*" >&2; exit 1; }
restic() { case "$1" in copy) echo copy >>"$FIXTURE/calls";; snapshots) cat "$FIXTURE/copied.json";; *) exit 99;; esac; }
'''
    for mode in ['healthy', 'held', 'pending-without-hold', 'accepted', 'destination-held', 'malformed-hold']:
        for folder in ['control/holds', 'control/resolutions', 'destination_control/holds']:
            for entry in (work / folder).iterdir():
                entry.unlink()
        (work / 'destination.json').write_text('[]')
        (work / 'destination_control/validated.jsonl').write_text('')
        (work / 'calls').write_text('')
        if mode in ['held', 'malformed-hold']:
            (work / 'control/holds/hold.json').write_text(json.dumps({'lineage': sid}) if mode == 'held' else '{}')
        if mode in ['held', 'pending-without-hold', 'accepted']:
            (work / f'control/resolutions/{sid}.json').write_text(json.dumps({'snapshot_id': sid, 'action': 'accept', 'stage': 'accepted' if mode == 'accepted' else 'started'}))
        if mode == 'destination-held':
            (work / 'destination_control/holds/hold.json').write_text(json.dumps({'lineage': sid}))
            (work / 'destination.json').write_text((work / 'copied.json').read_text())
            (work / 'destination_control/validated.jsonl').write_text(json.dumps({'lineage': sid}) + '\n')
        program = (setup + functions + loop + '\necho "missing=$missing_count newest=$newest"\n').replace('/vault-scripts', str(work / 'vault-scripts'))
        result = subprocess.run(['bash', '-c', program], env=dict(os.environ, FIXTURE=directory), capture_output=True, text=True)
        assert result.returncode == (1 if mode == 'malformed-hold' else 0), result.stderr
        assert bool((work / 'calls').read_text()) == (mode in ['healthy', 'accepted']), mode
        if mode in ['held', 'pending-without-hold', 'destination-held']:
            assert 'missing=1 newest=0' in result.stdout, result.stdout
    print('PASS: copy excludes unresolved source/destination holds and interrupted acceptance')

    resolver = (root / 'runbooks/backups/10-resolve-validation-hold.sh').read_text()
    gate = resolver[resolver.index('  b2_required=0'):resolver.index('  if [ "$b2_required" -eq 1 ]; then')]
    for path in ['/etc/homelab/', '/mnt/vault/', '/mnt/backups/', '/var/lib/node-exporter/textfile/']:
        gate = gate.replace(path, directory + path)
        (work / path.lstrip('/')).mkdir(parents=True, exist_ok=True)
    marker = work / 'etc/homelab/vault-b2.enrolled'
    setup = '''set -Eeuo pipefail
sudo() { "$@"; }
die() { exit 1; }
kubectl() { [ "$KUBE" != failure ] || return 1; [ "$KUBE" != absent ] || return 0; printf '{"spec":{"suspend":%s}}' "$KUBE"; }
'''
    for kube, enrolled, required in [('true', False, 0), ('absent', False, 0), ('false', False, 1), ('true', True, 1), ('absent', True, 1), ('failure', False, None)]:
        if marker.exists(): marker.unlink()
        if enrolled: marker.touch()
        result = subprocess.run(['bash', '-c', setup + gate + '\necho "$b2_required"'], env=dict(os.environ, KUBE=kube), capture_output=True, text=True)
        if required is None: assert result.returncode != 0
        else: assert result.returncode == 0 and result.stdout.strip() == str(required), result
    print('PASS: suspended staging permits local rejection; enrollment intent and API failures fail closed')

    # Execute the complete restore script with command fixtures and real scratch writes.
    for folder in ['bin', 'data/vault/.backup-credentials', 'etc/homelab', 'work']:
        (work / folder).mkdir(parents=True, exist_ok=True)
    (work / 'etc/homelab/vault.conf').write_text('VAULT_FS_UUID=fixture\n')
    (work / 'etc/homelab/vault-b2.conf').write_text('VAULT_B2_REPOSITORY=fixture-b2\n')
    (work / 'data/vault/.vault-sentinel').write_text('vault-contract-version=2\nfilesystem-uuid=fixture\n')
    for name in ['b2-password', 'b2-key-id', 'b2-application-key']:
        (work / 'data/vault/.backup-credentials' / name).write_text('fixture')
    listing = [{'message_type': 'node', 'type': 'file', 'path': f'{directory}/data/vault/{category}/{name}'} for category, name in [('documents', 'letter.txt'), ('photos', 'picture.jpg')]]
    (work / 'listing').write_text(''.join(json.dumps(n) + '\n' for n in listing))
    (work / 'mountinfo').write_text(f'1 0 0:1 / {directory}/data/vault rw - ext4 /dev/mapper/vault rw\n')
    restic = work / 'bin/restic'
    restic.write_text('''#!/bin/bash
set -Eeuo pipefail
shift 2 # --retry-lock value
case "$1" in
 check) [ "$2" = --read-data ]; echo check >>"$FIXTURE/operations"; [ "$MODE" != corrupt ];;
 ls) cat "$FIXTURE/listing";;
 dump)
   echo dump >>"$FIXTURE/operations"
   case "$3" in
     */ccs.kdbx) printf '\\x03\\xd9\\xa2\\x9a\\x67\\xfb\\x4b\\xb5';;
     */letter.txt) echo document;;
     */picture.jpg) [ "$MODE" = empty ] || echo photo;;
     *) exit 99;;
   esac;;
 *) exit 99;;
esac
''')
    restic.chmod(0o755)
    restore = copy['validate-vault-b2-restore.sh']
    for path in ['/data/vault', '/etc/homelab', '/vault-scripts', '/work']:
        restore = restore.replace(path, directory + path)
    restore = restore.replace('/proc/self/mountinfo', str(work / 'mountinfo'))
    for mode in ['healthy', 'corrupt', 'empty']:
        (work / 'operations').write_text('')
        result = subprocess.run(['bash', '-c', restore], env=dict(os.environ, FIXTURE=directory, MODE=mode, RESTORE_SNAPSHOT=sid, PATH=str(work / 'bin') + ':' + os.environ['PATH']), capture_output=True, text=True)
        assert (result.returncode == 0) == (mode == 'healthy'), (mode, result.stderr)
        operations = (work / 'operations').read_text().splitlines()
        assert operations[0] == 'check'
        if mode == 'corrupt': assert operations == ['check']
    assert list((work / 'data/vault/.restore-tests').glob('*/photo-picture.jpg'))
    assert 'homelab_restic_restore_drill_timestamp_seconds' not in restore
    wrapper = (root / 'runbooks/backups/14-validate-vault-b2-restore.sh').read_text()
    assert wrapper.index('[ "$confirmation" = "$RESTORE_SNAPSHOT" ]') < wrapper.index('homelab_restic_restore_drill_timestamp_seconds')
    print('PASS: B2 restore reads all data, retains encrypted artifacts, and does not auto-record semantic success')

    # Exercise the actual attended confirmation/publication path too.
    confirmation = wrapper[wrapper.index("read -r -p 'After inspecting"):]
    confirmation = confirmation.replace('/var/lib/node-exporter/textfile', str(work / 'metrics'))
    (work / 'metrics').mkdir()
    chown = work / 'bin/chown'
    chown.write_text('#!/bin/bash\nexit 0\n')
    chown.chmod(0o755)
    for answer, succeeds in [('wrong', False), (sid, True)]:
        result = subprocess.run(['bash', '-c', 'set -Eeuo pipefail\nsudo() { "$@"; }\ndie() { exit 1; }\nok() { :; }\n' + confirmation],
            input=answer + '\n', env=dict(os.environ, RESTORE_SNAPSHOT=sid, PATH=str(work / 'bin') + ':' + os.environ['PATH']), capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, result.stderr
        assert (work / 'metrics/restic-vault-b2-restore.prom').exists() == succeeds
    print('PASS: only attended confirmation publishes the semantic-drill timestamp')

    job_filter = re.search(r"yq -y -i '(.*?)' \"\$manifest\"", wrapper, re.S).group(1)
    cronjob = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-copy-cronjob.yaml').read_text())
    job = {'metadata': {'ownerReferences': [{'name': 'copy'}]}, 'spec': cronjob['spec']['jobTemplate']['spec']}
    rendered = subprocess.run(['yq', '-y', job_filter], input=json.dumps(job), text=True, capture_output=True,
        env=dict(os.environ, RESTORE_SNAPSHOT=sid, RESTORE_DOCUMENT_PATH='/data/vault/documents/letter.txt', RESTORE_PHOTO_PATH='/data/vault/photos/picture.jpg'), check=True)
    result = yaml.safe_load(rendered.stdout)
    assert 'ownerReferences' not in result['metadata']
    assert result['spec']['activeDeadlineSeconds'] == 86400
    container = result['spec']['template']['spec']['containers'][0]
    assert next(m for m in container['volumeMounts'] if m['name'] == 'vault')['readOnly'] is False
    assert next(e for e in container['env'] if e['name'] == 'RESTORE_PHOTO_PATH')['value'] == '/data/vault/photos/picture.jpg'
    print('PASS: attended Job retains owner-independent lifetime and encrypted writable scratch')
