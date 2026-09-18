#!/usr/bin/env python3
"""Explicit CI/local fixture download; never runs as part of zig build.

Pins reviewed from the v2.11.4 official release API; binary hashes were derived
from the verified archives. No live version discovery or system installation.
"""
import argparse
import hashlib
import io
import os
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request

VERSION = '2.11.4'
PINS = {
    ('Linux', 'x86_64'): ('linux_amd64', '527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9', 'b7105518e3ed1c0761f232e44fc09345535533c9cb0abf0e12809416c7ac64d9'),
    ('Linux', 'aarch64'): ('linux_arm64', '52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904', 'e1f904038fc11ca897ac5a12fdacfb2a7add02a8720c426d562a37f6fdad2afe'),
    ('Darwin', 'arm64'): ('mac_arm64', '9efb0af2d6cf09cfb5053c0e51721b9b3d4956d346234f39368d943d25a3c9a7', 'e9ebf99dfd4b72259debe1830c83e86c63fb89a88e28b4e7c5e78a35fa76c92d'),
    ('Darwin', 'x86_64'): ('mac_amd64', '34bc9e5cceee8d67844ef51da624f5b79e8d070f27236e050c3f0066a2dba534', '4900f5717695c2685e79a51fe4da87d897fd2feb4b19fd8c0c8ac425355e3cc9'),
}


def fetch(destination):
    name, archive_hash, binary_hash = PINS[(platform.system(), platform.machine())]
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError('Refusing a symlink destination')
    if destination.exists():
        if not destination.is_file() or hashlib.sha256(destination.read_bytes()).hexdigest() != binary_hash:
            raise ValueError('Existing fixture does not match its pin')
        return
    url = f'https://github.com/caddyserver/caddy/releases/download/v{VERSION}/caddy_{VERSION}_{name}.tar.gz'
    with urllib.request.urlopen(url, timeout=180) as response:
        archive = response.read(200_000_001)
    if len(archive) > 200_000_000 or hashlib.sha256(archive).hexdigest() != archive_hash:
        raise ValueError('Caddy archive checksum mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = tar.getmember('caddy')
        if not member.isfile() or member.size > 200_000_000:
            raise ValueError('Invalid Caddy archive member')
        binary = tar.extractfile(member).read()
    if hashlib.sha256(binary).hexdigest() != binary_hash:
        raise ValueError('Caddy binary checksum mismatch')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stage:
        name = stage.name
        try:
            stage.write(binary)
            stage.flush()
            os.chmod(name, 0o755)
            os.replace(name, destination)
        finally:
            if os.path.exists(name):
                os.unlink(name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    fetch(parser.parse_args().output)
