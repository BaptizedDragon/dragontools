#!/usr/bin/env python3
"""Explicit opt-in Linux fixture download using the existing production pins.

Never invoked by zig build/test. No version discovery or system installation.
Only the named regular archive member is extracted; both digests must match.
"""
import argparse
import hashlib
import io
from pathlib import Path
import platform
import re
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# (production component, local fixture name, upstream repo, archive name, member)
ARTIFACTS = (
    ('victoriametrics', 'victoria-metrics-prod', 'VictoriaMetrics/VictoriaMetrics', 'victoria-metrics-linux-{arch}-{version}.tar.gz', 'victoria-metrics-prod'),
    ('victorialogs', 'victoria-logs-prod', 'VictoriaMetrics/VictoriaLogs', 'victoria-logs-linux-{arch}-{version}.tar.gz', 'victoria-logs-prod'),
    ('vmalert', 'vmalert', 'VictoriaMetrics/VictoriaMetrics', 'vmutils-linux-{arch}-{version}.tar.gz', 'vmalert-prod'),
    ('vmagent', 'vmagent', 'VictoriaMetrics/VictoriaMetrics', 'vmutils-linux-{arch}-{version}.tar.gz', 'vmagent-prod'),
    ('vector', 'vector', 'vectordotdev/vector', 'vector-{bare}-{cpu}-unknown-linux-musl.tar.gz', './vector-{cpu}-unknown-linux-musl/bin/vector'),
    ('blackbox_exporter', 'blackbox_exporter', 'prometheus/blackbox_exporter', 'blackbox_exporter-{bare}.linux-{arch}.tar.gz', 'blackbox_exporter-{bare}.linux-{arch}/blackbox_exporter'),
    ('caddy', 'caddy', 'caddyserver/caddy', 'caddy_{bare}_linux_{arch}.tar.gz', 'caddy'),
)


def fetch(directory, arch):
    directory.mkdir(parents=True, exist_ok=True)
    cache = {}
    for component, name, repo, archive, member in ARTIFACTS:
        source = (ROOT / ('src/components/' + component + '.zig')).read_text()
        version = re.search(r'pub const version = "([v0-9.]+)";', source)[1]
        block = re.search(r'\.' + arch + r' => \.\{(.*?)\}', source, re.S)[1]
        archive_hash = re.search(r'\.archive_sha256 = "([a-f0-9]{64})"', block)[1]
        binary_hash = re.search(r'\.binary_sha256 = "([a-f0-9]{64})"', block)[1]
        path = directory / name
        if path.is_symlink():
            raise ValueError('Symlink fixture refused')
        if path.exists():
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != binary_hash:
                raise ValueError('Existing fixture pin mismatch: ' + name)
            continue
        fields = dict(version=version, bare=version.removeprefix('v'), arch=arch, cpu='aarch64' if arch == 'arm64' else 'x86_64')
        url = 'https://github.com/' + repo + '/releases/download/v' + fields['bare'] + '/' + archive.format(**fields)
        if url not in cache:
            with urllib.request.urlopen(url, timeout=180) as response:
                data = response.read(200_000_001)
            if len(data) > 200_000_000 or hashlib.sha256(data).hexdigest() != archive_hash:
                raise ValueError('Archive pin mismatch: ' + name)
            cache[url] = data
        data = cache[url]
        if hashlib.sha256(data).hexdigest() != archive_hash:
            raise ValueError('Shared archive pin mismatch')
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
            entry = tar.getmember(member.format(**fields))
            if not entry.isfile() or entry.size > 200_000_000:
                raise ValueError('Invalid regular archive member')
            binary = tar.extractfile(entry).read()
        if hashlib.sha256(binary).hexdigest() != binary_hash:
            raise ValueError('Binary pin mismatch: ' + name)
        path.write_bytes(binary); path.chmod(0o755)
    print('PASS: all seven Linux fixture binaries match production pins.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', choices=('arm64', 'amd64'), default='arm64' if platform.machine() in ('arm64', 'aarch64') else 'amd64')
    args = parser.parse_args()
    fetch(args.output, args.arch)
