#!/usr/bin/env python3
"""Continuously guard the backup mount and terminate rest-server on mismatch."""
import os
import signal
import subprocess
import sys
import time

from maintenance import mount_guard


def main():
    mount_guard()
    host = os.environ['WORKSTATION_HOST']
    cap = {'ryze': '161061273600', 'm5c': '107374182400'}[host]
    server = subprocess.Popen(['/tools/rest-server', '--path', '/repository',
        '--listen', ':8000', '--htpasswd-file', '/authentication/htpasswd',
        '--append-only', '--max-size', cap])
    def terminate(signum, frame):
        server.terminate()
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        while server.poll() is None:
            mount_guard()
            time.sleep(5)
    finally:
        if server.poll() is None:
            server.terminate()
        try:
            server.wait(timeout=20)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
    return server.returncode


if __name__ == '__main__':
    sys.exit(main())
