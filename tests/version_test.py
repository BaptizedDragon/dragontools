"""The compiled controller/helper and vendored crypto agree; no network."""
import json
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
values = []
for name in ('dragontool', 'dragontool-agent'):
    result = subprocess.run([str(ROOT/'zig-out/bin'/name), 'version', '--json'], capture_output=True, check=True)
    assert result.stderr == b''
    value = json.loads(result.stdout)
    assert value['mbedtls'] == value['minimum_approved_mbedtls'] == '4.2.0'
    assert value['zig'] == '0.16.0'
    assert value['tf_psa_crypto'] == '1.2.0'
    assert value['mbedtls_archive_sha256'] == '2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea'
    values.append(value)
assert values[0] == values[1]
print('PASS: controller/helper embedded version metadata and approved crypto pin.')

agent = ROOT/'zig-out/bin/dragontool-agent'
for payload in (b'', b'{', b'{"action":"arbitrary-command","args":["PRIVATE KEY sentinel"]}', b'x' * (512 * 1024 + 1)):
    result = subprocess.run([str(agent), 'internal', '--stdin'], input=payload, capture_output=True, timeout=10)
    assert result.returncode != 0 and not result.stdout and not result.stderr
print('PASS: malformed/bounded helper input fails without raw diagnostics or secret echo.')
