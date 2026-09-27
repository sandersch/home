#!/usr/bin/env python3
"""Root-only disposable loop-disk test. Invoke in a private mount namespace.

The USB discovery boundary is replaced ONLY in this test; the production CLI
never permits loop devices. Partitioning, formatting and mounting are real.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('offline_loop', HERE / 'offline-ssd.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert os.geteuid() == 0, 'run via sudo unshare --mount --propagation private'
assert Path('/proc/self/ns/mnt').readlink() != Path('/proc/1/ns/mnt').readlink(), 'private mount namespace required'

with tempfile.TemporaryDirectory(prefix='offline-loop-', dir='/tmp') as temp:
    root = Path(temp)
    image = root / 'disk.img'
    with image.open('wb') as stream:
        stream.truncate(256 * 1024 * 1024)
    loop = m.run('losetup', '--find', '--show', '--partscan', image).strip()
    assert loop.startswith('/dev/loop') and Path(m.run('losetup', '--noheadings', '--output', 'BACK-FILE', loop).strip()) == image
    mounts = root / 'mounts'
    mounts.mkdir(mode=0o700)
    mount = mounts / 'A'
    mount.mkdir(mode=0o555)
    control = root / 'control'
    control.mkdir(mode=0o700)
    uuid_link = None
    def disk(device):
        assert str(device) == loop, 'test may access only its newly allocated loop device'
        row = json.loads(m.run('lsblk', '--json', '--tree', '--bytes', '--paths', '-o',
            'PATH,TYPE,SIZE,MODEL,SERIAL,WWN,TRAN,RO,FSTYPE,UUID,PARTUUID,LABEL,MOUNTPOINTS', loop))['blockdevices'][0]
        assert row['type'] == 'loop'
        row.update(type='disk', tran='usb', serial='disposable-loop-test', model='test')
        return row
    try:
        m.run('chattr', '+i', mount)
        with patch.object(m, 'CONTROL', control), patch.object(m, 'MOUNTS', mounts), \
             patch.object(m, 'backup_guard', lambda: None), patch.object(m, 'disk', disk), \
             patch.object(m, 'confirm', lambda *args: None):
            args = argparse.Namespace(drive='A', device=Path(loop))
            try:
                m.provision(args)
            except Exception:
                print(m.run('lsblk', '--json', '--paths', loop))
                print(m.run('sfdisk', '--dump', loop))
                raise
            record = m.read(control / 'A.json')
            # udev may be absent in CI; provide the same UUID symlink only if absent.
            uuid_link = Path('/dev/disk/by-uuid') / record['uuid']
            created_link = not uuid_link.exists()
            if created_link:
                uuid_link.parent.mkdir(parents=True, exist_ok=True)
                uuid_link.symlink_to(disk(Path(loop))['children'][0]['path'])
            m.attach(record)
            assert m.mount_guard(record) == mount
            for key in ('uuid', 'partuuid', 'label', 'hardware'):
                wrong = {**record, key: {} if key == 'hardware' else 'substitution'}
                try:
                    m.mount_guard(wrong)
                    raise AssertionError('substitution accepted')
                except RuntimeError:
                    pass
            try:
                m.inactive(disk(Path(loop)))
                raise AssertionError('mounted child accepted')
            except RuntimeError:
                pass
            (mount / 'vault').symlink_to(root)
            try:
                m.mount_guard(record)
                raise AssertionError('symlink accepted')
            except RuntimeError:
                pass
            (mount / 'vault').unlink()
            nested = mount / 'lost+found' / 'nested'
            nested.mkdir()
            m.run('mount', '-t', 'tmpfs', 'tmpfs', nested)
            try:
                try:
                    m.mount_guard(record)
                    raise AssertionError('nested mount accepted')
                except RuntimeError:
                    pass
            finally:
                m.run('umount', nested)
                nested.rmdir()
            m.run('mount', '-o', 'remount,ro', mount)
            try:
                m.mount_guard(record)
                raise AssertionError('read-only mount accepted')
            except RuntimeError:
                pass
            m.run('umount', mount)
            try:
                m.mount_guard(record)
                raise AssertionError('lost mount accepted')
            except RuntimeError:
                pass
            try:
                (mount / 'must-not-land-on-host').mkdir()
                raise AssertionError('immutable uncovered mountpoint allowed write')
            except PermissionError:
                pass
            if created_link:
                uuid_link.unlink()
                uuid_link = None
            print('PASS: disposable loop provisioning, mount guards, substitutions and mount-loss protection')
    finally:
        if subprocess.run(['mountpoint', '-q', str(mount)]).returncode == 0:
            m.run('umount', mount)
        m.run('chattr', '-i', mount)
        if uuid_link is not None and locals().get('created_link') and uuid_link.is_symlink():
            uuid_link.unlink()
        m.run('losetup', '--detach', loop)
