#!/usr/bin/env python3
"""Freeze and upload Documents using portable tar/checksum and restricted SFTP."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', choices=['ryze', 'm5c'], required=True)
    args = parser.parse_args()
    os.umask(0o077)
    home = Path.home()
    source = home / 'Documents'
    config = home / '.config/vault-ingest'
    identity = config / 'id_ed25519'
    known = config / 'known_hosts'
    if identity.is_symlink() or not identity.is_file() or identity.stat().st_mode & 0o777 != 0o600:
        raise ValueError('dedicated identity must be a regular mode-0600 file')
    if not known.is_file() or known.stat().st_size == 0:
        raise ValueError('trusted dedicated known_hosts file is missing')
    if source.is_symlink() or not source.is_dir() or os.path.ismount(source):
        raise ValueError('Documents must be a local directory')
    if platform.system() == 'Darwin':
        runtime = home / '.local/state/workstation-backup/document-staging'
        # Enrollment verifies FileVault. A marker alone cannot establish encryption.
        result = subprocess.run(['/usr/bin/fdesetup', 'status'], check=True, capture_output=True, text=True)
        if 'FileVault is On.' not in result.stdout:
            raise ValueError('private staging requires FileVault on the startup volume')
    else:
        runtime = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')) / 'vault-ingest'
        result = subprocess.run(['findmnt', '-n', '-o', 'FSTYPE', '--target', str(runtime.parent)],
                                check=True, capture_output=True, text=True)
        if result.stdout.strip() != 'tmpfs':
            raise ValueError('Linux document staging must be memory-backed')
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    if runtime.is_symlink() or runtime.stat().st_uid != os.getuid() or runtime.stat().st_mode & 0o077:
        raise ValueError('staging must be private and owned by the client')
    if runtime.stat().st_dev != home.stat().st_dev and platform.system() == 'Darwin':
        raise ValueError('Mac staging must be on the startup home volume')
    with (runtime / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        files, required = [], 0
        def walk_error(error):
            raise error
        for root, directories, names in os.walk(source, followlinks=False, onerror=walk_error):
            for name in sorted(directories + names):
                path = Path(root) / name
                info = path.lstat()
                if info.st_dev != source.stat().st_dev or path.is_symlink() or os.path.ismount(path):
                    raise ValueError(f'Documents contains a link or mount: {path}')
                if not stat.S_ISREG(info.st_mode) and not stat.S_ISDIR(info.st_mode):
                    raise ValueError(f'Documents contains an unsupported type: {path}')
                files.append((path, info))
                # Tar block padding and PAX headers plus ample fixed slack.
                required += ((info.st_size + 511) // 512 * 512 if path.is_file() else 0) + 4096
        if required > 50 * 1024**3:
            raise ValueError('Documents exceeds the server archive ceiling')
        if shutil.disk_usage(runtime).free <= required + 64 * 1024**2:
            raise ValueError('insufficient staging capacity; no upload attempted')
        with tempfile.TemporaryDirectory(prefix='documents-', dir=runtime) as temporary:
            archive = Path(temporary) / 'archive.tar'
            checksum = Path(temporary) / 'archive.sha256'
            with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT, dereference=False) as output:
                for path, before in files:
                    output.add(path, arcname=path.relative_to(source).as_posix(), recursive=False)
                    after = path.lstat()
                    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                        raise ValueError(f'Documents changed during archival: {path}')
            if archive.stat().st_size > 50 * 1024**3:
                raise ValueError('archive exceeds server ceiling')
            with archive.open('rb') as stream:
                checksum.write_text(hashlib.file_digest(stream, 'sha256').hexdigest() + '  archive\n')
            token = str(time.time_ns())
            batch = (f'put "{archive}" /upload/documents.{token}.tar.tmp\n'
                     f'rename /upload/documents.{token}.tar.tmp /upload/documents.{token}.tar.ready\n'
                     f'put "{checksum}" /upload/documents.{token}.sha256.tmp\n'
                     f'rename /upload/documents.{token}.sha256.tmp /upload/documents.{token}.sha256.ready\n')
            subprocess.run(['sftp', '-q', '-b', '-', '-P', '2222', '-i', str(identity),
                '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
                '-o', 'UserKnownHostsFile=' + str(known), f'vault-ingest-{args.host}@10.137.20.5'],
                input=batch.encode(), check=True)


if __name__ == '__main__':
    main()
