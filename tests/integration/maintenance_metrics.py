"""Isolated pinned Vector + native helper contract. No SSH/systemd claim.

Provide --vector, --fixture (test-only native certificate/maintenance factory),
--agent (production agent), and --config (production-rendered apps-vector.yaml).
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
for name in ('vector', 'fixture', 'agent', 'config'):
    p.add_argument('--' + name, type=Path, required=True)
a = p.parse_args()
assert hashlib.sha256(a.vector.read_bytes()).hexdigest() in (ROOT/'src/components/vector.zig').read_text()
subprocess.run([str(a.vector), 'validate', '--no-environment', '--skip-healthchecks', str(a.config)], check=True)
actual = subprocess.run([str(a.agent), 'maintenance', 'metrics'], capture_output=True, check=True)
assert actual.stderr == b''
observed = json.loads(actual.stdout)
assert observed['dragontool_agent_version_info'] == 1
source = a.config.read_text()
# Exercise the exact production exec and log_to_metric blocks. Replace only
# fixture executable, capture interval, and network sink with a local file.
exec_source = source.split('  maintenance_exec:\n', 1)[1].split('  journal:\n', 1)[0]
exec_source = exec_source.replace('[/opt/dragontools/agent/current/dragontool-agent, maintenance, metrics]', '[' + str(a.fixture) + ', maintenance]').replace('exec_interval_secs: 60', 'exec_interval_secs: 1')
transform = source.split('transforms:\n', 1)[1].split('  metrics_identity_0:', 1)[0]
identity = source.split('  metrics_identity_0:', 1)[1].split('  metrics_identity_1:', 1)[0].replace('inputs: [host, internal, maintenance]', 'inputs: [maintenance]')
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    config = base/'vector.yaml'
    output = base/'metrics.jsonl'
    config.write_text('data_dir: ' + str(base) + '\napi:\n  enabled: false\nsources:\n  maintenance_exec:\n' + exec_source + 'transforms:\n' + transform + '  metrics_identity_0:' + identity + 'sinks:\n  capture:\n    type: file\n    inputs: [metrics_identity_0]\n    path: ' + str(output) + '\n    encoding:\n      codec: json\n')
    with (base/'errors').open('w+') as errors:
        process = subprocess.Popen([str(a.vector), '--config', str(config)], stdout=subprocess.DEVNULL, stderr=errors)
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise AssertionError('Vector exited')
                if output.exists() and len(output.read_text().splitlines()) >= 7:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('No bounded maintenance metrics')
        finally:
            process.terminate()
            process.wait(timeout=5)
        errors.seek(0)
        assert 'ERROR' not in errors.read()
    events = [json.loads(line) for line in output.read_text().splitlines()]
    expected = {'dragontool_host_updates_pending': 12, 'dragontool_host_security_updates_pending': 3, 'dragontool_host_reboot_required': 1, 'dragontool_host_automatic_security_updates_enabled': 1, 'dragontool_host_automatic_security_updates_healthy': 1, 'dragontool_host_package_metadata_fresh': 1, 'dragontool_agent_version_info': 1}
    assert {event['name'] for event in events} == set(expected)
    for event in events:
        assert event['gauge']['value'] == expected[event['name']]
        assert event.get('namespace') in (None, '')
        assert event['tags']['host'] == 'dt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        assert event['tags']['application'] == 'doers'
        assert event['tags']['environment'] == 'production'
        assert event['tags']['agent'] == 'vector'
        assert set(event['tags']) <= {'host', 'application', 'environment', 'agent', 'version'}
    for name, value in sorted(expected.items()):
        print(name + '{agent="vector",application="doers",environment="production",host="dt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' + (',version="0.1.0-fixture"' if name.endswith('version_info') else '') + '} ' + str(value))
print('PASS: actual native metrics decoded by pinned Vector; local process fixture only.')
