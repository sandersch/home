import os
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ingest
import verify_restore


class IngestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.destination = self.root / "destination"
        self.source.mkdir()
        self.destination.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def video(self, name="clip.mp4"):
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=32x32:d=1",
                        "-c:v", "mpeg4", str(self.source / name)], check=True)

    def image(self, name="still.png"):
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=16x16",
                        "-frames:v", "1", str(self.source / name)], check=True)

    def test_valid_video_and_image_and_repeat(self):
        self.video("clip with spaces.mp4")
        self.image()
        self.assertEqual(ingest.ingest(self.source, self.destination), (2, 0, 0, 0))
        self.assertEqual(ingest.ingest(self.source, self.destination), (0, 2, 0, 0))
        self.assertTrue((self.destination / ".ingestion-inventory.json").is_file())

    def test_source_deletion_does_not_delete_archive(self):
        self.image()
        ingest.ingest(self.source, self.destination)
        (self.source / "still.png").unlink()
        self.assertTrue((self.destination / "still.png").is_file())
        self.assertEqual(ingest.ingest(self.source, self.destination), (0, 0, 0, 0))
        inventory = __import__("json").loads((self.destination / ".ingestion-inventory.json").read_text())
        self.assertEqual([item["name"] for item in inventory["files"]], ["still.png"])

    def test_changing_source_is_deferred_and_blocks_backup(self):
        self.image()
        real_copy = shutil.copyfileobj

        def mutate(src, dst, length):
            real_copy(src, dst, length)
            with (self.source / "still.png").open("ab") as out:
                out.write(b"changed")

        with patch.object(ingest.shutil, "copyfileobj", mutate):
            with self.assertRaisesRegex(ingest.IngestError, "deferred"):
                ingest.ingest(self.source, self.destination)
        self.assertFalse((self.destination / "still.png").exists())

    def test_malformed_media_fails_without_publishing(self):
        (self.source / "bad.mp4").write_bytes(b"not media")
        with self.assertRaises(ingest.IngestError):
            ingest.ingest(self.source, self.destination)
        self.assertFalse((self.destination / "bad.mp4").exists())

    def test_different_content_collision_fails(self):
        self.image()
        (self.destination / "still.png").write_bytes(b"different")
        with self.assertRaisesRegex(ingest.IngestError, "different content"):
            ingest.ingest(self.source, self.destination)

    def test_symlink_is_rejected(self):
        target = self.root / "outside"
        target.write_text("not media")
        (self.source / "link.mp4").symlink_to(target)
        with self.assertRaises(ingest.IngestError):
            ingest.ingest(self.source, self.destination)

    def test_inaccessible_or_missing_source_fails(self):
        self.image()
        os.chmod(self.source, 0)
        try:
            with self.assertRaises((PermissionError, ingest.IngestError)):
                ingest.ingest(self.source, self.destination)
        finally:
            os.chmod(self.source, 0o755)
        with self.assertRaises(ingest.IngestError):
            ingest.ingest(self.root / "missing", self.destination)

    def test_destination_write_failure_fails(self):
        self.image()
        os.chmod(self.destination, 0o555)
        try:
            with self.assertRaises((PermissionError, ingest.IngestError)):
                ingest.ingest(self.source, self.destination)
        finally:
            os.chmod(self.destination, 0o755)
        with patch("ingest.tempfile.mkstemp", side_effect=PermissionError("denied")):
            with self.assertRaises(ingest.IngestError):
                ingest.ingest(self.source, self.destination)

    def test_disk_exhaustion_leaves_no_published_or_temp_file(self):
        self.image()

        def full(src, dst, length):
            dst.write(src.read(16))
            raise OSError("No space left on device")

        with patch.object(ingest.shutil, "copyfileobj", full):
            with self.assertRaises(ingest.IngestError):
                ingest.ingest(self.source, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_interruption_does_not_publish_partial_file_or_inventory(self):
        self.image()

        def interrupt(src, dst, length):
            dst.write(src.read(32))
            raise KeyboardInterrupt()

        with patch.object(ingest.shutil, "copyfileobj", interrupt):
            with self.assertRaises(KeyboardInterrupt):
                ingest.ingest(self.source, self.destination)
        self.assertFalse((self.destination / "still.png").exists())
        self.assertFalse((self.destination / ".ingestion-inventory.json").exists())
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_interrupted_copy_temp_is_cleaned_before_next_success(self):
        self.image()
        stale = self.destination / ".frigate-ingest-interrupted.tmp"
        stale.write_bytes(b"partial")
        self.assertEqual(ingest.ingest(self.source, self.destination), (1, 0, 0, 0))
        self.assertFalse(stale.exists())

    def test_empty_is_distinct_from_missing(self):
        self.assertEqual(ingest.ingest(self.source, self.destination), (0, 0, 0, 0))
        self.source.rmdir()
        with self.assertRaises(ingest.IngestError):
            ingest.ingest(self.source, self.destination)

    def test_restore_inventory_detects_change_and_validates_media(self):
        self.image()
        ingest.ingest(self.source, self.destination)
        verify_restore.verify(self.destination)
        (self.destination / "still.png").write_bytes(b"changed")
        with self.assertRaises(ingest.IngestError):
            verify_restore.verify(self.destination)

    def test_shell_guard_locked_wrong_mount_and_invalid_sentinel_fixtures(self):
        script = Path(__file__).with_name("run-ingest.sh")
        # The checked-in ConfigMap script must remain byte-identical to the tested guard.
        repository = next((parent for parent in Path(__file__).parents
                           if (parent / "infrastructure/monitoring/frigate-ingest-run.sh").exists()), None)
        if repository:
            configmap_copy = repository / "infrastructure/monitoring/frigate-ingest-run.sh"
            self.assertEqual(script.read_bytes(), configmap_copy.read_bytes())
        vault = self.root / "vault"
        source = self.root / "exports"
        vault.mkdir()
        source.mkdir()
        source_record = f"2 1 8:2 /exports {source} ro - ext4 /dev/mapper/hoardvg-frigate ro\n"

        def run(record, **extra):
            mountinfo = self.root / "mountinfo"
            mountinfo.write_text(record + source_record)
            env = os.environ | {
                "VAULT_PATH": str(vault), "SOURCE_PATH": str(source),
                "MOUNTINFO_PATH": str(mountinfo), "EXPECTED_SENTINEL_METADATA": f"{os.getuid()}:{os.getgid()}:444",
                "COPIER_BIN": "/bin/true", **extra,
            }
            return subprocess.run(["/bin/sh", str(script)], env=env, capture_output=True, text=True)

        locked = f"1 0 8:1 /mnt/vault {vault} rw - ext4 /dev/mapper/vg0-root rw\n"
        result = run(locked, SOURCE_PATH=str(self.root / "does-not-exist"))
        self.assertEqual(result.returncode, 0)
        self.assertIn("locked", result.stdout)

        wrong = f"1 0 8:1 / {vault} rw - xfs /dev/mapper/unexpected rw\n"
        self.assertNotEqual(run(wrong).returncode, 0)

        active = f"1 0 8:1 / {vault} rw - ext4 /dev/mapper/vault rw\n"
        (vault / ".vault-sentinel").write_text("invalid\n")
        os.chmod(vault / ".vault-sentinel", 0o444)
        result = run(active)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sentinel", result.stderr)

        os.chmod(vault / ".vault-sentinel", 0o644)
        (vault / ".vault-sentinel").write_text(
            f"vault-contract-version=3\nfilesystem-uuid=d926696b-2f04-45cb-805c-40af30dc156d\n")
        os.chmod(vault / ".vault-sentinel", 0o444)
        bad_source = source_record.replace("ext4", "xfs")
        (self.root / "mountinfo").write_text(active + bad_source)
        env = os.environ | {
            "VAULT_PATH": str(vault), "SOURCE_PATH": str(source),
            "MOUNTINFO_PATH": str(self.root / "mountinfo"), "EXPECTED_SENTINEL_METADATA": f"{os.getuid()}:{os.getgid()}:444",
            "COPIER_BIN": "/bin/true",
        }
        result = subprocess.run(["/bin/sh", str(script)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Frigate source", result.stderr)


if __name__ == "__main__":
    unittest.main()
