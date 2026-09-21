#!/usr/bin/env python3
"""Opt-in isolated pinned VM/Vector/Grafana processes, never systemd or SSH.

Arguments: monitoring-binary directory, extracted Grafana home, rendered Doers.
Run in a disposable Linux network namespace/container. No credentials or outbound
network are needed; generated databases and dashboard documents are temporary.
"""
import http.client
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]


def main(binaries, grafana, rendered):
    scope = {'__name__': 'dashboard_integration'}
    for name in ('model', 'state', 'signals'):
        exec(compile((ROOT / 'src/monitoring/dashboards' / (name + '.py')).read_text(), name, 'exec'), scope)
    config = json.loads((rendered / 'doers-station.json').read_text())
    config.pop('alerts')
    processes = []
    with tempfile.TemporaryDirectory(prefix='dragontools-dashboards-') as tmp:
        root = Path(tmp)
        log = (root / 'process.log').open('wb')
        def start(argv, **kwargs):
            child = subprocess.Popen(argv, stdout=log, stderr=log, **kwargs)
            processes.append(child)
            return child
        def wait(check, label, seconds=60):
            end = time.monotonic() + seconds
            last = None
            while time.monotonic() < end:
                if any(p.poll() is not None for p in processes):
                    raise AssertionError('Fixture process exited: ' + (root / 'process.log').read_text()[-8000:])
                try:
                    if check(): return
                except (Exception,) as error:
                    last = error
                time.sleep(0.2)
            raise AssertionError(label + ': ' + repr(last) + '\n' + (root / 'process.log').read_text()[-5000:])
        def request(port, path, body=None):
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            try:
                conn.request('POST' if body is not None else 'GET', path, body=body)
                response = conn.getresponse()
                data = response.read()
                assert response.status in (200, 204), (response.status, data[:1000])
                return data
            finally: conn.close()
        try:
            for path in ('vm', 'grafana', 'manifests', 'provisioning/dashboards', 'provisioning/datasources', 'data'):
                (root / path).mkdir(parents=True, exist_ok=True)
            scope.update(VM_ROOT=str(root / 'vm'), GRAFANA_ROOT=str(root / 'grafana'), MANIFEST_ROOT=str(root / 'manifests'), DB_PATH=str(root / 'data/grafana.db'), PROVIDER_PATH=str(root / 'provisioning/dashboards/dragontools.yaml'))
            def parents(path, create=False, missing=False):
                target = Path(path)
                assert target.is_relative_to(root)
                if create: target.mkdir(parents=True, exist_ok=True, mode=0o755)
                elif not missing: assert target.is_dir()
                return False
            scope['parents'] = parents
            scope['grafana_owner'] = lambda: (os.getuid(), os.getgid())
            scope['publish'](config, allow_absent=True)
            scope['publish']({'station': True}, allow_absent=True)
            provider = scope['PROVIDER']
            provider['providers'][0]['options']['path'] = str(root / 'grafana')
            (root / 'provisioning/dashboards/dragontools.yaml').write_bytes(scope['encoded'](provider))
            (root / 'provisioning/datasources/dragontools.yaml').write_text('apiVersion: 1\ndatasources:\n  - name: Metrics\n    uid: dragontools-metrics\n    type: prometheus\n    url: http://127.0.0.1:8428\n    access: proxy\n')
            start([str(binaries / 'victoria-metrics-prod'), '-storageDataPath=' + str(root / 'vm-data'), '-httpListenAddr=127.0.0.1:8428', '-selfScrapeInterval=1s', '-vmui.customDashboardsPath=' + str(root / 'vm'), '-loggerLevel=ERROR'])
            env = dict(os.environ, GF_PATHS_DATA=str(root / 'data'), GF_PATHS_LOGS=str(root / 'logs'), GF_PATHS_PLUGINS=str(root / 'plugins'), GF_PATHS_PROVISIONING=str(root / 'provisioning'), GF_SERVER_HTTP_ADDR='127.0.0.1', GF_SERVER_HTTP_PORT='3000', GF_DATABASE_WAL='false', GF_PLUGINS_PREINSTALL_DISABLED='true', GF_PLUGINS_PREINSTALL_AUTO_UPDATE='false', GF_ANALYTICS_REPORTING_ENABLED='false', GF_ANALYTICS_CHECK_FOR_UPDATES='false', GF_SECURITY_ADMIN_PASSWORD='isolated-fixture-only')
            start([str(grafana / 'bin/grafana'), 'server', '--homepath=' + str(grafana)], env=env)
            wait(lambda: request(8428, '/health') is not None, 'VM start')
            wait(lambda: request(3000, '/api/health') is not None, 'Grafana start')
            def loaded():
                scope['loaded'](config)
                scope['loaded']({'station': True})
                return True
            wait(loaded, 'native loaded dashboards', seconds=45)
            with sqlite3.connect(scope['DB_PATH']) as database:
                folders = [json.loads(row[0]) for row in database.execute("SELECT value FROM resource WHERE resource='folders'")]
                parent = next(folder['metadata']['name'] for folder in folders if folder['spec']['title'] == 'DragonTools')
                for title in ('Station', config['application']):
                    folder = next(folder for folder in folders if folder['spec']['title'] == title)
                    assert folder['metadata']['annotations']['grafana.app/folder'] == parent
            print('PASS: pinned VMUI custom-dashboards API and Grafana file provisioning/SQLite loaded state.', flush=True)
            assert not scope['publish'](config)
            config['services'][0]['http']['route_label'] = None
            assert scope['publish'](config)
            wait(loaded, 'Grafana polled update without restart')
            scope['finish'](config)
            assert not scope['publish'](config)
            assert len(processes) == 2 and all(p.poll() is None for p in processes)
            print('PASS: dashboard update is picked up without restarting Grafana or VictoriaMetrics; next publish is a no-op.', flush=True)
            for p in scope['panels'](config) + scope['panels']({'station': True}):
                for expression in p['expr']:
                    response = json.loads(request(8428, '/api/v1/query?' + urllib.parse.urlencode({'query': expression})))
                    assert response['status'] == 'success', p['title']
            # Inspect the pinned VM's actual self-scrape label, not a guessed job.
            def self_samples():
                return json.loads(request(8428, '/api/v1/query?' + urllib.parse.urlencode({'query': 'process_cpu_seconds_total'})))['data']['result']
            wait(self_samples, 'VM self-scrape stored sample', seconds=45)
            jobs = json.loads(request(8428, '/api/v1/query?' + urllib.parse.urlencode({'query': 'count by (job) (process_cpu_seconds_total)'})))
            print('Observed VM self-scrape jobs:', [row['metric'] for row in jobs['data']['result']], flush=True)
            assert [row['metric'] for row in jobs['data']['result']] == [{'job': 'victoria-metrics'}]
            for panel in scope['panels']({'station': True}):
                for expression in panel['expr']:
                    wait(lambda: json.loads(request(8428, '/api/v1/query?' + urllib.parse.urlencode({'query': expression})))['data']['result'], panel['title'], seconds=45)
            print('PASS: all rendered MetricsQL expressions accepted by pinned VM.', flush=True)
            print('PASS: every station resource panel has stored VM self-scrape data.', flush=True)
        finally:
            for process in reversed(processes):
                if process.poll() is None: process.terminate()
            for process in reversed(processes):
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            log.close()


if __name__ == '__main__':
    main(*(Path(p).resolve() for p in sys.argv[1:4]))
