#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repo_root" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml

repo = Path(sys.argv[1])
data = yaml.safe_load((repo / 'infrastructure/monitoring/restic-vault-config.yaml').read_text())['data']
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    scripts = root / 'scripts'
    scripts.mkdir()
    work = root / 'work'
    work.mkdir()
    fixture = root / 'fixture'
    fixture.mkdir()
    bindir = root / 'bin'
    bindir.mkdir()
    contracts = repo / 'infrastructure/monitoring/contracts'
    script = data['validate-vault-snapshot.sh'].replace('/contracts/', str(contracts) + '/').replace('/scripts/', str(scripts) + '/').replace('/work/validate-', str(work) + '/validate-')
    (scripts / 'validate.sh').write_text(script)
    (scripts / 'detect-vault-exclusions.jq').write_text(data['detect-vault-exclusions.jq'])
    mock = bindir / 'restic'
    mock.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
p=pathlib.Path(os.environ['FIXTURE'])
if os.environ.get('FAIL_COMMAND') == sys.argv[1]: sys.exit(1)
if sys.argv[1] == 'snapshots': name='metadata'
elif sys.argv[1] == 'ls': name='listing'
else: name={'/work/backup-manifest.json':'manifest','/data/vault/.vault-sentinel':'sentinel','/data/vault/credentials/strongbox/ccs.kdbx':'kdbx'}[sys.argv[3]]
sys.stdout.buffer.write((p/name).read_bytes())
''')
    mock.chmod(0o755)
    env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'], FIXTURE=str(fixture))
    sid = 'a' * 64
    kdbx = bytes.fromhex('03d9a29a67fb4bb5') + bytes(102400-8)
    (fixture / 'kdbx').write_bytes(kdbx)
    (fixture / 'sentinel').write_text('vault-contract-version=1\nfilesystem-uuid=fixture\n')
    metadata = [{'id':sid,'hostname':'minis-vault','paths':['/data/vault','/work/backup-manifest.json']}]
    contract = json.loads((contracts / 'vault-v1.json').read_text())
    kpath, dpath = [x['path'] for x in contract['required_content']]
    nodes = [{'message_type':'node','path':kpath,'type':'file','size':len(kdbx)},
             {'message_type':'node','path':dpath,'type':'dir'}]
    nodes += [{'message_type':'node','path':dpath+'/file'+str(i),'type':'file','size':524288} for i in range(400)]
    measured = [{'path':kpath,'kind':'kdbx','files':1,'bytes':102400},
                {'path':dpath,'kind':'directory','files':400,'bytes':209715200}]
    manifest = dict(contract='vault-v1',contract_sha256=hashlib.sha256((contracts/'vault-v1.json').read_bytes()).hexdigest(),exclusion_sha256=contract['exclusion_sha256'],filesystem_uuid='fixture',generated_at='2026-01-01T00:00:00Z',measurements=measured,total_files=401,total_bytes=209817600)
    def run_case(name, valid=False, listing=None, claimed=None, meta=None, failure=''):
        (fixture/'listing').write_text(''.join(json.dumps(n)+'\n' for n in (nodes if listing is None else listing)))
        (fixture/'manifest').write_text(json.dumps(manifest if claimed is None else claimed))
        (fixture/'metadata').write_text(json.dumps(metadata if meta is None else meta))
        result=subprocess.run(['bash', str(scripts/'validate.sh'),sid],env=dict(env,FAIL_COMMAND=failure),capture_output=True,text=True)
        assert (result.returncode == 0) == valid, (name,result.stderr)
        print('PASS:', name)
    run_case('healthy snapshot', valid=True)
    run_case('file removed after source measurement', listing=nodes[:-1])
    truncated = json.loads(json.dumps(nodes)); truncated[-1]['size']=0
    run_case('file truncated after source measurement', listing=truncated)
    run_case('empty claimed inventory', claimed=dict(manifest,measurements=[],total_files=0,total_bytes=0))
    run_case('forged totals', claimed=dict(manifest,total_bytes=1))
    below_floor = json.loads(json.dumps(manifest))
    below_floor['measurements'][1]['files'] -= 1
    below_floor['measurements'][1]['bytes'] -= 524288
    below_floor['total_files'] -= 1
    below_floor['total_bytes'] -= 524288
    run_case('accurately measured snapshot below released floors', listing=nodes[:-1], claimed=below_floor)
    run_case('missing required directory', listing=[n for n in nodes if n['path'] != dpath])
    run_case('excluded credential', listing=nodes+[dict(message_type='node',path='/data/vault/.backup-credentials/nas-password',type='file',size=10)])
    run_case('unexpected snapshot source', meta=[dict(metadata[0],paths=['/data/vault'])])
    run_case('listing I/O failure', failure='ls')
    run_case('manifest I/O failure', failure='dump')
    (fixture/'kdbx').write_bytes(bytes(102400))
    run_case('invalid captured KDBX signature')

    # Execute the actual destructive branch against a disposable state machine.
    # Simulate loss immediately after forget removes the snapshot, before the
    # caller can advance its state. Rerun must finish without another deletion.
    resolver=data['resolve-validation-hold.sh']
    block=resolver[resolver.index('if [ "$HOLD_ACTION" = reject ]; then'):resolver.index('\nvalidate_candidate\n')]
    reject = root/'reject.sh'
    reject.write_text('''set -Eeuo pipefail
