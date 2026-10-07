#!/usr/bin/env python3
"""Skip costly integrations only for PRs with known unrelated changes.

The cheap policy, backup contract, shell and render checks always run. Main
pushes and unknown paths always get the full integration suite.
"""
import os
import subprocess
import sys


def integration_required(paths):
    if not paths:
        return True
    for path in paths:
        if path in ('AGENTS.md', 'README.md', 'renovate.json5'):
            continue
        if path.startswith('docs/') and path.endswith('.md'):
            continue
        # Offline appstate verification imports the actual RomM MariaDB image.
        # Other apps are covered by the always-on inventory and render checks.
        if path.startswith('apps/') and not path.startswith('apps/media/romm/'):
            continue
        return True
    return False


def select(event, base):
    if event != 'pull_request' or not base:
        return True
    try:
        # No rename detection: both old and new paths must participate. Compare
        # the PR base with the checked-out merge result, not just its last commit.
        result = subprocess.run(
            ['git', 'diff', '--no-renames', '--name-only', '-z', base, 'HEAD', '--'],
            check=True, capture_output=True,
        )
    except subprocess.CalledProcessError:
        print('Cannot determine changed paths; running all integrations.', file=sys.stderr)
        return True
    paths = [os.fsdecode(path) for path in result.stdout.split(b'\0') if path]
    return integration_required(paths)


if __name__ == '__main__':
    required = select(os.environ.get('GITHUB_EVENT_NAME'), os.environ.get('PR_BASE_SHA'))
    print(f'integration={str(required).lower()}')
