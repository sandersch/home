#!/usr/bin/env python3
"""Restore or metadata-verify an exact workstation snapshot."""
import argparse, base64, datetime as dt, hashlib, json, os, re, stat, subprocess, sys, tempfile, time
from contextlib import contextmanager
import threading
from pathlib import Path, PurePath

PROGRESS_SECONDS = 30
LOG_LOCK = threading.Lock()

@contextmanager
def progress(name, log_path, durations=None):
    started = time.monotonic(); counters = {}; stopped = threading.Event()
    def record(event):
        message = json.dumps({'time': dt.datetime.now(dt.timezone.utc).isoformat(),
                              'phase': name, 'event': event,
                              'elapsed_seconds': round(time.monotonic() - started, 3), **counters})
        with LOG_LOCK:
            with log_path.open('a') as log:
                log.write(message + '\n'); log.flush()
            print(message, file=sys.stderr, flush=True)
    def heartbeat():
        while not stopped.wait(PROGRESS_SECONDS): record('progress')
    record('start'); worker = threading.Thread(target=heartbeat, daemon=True); worker.start()
    outcome = 'complete'
    try:
        yield counters
    except BaseException:
        outcome = 'failed'
        raise
    finally:
        stopped.set(); worker.join()
        if durations is not None:
            durations[name] = durations.get(name, 0) + time.monotonic() - started
        record(outcome)

