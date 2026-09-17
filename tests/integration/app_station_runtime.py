"""Opt-in isolated pinned Linux processes: app loaders, scoped rules, down probes.

No SSH/systemd, notification test, outside network or disposable-host claim.
Pass a directory containing pinned victoria-metrics-prod, victoria-logs-prod and
vmalert. Run in a network-isolated container with a private writable /tmp.
"""
import datetime
import http.client
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
fixture = Path(sys.argv[1])
namespace = {'__name__': 'app_native_fixture'}
for name in ('apps/station_model.py', 'scrape.py', 'vmalert_rules.py'):
    exec(compile((ROOT / 'src/monitoring' / name).read_text(), name, 'exec'), namespace)
spec = importlib.util.spec_from_file_location('rules_fixture', ROOT / 'tests/vmalert_test.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = {'application': 'doers', 'environment': 'production', 'host': 'dt-' + 'a' * 32,
          'services': [{'name': 'api', 'systemd': 'api.service', 'logs': True, 'metrics_url': None}],
          'probes': [{'name': 'web', 'url': 'https://does-not-exist.invalid/health'}],
          'alerts': [{'name': 'HighErrorRate', 'source': 'logs', 'severity': 'warning', 'service': 'api', 'level': 'error', 'window': '5m', 'threshold': 10}]}


def get(port, path):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
    try:
        connection.request('GET', path)
        response = connection.getresponse()
        body = response.read(1048577)
        assert response.status == 200 and len(body) <= 1048576
        return body
    finally:
        connection.close()


def wait(check, seconds=20):
    end = time.monotonic() + seconds
    while True:
        try:
            return check()
        except (OSError, AssertionError, namespace['NotReady']):
            if time.monotonic() >= end:
                raise
            time.sleep(.1)


with tempfile.TemporaryDirectory(prefix='app-native-') as temporary:
    root = Path(temporary)
    apps = root / 'apps'
    app = apps / 'doers'
    app.mkdir(parents=True)
    for name, data in namespace['app_documents'](config).items():
        (app / name).write_bytes(data)
    namespace['app_all'] = lambda: [{'config': config}]
    namespace['APP_ROOT'] = str(apps)
    processes = []
    try:
        for kind in ('logs', 'metrics'):
            groups = []
            for loaded in module.fixture(kind)['data']['groups']:
                groups.append({'name': loaded['name'], 'type': loaded['type'], 'interval': str(loaded['interval']) + 's', 'rules': [
                    dict({'alert': rule['name'], 'expr': rule['query'], 'labels': rule['labels'], 'annotations': rule['annotations']},
                         **({'for': str(rule['duration']) + 's'} if rule['duration'] else {})) for rule in loaded['rules']]})
            (root / (kind + '.rules.yml')).write_text(json.dumps({'groups': groups}))
            subprocess.run([str(fixture / 'vmalert'), '-dryRun', '-rule=' + str(app / (kind + '.rules.yml'))], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        main = root / 'prometheus.yml'
        main.write_text(json.dumps({'global': {'scrape_interval': '30s', 'scrape_timeout': '5s'}, 'scrape_config_files': [str(apps / '*' / 'scrape.yml')]}))
        subprocess.run([str(fixture / 'victoria-metrics-prod'), '-promscrape.config=' + str(main), '-promscrape.config.dryRun'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        processes.append(subprocess.Popen([str(fixture / 'victoria-metrics-prod'), '-storageDataPath=' + str(root / 'vm'), '-httpListenAddr=127.0.0.1:8428', '-promscrape.config=' + str(main), '-loggerLevel=ERROR'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        processes.append(subprocess.Popen([str(fixture / 'victoria-logs-prod'), '-storageDataPath=' + str(root / 'vl'), '-httpListenAddr=127.0.0.1:9428', '-loggerLevel=ERROR'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        wait(lambda: get(8428, '/health'))
        wait(lambda: get(9428, '/health'))
        wait(lambda: namespace['loaded_policy']({}))
        namespace['targets_loaded']({}, False)
        print('PASS actual native app include and loaded metric/relabel policy')
        for kind, port, datasource in (('logs', 8880, 9428), ('metrics', 8881, 8428)):
            processes.append(subprocess.Popen([str(fixture / 'vmalert'), '-rule=' + str(root / (kind + '.rules.yml')), '-rule=' + str(apps / '*' / (kind + '.rules.yml')), '-datasource.url=http://127.0.0.1:' + str(datasource), '-notifier.url=http://127.0.0.1:9093', '-httpListenAddr=127.0.0.1:' + str(port), '-group.maxStartDelay=1s', '-loggerLevel=ERROR'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            expected = json.loads((app / (kind + '.rules.yml')).read_bytes())['groups'][0]
            def check(port=port, expected=expected, kind=kind):
                groups = json.loads(get(port, '/api/v1/rules?exclude_alerts=true'))['data']['groups']
                assert len(groups) == (2 if kind == 'logs' else 3)
                assert all(rule.get('health') == 'ok' and not rule.get('lastError') for group in groups for rule in group['rules'])
                group = next(group for group in groups if group['name'] == expected['name'])
                namespace['validate_application_group'](group, str(app / (kind + '.rules.yml')), expected, time.time())
            wait(check)
        print('PASS actual vmalert app rule glob, scoped LogsQL, PromQL and healthy evaluation')
        # Removal/no-alert apps retain exact empty documents. Validate their
        # combination with the permanently nonempty shared groups, as deployed.
        for kind in ('logs', 'metrics'):
            empty = root / ('empty-' + kind + '.rules.yml')
            empty.write_text('{"groups":[]}\n')
            subprocess.run([str(fixture / 'vmalert'), '-dryRun', '-rule=' + str(root / (kind + '.rules.yml')),
                            '-rule=' + str(empty)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print('PASS empty app rules coexist with the fixed shared packs')
        # Import stored failed telemetry; does not contact the target or synthesize
        # alerts. This isolates query semantics from blackbox/network availability.
        labels = next(iter(namespace['application_definitions']().values()))
        text = ''.join(metric + '{' + ','.join(k + '=' + json.dumps(v) for k, v in labels.items()) + '} ' + value + '\n' for metric, value in [('probe_success', '0'), ('up', '1')])
        connection = http.client.HTTPConnection('127.0.0.1', 8428, timeout=2)
        connection.request('POST', '/api/v1/import/prometheus', body=text)
        assert connection.getresponse().status == 204
        connection.close()
        expected = namespace['application_definitions']()
        def stored():
            assert list(namespace['stored_states'](expected, True).values()) == ['unhealthy']
        wait(stored)
        print('PASS failed app probe sample is valid stored pipeline telemetry')
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            process.wait(timeout=10)
