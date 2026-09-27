#!/usr/bin/env python3
"""Execute destination retention guards and deletion flow with disposable repositories."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
script = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-prune-config.yaml').read_text())['data']['prune-vault.sh']
vault = yaml.safe_load((root / 'infrastructure/monitoring/restic-vault-config.yaml').read_text())
# Run the actual functions and retention flow after NAS baseline validation. Host
# mount/credential guards are outside this fixture; every Restic operation is mocked.
functions = script.split('mount_record=', 1)[0]
functions = functions[functions.index('write_metrics() {'):]
flow = script[script.index('[ "$(jq \'length\' "$destination_listing")" -gt 0 ]'):]
latest, old, copied_latest, copied_old = (c * 64 for c in 'abcd')
now = datetime.datetime.now(datetime.timezone.utc)
time = now.strftime('%Y-%m-%dT%H:%M:%SZ')
older = (now - datetime.timedelta(days=40)).strftime('%Y-%m-%dT%H:%M:%SZ')


def run_case(name, mode='', holds=False, files=1000, size=10000, expected=None):
    with tempfile.TemporaryDirectory(prefix='b2-retention-') as directory:
        work = Path(directory)
        for folder in ['nas', 'source-control', 'destination-control', 'scripts', 'bin', 'offline']:
            (work / folder).mkdir()
        (work / 'nas/.control/offline').mkdir(parents=True)
        (work / 'nas/.control/offline-retention.lock').touch()
        source = [{'id': latest, 'time': time}, {'id': old, 'time': older}]
        destination = [{'id': copied_latest, 'original': latest, 'time': time},
                       {'id': copied_old, 'original': old, 'time': older,
                        'tags': ['offline-checkpoint']}]
        if mode == 'source-kept':
            source[1]['tags'] = ['offline-checkpoint']
            destination[1]['tags'] = []
        (work / 'source.json').write_text(json.dumps(source))
        (work / 'destination.json').write_text(json.dumps(destination))
        (work / 'source-seed.json').write_text(json.dumps(source))
        (work / 'destination-seed.json').write_text(json.dumps(destination))
        for folder in ['source-control', 'destination-control']:
            (work / folder / 'validated.jsonl').write_text(''.join(json.dumps({'lineage': x}) + '\n' for x in [latest, old]))
        if mode == 'invalid-hold-directory':
            (work / 'destination-control/holds').write_text('invalid')
        if holds:
            (work / 'destination-control/holds').mkdir()
            # Even an older snapshot with historical ledger evidence remains held.
            (work / 'destination-control/holds' / (copied_old + '.json')).write_text('{}')
        (work / 'scripts/snapshot-time.jq').write_text(vault['data']['snapshot-time.jq'])
        validator = work / 'scripts/validate-vault-snapshot.sh'
        validator.write_text('''#!/usr/bin/env bash
set -Eeuo pipefail
[ "$RESTIC_REPOSITORY" = fixture-b2 ]
[ "$RESTIC_PASSWORD_FILE" = /data/vault/.backup-credentials/b2-password ]
[ "$1" = "$LATEST_B2" ]
printf 'validate %s\n' "$1" >>"$FIXTURE/operations"
[ "$MODE" != validation-failure ] || exit 1
if [ "$MODE" = malformed ]; then echo '{}'; else
  printf '{"contract":"vault-v2","total_files":%s,"total_bytes":%s}\n' "$FILES" "$BYTES"
fi
''')
        validator.chmod(0o755)
        restic = work / 'bin/restic'
        restic.write_text('''#!/usr/bin/env bash
set -Eeuo pipefail
[ "$1" = -r ]
repository="$2"
shift 2
  case "$1" in
  snapshots)
    if [ "$repository" = fixture-b2 ]; then cat "$FIXTURE/destination-seed.json"
    else cat "$FIXTURE/source-seed.json"; fi ;;
  forget)
    if [[ " $* " == *" --dry-run "* ]]; then
      if [[ "$MODE" = empty-candidates || "$MODE" = cleanup-failure ]]; then echo '[{"remove":[]}]'; exit 0; fi
      if [ "$repository" = fixture-b2 ]; then
        [[ " $* " != *" --keep-tag "* ]] || exit 98
      else
        [[ " $* " == *" --keep-tag offline-checkpoint "* ]] || exit 98
        if [ "$MODE" = source-kept ]; then echo '[{"remove":[]}]'; exit 0; fi
      fi
      candidate="$OLD_NAS"
      [ "$repository" != fixture-b2 ] || candidate="$OLD_B2"
      printf '[{"remove":[{"id":"%s"}]}]\n' "$candidate"
    else
      printf 'forget %s %s\n' "$repository" "${@: -1}" >>"$FIXTURE/operations"
      if [ "$repository" != fixture-b2 ]; then
        jq --arg id "$OLD_NAS" 'map(select(.id != $id))' "$FIXTURE/source-seed.json" >"$FIXTURE/source-new.json"
        mv "$FIXTURE/source-new.json" "$FIXTURE/source-seed.json"
      fi
    fi ;;
  prune)
    printf 'prune %s\n' "$repository" >>"$FIXTURE/operations"
    [ "$MODE" != cleanup-failure ] || exit 1
    if [ "$MODE" = late-hold ] && [ "$repository" != fixture-b2 ]; then
      mkdir -p "$FIXTURE/destination-control/holds"
      echo '{}' >"$FIXTURE/destination-control/holds/late.json"
    fi ;;
  *) exit 99 ;;
esac
''')
        restic.chmod(0o755)
        setup = '''set -Eeuo pipefail
log() { :; }
die() { echo "$*" >&2; exit 1; }
source_repo="$FIXTURE/nas"
source_control="$FIXTURE/source-control"
destination_control="$FIXTURE/destination-control"
source "${ROOT}/infrastructure/monitoring/offline/pin-retention.sh"
release_offline_pins() {
  offline_pin_reconcile_and_release vault "$FIXTURE/offline" "$FIXTURE" -r "$source_repo"
}
metrics="$FIXTURE/metrics.prom"
source_listing="$FIXTURE/source.json"
destination_listing="$FIXTURE/destination.json"
VAULT_B2_REPOSITORY=fixture-b2
now="$(date +%s)"
baseline_files=1000
baseline_bytes=10000
minimum_retained_percent=80
'''
        executable = setup + functions + '\n' + flow
        executable = executable.replace('/vault-scripts', str(work / 'scripts')).replace('/work/', directory + '/')
        executable = executable.replace('/repo/nas/.control', directory + '/nas/.control')
        env = dict(os.environ, ROOT=str(root), FIXTURE=directory, MODE=mode, FILES=str(files), BYTES=str(size),
                   LATEST_B2=copied_latest, OLD_NAS=old, OLD_B2=copied_old,
                   PATH=f'{work / "bin"}:{os.environ["PATH"]}')
        result = subprocess.run(['bash', '-c', executable], env=env, text=True, capture_output=True)
        if mode == 'cleanup-failure':
            assert result.returncode != 0, result
            assert not (work / 'metrics.prom').exists(), 'failed cleanup advanced success'
            print(f'PASS: {name}')
            return
        assert result.returncode == 0, (name, result.stderr)
        operations = (work / 'operations').read_text() if (work / 'operations').exists() else ''
        metrics = (work / 'metrics.prom').read_text()
        if expected:
            assert f'reason="{expected}"}} 1' in metrics, (name, metrics)
            assert 'forget fixture-b2' not in operations and 'prune fixture-b2' not in operations, (name, operations)
            if mode != 'late-hold':
                assert 'forget ' not in operations, (name, operations)
        elif mode in ('empty-candidates', 'source-kept'):
            assert 'forget ' not in operations, operations
            assert f'prune {work / "nas"}' in operations and 'prune fixture-b2' in operations, operations
        else:
            assert f'forget fixture-b2 {copied_old}' in operations, operations
            assert operations.index('validate ') < operations.index('forget ')
            assert operations.index(f'forget {work / "nas"}') < operations.index('forget fixture-b2')
            assert 'prune fixture-b2' in operations
        print(f'PASS: {name}')

run_case('healthy destination permits exact-ID retention')
run_case('older destination hold blocks retention', holds=True, expected='destination-hold')
run_case('destination validation failure blocks retention', mode='validation-failure', expected='destination-validation')
run_case('invalid destination manifest blocks retention', mode='malformed', expected='destination-manifest')
run_case('destination file-count shrink blocks retention', files=799, expected='destination-baseline-tolerance')
run_case('destination byte-count shrink blocks retention', size=7999, expected='destination-baseline-tolerance')
run_case('baseline boundary permits retention', files=800, size=8000)
run_case('hold arriving during NAS prune blocks B2 deletion', mode='late-hold', expected='destination-hold')
run_case('invalid destination hold path blocks retention', mode='invalid-hold-directory', expected='destination-hold')

run_case("retry completes cleanup after candidates were already forgotten", mode="empty-candidates")

run_case("failed cleanup without candidates cannot advance success", mode="cleanup-failure")

run_case('NAS survivor blocks B2 removal despite different tags', mode='source-kept')

# Exercise the shared NAS pin implementation, including a crash after Restic
# commits a retag. No credentials or production paths are used.
with tempfile.TemporaryDirectory(prefix='offline-pin-release-') as directory:
    work = Path(directory)
    records = work / 'records'
    records.mkdir()
    snapshot = {'id': old, 'original': latest,
                'tags': ['vault', 'offline-checkpoint', 'offline-checkpoint-2026-Q4']}
    listing = work / 'listing.json'
    listing.write_text(json.dumps([snapshot]))
    operation = {'selected': {'vault': {'lineage': latest}}, 'stage': 'complete',
                 'success_at': 1, 'clean_unmount': True,
                 'copies': {'vault': {'lineage': latest, 'source_id': old,
                                      'destination_id': copied_old}}}
    completed = records / 'A-enroll-2026-Q4.json'
    completed.write_text(json.dumps(operation))
    # Exercise replacement when the record's group differs from mktemp's.
    record_group = next((gid for gid in os.getgroups() if gid != os.getegid()), os.getegid())
    os.chown(completed, os.geteuid(), record_group)
    original_owner = (completed.stat().st_uid, completed.stat().st_gid)
    pending = records / 'B-enroll-2026-Q4.json'
    pending.write_text(json.dumps({**operation, 'stage': 'selected'}))
    stub = r'''set -Eeuo pipefail
source_repo=fixture
log() { :; }
die() { echo "$*" >&2; exit 1; }
restic() {
  shift 2
  case "$1" in
    snapshots) cat "$FIXTURE/listing.json" ;;
    tag)
      if [ "$2" = --add ]; then
        jq --arg id "$4" --arg tag "$3" 'map(if .id == $id then .original = (.original // .id) | .tags += [$tag] | .id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" else . end)' "$FIXTURE/listing.json" >"$FIXTURE/new.json"
      else
        jq 'map(.tags -= ["offline-checkpoint"] | .id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")' "$FIXTURE/listing.json" >"$FIXTURE/new.json"
      fi
      mv "$FIXTURE/new.json" "$FIXTURE/listing.json"
      echo tag >>"$FIXTURE/actions"
      [ "${FAIL:-0}" = 0 ] ;;
    *) return 99 ;;
  esac
}
'''
    def release(fail=False, snapshots=None, dataset='vault'):
        if snapshots is not None:
            listing.write_text(json.dumps(snapshots))
        call = f'\nsource {root}/infrastructure/monitoring/offline/pin-retention.sh\noffline_pin_reconcile_and_release {dataset} {records} {directory} -r fixture'
        return subprocess.run(['bash', '-c', stub + call],
                              env=dict(os.environ, FIXTURE=directory, FAIL=str(int(fail))),
                              text=True, capture_output=True)
    assert release().returncode == 0
    assert not (work / 'actions').exists(), 'pending shared lineage lost its pin'
    pending.unlink()
    assert release(fail=True).returncode != 0
    assert release().returncode == 0, 'cleanup retry failed after snapshot ID changed'
    assert (completed.stat().st_uid, completed.stat().st_gid) == original_owner, 'pin release changed operation ownership'
    assert completed.stat().st_mode & 0o777 == 0o600, 'pin release changed operation permissions'
    assert (work / 'actions').read_text().splitlines() == ['tag']
    tags = json.loads(listing.read_text())[0]['tags']
    assert tags == ['vault', 'offline-checkpoint-2026-Q4']
    released_operation = json.loads(completed.read_text())
    assert released_operation['copies']['vault']['source_id'] == old, 'copy-time source ID must remain historical evidence'
    assert released_operation['copies']['vault']['released_source_id'] == 'e' * 64, 'post-release ID was not recorded'
    # No completion evidence means no automatic release.
    completed.unlink()
    listing.write_text(json.dumps([snapshot]))
    assert release().returncode == 0
    assert 'offline-checkpoint' in json.loads(listing.read_text())[0]['tags']
    completed.write_text('{broken')
    assert release().returncode != 0, 'malformed evidence did not fail closed'
    completed.write_text(json.dumps(operation))
    appstate = {'selected': {'appstate': {'lineage': latest}}, 'stage': 'complete',
                'success_at': 1, 'clean_unmount': True,
                'copies': {'appstate': {'lineage': latest, 'source_id': old,
                                        'destination_id': copied_old}}}
    (records / 'A-rotate-2026-Q4.json').write_text(json.dumps(appstate))
    assert release(dataset='appstate', snapshots=[{
        'id': old, 'original': latest,
        'tags': ['opt', 'offline-checkpoint', 'offline-checkpoint-2026-Q4']}]).returncode == 0
    appstate_tags = json.loads(listing.read_text())[0]['tags']
    assert appstate_tags == ['opt', 'offline-checkpoint-2026-Q4'], appstate_tags
    released_appstate = json.loads((records / 'A-rotate-2026-Q4.json').read_text())
    assert released_appstate['copies']['appstate']['released_source_id'] == 'e' * 64
    listing.write_text(json.dumps([{'id': old, 'original': latest,
                                    'tags': ['vault', 'offline-checkpoint-2026-Q4']}]))
    pending.write_text(json.dumps({**operation, 'stage': 'selected'}))
    assert release().returncode == 0, 'pending unpinned source was not reconciled'
    reconciled = json.loads(listing.read_text())[0]['tags']
    assert 'offline-checkpoint' in reconciled, reconciled
    print('PASS: durable completion releases only unshared pins; interrupted cleanup retries safely')

    # A pending selected lineage whose NAS source has already disappeared is
    # left for destination-based resume; it must not stop unrelated retention.
    completed.write_text(json.dumps({**operation, 'stage': 'selected'}))
    pending.write_text(json.dumps({**operation, 'stage': 'selected'}))
    assert release(snapshots=[]).returncode == 0, 'missing pending source blocked retention'
