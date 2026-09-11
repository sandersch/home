#!/usr/bin/env python3
"""Root-owned workstation validation, replication, retention and hold resolution.

No client tag or original field is used as authority. The atomic state is outside
repositories and all maintenance actions share one per-host advisory lock.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import ssl
import statistics
import subprocess
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET

from workstation import atomic, attach_link_targets, check_floors, digest, excluded, patterns, read_json, snapshot_records, totals, KDBX

ID = re.compile(r'^[0-9a-f]{64}$')
CONTRACT = re.compile(r'workstation-(?P<host>ryze|m5c)-v(?P<version>[1-9][0-9]*)')
RETENTION = ['--group-by', 'host', '--keep-within', '30d', '--keep-within-daily', '30d',
             '--keep-within-weekly', '84d', '--keep-within-monthly', '12m']


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('snapshot timestamp lacks timezone')
    return parsed.timestamp()


def version(name):
    match = CONTRACT.fullmatch(name)
    if not match:
        raise ValueError('unexpected workstation contract name')
    return int(match['version'])


def load_contracts(host, directory):
    """Return every released version as {name: (contract, rules, sha256)}."""
    contracts = {}
    for path in sorted(Path(directory).glob(f'workstation-{host}-v*.json')):
        name = path.stem
        version(name)
        contract = read_json(path)
        rules_file = path.with_suffix('.excludes')
        if (contract.get('contract') != name or contract.get('hostname') != host or
                CONTRACT.fullmatch(name)['host'] != host):
            raise ValueError(f'contract identity mismatch: {name}')
        if contract.get('enrollment_status') != 'released':
            raise ValueError(f'measured contract has not been released: {name}')
        if digest(rules_file.read_bytes()) != contract['exclusion_sha256']:
            raise ValueError(f'released contract/exclusion identity mismatch: {name}')
        contracts[name] = (contract, patterns(rules_file), digest(path.read_bytes()))
    if not contracts:
        raise ValueError('no released contract')
    versions = sorted(version(name) for name in contracts)
    if versions != list(range(1, len(versions) + 1)):
        raise ValueError('released contract versions must be contiguous from v1')
    # Accepted snapshot identity and the manifest location span all versions.
    if len({(json.dumps(c['source_roots']), c['manifest']) for c, _, _ in contracts.values()}) != 1:
        raise ValueError('contract versions disagree on source root or manifest')
    return contracts


def pin_contracts(state, host, contracts):
    """Pin each released version the first time it is trusted; never repin."""
    pinned = state.setdefault('contracts', {})
    # The pre-versioning single pin is the v1 hash.
    if 'contract_sha256' in state:
        pinned.setdefault(f'workstation-{host}-v1', state.pop('contract_sha256'))
    for name, (_, _, contract_hash) in contracts.items():
        if pinned.setdefault(name, contract_hash) != contract_hash:
            raise ValueError(f'released contract {name} differs from trusted enrollment state')
    if set(pinned) - set(contracts):
        raise ValueError('a trusted released contract is missing')


def mount_guard(root='/repo/nas', mountinfo='/proc/self/mountinfo'):
    source = '/dev/mapper/hoardvg-backuplv'
    uuid = 'cc1cedb8-ef22-44b5-b1d0-5ca020d72669'
    matches = []
    for line in Path(mountinfo).read_text().splitlines():
        fields = line.split()
        if fields[4] == root:
            separator = fields.index('-')
            matches.append((fields[separator + 1], fields[separator + 2], fields[5]))
    if not matches or matches[-1][:2] != ('ext4', source):
        raise ValueError('backup mount identity mismatch')
    if os.environ.get('WORKSTATION_HOST'):
        # The server sees the parent mount read-only and only its own repo rw.
        repository = [line.split() for line in Path(mountinfo).read_text().splitlines()
                      if line.split()[4] == '/repository']
        if not repository or 'rw' not in repository[-1][5].split(','):
            raise ValueError('server repository mount is not writable')
        fields = repository[-1]
        separator = fields.index('-')
        if fields[separator + 1:separator + 3] != ['ext4', source]:
            raise ValueError('server repository mount identity mismatch')
    elif 'rw' not in matches[-1][2].split(','):
        raise ValueError('backup mount is not writable')
    sentinel = Path(root) / '.backup-sentinel'
    info = sentinel.lstat()
    if sentinel.is_symlink() or not sentinel.is_file() or (info.st_uid, info.st_gid, info.st_mode & 0o777) != (0, 0, 0o444):
        raise ValueError('backup sentinel metadata mismatch')
    if sentinel.read_text().splitlines()[0] != uuid:
        raise ValueError('backup sentinel UUID mismatch')


class Manager:
    def __init__(self, host, root=Path('/repo/nas'), contracts=Path('/contracts')):
        self.host = host
        self.root = root
        self.control = root / '.control' / ('workstation-' + host)
        self.control.mkdir(parents=True, exist_ok=True, mode=0o700)
        for path in (root / '.control', self.control):
            info = path.lstat()
            if path.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
                raise ValueError('control directories must be root-owned and not writable by others')
        self.file = self.control / 'state.json'
        self.state = read_json(self.file) if self.file.exists() else {
            'accepted': {}, 'rejected': {}, 'holds': {}, 'copies': {}, 'pending': [],
            'generation': 1, 'baseline': [], 'highwater': 0, 'prune_success': 0,
            'copy_success': 0, 'check_success': {}, 'validation_success': 0}
        self.contracts = load_contracts(host, contracts)
        pin_contracts(self.state, host, self.contracts)
        self.contract, self.rules, _ = self.contracts[max(self.contracts, key=version)]
        self.credentials = read_json('/credentials/maintenance.json')

    def save(self):
        atomic(self.file, self.state)

    def run(self, destination, *args, raw=False, extra_env=None):
        env = os.environ.copy()
        env.update(self.credentials[destination])
        if extra_env:
            env.update(extra_env)
        command = ['/tools/restic', '--no-cache', '--retry-lock', '30m', *map(str, args)]
        # All repository objects retain the serving uid, including indexes made
        # by prune. Only the parent process can write root-owned control state.
        output = subprocess.run(command, check=True, env=env, stdout=subprocess.PIPE,
                                user=65534, group=65534, extra_groups=[]).stdout
        return output if raw else json.loads(output or b'null')

    def listing(self, destination):
        rows = self.run(destination, 'snapshots', '--json') or []
        if any(not ID.fullmatch(row['id']) for row in rows):
            raise ValueError('snapshot listing contains a non-exact ID')
        return {row['id']: row for row in rows}

    def content(self, destination, snapshot):
        sid = snapshot['id']
        contract = self.contract
        home, = contract['source_roots']
        if snapshot['hostname'] != self.host or snapshot['paths'] != [home]:
            raise ValueError('source roots or logical hostname differ from contract')
        nodes = [json.loads(line) for line in self.run(destination, 'ls', '--json', sid, raw=True).splitlines()]
        attach_link_targets(nodes, snapshot['tree'], lambda tree: self.run(destination, 'cat', 'blob', tree))
        manifests = [n for n in nodes if n.get('path') == contract['manifest'] and n.get('type') == 'file']
        if len(manifests) != 1 or not 0 < manifests[0]['size'] <= 128 * 1024 * 1024:
            raise ValueError('missing or oversized measured manifest')
        manifest = json.loads(self.run(destination, 'dump', sid, contract['manifest'], raw=True))
        # The manifest names its contract; only a released, pinned version with
        # the same exclusion identity can validate it.
        if manifest.get('contract') not in self.contracts:
            raise ValueError('manifest contract drift')
        contract, rules, _ = self.contracts[manifest['contract']]
        if manifest['exclusion_sha256'] != contract['exclusion_sha256']:
            raise ValueError('manifest contract drift')
        records = snapshot_records(nodes, home, contract['manifest'])
        if records != manifest['records'] or totals(records) != manifest['measured']:
            raise ValueError('manifest does not match actual snapshot listing')
        if any(excluded(path, rules) for path in records):
            raise ValueError('excluded content leaked into snapshot')
        if not any(n.get('path') == home + '/Documents' and n.get('type') == 'dir' for n in nodes):
            raise ValueError('Documents directory is absent')
        check_floors(records, contract)
        database_path = contract.get('kdbx_path', 'Dropbox/ccs.kdbx')
        database = records.get(database_path, {})
        if database.get('type') != 'file' or database.get('size', 0) < contract['kdbx_minimum_bytes']:
            raise ValueError('required KDBX absent or undersized')
        if database['size'] > 100 * 1024 * 1024:
            raise ValueError('KDBX exceeds validation bound')
        if not self.run(destination, 'dump', sid, home + '/' + database_path, raw=True).startswith(KDBX):
            raise ValueError('KDBX signature mismatch')
        return contract['contract'], {prefix: totals(records, prefix) for prefix in contract['floors']}

    def hold(self, sid, reason, destination='nas'):
        key = destination + ':' + sid
        self.state['holds'].setdefault(key, {'id': sid, 'destination': destination,
                                          'reason': reason, 'time': time.time()})
        self.save()

    def validate(self, accept_shrink=None):
        listing = self.listing('nas')
        def order(row):
            try:
                return timestamp(row['time'])
            except (ValueError, KeyError):
                return 0
        for row in sorted(listing.values(), key=lambda r: (order(r), r['id'])):
            sid = row['id']
            if 'nas:' + sid in self.state['rejected']:
                continue
            if sid in self.state['accepted']:
                # Immutable exact IDs already have content validation evidence.
                # Rechecking identity avoids rescanning every historical home
                # daily; prune revalidates actual removal candidates below.
                try:
                    self.accepted_identity(sid, row)
                except (ValueError, KeyError, subprocess.CalledProcessError) as error:
                    self.hold(sid, str(error))
                    break
                continue
            try:
                stamp = timestamp(row['time'])
                if stamp > time.time() + 600 or stamp < self.state['highwater'] - 600:
                    raise ValueError('snapshot-time-invalid')
                name, measured = self.content('nas', row)
                current = self.state.get('contract', f'workstation-{self.host}-v1')
                if version(name) < version(current):
                    raise ValueError('contract-downgrade')
                # A released version is a reviewed scope change with its own
                # measured floors, so its sizes start a new shrink baseline.
                transition = version(name) > version(current)
                baseline = [] if transition else self.state['baseline'][-7:]
                shrink = len(baseline) == 7 and any(
                    measured[p][k] < statistics.median(b[p][k] for b in baseline) * .8
                    for p in measured for k in ('files', 'bytes'))
                if shrink and sid != accept_shrink:
                    raise ValueError('shrink')
                if sid == accept_shrink:
                    if not shrink:
                        raise ValueError('accept-shrink requires a current shrink and passing all other checks')
                    self.state['generation'] += 1
                    self.state['baseline'] = []
                    self.state.setdefault('resolutions', {})[sid] = {
                        'action': 'accept-shrink', 'time': time.time(),
                        'generation': self.state['generation']}
                if transition:
                    self.state['generation'] += 1
                    self.state['baseline'] = []
                    self.state.setdefault('resolutions', {})[sid] = {
                        'action': 'contract-transition', 'from': current, 'to': name,
                        'time': time.time(), 'generation': self.state['generation']}
                    self.state['contract'] = name
                self.state['accepted'][sid] = {'time': stamp, 'measured': measured, 'contract': name,
                    'tree': row['tree'], 'generation': self.state['generation']}
                self.state['highwater'] = max(self.state['highwater'], stamp)
                self.state['baseline'] = (self.state['baseline'] + [measured])[-7:]
                self.state['holds'].pop('nas:' + sid, None)
                self.save()
            except (ValueError, KeyError, subprocess.CalledProcessError) as error:
                self.hold(sid, str(error))
                # Do not advance the high-water mark beyond an unresolved hold.
                break
        self.state['validation_success'] = time.time()
        self.save()
        return listing

    def clear(self):
        if self.state['holds']:
            raise ValueError('unresolved validation holds prohibit this operation')

    @staticmethod
    def same_snapshot(source, destination):
        return all(source[k] == destination[k] for k in ('tree', 'hostname', 'paths', 'time'))

    def accepted_identity(self, source_id, row):
        accepted = self.state['accepted'][source_id]
        if (row['tree'] != accepted['tree'] or timestamp(row['time']) != accepted['time'] or
                row['hostname'] != self.host or row['paths'] != self.contract['source_roots']):
            raise ValueError('snapshot identity differs from root-owned exact-ID validation evidence')

    def copy(self):
        source = self.validate()
        self.clear()
        destination = self.listing('b2')
        for sid, row in sorted(source.items(), key=lambda item: timestamp(item[1]['time'])):
            if sid not in self.state['accepted']:
                continue
            counterpart = self.state['copies'].get(sid)
            if counterpart and counterpart in destination:
                try:
                    self.accepted_identity(sid, destination[counterpart])
                except (ValueError, KeyError) as error:
                    self.hold(counterpart, str(error), 'b2')
                    raise
                continue
            if sid not in self.state['pending']:
                self.state['pending'].append(sid)
                self.save()
            # An interrupted copy can be recovered by actual tree/content identity,
            # never by an untrusted `original` claim supplied by the client.
            candidates = [r for r in destination.values() if self.same_snapshot(row, r)]
            if not candidates:
                source_env = self.credentials['nas']
                self.run('b2', 'copy', '--from-repo', source_env['RESTIC_REPOSITORY'], sid,
                         raw=True, extra_env={'RESTIC_FROM_PASSWORD': source_env['RESTIC_PASSWORD']})
                destination = self.listing('b2')
                candidates = [r for r in destination.values() if self.same_snapshot(row, r)]
            if len(candidates) != 1:
                for candidate in candidates:
                    self.hold(candidate['id'], 'ambiguous copy counterpart; inspect and reject before retry', 'b2')
                raise ValueError('copy counterpart cannot be identified uniquely')
            target = candidates[0]
            self.validate_pair(row, target)
            self.state['copies'][sid] = target['id']
            self.state['pending'].remove(sid)
            self.save()
        tracked = set(self.state['copies'].values())
        for sid in destination.keys() - tracked:
            self.hold(sid, 'untracked destination snapshot', 'b2')
        self.clear()
        self.state['copy_success'] = time.time()
        self.save()

    def validate_pair(self, source, destination):
        if not self.same_snapshot(source, destination):
            self.hold(destination['id'], 'counterpart identity mismatch', 'b2')
            raise ValueError('recorded B2 counterpart differs from exact source snapshot')
        try:
            nas_content = self.content('nas', source)
        except (ValueError, KeyError, subprocess.CalledProcessError) as error:
            self.hold(source['id'], str(error))
            raise
        try:
            b2_content = self.content('b2', destination)
        except (ValueError, KeyError, subprocess.CalledProcessError) as error:
            self.hold(destination['id'], str(error), 'b2')
            raise
        if nas_content != b2_content:
            self.hold(destination['id'], 'counterpart content mismatch', 'b2')
            raise ValueError('destination content differs')

    def candidates(self, destination):
        result = self.run(destination, 'forget', '--dry-run', '--json', *RETENTION)
        ids = [s['id'] for group in result or [] for s in (group.get('remove') or [])]
        if any(not ID.fullmatch(sid) for sid in ids):
            raise ValueError('retention returned a non-exact ID')
        return ids

    def restart(self):
        token = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text().strip()
        context = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
        url = 'https://kubernetes.default.svc/apis/apps/v1/namespaces/monitoring/deployments/restic-' + self.host
        headers = {'Authorization': 'Bearer ' + token}
        marker = str(time.time_ns())
        body = json.dumps({'spec': {'template': {'metadata': {'annotations': {
            'worm.run/quota-recount': marker}}}}}).encode()
        request = urllib.request.Request(url, body, {**headers, 'Content-Type': 'application/merge-patch+json'}, method='PATCH')
        with urllib.request.urlopen(request, context=context, timeout=30) as response:
            generation = json.load(response)['metadata']['generation']
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), context=context, timeout=30) as response:
                deployment = json.load(response)
            status = deployment.get('status', {})
            if (status.get('observedGeneration', 0) >= generation and
                    status.get('updatedReplicas') == 1 and status.get('readyReplicas') == 1 and
                    status.get('replicas') == 1 and status.get('availableReplicas') == 1):
                return
            time.sleep(5)
        raise ValueError('quota recount restart did not become ready')

    def prune(self):
        source = self.validate()
        self.clear()
        if self.state['pending']:
            raise ValueError('unfinished copy prohibits retention')
        # Rejected invalid clocks cannot participate in policy evaluation. The
        # attended reject operation removes only its reviewed exact ID first.
        if any('nas:' + sid in self.state['rejected'] for sid in source):
            raise ValueError('rejected snapshot still present; resume attended rejection')
        destination = self.listing('b2')
        tracked = set(self.state['copies'].values())
        if set(destination) - tracked:
            for sid in set(destination) - tracked:
                self.hold(sid, 'untracked destination snapshot', 'b2')
            self.clear()
        for sid, row in destination.items():
            source_ids = [source_id for source_id, target in self.state['copies'].items() if target == sid]
            if not source_ids:
                raise ValueError('destination has no trusted source ID')
            self.accepted_identity(source_ids[0], row)
        nas_candidates = self.candidates('nas')
        if self.listing('nas') != source:
            raise ValueError('NAS snapshot set changed during retention planning; retry validation')
        self.state['recount_required'] = True
        self.save()
        for sid in nas_candidates:
            if sid not in self.state['accepted']:
                raise ValueError('NAS candidate was not validated')
            counterpart = self.state['copies'].get(sid)
            if counterpart not in destination:
                raise ValueError('NAS removal candidate lacks a physically present B2 counterpart')
            self.validate_pair(source[sid], destination[counterpart])
            mount_guard()
            self.run('nas', 'forget', '--group-by', 'host', sid, raw=True)
        # Persist a recount obligation BEFORE filesystem pruning; interruption
        # anywhere afterwards will repeat the restart before success is emitted.
        self.run('nas', 'prune', raw=True)
        self.restart()
        self.state['recount_required'] = False
        self.save()
        b2_candidates = self.candidates('b2')
        if self.listing('b2') != destination:
            raise ValueError('B2 snapshot set changed during retention planning; retry validation')
        for sid in b2_candidates:
            if sid not in tracked or sid not in destination:
                raise ValueError('B2 removal candidate lacks exact-ID validation')
            self.content('b2', destination[sid])
            self.run('b2', 'forget', '--group-by', 'host', sid, raw=True)
        self.run('b2', 'prune', raw=True)
        self.state['prune_success'] = time.time()
        self.save()

    def reject(self, sid, reason, destination):
        if not ID.fullmatch(sid) or not reason.strip():
            raise ValueError('rejection requires a full snapshot ID and audit reason')
        key = destination + ':' + sid
        if key not in self.state['holds'] and key not in self.state['rejected']:
            raise ValueError('snapshot is not held')
        # Intent survives termination after forget but before clearing the hold.
        self.state['rejected'][key] = {'reason': reason, 'time': time.time(), 'destination': destination}
        self.save()
        if sid in self.listing(destination):
            self.run(destination, 'forget', '--group-by', 'host', sid, raw=True)
        self.state['holds'].pop(key, None)
        if destination == 'nas' and sid in self.state['pending']:
            self.state['pending'].remove(sid)
        self.save()

    def check(self):
        self.validate()
        self.clear()
        for destination in ('nas', 'b2'):
            month = dt.datetime.now(dt.timezone.utc).month
            self.run(destination, 'check', f'--read-data-subset={month}/12', raw=True)
            self.state['check_success'][destination] = time.time()
            self.save()

    def initialize(self):
        if not os.isatty(0):
            raise ValueError('repository initialization requires an attended TTY')
        for destination in ('nas', 'b2'):
            try:
                self.listing(destination)
            except subprocess.CalledProcessError as error:
                if error.returncode != 10:
                    raise
                if destination == 'nas':
                    self.run('nas', 'init', raw=True)
                else:
                    nas = self.credentials['nas']
                    self.run('b2', 'init', '--from-repo', nas['RESTIC_REPOSITORY'],
                             '--copy-chunker-params', raw=True,
                             extra_env={'RESTIC_FROM_PASSWORD': nas['RESTIC_PASSWORD']})
        nas_config = self.run('nas', 'cat', 'config')
        b2_config = self.run('b2', 'cat', 'config')
        if nas_config['chunker_polynomial'] != b2_config['chunker_polynomial']:
            raise ValueError('repository chunker parameters differ')
        self.state['initialized'] = time.time()
        self.save()

    def metrics(self):
        label = f'dataset="workstations",host="{self.host}"'
        rows = []
        def emit(name, value, destination=None):
            labels = label + (f',destination="{destination}"' if destination else '')
            rows.append(f'homelab_workstation_{name}{{{labels}}} {value}')
        # Enrollment begins when the first seed snapshot is accepted or held, not
        # at initialization, so alerts stay quiet until an attended seed exists.
        # Accepted entries survive retention, keeping the timestamp stable.
        seeded = [row['time'] for row in self.state['accepted'].values()]
        seeded += [row['time'] for row in self.state['holds'].values()]
        emit('enrolled', int(bool(seeded)))
        emit('enrollment_timestamp_seconds', min(seeded, default=0))
        emit('prune_success_timestamp_seconds', self.state['prune_success'])
        emit('copy_success_timestamp_seconds', self.state['copy_success'])
        emit('validation_success_timestamp_seconds', self.state['validation_success'])
        emit('validation_hold', len(self.state['holds']))
        emit('snapshot_time_invalid', sum(h['reason'] == 'snapshot-time-invalid' for h in self.state['holds'].values()))
        for destination in ('nas', 'b2'):
            # Freshness is trusted accepted snapshot time, never Job completion.
            try:
                present = self.listing(destination)
            except (ValueError, subprocess.CalledProcessError):
                present = {}
            ids = ([sid for sid in self.state['accepted'] if sid in present] if destination == 'nas'
                   else [sid for sid, target in self.state['copies'].items() if target in present])
            stamps = [self.state['accepted'][sid]['time'] for sid in ids if sid in self.state['accepted']]
            emit('snapshot_timestamp_seconds', max(stamps, default=0), destination)
            emit('check_success_timestamp_seconds', self.state['check_success'].get(destination, 0), destination)
            ceiling = (161061273600 if self.host == 'ryze' else 107374182400) if destination == 'nas' else (100000000000 if self.host == 'ryze' else 50000000000)
            emit('ceiling_bytes', ceiling, destination)
            # stats raw-data does not include every physical pack/header. Use
            # backend object sizes for the actual quota/cost signal.
            try:
                if destination == 'nas':
                    size = sum(path.stat().st_size for path in
                               (self.root / 'workstations' / self.host).rglob('*') if path.is_file())
                else:
                    size = s3_size(self.credentials['b2'])
                emit('repository_bytes', size, destination)
                emit('size_collection_success', 1, destination)
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError, ET.ParseError):
                emit('size_collection_success', 0, destination)
        path = Path('/metrics') / ('restic-workstation-' + self.host + '.prom')
        temporary = path.with_suffix('.prom.tmp')
        temporary.write_text('\n'.join(rows) + '\n')
        temporary.chmod(0o644)
        os.replace(temporary, path)


def s3_size(credentials):
    """Sum physical S3 object sizes using paginated SigV4 ListObjectsV2."""
    repository = credentials['RESTIC_REPOSITORY']
    if not repository.startswith('s3:https://'):
        raise ValueError('B2 repository must use an explicit HTTPS S3 endpoint')
    parsed = urllib.parse.urlsplit(repository[3:])
    bucket, _, prefix = parsed.path.lstrip('/').partition('/')
    region = credentials['AWS_DEFAULT_REGION']
    total, continuation = 0, None
    while True:
        now = dt.datetime.now(dt.timezone.utc)
        day, date = now.strftime('%Y%m%d'), now.strftime('%Y%m%dT%H%M%SZ')
        parameters = {'list-type': '2', 'prefix': prefix.rstrip('/') + '/' if prefix else ''}
        if continuation:
            parameters['continuation-token'] = continuation
        query = urllib.parse.urlencode(sorted(parameters.items()), quote_via=urllib.parse.quote, safe='~')
        uri = '/' + urllib.parse.quote(bucket, safe='~')
        empty = hashlib.sha256(b'').hexdigest()
        headers = f'host:{parsed.netloc}\nx-amz-content-sha256:{empty}\nx-amz-date:{date}\n'
        signed = 'host;x-amz-content-sha256;x-amz-date'
        canonical = '\n'.join(['GET', uri, query, headers, signed, empty])
        scope = f'{day}/{region}/s3/aws4_request'
        message = '\n'.join(['AWS4-HMAC-SHA256', date, scope, digest(canonical.encode())])
        key = ('AWS4' + credentials['AWS_SECRET_ACCESS_KEY']).encode()
        for piece in (day, region, 's3', 'aws4_request'):
            key = hmac.new(key, piece.encode(), hashlib.sha256).digest()
        signature = hmac.new(key, message.encode(), hashlib.sha256).hexdigest()
        authorization = (f'AWS4-HMAC-SHA256 Credential={credentials["AWS_ACCESS_KEY_ID"]}/{scope}, '
                         f'SignedHeaders={signed}, Signature={signature}')
        request = urllib.request.Request(f'https://{parsed.netloc}{uri}?{query}', headers={
            'Authorization': authorization, 'x-amz-date': date, 'x-amz-content-sha256': empty})
        with urllib.request.urlopen(request, timeout=60) as response:
            document = ET.fromstring(response.read())
        ns = {'s3': 'http://s3.amazonaws.com/doc/2006-03-01/'}
        total += sum(int(node.text) for node in document.findall('s3:Contents/s3:Size', ns))
        if document.findtext('s3:IsTruncated', namespaces=ns) != 'true':
            return total
        following = document.findtext('s3:NextContinuationToken', namespaces=ns)
        if not following or following == continuation:
            raise ValueError('invalid S3 pagination')
        continuation = following


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['validate', 'copy', 'prune', 'check', 'initialize', 'reject', 'accept-shrink', 'guard'])
    parser.add_argument('--host', choices=['ryze', 'm5c'])
    parser.add_argument('--id')
    parser.add_argument('--reason')
    parser.add_argument('--destination', choices=['nas', 'b2'], default='nas')
    args = parser.parse_args()
    mount_guard()
    if args.action == 'guard':
        return
    if os.geteuid() != 0 or not args.host:
        raise ValueError('root and a fixed host are required')
    control = Path('/repo/nas/.control') / ('workstation-' + args.host)
    control.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (control / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manager = Manager(args.host)
        try:
            if args.action in ('reject', 'accept-shrink'):
                if not os.isatty(0):
                    raise ValueError('hold resolution requires attended TTY')
                if args.action == 'reject':
                    manager.reject(args.id or '', args.reason or '', args.destination)
                else:
                    held = manager.state['holds'].get('nas:' + (args.id or ''))
                    if not held and manager.state.get('resolutions', {}).get(args.id, {}).get('action') == 'accept-shrink':
                        return
                    if not held or held['reason'] != 'shrink':
                        raise ValueError('exact ID is not held solely for shrink')
                    manager.validate(accept_shrink=args.id)
                    manager.clear()
            else:
                getattr(manager, args.action)()
        finally:
            manager.metrics()


if __name__ == '__main__':
    main()
