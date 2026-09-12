#!/usr/bin/env python3
"""Restore or metadata-verify an exact workstation snapshot."""
import argparse, base64, datetime as dt, hashlib, json, os, re, stat, subprocess, sys, tempfile, time
from pathlib import Path, PurePath

def read_xattr(path, name):
    if sys.platform == 'darwin':
        return bytes.fromhex(subprocess.check_output(['/usr/bin/xattr','-p','-x','-s',name,str(path)]).decode())
    return os.getxattr(path, name, follow_symlinks=False)

def mtime_ns(value):
    match = re.fullmatch(r'(.+T\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)', value)
    if not match: raise ValueError('unexpected snapshot mtime: ' + value)
    seconds = dt.datetime.fromisoformat(match[1] + match[3].replace('Z','+00:00'))
    return int(seconds.timestamp()) * 10**9 + int((match[2] or '').ljust(9,'0'))

def atomic_private(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def safe_child(root, value):
    root, value = Path(root).resolve(), Path(value)
    if value.is_symlink(): raise ValueError('restored-home must not be a symlink')
    resolved = value.resolve(strict=False)
    if not resolved.is_relative_to(root): raise ValueError('restored-home escapes scratch parent')
    return resolved

def nodes(raw):
    return [row for line in raw.splitlines() if (row := json.loads(line)).get('message_type') == 'node']

def verify(args, rows, listing, restored, restic, log_path):
    source_root = Path(rows[0]['paths'][0])
    if args.source_root and args.source_root != str(source_root): raise ValueError('snapshot source root mismatch')
    if args.hostname and rows[0].get('hostname') != args.hostname: raise ValueError('snapshot hostname mismatch')
    if restored.is_symlink() or not restored.is_dir(): raise ValueError('restored-home must be an existing real directory')
    started = time.time(); phases = {}; tree_cache = {}
    def tree_at(path):
        path = str(path)
        if path not in tree_cache:
            if not path.startswith(str(source_root)):
                raise ValueError('tree lookup escaped source root')
            # The snapshot-qualified form asks Restic to authenticate and
            # resolve the tree; cache it once per unique source path.
            tree_cache[path] = json.loads(restic('cat','tree',args.snapshot + ':' + path))
        return tree_cache[path]
    def stored(path):
        parent = str(Path(path).parent)
        return next(n for n in tree_at(parent)['nodes'] if n['name'] == Path(path).name)
    def phase(name):
        start = time.time()
        def record(message):
            with log_path.open('a') as log:
                log.write(message + '\n'); log.flush(); os.fsync(log.fileno())
            print(message, flush=True)
        record(f'[{dt.datetime.now(dt.timezone.utc).isoformat()}] {name}: start')
        def finish():
            phases[name] = time.time() - start
            record(f'[{dt.datetime.now(dt.timezone.utc).isoformat()}] {name}: end ({phases[name]:.3f}s)')
        return finish
    finish = phase('metadata')
    verified = 0
    for node in listing:
        source = Path(node['path'])
        if source == source_root: continue
        if not source.is_relative_to(source_root):
            if node.get('type') == 'dir' and source_root.is_relative_to(source):
                continue
            raise ValueError('snapshot path outside source root')
        path = restored / source.relative_to(source_root); info = path.lstat(); kind = node['type']
        if kind == 'file' and (not stat.S_ISREG(info.st_mode) or info.st_size != node['size']): raise ValueError('file mismatch: '+node['path'])
        if kind == 'symlink' and (not stat.S_ISLNK(info.st_mode) or os.readlink(path) != stored(source)['linktarget']): raise ValueError('symlink target mismatch: '+node['path'])
        if kind == 'dir' and not stat.S_ISDIR(info.st_mode): raise ValueError('directory mismatch: '+node['path'])
        if kind not in ('file','dir','symlink'): raise ValueError('unsupported node type')
        if (info.st_uid,info.st_gid) != (node['uid'],node['gid']): raise ValueError('ownership mismatch: '+node['path'])
        if kind != 'symlink':
            mode = node['mode'] & 0o777
            for bit, permission in ((23,0o4000),(22,0o2000),(20,0o1000)):
                if node['mode'] & (1 << bit): mode |= permission
            if stat.S_IMODE(info.st_mode) != mode: raise ValueError('mode mismatch: '+node['path'])
            if abs(info.st_mtime_ns - mtime_ns(node['mtime'])) >= 1000: raise ValueError('mtime mismatch: '+node['path'])
        verified += 1
    finish(); finish = phase('xattrs'); xattrs = []
    for selected in args.metadata_path:
        path = Path(selected)
        if not path.is_absolute() or str(path) != str(PurePath(path)): raise ValueError('metadata path must be canonical absolute')
        if not any(n.get('path') == selected for n in listing): raise ValueError('metadata sample not present')
        attrs = stored(path).get('extended_attributes') or []
        if not attrs: raise ValueError('metadata sample contains no extended attributes')
        target = restored / path.relative_to(source_root)
        for attr in attrs:
            try: outcome = read_xattr(target, attr['name']) == base64.b64decode(attr['value'])
            except OSError: outcome = False
            xattrs.append({'path':selected,'name':attr['name'],'outcome':outcome})
            if not outcome: raise ValueError('extended attribute mismatch: '+selected)
    finish(); finish = phase('representatives'); representatives = {}
    files = [(n, restored / Path(n['path']).relative_to(source_root)) for n in listing if n.get('type') == 'file']
    for label, item in (('executable', next(((n,p) for n,p in files if n.get('mode',0) & (1<<6)), None)),
                        ('hidden_application_state', next(((n,p) for n,p in files if Path(n['path']).name.startswith('.')), None))):
        if item:
            n, path = item
            with path.open('rb') as stream: digest = hashlib.sha256(stream.read()).hexdigest()
            representatives[label] = {'path':n['path'],'sha256':digest,'execute_bits':oct(stat.S_IMODE(path.lstat().st_mode)&0o111)}
    finish()
    return {'snapshot_id':args.snapshot,'destination':args.destination,'hostname':rows[0].get('hostname'),'source_root':str(source_root),
            'restored_nodes':verified,'metadata_paths':args.metadata_path,'xattrs':xattrs,'representatives':representatives,
            'verification_only':args.verify_only,'content_verification_reference':str(args.content_reference) if args.content_reference else None,
            'phase_durations_seconds':phases,'started_at':dt.datetime.fromtimestamp(started,dt.timezone.utc).isoformat(),
            'ended_at':dt.datetime.now(dt.timezone.utc).isoformat(),'elapsed_seconds':time.time()-started,
            'log':str(log_path)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', required=True); parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--destination', choices=['nas','b2'], required=True); parser.add_argument('--scratch-parent', type=Path, required=True)
    parser.add_argument('--restored-home', type=Path); parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--hostname'); parser.add_argument('--source-root'); parser.add_argument('--metadata-path', action='append', default=[])
    parser.add_argument('--content-reference', type=Path); parser.add_argument('--restic', default='/usr/local/bin/restic'); args = parser.parse_args(); os.umask(0o077)
    if not re.fullmatch('[0-9a-f]{64}',args.snapshot): raise ValueError('a full exact snapshot ID is required')
    parent=args.scratch_parent
    if parent.is_symlink() or not parent.is_dir() or parent.stat().st_mode & 0o077: raise ValueError('scratch parent must be private and existing')
    if args.credentials.is_symlink() or args.credentials.stat().st_mode & 0o077: raise ValueError('credentials must be private')
    env={**os.environ,**json.loads(args.credentials.read_text())}; cache=Path(tempfile.mkdtemp(prefix='restic-'+args.destination+'-',dir=parent)); cache.chmod(0o700)
    def restic(*values): return subprocess.check_output([args.restic,'--cache-dir',str(cache),*values],env=env)
    rows=json.loads(restic('snapshots','--json',args.snapshot))
    if len(rows)!=1 or rows[0]['id']!=args.snapshot or len(rows[0].get('paths',[]))!=1: raise ValueError('exact snapshot with one source root not found')
    identity={'snapshot_id':args.snapshot,'destination':args.destination,'hostname':rows[0].get('hostname'),'scratch_parent':str(parent.resolve())}
    if args.verify_only:
        if not args.restored_home: raise ValueError('--verify-only requires --restored-home')
        restored=safe_child(parent,args.restored_home); report_dir=restored.parent
    else:
        report_dir=Path(tempfile.mkdtemp(prefix='workstation-restore-',dir=parent)); restored=report_dir/'home'; source=rows[0]['paths'][0]
        print(f'Restoring into {restored}',flush=True); subprocess.run([args.restic,'--cache-dir',str(cache),'restore',args.snapshot+':'+source,'--target',str(restored),'--verify'],env=env,check=True)
    log_path = report_dir / 'restore-verification.log'
    log_path.touch(mode=0o600)
    try:
        report=verify(args,rows,nodes(restic('ls','--json',args.snapshot)),restored,restic,log_path); report.update(identity)
        prior_reports = [report_dir/'restore-verification.json', report_dir/'restore-evidence.json']
        for prior in prior_reports:
            if prior.exists():
                old=json.loads(prior.read_text())
                old_identity = {k: old.get(k) for k in identity if k in old}
                if old_identity == {k: identity[k] for k in old_identity} and old.get('kdbx_manually_opened') is True:
                    report['kdbx_manually_opened']=True
                    break
        atomic_private(prior,report); print(json.dumps(report,indent=2))
    except Exception as error:
        atomic_private(report_dir/'restore-verification-failed.json',{'identity':identity,'failed_at':dt.datetime.now(dt.timezone.utc).isoformat(),'error':str(error)}); raise
if __name__ == '__main__': main()
