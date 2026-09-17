#!/usr/bin/env python3
"""Audit an already-downloaded pinned blackbox archive; never extract or execute."""
import argparse
import hashlib
from pathlib import Path
import re
import tarfile


def audit(archive, arch):
    source = (Path(__file__).resolve().parents[2] /
              "src/components/blackbox_exporter.zig").read_text()
    version = re.search(r'pub const version = "([0-9.]+)";', source).group(1)
    pin = re.search(r"\." + arch + r" => \.\{(.*?)\n        \},", source, re.S).group(1)
    hashes = [re.search(r"\." + name + r' = "([0-9a-f]{64})"', pin).group(1)
              for name in ("archive_sha256", "binary_sha256")]
    with archive.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == hashes[0], "archive checksum"
    root = f"blackbox_exporter-{version}.linux-{arch}"
    expected = {
        root: (True, 0o755),
        root + "/blackbox_exporter": (False, 0o755),
        root + "/blackbox.yml": (False, 0o644),
        root + "/LICENSE": (False, 0o644),
        root + "/NOTICE": (False, 0o644),
    }
    seen = set()
    with tarfile.open(archive, "r:gz") as contents:
        for member in contents:
            assert member.name in expected and member.name not in seen, "archive member"
            seen.add(member.name)
            directory, mode = expected[member.name]
            assert member.isdir() if directory else member.isfile(), "member type"
            assert member.mode == mode, "member mode"
            assert 0 <= member.size <= 64 * 1024 * 1024, "member size"
            if member.name == root + "/blackbox_exporter":
                with contents.extractfile(member) as stream:
                    assert hashlib.file_digest(stream, "sha256").hexdigest() == hashes[1], "binary checksum"
    assert seen == set(expected), "incomplete archive"
    print(f"PASS: blackbox_exporter {version} linux-{arch} archive and binary pins; no code executed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("arch", choices=("amd64", "arm64"))
    args = parser.parse_args()
    audit(args.archive, args.arch)
