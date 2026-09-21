#!/usr/bin/env python3
"""Safely archive stable Frigate media exports without deleting the source."""

import argparse
import hashlib
import json
import math
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


class IngestError(RuntimeError):
    pass


def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise IngestError(f"validation failed ({args[0]}): {result.stderr.strip()}")
    return result.stdout


def validate(path):
    kind = run(["ffprobe", "-v", "error", "-show_entries", "format=format_name,duration",
                "-show_entries", "stream=codec_type", "-of", "json", str(path)])
    try:
        info = json.loads(kind)
    except json.JSONDecodeError as exc:
        raise IngestError(f"invalid media probe for {path.name}") from exc
    streams = info.get("streams", [])
    if any(stream.get("codec_type") == "video" for stream in streams):
        try:
            duration = float(info.get("format", {}).get("duration", 0))
        except (TypeError, ValueError):
            duration = 0
        if math.isfinite(duration) and duration > 0:
            return "video"
        format_names = set(info.get("format", {}).get("format_name", "").split(","))
        if format_names & {"image2", "png_pipe", "jpeg_pipe", "webp_pipe", "bmp_pipe", "tiff_pipe"}:
            run(["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-f", "null", "-"])
            return "image"
        raise IngestError(f"video has no positive duration: {path.name}")
    # Decode a still image completely; ffprobe alone accepts truncated files.
    run(["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-f", "null", "-"])
    return "image"


def identity(st):
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.digest()


def digest_hex(path):
    return digest(path).hex()


def write_inventory(destination, copied, unchanged):
    inventory_path = Path(destination) / ".ingestion-inventory.json"
    try:
        existing = os.lstat(inventory_path)
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISREG(existing.st_mode):
            raise IngestError("existing archival inventory is not a regular file")
    records = []
    for entry in sorted(os.scandir(destination), key=lambda item: os.fsencode(item.name)):
        if entry.name == ".ingestion-inventory.json":
            continue
        st = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(st.st_mode):
            raise IngestError(f"unexpected non-file in archive: {entry.name!r}")
        path = Path(destination) / entry.name
        validate(path)
        records.append({"name": entry.name, "size": st.st_size,
                        "mtime_ns": st.st_mtime_ns, "sha256": digest_hex(path)})
    document = {"schema": 1, "captured_at": datetime.now(timezone.utc).isoformat(),
                "copied": copied, "unchanged": unchanged, "deferred": 0,
                "failed": 0, "files": records}
    fd, temp = tempfile.mkstemp(prefix=".frigate-ingest-inventory-", suffix=".tmp", dir=destination)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(document, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, 0o640)
        os.replace(temp, inventory_path)
        directory_fd = os.open(destination, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def ingest(source, destination):
    src = Path(source)
    dst = Path(destination)
    if not src.is_dir() or src.is_symlink():
        raise IngestError("source export directory is missing, inaccessible, or a symlink")
    if not dst.is_dir() or dst.is_symlink():
        raise IngestError("destination directory is missing, inaccessible, or a symlink")
    copied = unchanged = deferred = failed = 0
    failures = []

    # Clear only our private temporary-name pattern. Any interruption leaves the
    # init container failed; this cleanup makes retries deterministic.
    for entry in os.scandir(dst):
        if entry.name.startswith(".frigate-ingest-") and entry.name.endswith(".tmp"):
            if entry.is_file(follow_symlinks=False):
                os.unlink(entry.path)
            else:
                raise IngestError(f"unexpected object using temporary name: {entry.name!r}")

    entries = sorted(os.scandir(src), key=lambda item: os.fsencode(item.name))
    if not entries:
        print("empty export directory; no files to ingest")
    for entry in entries:
        name = entry.name
        try:
            if name == ".ingestion-inventory.json" or name.startswith(".frigate-ingest-"):
                raise IngestError("filename is reserved for ingestion metadata or temporary files")
            # Reject control chars and all path separators; names stay a single
            # filesystem component and are always passed as argv, never shell text.
            if name in (".", "..") or "/" in name or "\\" in name or any(ord(c) < 32 for c in name):
                raise IngestError("unsafe filename")
            st = entry.stat(follow_symlinks=False)
            if not stat.S_ISREG(st.st_mode):
                raise IngestError("not a regular non-symlink file")
            src_path = src / name
            out = dst / name
            temp_fd, temp_name = tempfile.mkstemp(prefix=".frigate-ingest-", suffix=".tmp", dir=dst)
            os.close(temp_fd)
            try:
                source_fd = os.open(src_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                before_stat = os.fstat(source_fd)
                before = identity(before_stat)
                if not stat.S_ISREG(before_stat.st_mode):
                    os.close(source_fd)
                    raise IngestError("source changed to a non-regular file")
                if before != identity(st):
                    os.close(source_fd)
                    deferred += 1
                    os.unlink(temp_name)
                    continue
                with os.fdopen(source_fd, "rb", buffering=0) as reader, open(temp_name, "wb", buffering=0) as writer:
                    shutil.copyfileobj(reader, writer, 1024 * 1024)
                    os.fsync(writer.fileno())
                after = identity(os.stat(src_path, follow_symlinks=False))
                if before != after:
                    deferred += 1
                    os.unlink(temp_name)
                    continue
                validate(Path(temp_name))
                os.chmod(temp_name, 0o640)
                try:
                    # link(2) publishes the fully written inode atomically and
                    # refuses to replace an existing name.
                    os.link(temp_name, out, follow_symlinks=False)
                except FileExistsError:
                    if not stat.S_ISREG(os.lstat(out).st_mode):
                        raise IngestError("destination collision is not a regular file")
                    if digest(Path(temp_name)) != digest(out):
                        raise IngestError("different content already exists at destination")
                    unchanged += 1
                else:
                    copied += 1
                    directory_fd = os.open(dst, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
                    try:
                        os.fsync(directory_fd)
                    finally:
                        os.close(directory_fd)
                os.unlink(temp_name)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)
        except (OSError, IngestError) as exc:
            failed += 1
            failures.append(f"{name!r}: {exc}")
            print(f"failed {name!r}: {exc}", file=sys.stderr)
    if deferred or failed:
        print(f"copied={copied} unchanged={unchanged} deferred={deferred} failed={failed}")
        detail = "; ".join(failures[:5])
        raise IngestError(f"{deferred} export(s) deferred and {failed} failed; backup withheld" + (f": {detail}" if detail else ""))
    try:
        write_inventory(dst, copied, unchanged)
    except (OSError, IngestError) as exc:
        print(f"copied={copied} unchanged={unchanged} deferred=0 failed=1", file=sys.stderr)
        raise IngestError(f"archive inventory failed; backup withheld: {exc}") from exc
    print(f"copied={copied} unchanged={unchanged} deferred=0 failed=0")
    return copied, unchanged, deferred, failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", nargs="?", default="/data/frigate-exports")
    parser.add_argument("destination", nargs="?", default="/data/vault/frigate-exports")
    args = parser.parse_args()
    try:
        ingest(args.source, args.destination)
    except (OSError, IngestError) as exc:
        print(f"frigate-ingest: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
