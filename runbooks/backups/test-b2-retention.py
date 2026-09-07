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
        for folder in ['nas', 'source-control', 'destination-control', 'scripts', 'bin']:
            (work / folder).mkdir()
        source = [{'id': latest, 'time': time}, {'id': old, 'time': older}]
        destination = [{'id': copied_latest, 'original': latest, 'time': time},
                       {'id': copied_old, 'original': old, 'time': older}]
        (work / 'source.json').write_text(json.dumps(source))
        (work / 'destination.json').write_text(json.dumps(destination))
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
  snapshots) echo '[]' ;;
  forget)
    if [[ " $* " == *" --dry-run "* ]]; then
      candidate="$OLD_NAS"
      [ "$repository" != fixture-b2 ] || candidate="$OLD_B2"
      printf '[{"remove":[{"id":"%s"}]}]\n' "$candidate"
    else
      printf 'forget %s %s\n' "$repository" "${@: -1}" >>"$FIXTURE/operations"
    fi ;;
  prune)
    printf 'prune %s\n' "$repository" >>"$FIXTURE/operations"
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
        env = dict(os.environ, FIXTURE=directory, MODE=mode, FILES=str(files), BYTES=str(size),
                   LATEST_B2=copied_latest, OLD_NAS=old, OLD_B2=copied_old,
                   PATH=f'{work / "bin"}:{os.environ["PATH"]}')
        result = subprocess.run(['bash', '-c', executable], env=env, text=True, capture_output=True)
        assert result.returncode == 0, (name, result.stderr)
        operations = (work / 'operations').read_text() if (work / 'operations').exists() else ''
        metrics = (work / 'metrics.prom').read_text()
        if expected:
            assert f'reason="{expected}"}} 1' in metrics, (name, metrics)
            assert 'forget fixture-b2' not in operations and 'prune fixture-b2' not in operations, (name, operations)
            if mode != 'late-hold':
                assert 'forget ' not in operations, (name, operations)
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
