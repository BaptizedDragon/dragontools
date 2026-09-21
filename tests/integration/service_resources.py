"""Isolated native cgroup -> pinned Vector -> VM and dashboard LogsQL contract.

Filesystem fixtures replace systemd/cgroupfs; the transport here is loopback.
Run in a disposable network namespace with no external network, never a station.
Arguments: pinned binaries, native test helper, rendered Doers directory.
"""
import http.client
import json
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main(binaries, helper, rendered):
    scope = {'__name__': 'fixture'}
    for filename in ('model', 'signals'):
        exec(compile((ROOT / 'src/monitoring/dashboards' / (filename + '.py')).read_text(), filename, 'exec'), scope)
    signals = {'__name__': 'fixture'}
    exec(compile((ROOT / 'src/monitoring/agents/signals.py').read_text(), 'signals', 'exec'), signals)
    config = json.loads((rendered / 'doers-station.json').read_text())
    config.pop('alerts')
    registration = json.loads((rendered / 'doers-registration.json').read_text())
    processes = []
    with tempfile.TemporaryDirectory(prefix='dragontools-service-metrics-') as tmp:
        root = Path(tmp)
        with (root / 'process.log').open('wb') as log:
            def start(argv):
                process = subprocess.Popen(argv, stdout=log, stderr=log)
                processes.append(process)
                return process
            def request(port, path, body=None):
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
                try:
                    connection.request('GET' if body is None else 'POST', path, body)
                    response = connection.getresponse()
                    data = response.read()
                    assert response.status in (200, 204), (response.status, data[:500])
                    return data
                finally:
                    connection.close()
            def wait(check):
                deadline = time.monotonic() + 45
                last = None
                while time.monotonic() < deadline:
                    assert all(p.poll() is None for p in processes), (root / 'process.log').read_text()[-5000:]
                    try:
                        value = check()
                        if value:
                            return value
                    except (ConnectionError, TimeoutError, OSError) as error:
                        last = error
                    time.sleep(.5)
                raise AssertionError('Fixture readiness timeout: ' + str(last) + '\n' + (root / 'process.log').read_text()[-5000:])
            def query(expression):
                return json.loads(request(8428, '/api/v1/query?' + urllib.parse.urlencode({'query': expression})))['data']['result']
            def group(path, cpu):
                destination = root / 'cgroup' / path
                destination.mkdir(parents=True, exist_ok=True)
                for name, data in {'cpu.stat': f'usage_usec {cpu}\nuser_usec 1000000\nsystem_usec 500000\nnr_throttled 3\nthrottled_usec 20000\n',
                                   'memory.current': '123456\n', 'memory.peak': '234567\n', 'memory.max': '1048576\n',
                                   'pids.current': '14\n', 'pids.max': '256\n', 'memory.events': 'oom 4\noom_kill 1\n',
                                   'io.stat': '8:0 rbytes=100 wbytes=200\n8:1 rbytes=300 wbytes=400\n'}.items():
                    (destination / name).write_text(data)
                (root / 'cgroup/unit.properties').write_text('Id=doers.service\nActiveState=active\nControlGroup=/' + path + '\n')
            try:
                group('system.slice/doers.service', 1500000)
                (root / 'cgroup/cgroup.controllers').write_text('cpu memory pids io\n')
                output = subprocess.check_output([str(helper), 'service-metrics', str(root / 'cgroup')])
                events = [json.loads(line) for line in output.splitlines()]
                assert len(events) == 16, events
                assert all(set(e['tags']) == {'application', 'environment', 'host', 'service'} and e['kind'] == 'absolute' for e in events)
                # Keep production exec/JSON/all_metrics configuration. Only the
                # injected cgroup reader, interval and transport differ here.
                production = (rendered / 'doers-vector.yaml').read_text()
                source = re.search(r'^  service_0_0:\n.*?(?=^  \w|^transforms:)', production, re.S | re.M)[0]
                source = re.sub(r'    command: .*', '    command: ' + json.dumps([str(helper), 'service-metrics', str(root / 'cgroup')]), source)
                source = source.replace('exec_interval_secs: 15', 'exec_interval_secs: 1')
                transform = re.search(r'^  service_metrics_0_0:\n.*?(?=^  \w|^sinks:)', production, re.S | re.M)[0]
                (root / 'vector.yaml').write_text('data_dir: ' + str(root / 'vector-data') + '\nsources:\n' + source + 'transforms:\n' + transform + 'sinks:\n  metrics:\n    type: prometheus_remote_write\n    inputs: [service_metrics_0_0]\n    endpoint: http://127.0.0.1:8428/api/v1/write\n    batch:\n      timeout_secs: 1\n')
                (root / 'vector-data').mkdir()
                start([str(binaries / 'victoria-metrics-prod'), '-storageDataPath=' + str(root / 'vm-data'), '-httpListenAddr=127.0.0.1:8428', '-search.latencyOffset=0s', '-loggerLevel=ERROR'])
                start([str(binaries / 'victoria-logs-prod'), '-storageDataPath=' + str(root / 'vl-data'), '-httpListenAddr=127.0.0.1:9428', '-loggerLevel=ERROR'])
                wait(lambda: request(8428, '/health') is not None)
                wait(lambda: request(9428, '/health') is not None)
                since = time.time()
                start([str(binaries / 'vector'), '--config', str(root / 'vector.yaml')])
                wait(lambda: len(query('{__name__=~"dragontools_service_.*"}')) == len(events))
                expected = {e['name']: (e.get('counter') or e['gauge'])['value'] for e in events}
                for row in query('{__name__=~"dragontools_service_.*"}'):
                    name = row['metric'].pop('__name__')
                    assert row['metric'] == events[0]['tags'], row
                    assert float(row['value'][1]) == expected[name], row
                assert signals['check']('service', registration, since)
                group('replacement.slice/doers.service', 2500000)
                wait(lambda: query('dragontools_service_cpu_seconds_total == 2.5'))
                assert not query('dragontools_service_cpu_seconds_total > 2.5')  # never accumulated as deltas
                (root / 'cgroup/unit.properties').write_text('Id=doers.service\nActiveState=inactive\nControlGroup=\n')
                wait(lambda: query('dragontools_service_cgroup_available == 0'))
                assert signals['check']('service', registration, since)
                print('PASS: native cgroup fixtures -> Vector 0.58.0 -> VM; exact labels, absolute counters, changed path and inactive service.', flush=True)
                identity = dict(application='doers', environment='production', host=config['host'], service='doers')
                rows = [dict(identity, level=level, message=level + ' fixture') for level in ('warning', 'warn', 'error', 'critical', 'fatal', 'info')]
                request(9428, '/insert/jsonline?_stream_fields=application,environment,host,service&_msg_field=message', '\n'.join(json.dumps(row) for row in rows))
                dashboard = json.loads(scope['render'](config)['grafana'])
                expression = dashboard['panels'][-1]['targets'][0]['expr'].replace('${service:regex}', 'doers')
                def logs():
                    lines = request(9428, '/select/logsql/query?' + urllib.parse.urlencode({'query': expression})).splitlines()
                    return [json.loads(line) for line in lines]
                wait(lambda: len(logs()) == 5)
                assert {row['level'] for row in logs()} == {'warning', 'warn', 'error', 'critical', 'fatal'}
                assert all(set(row) <= {'_time', 'service', 'level', 'event', 'method', 'path', 'status', '_msg'} for row in logs())
                print('PASS: rendered dashboard LogsQL accepted by VictoriaLogs 1.52.0; all five severities, INFO excluded, bounded fields.', flush=True)
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                for process in reversed(processes):
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()


if __name__ == '__main__':
    main(*(Path(value).resolve() for value in sys.argv[1:4]))
