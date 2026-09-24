"""Verify the versioned Core ML resource before invoking Xcode (stdlib only)."""
import hashlib
import json
from pathlib import Path


def verify(package: Path, checksums: dict[str, str]) -> None:
    if not checksums:
        raise ValueError("Model checksum manifest is empty")
    for relative, expected in checksums.items():
        path = package / relative
        if not path.is_file():
            raise ValueError(f"Missing model resource: {path}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise ValueError(f"Model resource checksum mismatch: {path}")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    try:
        verify(here.parents[1] / "FB-808/StemSeparator.mlpackage",
               json.loads((here / "model-checksums.json").read_text()))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print("Bundled stem model: all SHA-256 checksums match")
