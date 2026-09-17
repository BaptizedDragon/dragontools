"""Observe pinned Vector filesystem capacity/network contract in isolated Linux.

No SSH/systemd validation. Run in an isolated no-network container with reviewed
Vector at /fixture/vector. Only a localhost ephemeral exporter is created.
"""
import hashlib
import http.client
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
binary = Path('/fixture/vector')
assert hashlib.sha256(binary.read_bytes()).hexdigest() in (ROOT / 'src/components/vector.zig').read_text()
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    config = dict(data_dir=temporary, api=dict(enabled=False), sources=dict(host=dict(type='host_metrics', namespace='host', collectors=['filesystem', 'network'], scrape_interval_secs=1)), sinks=dict(output=dict(type='prometheus_exporter', inputs=['host'], address='127.0.0.1:9918')))
    (base / 'vector.json').write_text(json.dumps(config))
    process = subprocess.Popen([str(binary), '--config', str(base / 'vector.json')], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 10
        names = ('host_filesystem_free_bytes', 'host_network_receive_bytes_total', 'host_network_transmit_bytes_total')
        while True:
            body = ''
            try:
                connection = http.client.HTTPConnection('127.0.0.1', 9918, timeout=1)
                connection.request('GET', '/metrics')
                response = connection.getresponse()
                assert response.status == 200
                body = response.read(1024 * 1024).decode()
                connection.close()
            except (OSError, AssertionError):
                pass
            lines = [line for line in body.splitlines() if any(line.startswith(name + '{') for name in names) and ('mountpoint="/"' in line or 'device="lo"' in line)]
            if len(lines) == len(names):
                break
            if time.monotonic() >= deadline:
                raise AssertionError('capacity/network exporter samples did not arrive')
            time.sleep(min(0.5, deadline - time.monotonic()))
        for name in names:
            declaration = next(line for line in body.splitlines() if line.startswith('# TYPE ' + name + ' '))
            print(declaration)
            line = next(line for line in lines if line.startswith(name + '{'))
            print(re.sub(r'host="[^"]*"', 'host="fixture-host"', line))
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
