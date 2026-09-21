#!/usr/bin/env python3
"""Verify an extracted Frigate archive against its in-snapshot inventory."""

import hashlib
import json
import os
import stat
import sys
from pathlib import Path

import ingest


def verify(directory):
    root = Path(directory)
    inventory_path = root / ".ingestion-inventory.json"
    if inventory_path.is_symlink() or not inventory_path.is_file():
        raise ingest.IngestError("snapshot has no regular archival inventory")
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    if inventory.get("schema") != 1:
        raise ingest.IngestError("unsupported inventory schema")
    expected = {item["name"]: item for item in inventory.get("files", [])}
    observed_names = set()
    for entry in os.scandir(root):
        if entry.name == ".ingestion-inventory.json":
            continue
        st = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(st.st_mode):
            raise ingest.IngestError(f"restored object is not a regular file: {entry.name!r}")
        observed_names.add(entry.name)
    if observed_names != set(expected):
        missing = sorted(set(expected) - observed_names)
        extra = sorted(observed_names - set(expected))
        raise ingest.IngestError(f"inventory path mismatch; missing={missing!r} extra={extra!r}")
    for name, expected_item in expected.items():
        path = root / name
        st = os.stat(path, follow_symlinks=False)
        if st.st_size != expected_item["size"]:
            raise ingest.IngestError(f"size mismatch: {name!r}")
        if ingest.digest_hex(path) != expected_item["sha256"]:
            raise ingest.IngestError(f"SHA-256 mismatch: {name!r}")
        kind = ingest.validate(path)
        print(f"validated {kind} {name!r} size={st.st_size} sha256={expected_item['sha256']}")
    print(f"restore validation passed: {len(expected)} files")


if __name__ == "__main__":
    try:
        verify(sys.argv[1])
    except (OSError, ValueError, ingest.IngestError, KeyError) as exc:
        print(f"restore validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
