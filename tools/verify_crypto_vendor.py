#!/usr/bin/env python3
"""Offline vendor integrity guard; optional comparison to the official archive."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor/mbedtls"


def check(archive=None):
    metadata = (ROOT / "src/pki/mbedtls.zig").read_text()
    version = re.search(r'pub const version = "([0-9.]+)";', metadata)[1]
    expected_archive = re.search(r'pub const archive_sha256 = "([0-9a-f]{64})";', metadata)[1]
    manifest = json.loads((VENDOR / "SHA256FILES.json").read_text())
    actual_names = {str(p.relative_to(VENDOR)) for p in VENDOR.rglob("*") if p.is_file()}
    if actual_names != set(manifest) | {"README.md", "SHA256FILES.json"}:
        raise ValueError("Unexpected or missing vendored file")
    for name, expected in manifest.items():
        path = VENDOR / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("Vendored file integrity mismatch")
    if archive:
        raw = Path(archive).read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected_archive:
            raise ValueError("Official archive integrity mismatch")
        with tarfile.open(archive, "r:bz2") as source:
            for name, expected in manifest.items():
                member = source.getmember(f"mbedtls-{version}/{name}")
                if not member.isfile() or hashlib.sha256(source.extractfile(member).read()).hexdigest() != expected:
                    raise ValueError("Vendored source differs from official archive")
    print(f"Mbed TLS {version}: {len(manifest)} unmodified vendored files verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive")
    check(parser.parse_args().archive)