def captured(command, env, counters):
    chunks = []; counters.update(stdout_bytes=0, stdout_lines=0)
    with subprocess.Popen(command, env=env, stdout=subprocess.PIPE) as process:
        try:
            while chunk := os.read(process.stdout.fileno(), 64 * 1024):
                chunks.append(chunk)
                counters['stdout_bytes'] += len(chunk)
                counters['stdout_lines'] += chunk.count(b'\n')
            code = process.wait()
            if code: raise subprocess.CalledProcessError(code, command)
        except BaseException:
            if process.poll() is None: process.kill()
            process.wait(); raise
    return b''.join(chunks)

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
    started = time.time(); monotonic_started = time.monotonic(); phases = {}; tree_cache = {}
    tree_counts = {'tree_requests': 0, 'tree_cache_hits': 0}
    def tree_at(path):
        path = str(path)
        if path not in tree_cache:
            if not Path(path).is_relative_to(source_root):
                raise ValueError('tree lookup escaped source root')
            # The snapshot-qualified form asks Restic to authenticate and
            # resolve the tree; cache it once per unique source path.
            tree_counts['tree_requests'] += 1
            counters.update(tree_counts)
            tree_cache[path] = json.loads(restic('cat','tree',args.snapshot + ':' + path))
        else:
            tree_counts['tree_cache_hits'] += 1
        counters.update(tree_counts)
        return tree_cache[path]
    def stored(path):
        parent = str(Path(path).parent)
        return next(n for n in tree_at(parent)['nodes'] if n['name'] == Path(path).name)
    with progress('metadata', log_path, phases) as counters:
        verified = 0; symlink_count = 0
        counters.update(nodes_total=len(listing), nodes_examined=0, nodes_verified=0)
        for node in listing:
            counters['nodes_examined'] += 1
            source = Path(node['path'])
            if source == source_root: continue
            if not source.is_relative_to(source_root):
                if node.get('type') == 'dir' and source_root.is_relative_to(source):
                    continue
                raise ValueError('snapshot path outside source root')
            path = restored / source.relative_to(source_root); info = path.lstat(); kind = node['type']
            if kind == 'file' and (not stat.S_ISREG(info.st_mode) or info.st_size != node['size']): raise ValueError('file mismatch: '+node['path'])
            if kind == 'symlink':
                if not stat.S_ISLNK(info.st_mode): raise ValueError('symlink type mismatch: '+node['path'])
                symlink_count += 1
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
            counters['nodes_verified'] = verified
    with progress('symlink_targets', log_path, phases) as counters:
        symlink_samples = []
        # Target strings require additional authenticated tree reads. Fetch these
        # only for explicit recovery samples, never for every dependency symlink.
        for selected in dict.fromkeys(args.symlink_path):
            path = Path(selected)
            if (not path.is_absolute() or str(path) != selected or '..' in path.parts
                    or path == source_root or not path.is_relative_to(source_root)):
                raise ValueError('symlink sample must be a canonical absolute path within source root')
            if not any(n.get('path') == selected and n.get('type') == 'symlink' for n in listing):
                raise ValueError('symlink sample not present as a symlink: ' + selected)
            expected = stored(path)['linktarget']
            if os.readlink(restored / path.relative_to(source_root)) != expected:
                raise ValueError('symlink target mismatch: ' + selected)
            symlink_samples.append({'path': selected, 'outcome': True})
    with progress('xattrs', log_path, phases) as counters:
        xattrs = []
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
    with progress('representatives', log_path, phases) as counters:
        representatives = {}
        files = [(n, restored / Path(n['path']).relative_to(source_root)) for n in listing if n.get('type') == 'file']
        for label, item in (('executable', next(((n,p) for n,p in files if n.get('mode',0) & (1<<6)), None)),
                            ('hidden_application_state', next(((n,p) for n,p in files if Path(n['path']).name.startswith('.')), None))):
            if item:
                n, path = item
                with path.open('rb') as stream: digest = hashlib.sha256(stream.read()).hexdigest()
                representatives[label] = {'path':n['path'],'sha256':digest,'execute_bits':oct(stat.S_IMODE(path.lstat().st_mode)&0o111)}
    return {'snapshot_id':args.snapshot,'destination':args.destination,'hostname':rows[0].get('hostname'),'source_root':str(source_root),
            'restored_nodes':verified,'metadata_paths':args.metadata_path,'xattrs':xattrs,'representatives':representatives,
            'symlink_presence_count':symlink_count,'symlink_target_scope':'selected_paths',
            'symlink_target_samples':symlink_samples,
            'verification_only':args.verify_only,'content_verification_reference':str(args.content_reference) if args.content_reference else None,
            'phase_durations_seconds':phases,'started_at':dt.datetime.fromtimestamp(started,dt.timezone.utc).isoformat(),
            'ended_at':dt.datetime.now(dt.timezone.utc).isoformat(),'elapsed_seconds':time.monotonic()-monotonic_started,
            'log':str(log_path)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', required=True); parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--destination', choices=['nas','b2'], required=True); parser.add_argument('--scratch-parent', type=Path, required=True)
    parser.add_argument('--restored-home', type=Path); parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--hostname'); parser.add_argument('--source-root'); parser.add_argument('--metadata-path', action='append', default=[])
    parser.add_argument('--symlink-path', action='append', default=[],
                        help='absolute source symlink whose target must match; repeat for recovery samples (default: presence only)')
    parser.add_argument('--content-reference', type=Path); parser.add_argument('--restic', default='/usr/local/bin/restic'); args = parser.parse_args(); os.umask(0o077)
    if not re.fullmatch('[0-9a-f]{64}',args.snapshot): raise ValueError('a full exact snapshot ID is required')
    parent=args.scratch_parent
    if parent.is_symlink() or not parent.is_dir() or parent.stat().st_mode & 0o077: raise ValueError('scratch parent must be private and existing')
    if args.credentials.is_symlink() or args.credentials.stat().st_mode & 0o077: raise ValueError('credentials must be private')
    env={**os.environ,**json.loads(args.credentials.read_text())}; cache=Path(tempfile.mkdtemp(prefix='restic-'+args.destination+'-',dir=parent)); cache.chmod(0o700)
    if args.verify_only:
        if not args.restored_home: raise ValueError('--verify-only requires --restored-home')
        restored=safe_child(parent,args.restored_home); report_dir=restored.parent
    else:
        report_dir=Path(tempfile.mkdtemp(prefix='workstation-restore-',dir=parent)); restored=report_dir/'home'
    log_path = report_dir / 'restore-verification.log'
    log_path.touch(mode=0o600)
    phases = {}; started = time.time(); monotonic_started = time.monotonic()
    identity={'snapshot_id':args.snapshot,'destination':args.destination,'scratch_parent':str(parent.resolve())}
    def restic(*values):
        name = {'snapshots': 'snapshot-discovery', 'ls': 'snapshot-listing', 'cat': 'tree-read'}[values[0]]
        with progress(name, log_path, phases) as counters:
            return captured([args.restic,'--cache-dir',str(cache),*values],env,counters)
    try:
        with progress('restore-total', log_path):
            rows=json.loads(restic('snapshots','--json',args.snapshot))
            if len(rows)!=1 or rows[0]['id']!=args.snapshot or len(rows[0].get('paths',[]))!=1:
                raise ValueError('exact snapshot with one source root not found')
            identity['hostname'] = rows[0].get('hostname')
            if not args.verify_only:
                print(f'Restoring into {restored}',flush=True)
                with progress('restore-content-verification', log_path, phases):
                    subprocess.run([args.restic,'--cache-dir',str(cache),'restore',
                                    args.snapshot+':'+rows[0]['paths'][0],'--target',str(restored),'--verify'],
                                   env=env,check=True)
            raw = restic('ls','--json',args.snapshot)
            with progress('listing-decode', log_path, phases) as counters:
                listing = nodes(raw)
                counters['nodes_total'] = len(listing)
            report=verify(args,rows,listing,restored,restic,log_path); report.update(identity)
            report['phase_durations_seconds'].update(phases)
            report.update(started_at=dt.datetime.fromtimestamp(started,dt.timezone.utc).isoformat(),
                          ended_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                          elapsed_seconds=time.monotonic()-monotonic_started)
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
