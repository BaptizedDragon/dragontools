#!/usr/bin/env python3
"""Explicit maintainer/CI release check. Never called by installation or verification."""
import json
import re
import urllib.request
from pathlib import Path
source = (Path(__file__).resolve().parents[1] / 'src/pki/mbedtls.zig').read_text()
pin = re.search(r'pub const version = "([0-9.]+)";', source).group(1)
request = urllib.request.Request('https://api.github.com/repos/Mbed-TLS/mbedtls/releases?per_page=100', headers={'Accept':'application/vnd.github+json','User-Agent':'DragonTools-dependency-maintenance'})
with urllib.request.urlopen(request, timeout=30) as response:
    releases = json.load(response)
versions = []
for item in releases:
    if item['prerelease'] or item['draft']:
        continue
    match = re.fullmatch(r'mbedtls-(\d+)\.(\d+)\.(\d+)', item['tag_name'])
    if match:
        versions.append(tuple(map(int, match.groups())))
if not versions:
    raise SystemExit('Upstream release check unavailable: no stable versions in response.')
latest = max(versions)
if latest > tuple(map(int, pin.split('.'))):
    raise SystemExit('Maintenance required: newer stable Mbed TLS available: ' + '.'.join(map(str, latest)) + '. Review release/security notes; no dependency was changed.')
print('Pinned Mbed TLS matches the latest stable version observed by this check. No advisory assessment or dependency update was performed.')
