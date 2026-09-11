#!/usr/bin/env python3
"""Regenerate the empty NAS/B2 Restic repositories used by test-workstations.py.

Restic calibrates scrypt to roughly half a second and repeats it on every
repository open. These disposable fixtures protect nothing, so their keys are
rewrapped with minimal scrypt parameters to make each test command cheap.
Requires the `cryptography` package and checksum-verified Restic 0.19.1.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.poly1305 import Poly1305

PASSWORD = 'disposable-test-password'
KDF = {'N': 1024, 'r': 1, 'p': 1}
OUTPUT = Path(__file__).resolve().parent / 'workstation-repositories'


def user_key(params, salt):
    derived = hashlib.scrypt(PASSWORD.encode(), salt=salt, n=params['N'], r=params['r'],
                             p=params['p'], dklen=64, maxmem=2**31 - 1)
    return derived[:32], derived[32:48], derived[48:]


def mac_key(k, r, nonce):
    encryptor = Cipher(algorithms.AES(k), modes.ECB()).encryptor()
    return r + encryptor.update(nonce) + encryptor.finalize()


def decrypt(key, blob):
    encrypt, k, r = key
    nonce, ciphertext, tag = blob[:16], blob[16:-16], blob[-16:]
    Poly1305.verify_tag(mac_key(k, r, nonce), ciphertext, tag)
    decryptor = Cipher(algorithms.AES(encrypt), modes.CTR(nonce)).decryptor()
    return decryptor.update(ciphertext) + decryptor.finalize()


def encrypt(key, plaintext):
    encrypt_key, k, r = key
    nonce = secrets.token_bytes(16)
    encryptor = Cipher(algorithms.AES(encrypt_key), modes.CTR(nonce)).encryptor()
    ciphertext = encryptor.update(plaintext) + encryptor.finalize()
    return nonce + ciphertext + Poly1305.generate_tag(mac_key(k, r, nonce), ciphertext)


def rewrap(repository):
    [path] = (repository / 'keys').iterdir()
    old = json.loads(path.read_bytes())
    master = decrypt(user_key(old, base64.b64decode(old['salt'])), base64.b64decode(old['data']))
    salt = secrets.token_bytes(64)
    new = {'created': old['created'], 'username': 'fixture', 'hostname': 'fixture', 'kdf': 'scrypt',
           **KDF, 'salt': base64.b64encode(salt).decode(),
           'data': base64.b64encode(encrypt(user_key(KDF, salt), master)).decode()}
    content = json.dumps(new, separators=(',', ':')).encode()
    path.unlink()
    (repository / 'keys' / hashlib.sha256(content).hexdigest()).write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restic', default=os.environ.get('WORKSTATION_RESTIC', 'restic'))
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='workstation-repositories-') as temporary:
        base = Path(temporary)
        env = {**os.environ, 'RESTIC_PASSWORD': PASSWORD, 'RESTIC_FROM_PASSWORD': PASSWORD}
        restic = [arguments.restic, '--no-cache', '--quiet']
        subprocess.run(restic + ['-r', base / 'nas', 'init'], env=env, check=True)
        subprocess.run(restic + ['-r', base / 'b2', 'init', '--from-repo', base / 'nas',
                                 '--copy-chunker-params'], env=env, check=True)
        shutil.rmtree(OUTPUT, ignore_errors=True)
        for destination in ('nas', 'b2'):
            rewrap(base / destination)
            (OUTPUT / destination / 'keys').mkdir(parents=True)
            shutil.copy(base / destination / 'config', OUTPUT / destination / 'config')
            for key in (base / destination / 'keys').iterdir():
                shutil.copy(key, OUTPUT / destination / 'keys' / key.name)
    print(f'wrote {OUTPUT}')


if __name__ == '__main__':
    main()
