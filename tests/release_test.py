#!/usr/bin/env python3
"""Local release packaging tests. No GitHub token or publishing required."""
import hashlib
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("package_release", Path(__file__).resolve().parents[1] / "tools/package_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_six_portable_archives_and_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "binary"
            binary.write_bytes(b"binary fixture\x00\xff")
            output = root / "release"
            for target in release.TARGETS:
                path = release.package("v0.1.0-test.1", target, binary, output)
                original = path.read_bytes()
                release.package("v0.1.0-test.1", target, binary, output)
                self.assertEqual(original, path.read_bytes())
                with tarfile.open(path) as archive:
                    self.assertEqual(archive.getnames(), ["dragontool", "LICENSE", "README.md", "THIRD_PARTY_NOTICES", "MbedTLS-LICENSE", "TF-PSA-Crypto-LICENSE"])
                    self.assertEqual(archive.getmember("dragontool").mode, 0o755)
                    self.assertEqual(archive.extractfile("dragontool").read(), binary.read_bytes())
            for target in ("aarch64-linux", "x86_64-linux"):
                path = release.package("v0.1.0-test.1", target, binary, output, agent=True)
                with tarfile.open(path) as archive:
                    self.assertEqual(archive.getmember("dragontool-agent").mode, 0o755)
                    self.assertIn("MbedTLS-LICENSE", archive.getnames())
            release.checksums("v0.1.0-test.1", output)
            lines = (output / "SHA256SUMS").read_text().splitlines()
            self.assertEqual(len(lines), 6)
            for line in lines:
                digest, name = line.split("  ")
                self.assertEqual(digest, hashlib.sha256((output / name).read_bytes()).hexdigest())
            next(output.glob("*.tar.gz")).unlink()
            with self.assertRaises(ValueError):
                release.checksums("v0.1.0-test.1", output)

    def test_unsafe_or_ambiguous_version_rejected(self):
        for value in ["latest", "../tag", "v1", "1.2.3/other", "v1.2.3\n", "01.2.3", "1.2.3$(id)"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.version(value)


if __name__ == "__main__":
    unittest.main()
