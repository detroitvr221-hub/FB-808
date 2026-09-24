import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from verify_model import verify


class ModelVerificationTests(unittest.TestCase):
    def test_missing_and_corrupt_resources_fail(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            expected = {"weights.bin": hashlib.sha256(b"model weights").hexdigest()}
            with self.assertRaisesRegex(ValueError, "Missing"):
                verify(root, expected)
            (root / "weights.bin").write_bytes(b"version https://git-lfs.github.com/spec/v1")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                verify(root, expected)
            (root / "weights.bin").write_bytes(b"model weights")
            verify(root, expected)

    def test_empty_manifest_fails(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            verify(Path("."), {})
