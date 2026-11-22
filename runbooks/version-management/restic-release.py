#!/usr/bin/env python3
"""Prepare a custom Restic image release without hand edits.

  version --base REF   When the Containerfile differs from REF but VERSION does
                       not, write the next release: <upstream>-1 for a new
                       restic/restic version, otherwise the next revision.
  next-revision        Increment VERSION's revision (its tag is already taken).
  pin IMAGE@DIGEST     Point every custom image reference that image_policy.py
                       finds at the published release.

The restic-backup-image workflow runs these on Renovate branches; the attended
manual workflow can use the same commands.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import image_policy  # noqa: E402

REPOSITORY = "ghcr.io/sandersch/restic-backup"
CONTAINERFILE = Path("containers/restic-backup/Containerfile")
VERSION_FILE = Path("containers/restic-backup/VERSION")
FROM_RE = re.compile(r"^FROM restic/restic:(?P<upstream>\d+\.\d+\.\d+)@sha256:[0-9a-f]{64}$", re.MULTILINE)
VERSION_RE = re.compile(r"^(?P<upstream>\d+\.\d+\.\d+)-(?P<revision>[1-9]\d*)$")
PIN_RE = re.compile(rf"^{re.escape(REPOSITORY)}:(?P<tag>[^@\s]+)@sha256:[0-9a-f]{{64}}$")


def parse_version(text: str) -> tuple[str, int]:
    match = VERSION_RE.fullmatch(text.strip())
    if not match:
        raise SystemExit(f"malformed VERSION {text.strip()!r}")
    return match["upstream"], int(match["revision"])


def upstream_of(containerfile: str) -> str:
    match = FROM_RE.search(containerfile)
    if not match:
        raise SystemExit(f"{CONTAINERFILE} must pin restic/restic by exact release and digest")
    return match["upstream"]


def git_show(root: Path, ref: str, path: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(root), "show", f"{ref}:{path.as_posix()}"],
        check=True, capture_output=True, text=True,
    ).stdout


def version(root: Path, base: str) -> str:
    containerfile = (root / CONTAINERFILE).read_text()
    current = (root / VERSION_FILE).read_text().strip()
    upstream = upstream_of(containerfile)
    base_version = git_show(root, base, VERSION_FILE).strip()
    if containerfile == git_show(root, base, CONTAINERFILE) or current != base_version:
        # Nothing to release, or VERSION was already bumped on this branch.
        if parse_version(current)[0] != upstream:
            raise SystemExit(f"VERSION {current!r} does not match restic/restic {upstream}")
        return current
    base_upstream, base_revision = parse_version(base_version)
    revision = base_revision + 1 if base_upstream == upstream else 1
    new = f"{upstream}-{revision}"
    (root / VERSION_FILE).write_text(new + "\n")
    return new


def next_revision(root: Path) -> str:
    upstream, revision = parse_version((root / VERSION_FILE).read_text())
    new = f"{upstream}-{revision + 1}"
    (root / VERSION_FILE).write_text(new + "\n")
    return new


def pin(root: Path, ref: str) -> list[str]:
    match = PIN_RE.fullmatch(ref)
    current = (root / VERSION_FILE).read_text().strip()
    if not match or match["tag"] != current:
        raise SystemExit(f"expected {REPOSITORY}:{current}@sha256:<64 hex>, got {ref!r}")
    references, _ = image_policy.scan(root)
    edits: dict[Path, set[tuple[int, str]]] = {}
    for reference in references:
        # shell-indirect lines name $RECOVERY_IMAGE; its definition is edited.
        if reference.repository == REPOSITORY and reference.source_type != "shell-indirect":
            edits.setdefault(reference.path, set()).add((reference.line, reference.raw))
    if not edits:
        raise SystemExit(f"no {REPOSITORY} references found")
    for relative, lines in sorted(edits.items()):
        path = root / relative
        text = path.read_text().splitlines(keepends=True)
        for number, raw in lines:
            if text[number - 1].count(raw) != 1:
                raise SystemExit(f"{relative}:{number}: cannot locate {raw!r} exactly once")
            text[number - 1] = text[number - 1].replace(raw, ref)
        path.write_text("".join(text))
    return sorted(str(path) for path in edits)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version").add_argument("--base", required=True)
    commands.add_parser("next-revision")
    commands.add_parser("pin").add_argument("ref")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "version":
        print(version(root, args.base))
    elif args.command == "next-revision":
        print(next_revision(root))
    else:
        for path in pin(root, args.ref):
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