control="$FIXTURE/control"
state="$control/state.json"
hold="$control/hold.json"
HOLD_ACTION=reject
HOLD_SNAPSHOT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HOLD_OPERATOR=test
lineage="$HOLD_SNAPSHOT"
snapshot_present=false
[ ! -f "$control/present" ] || snapshot_present=true
die() { echo "$*" >&2; exit 1; }
log() { echo "$*"; }
update_state() { jq --arg stage "$1" '.stage=$stage' "$state" >"$state.tmp"; mv "$state.tmp" "$state"; }
update_hold_metric() { :; }
restic() {
  case "$1" in
    forget) echo forget >>"$control/actions"; rm "$control/present"; [ "${INTERRUPT:-0}" != 1 ] ;;
    snapshots) if [ -f "$control/present" ]; then printf '[{"id":"%s"}]' "$HOLD_SNAPSHOT"; else echo '[]'; fi ;;
    prune) echo prune >>"$control/actions" ;;
    *) return 1 ;;
  esac
}
''' + block)
    control=fixture/'control'; control.mkdir()
    (control/'state.json').write_text('{"stage":"started"}')
    (control/'hold.json').write_text('{}')
    (control/'present').touch()
    first=subprocess.run(['bash',str(reject)],env=dict(env,INTERRUPT='1'),capture_output=True,text=True)
    assert first.returncode != 0, first.stderr
    assert (control/'hold.json').exists()
    assert json.loads((control/'state.json').read_text())['stage']=='forgetting'
    second=subprocess.run(['bash',str(reject)],env=env,capture_output=True,text=True)
    assert second.returncode == 0, second.stderr
    assert not (control/'hold.json').exists()
    assert (control/'actions').read_text().splitlines()==['forget','prune']
    print('PASS: rejection resumes after interrupted forget')

    install=(repo/'runbooks/backups/01-install-backup-guard.sh').read_text()
    transition=install[install.index('sudo systemctl stop mnt-backups.automount'):install.index('\nstep "Remount')]
    mount_test=root/'mount.sh'
    mount_test.write_text('''set -Eeuo pipefail
BACKUPS_MOUNT=/fixture
mounted=1
hardened=0
die() { echo "$*" >&2; exit 1; }
mountpoint() { [ "$mounted" = 1 ]; }
sudo() {
  if [ "$1" = umount ]; then [ "$mounted" = 1 ]; mounted=0; return; fi
  case "$2 $3" in
    'stop mnt-backups.automount') mounted="$STOP_LEAVES_MOUNT" ;;
    'restart backups-mountpoint-guard.service') [ "$mounted" = 0 ]; hardened=1 ;;
  esac
}
''' + transition + '\n[ "$hardened" = 1 ]\n')
    for remains in ['0','1']:
        result=subprocess.run(['bash',str(mount_test)],env=dict(env,STOP_LEAVES_MOUNT=remains),capture_output=True,text=True)
        assert result.returncode == 0, result.stderr
    print('PASS: guard installation handles both automount stop outcomes')
    # Exercise the real metric writer with a hold that remains unresolved while locked.
    backup = data['backup-vault.sh']
    writer = backup[backup.index('write_metrics() {'):backup.index('\nmount_record=')]
    metric_control = root / 'metric-control'
    (metric_control / 'holds').mkdir(parents=True)
    (metric_control / 'holds' / 'held.json').write_text('{}')
    (metric_control / 'baseline.json').write_text('{}')
    metric = root / 'vault.prom'
    metric.write_text('homelab_restic_repository_size_bytes{dataset="vault",destination="nas"} 123456\n')
    result = subprocess.run(['bash', '-c', 'set -Eeuo pipefail\ncontrol="$1"\nmetrics="$2"\n' + writer + '\nwrite_metrics 1\n', 'test', str(metric_control), str(metric)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'homelab_restic_validation_hold{dataset="vault",destination="nas"} 1' in metric.read_text()
    assert 'homelab_restic_repository_size_bytes{dataset="vault",destination="nas"} 123456' in metric.read_text()
    print('PASS: locked runs preserve holds and repository size')

    # Staged host tables must preserve arbitrary unrelated live entries byte-for-byte.
    table = root / 'mount-table'
    original = '# live configuration\nUUID=actual-efi /boot/efi vfat defaults 0 2\n'
    table.write_text(original)
    entry = '/dev/mapper/vault /mnt/vault ext4 defaults,noauto,nofail 0 2'
    command = 'source "$1/runbooks/backups/lib.sh"; ensure_mount_table_entry "$2" 2 /mnt/vault "$3"'
    args = ['bash', '-c', command, 'test', str(repo), str(table), entry]
    result = subprocess.run(args, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    expected = table.read_bytes()
    assert table.read_text().startswith(original)
    assert table.read_text().count(entry) == 1
    assert subprocess.run(args, capture_output=True).returncode == 0
    assert table.read_bytes() == expected
    for contents in [original + '/dev/wrong /mnt/vault ext4 defaults 0 2\n', original + entry + '\n' + entry + '\n']:
        table.write_text(contents)
        assert subprocess.run(args, capture_output=True).returncode != 0
        assert table.read_text() == contents
    table.write_text('other UUID=keep /etc/other-key luks\n')
    crypt_entry = 'vault UUID=new none luks,noauto'
    args = ['bash', '-c', 'source "$1/runbooks/backups/lib.sh"; ensure_mount_table_entry "$2" 1 vault "$3"', 'test', str(repo), str(table), crypt_entry]
    assert subprocess.run(args, capture_output=True).returncode == 0
    assert table.read_text().startswith('other UUID=keep /etc/other-key luks\n')
    print('PASS: staged mount tables preserve unrelated entries and reject conflicts')

PY
