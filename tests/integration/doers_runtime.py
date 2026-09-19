"""Isolated Linux reference integration using pinned processes and real mTLS.

Render with render_doers.py first. Run with --network none in a disposable
container, not on a station. No SSH/systemd, live Doers, journal access, external
notifications or provider changes. The reference's DNS/probe are redirected to
localhost and journal input is replaced with stdin; identity, buffers, relabeling,
rules, scrape/evaluation intervals and the two-minute alert hold are unchanged.
"""
import copy
import datetime
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pipeline = load('pipeline', ROOT / 'tests/integration/agent_ingestion_pipeline.py')
request = pipeline.request


def wait(check, label, seconds=45):
    deadline = time.monotonic() + seconds
    delay = .5
    while True:
        try:
            result = check()
            if result:
                return result
        except (ConnectionError, TimeoutError, OSError):
            pass
        left = deadline - time.monotonic()
        if left <= 0:
            raise AssertionError('Deadline: ' + label)
        time.sleep(min(delay, left))
        delay = 1


def snapshot(root):
    return {str(p.relative_to(root)): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
            for p in root.rglob('*') if p.is_file()}


def main(fixture):
    for name, component in (('victoria-metrics-prod', 'victoriametrics'), ('victoria-logs-prod', 'victorialogs'),
                            ('vector', 'vector'), ('vmagent', 'vmagent'), ('caddy', 'caddy'),
                            ('vmalert', 'vmalert'), ('blackbox_exporter', 'blackbox_exporter')):
        digest = hashlib.sha256((fixture / name).read_bytes()).hexdigest()
        assert digest in (ROOT / ('src/components/' + component + '.zig')).read_text(), name + ' pin mismatch'
    config = json.loads((fixture / 'doers-station.json').read_text())
    registration = json.loads((fixture / 'doers-registration.json').read_text())
    assert json.loads((fixture / 'doers-transport.json').read_text()) == dict(
        target_ssh_host='softwarelanding', station_ssh_host='monitoring', station_hostname='monitoring.baptizeddragon.com')
    assert config['application'] == 'doers' and config['environment'] == 'production'
    assert config['services'] == [dict(name='doers', systemd='doers.service', logs=True, metrics_url='http://127.0.0.1:16005/metrics')]
    assert config['probes'] == [dict(name='web', url='https://doers.business/healthz')]
    assert registration['services'] == ['doers.service']
    registration['station'] = 'localhost'
    config['probes'][0]['url'] = 'http://127.0.0.1:16005/healthz'
    n = {'__name__': 'doers_station_fixture'}
    for name in ('apps/station_model.py', 'scrape.py', 'vmalert_rules.py', 'apps/station_read.py', 'apps/station_mutate.py'):
        exec(compile((ROOT / 'src/monitoring' / name).read_text(), name, 'exec'), n)
    signals = load('signals', ROOT / 'src/monitoring/agents/signals.py')
    health = load('ingress_health', ROOT / 'src/monitoring/ingress_health.py')
    ingestion = load('ingestion', ROOT / 'src/monitoring/agents/ingestion.py')
    proxy = load('proxy_fixture', ROOT / 'tests/ingress_proxy_fixture.py')
    processes, servers = [], []
    ingress = None
    with tempfile.TemporaryDirectory(prefix='doers-runtime-') as temporary:
        root = Path(temporary)
        apps, registry = root / 'apps', root / 'registry'
        registry.mkdir()
        main_config = root / 'prometheus.yml'
        n['APP_ROOT'] = str(apps)
        n['APP_VM_CONFIG'] = str(main_config)
        n['APP_INCLUDE'] = "scrape_config_files: ['" + str(apps / '*' / 'scrape.yml') + "']\n"
        n['APP_PENDING'] = {name: str(root / (name + '.pending')) for name in n['APP_FILES']}
        n['APP_VM_BINARY'] = str(fixture / 'victoria-metrics-prod')
        n['APP_ALERT_BINARY'] = str(fixture / 'vmalert')
        main_config.write_text('# Managed by DragonTools\nglobal:\n  scrape_interval: 30s\n  scrape_timeout: 5s\n' + n['APP_INCLUDE'] + 'scrape_configs: []\n')
        main_config.chmod(0o644)
        # These represent administrator files outside the app glob. Never passed
        # to an app renderer, never adopted as managed inputs.
        manual = root / 'manual'; manual.mkdir()
        (manual / 'probes.yml').write_text('administrator-owned probe\n')
        (manual / 'rules.yml').write_text('administrator-owned rules\n')
        protected = snapshot(manual)
        credentials = snapshot(fixture / 'certs')
        def start(argv, stdin=False):
            p = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env=dict(os.environ, GOMAXPROCS='2'))
            processes.append(p)
            return p
        def query(expression):
            return json.loads(request(8428, 'GET', '/api/v1/query?' + urllib.parse.urlencode(dict(query=expression, nocache=1))))['data']['result']
        def checked(fn):
            try:
                fn()
                return True
            except n['NotReady']:
                return False
        def rules(kind):
            return json.loads(request(8880 if kind == 'logs' else 8881, 'GET', '/api/v1/rules'))
        def base_ready(kind):
            response = rules(kind)
            # Only fixture file locations differ from the production policy.
            for group in response['data']['groups']:
                if group['file'] == str(fixture / ('base-' + kind + '.rules.yml')):
                    group['file'] = '/etc/dragontools/vmalert-' + kind + '/rules.yml'
                    for rule in group['rules']:
                        rule['file'] = group['file']
            return checked(lambda: n['validate'](response, kind))
        def evaluator(kind):
            return start([str(fixture / 'vmalert'), '-rule=' + str(fixture / ('base-' + kind + '.rules.yml')),
                          '-rule=' + str(apps / '*' / (kind + '.rules.yml')),
                          '-datasource.url=http://127.0.0.1:' + ('9428' if kind == 'logs' else '8428'),
                          '-notifier.url=http://127.0.0.1:19093', '-httpListenAddr=127.0.0.1:' + ('8880' if kind == 'logs' else '8881'),
                          '-group.maxStartDelay=1s', '-loggerLevel=ERROR'])
        def application():
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 16005), pipeline.Application)
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            return server
        class NotificationSink(http.server.BaseHTTPRequestHandler):
            # Local discard receiver; no Telegram or outside request.
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                self.send_response(200); self.end_headers()
            def log_message(self, *_):
                pass
        try:
            sink = http.server.ThreadingHTTPServer(('127.0.0.1', 19093), NotificationSink)
            servers.append(sink)
            threading.Thread(target=sink.serve_forever, daemon=True).start()
            vm = start([str(fixture / 'victoria-metrics-prod'), '-httpListenAddr=127.0.0.1:8428', '-storageDataPath=' + str(root / 'vm'),
                        '-promscrape.config=' + str(main_config), '-search.latencyOffset=0s', '-memory.allowedBytes=67108864'])
            start([str(fixture / 'victoria-logs-prod'), '-httpListenAddr=127.0.0.1:9428', '-storageDataPath=' + str(root / 'vl'), '-memory.allowedBytes=67108864'])
            for port in (8428, 9428):
                wait(lambda: request(port, 'GET', '/health') is not None, 'backend health')
            ingress = proxy.Harness(root, fixture / 'certs', registry, ingestion, dict(metrics=8428, logs=9428), str(fixture / 'caddy'), ports=dict(metrics=9443, logs=9444))
            assert list(registry.iterdir()) == [] and not apps.exists()
            health.tls(fixture / 'certs', 'localhost', (9443, 9444))
            health.authorization([str(root / 'metrics.sock'), str(root / 'logs.sock')])
            evaluators = {kind: evaluator(kind) for kind in ('logs', 'metrics')}
            for kind in evaluators:
                wait(lambda: base_ready(kind), 'zero-app base ' + kind + ' rules')
            wait(lambda: checked(lambda: n['app_probe_ready']()), 'empty scrape glob')
            apps.mkdir(mode=0o755)
            assert list(apps.glob('*/scrape.yml')) == []
            assert checked(lambda: n['app_probe_ready']())
            print('PASS: zero clients, absent/empty app tree, Caddy 9443/9444 mTLS and healthy base rules.', flush=True)

            cert = (fixture / 'certs/client.crt').read_text()
            registration.update(certificate_sha256=hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest(),
                                certificate_identity='dragontools://hosts/' + registration['host'])
            record = registry / (registration['host'] + '.json')
            record.write_text(json.dumps(registration)); record.chmod(0o640)
            caddy_pid = ingress.process.pid
            assert n['app_publish'](config)
            assert sorted(p.name for p in apps.iterdir()) == ['doers']
            assert n['app_base_probes']() == []  # App TOML never becomes a station probe.
            for kind in evaluators:
                evaluators[kind].terminate(); evaluators[kind].wait(timeout=10)
                evaluators[kind] = evaluator(kind)
            start([str(fixture / 'blackbox_exporter'), '--config.file=' + str(fixture / 'blackbox.yml'),
                   '--web.listen-address=127.0.0.1:9115', '--history.limit=0', '--log.prober=error'])
            app = application()
            request(8428, 'POST', '/-/reload')
            for kind in evaluators:
                wait(lambda: checked(lambda: n['app_rules_ready'](config, (kind,))), 'scoped ' + kind + ' rules')
            wait(lambda: checked(lambda: n['app_probe_ready']()), 'app probe pipeline')
            expected = n['application_definitions']()
            wait(lambda: list(n['stored_states'](expected, True).values()) == ['healthy'], 'healthy blackbox probe')
            for path in n['APP_PENDING'].values():
                Path(path).unlink(missing_ok=True)  # Fixture activation finished; no systemd claim.
            print('PASS: only Doers namespace published; live blackbox scraping and both scoped rule APIs ready.', flush=True)

            original = (fixture / 'doers-vector.yaml').read_text()
            assert original.count('max_size: 268435488') == 2 and original.count('when_full: block') == 2
            subprocess.run([str(fixture / 'vector'), 'validate', '--no-environment', '--skip-healthchecks', str(fixture / 'doers-vector.yaml')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            begin, end = original.index('  journal:\n'), original.index('  stream_0:\n')
            vector_config = original[:begin] + '  journal:\n    type: stdin\n    decoding:\n      codec: json\n' + original[end:]
            for old, new in (('/var/lib/dragontools/vector', str(root / 'vector')), ('/etc/dragontools/vector', str(fixture / 'certs')),
                             ('monitoring.baptizeddragon.com', 'localhost'), ('/opt/dragontools/agent/current/dragontool-agent', str(fixture / 'dragontool-agent'))):
                vector_config = vector_config.replace(old, new)
            (root / 'vector').mkdir()
            (root / 'vector.yaml').write_text(vector_config)
            since = time.time()
            vector = start([str(fixture / 'vector'), '--config', str(root / 'vector.yaml')], stdin=True)
            wait(lambda: signals.check('host', registration, since), 'trusted host metrics')
            wait(lambda: signals.check('logs', registration, since), 'quiet stream metadata')
            def logs(query):
                body = request(9428, 'POST', '/select/logsql/query', urllib.parse.urlencode(dict(query=query)), headers={'Content-Type': 'application/x-www-form-urlencoded'})
                return [json.loads(line) for line in body.splitlines()]
            quiet = logs('application:="doers" service:="doers" | limit 10')
            assert quiet and all(row['type'] == 'dragontools_stream' and row['level'] == 'info' for row in quiet)
            trusted = dict(application='doers', environment='production', host=registration['host'], service='doers')
            assert all(all(row[k] == v for k, v in trusted.items()) for row in quiet)
            event = dict(_SYSTEMD_UNIT='doers.service', message=json.dumps(dict(application='forged', environment='forged', host='forged', service='forged', level='info', request_id='reference-fixture', message='normal fixture event')), PRIORITY='6')
            vector.stdin.write((json.dumps(event) + '\n').encode()); vector.stdin.flush()
            actual = wait(lambda: logs('request_id:="reference-fixture" | limit 1'), 'normal structured log')
            assert all(actual[0][k] == v for k, v in trusted.items())
            vm_since = time.time()
            vmagent = start([str(fixture / 'vmagent'), '-httpListenAddr=127.0.0.1:8429', '-promscrape.config=' + str(fixture / 'doers-prometheus.yml'),
                             '-remoteWrite.url=https://localhost:9443/api/v1/write', '-remoteWrite.forcePromProto=true',
                             '-remoteWrite.tlsCAFile=' + str(fixture / 'certs/ca.crt'), '-remoteWrite.tlsCertFile=' + str(fixture / 'certs/client.crt'),
                             '-remoteWrite.tlsKeyFile=' + str(fixture / 'certs/client.key'), '-remoteWrite.tmpDataPath=' + str(root / 'vmagent'), '-remoteWrite.maxDiskUsagePerURL=1GiB'])
            wait(lambda: signals.check('app', registration, vm_since), 'application metrics')
            selector = '{' + ','.join(k + '=' + json.dumps(v) for k, v in trusted.items()) + '}'
            assert query('fixture_requests_total' + selector)
            assert not query('fixture_requests_total{application="forged"}')
            assert not signals.check('app', registration, time.time() + 3600)
            print('PASS: Vector host/logs and vmagent metrics traverse real Caddy with trusted labels; quiet logs need no fake error.', flush=True)

            def alert_state():
                group = next(g for g in rules('metrics')['data']['groups'] if g['name'] == 'dragontools-app-doers-metrics')
                return group['rules'][0]
            wait(lambda: alert_state()['state'] == 'inactive', 'healthy alert baseline', 90)
            app.shutdown(); app.server_close(); servers.remove(app)
            # Observe pending first, before separate signal queries. Otherwise
            # their polling can miss part of the hold on a loaded CI runner.
            pending = wait(lambda: (r if (r := alert_state())['state'] == 'pending' else None), 'pending alert', 90)
            assert pending['duration'] == 120 and pending['health'] == 'ok'
            wait(lambda: list(n['stored_states'](expected, True).values()) == ['unhealthy'], 'probe_success=0')
            wait(lambda: query('up' + selector + ' == 0'), 'vmagent failed scrape')
            assert signals.check('app', registration, vm_since)
            assert checked(lambda: n['app_probe_ready']())
            print('PASS: stopped fixture target has probe_success=0 and up=0; monitoring readiness passes, alert pending for 2m.', flush=True)
            firing = wait(lambda: (r if (r := alert_state())['state'] == 'firing' else None), 'firing alert after configured hold', 180)
            active = datetime.datetime.fromisoformat(firing['alerts'][0]['activeAt'].replace('Z', '+00:00')).timestamp()
            assert time.time() - active >= 120
            app = application()
            wait(lambda: list(n['stored_states'](expected, True).values()) == ['healthy'], 'probe recovery')
            wait(lambda: alert_state()['state'] == 'inactive', 'alert resolution', 75)
            wait(lambda: query('up' + selector + ' == 1') and signals.check('app', registration, vm_since), 'metrics recovery')
            print('PASS: ServiceProbeFailed fired after the real 2m hold, then resolved after target recovery.', flush=True)

            before = snapshot(apps)
            assert not n['app_publish'](config) and snapshot(apps) == before
            assert snapshot(fixture / 'certs') == credentials
            reduced = copy.deepcopy(config); reduced['probes'] = []
            logs_before = snapshot(apps)['doers/logs.rules.yml']
            assert n['app_publish'](reduced)
            assert snapshot(apps)['doers/logs.rules.yml'] == logs_before
            assert set(p.name for p in root.glob('*.pending')) == {'metrics.rules.yml.pending', 'scrape.yml.pending'}
            request(8428, 'POST', '/-/reload')
            evaluators['metrics'].terminate(); evaluators['metrics'].wait(timeout=10)
            evaluators['metrics'] = evaluator('metrics')
            wait(lambda: checked(lambda: n['app_probe_ready']()), 'removed app probe')
            wait(lambda: checked(lambda: n['app_rules_ready'](reduced)), 'removed app rule')
            assert not json.loads(request(8428, 'GET', '/api/v1/targets?state=active'))['data']['activeTargets']
            assert snapshot(manual) == protected and n['app_base_probes']() == []
            after = snapshot(apps)
            assert not n['app_publish'](reduced) and snapshot(apps) == after
            assert all(p.poll() is None for p in (vm, vector, vmagent, ingress.process))
            assert ingress.process.pid == caddy_pid and snapshot(fixture / 'certs') == credentials
            assert not logs('application:="doers" level:in(error,critical,fatal) | limit 1')
            print('PASS: identical publication is a no-op; probe removal only dirties its scraper/metrics rules; agents, Caddy, credentials and manual files preserved.', flush=True)
            if '--outage' in sys.argv:
                load('vector_outage', ROOT / 'tests/integration/vector_outage.py').exercise(
                    vector, ingress.process, root / 'vector', request, wait, logs)
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
            for p in reversed(processes):
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait()
            if ingress:
                ingress.close()
            for server in servers:
                server.shutdown(); server.server_close()


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve())
