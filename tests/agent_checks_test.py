#!/usr/bin/env python3
"""Execute the real read-only verifier entrypoints against bounded local fakes.

No SSH, services, network listeners, or credentials are used by this test.
"""
import contextlib
import datetime
import hashlib
import io
import json
from pathlib import Path
import re
import socket
import ssl
import stat
import sys
import types
import unittest
from unittest.mock import patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
CHECKS = compile((ROOT / 'src/monitoring/agents/checks.py').read_text(), 'checks.py', 'exec')
SIGNALS = compile((ROOT / 'src/monitoring/agents/signals.py').read_text(), 'signals.py', 'exec')
METRICS = compile((ROOT / 'src/monitoring/agents/metrics_checks.py').read_text(), 'metrics_checks.py', 'exec')
NOW = 1_800_000_000
SINCE = NOW - 10
REGISTRATION = dict(host='dt-0123456789abcdef0123456789abcdef', station='station.example',
                    services=['application.service'], metrics_targets=[dict(name='software', url='http://127.0.0.1:16000/metrics')])


def entrypoint(code, argv, scope=None):
    stdout, stderr = io.StringIO(), io.StringIO()
    with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        try:
            exec(code, {'__name__': '__main__', **(scope or {})})
            result = 0
        except SystemExit as error:
            result = error.code
    assert stdout.getvalue() == stderr.getvalue() == '', 'verifier exposed diagnostic text'
    return result


class Runtime(unittest.TestCase):
    def run_runtime(self, scenario):
        command = '/opt/dragontools/components/vector/current/vector --config /etc/dragontools/vector/vector.yaml'
        binary = b'fixture verified executable bytes'
        spec = dict(kind='vector', owner='dt-vector', listener='127.0.0.1:8686', command=command,
                    digest=hashlib.sha256(binary).hexdigest())
        calls = []
        real_open = open

        def output(argv, **_):
            calls.append(argv)
            if argv == ('systemctl', 'show', '--all', 'dragontools-vector.service'):
                return ('MainPID=' + ('0' if scenario in ('absent', 'public-before-start') else '123') + '\nActiveState=active\n').encode()
            if argv == ('ss', '-H', '-ltnp'):
                if scenario in ('absent', 'listener-not-ready'):
                    return b''
                address = '0.0.0.0:8686' if scenario in ('public', 'public-before-start') else '127.0.0.1:8686'
                return ('LISTEN 0 128 ' + address + ' 0.0.0.0:* users:(("vector",pid=123,fd=12))\n').encode()
            if argv == ('ss', '-H', '-lunp'):
                return b'UNCONN 0 0 0.0.0.0:9000 0.0.0.0:* users:(("vector",pid=123,fd=13))\n' if scenario == 'udp' else b''
            raise AssertionError('unexpected subprocess')

        def fixture_open(path, *args, **kwargs):
            if path == '/proc/123/cmdline':
                parts = (command + (' --api-enabled' if scenario == 'arguments' else '')).split()
                return io.BytesIO(b'\0'.join(part.encode() for part in parts) + b'\0')
            if path == '/proc/123/exe':
                return io.BytesIO(b'corrupt binary' if scenario == 'checksum' else binary)
            return real_open(path, *args, **kwargs)

        account = types.SimpleNamespace(pw_uid=120, pw_gid=120)
        process = types.SimpleNamespace(st_uid=121 if scenario == 'user' else 120, st_gid=121 if scenario == 'group' else 120)
        with patch('subprocess.check_output', side_effect=output), patch('pwd.getpwnam', return_value=account), \
             patch('os.path.isdir', return_value=True), patch('os.stat', return_value=process):
            result = entrypoint(CHECKS, ['checks.py', 'active', json.dumps(spec)], {'open': fixture_open})
        return result, calls

    def test_absence_is_retryable_and_valid_runtime_has_no_output(self):
        for scenario in ('absent', 'listener-not-ready'):
            with self.subTest(scenario=scenario):
                self.assertEqual(self.run_runtime(scenario)[0], 75)
        self.assertEqual(self.run_runtime('healthy')[0], 0)

    def test_public_udp_arguments_identity_and_checksum_fail_without_retry_code(self):
        for scenario in ('public', 'public-before-start', 'udp', 'arguments', 'checksum', 'user', 'group'):
            with self.subTest(scenario=scenario):
                result, calls = self.run_runtime(scenario)
                self.assertEqual(result, 1)
                self.assertEqual(calls.count(('systemctl', 'show', '--all', 'dragontools-vector.service')), 1)


class IngressRuntime(unittest.TestCase):
    def run_ingress(self, kind, scenario='healthy'):
        binary = b'pinned Caddy fixture'
        command = 'caddy run --config fixed' if kind == 'caddy' else 'python3 -I -B authorize.py'
        spec = dict(kind=kind, service='caddy' if kind == 'caddy' else 'ingress-auth',
                    owner='dt-caddy' if kind == 'caddy' else 'dt-ingest', command=command,
                    digest=hashlib.sha256(binary).hexdigest())
        pid = 0 if scenario == 'absent' else 123
        account = types.SimpleNamespace(pw_uid=120, pw_gid=120)
        def output(argv, **_):
            if argv[0] == 'systemctl':
                return f'MainPID={pid}\nActiveState=active\n'.encode()
            if argv == ('ss', '-H', '-ltnp'):
                addresses = ['0.0.0.0:9443', '0.0.0.0:9444'] if kind == 'caddy' else []
                if scenario in ('absent', 'missing'):
                    addresses = addresses[:1] if scenario == 'missing' else []
                if scenario == 'trace':
                    addresses += ['0.0.0.0:9445']
                if scenario == 'ipv6':
                    addresses[0] = '[::]:9443'
                peer = 456 if scenario == 'foreign' else 123
                return ''.join(f'LISTEN 0 128 {address} *:* users:(("fixture",pid={peer},fd=12))\n' for address in addresses).encode()
            if argv == ('ss', '-H', '-lunp'):
                return b'UNCONN 0 0 *:9443 *:* users:(("fixture",pid=123,fd=13))\n' if scenario == 'udp' else b''
            if argv == ('ss', '-H', '-lxnp'):
                return ''.join(f'u_str LISTEN 0 32 /run/dragontools-ingress/{signal}.sock 0 * 0 users:(("python3",pid=123,fd=4))\n' for signal in ('metrics', 'logs')).encode()
            raise AssertionError(argv)
        def fixture_open(path, *_):
            if path.endswith('/cmdline'):
                return io.BytesIO((command + (' bad' if scenario == 'arguments' else '')).replace(' ', '\0').encode() + b'\0')
            if path.endswith('/exe'):
                return io.BytesIO(b'corrupt' if scenario == 'checksum' else binary)
            raise AssertionError(path)
        def metadata(path):
            directory = not path.endswith('.sock')
            mode = (stat.S_IFDIR | 0o750) if directory else (stat.S_IFSOCK | (0o666 if scenario == 'socket-mode' else 0o660))
            if scenario == 'socket-symlink' and not directory:
                mode = stat.S_IFLNK | 0o777
            return types.SimpleNamespace(st_uid=121 if scenario == 'user' else 120, st_gid=120, st_mode=mode)
        with patch('subprocess.check_output', side_effect=output), patch('pwd.getpwnam', return_value=account), \
             patch('os.path.isdir', return_value=True), patch('os.stat', side_effect=metadata), \
             patch('os.lstat', side_effect=metadata), patch('os.path.lexists', return_value=scenario != 'missing'), \
             patch('socket.create_connection', return_value=contextlib.nullcontext()):
            return entrypoint(CHECKS, ['checks.py', 'active', json.dumps(spec)], {'open': fixture_open})

    def test_caddy_exact_tcp_listeners_and_private_auth_sockets(self):
        for kind in ('caddy', 'ingestion'):
            with self.subTest(kind=kind):
                self.assertEqual(self.run_ingress(kind), 0)
                for scenario in ('absent', 'missing'):
                    self.assertEqual(self.run_ingress(kind, scenario), 75)
                for scenario in ('trace', 'udp', 'arguments', 'user'):
                    self.assertEqual(self.run_ingress(kind, scenario), 1)
        for scenario in ('foreign', 'ipv6', 'checksum'):
            self.assertEqual(self.run_ingress('caddy', scenario), 1)
        for scenario in ('socket-mode', 'socket-symlink'):
            self.assertEqual(self.run_ingress('ingestion', scenario), 1)


class Signals(unittest.TestCase):
    def run_signal(self, mode, sample_time=NOW, status=200, invalid=False, oversized=False):
        queries = []

        class Connection:
            def __init__(self, address, port, timeout):
                assert address == '127.0.0.1' and port in (8428, 9428) and timeout == 5
                self.port = port

            def request(self, method, path, body, headers):
                assert method == 'POST' and headers == {'Content-Type': 'application/x-www-form-urlencoded'}
                assert path == ('/api/v1/query' if self.port == 8428 else '/select/logsql/query')
                self.query = urllib.parse.parse_qs(body)['query'][0]
                queries.append(self.query)

            def getresponse(self):
                query = self.query
                if self.port == 9428:
                    assert '| sort by (_time) desc limit 1' in query
                    assert 'host=' + json.dumps(REGISTRATION['host']) in query
                    stamp = datetime.datetime.fromtimestamp(sample_time, datetime.timezone.utc).isoformat()
                    identity = dict(host=REGISTRATION['host'], service='application.service')
                    if 'service="dragontools-host"' in query: identity.update(application='host', environment='host', service='dragontools-host')
                    stream = '{'+','.join(k+'='+json.dumps(v) for k,v in sorted(identity.items()))+'}'
                    body = json.dumps(dict(identity, _time=stamp, _stream=stream)).encode()
                else:
                    assert 'host=' + json.dumps(REGISTRATION['host']) in query
                    if query.startswith('up{'):
                        found = True
                    else:
                        # Minimal stored timestamp model: assertions require both
                        # independently meaningful deployment and recency bounds.
                        match = re.search(r' >= ([0-9]+[.]0)\) and \(timestamp\(', query)
                        assert match and query.endswith(' > time()-90)) > 0')
                        found = sample_time >= float(match[1]) and sample_time > NOW - 90
                    body = json.dumps(dict(status='success', data=dict(resultType='vector', result=[dict(metric={}, value=[NOW, '1'])] if found else []))).encode()
                if invalid:
                    body = b'PRIVATE malformed backend response'
                if oversized:
                    body = b'x' * (1024 * 1024 + 1)
                return types.SimpleNamespace(status=status, read=lambda limit: body[:limit])

            def close(self):
                pass

        with patch('http.client.HTTPConnection', Connection):
            result = entrypoint(SIGNALS, ['signals.py', mode, json.dumps(REGISTRATION), str(SINCE)])
        return result, queries

    def test_prior_process_samples_are_not_new_arrival_even_when_recent(self):
        for mode in ('host', 'logs', 'app', 'events'):
            with self.subTest(mode=mode):
                self.assertEqual(self.run_signal(mode, SINCE - 1)[0], 75)
                self.assertEqual(self.run_signal(mode, SINCE + 1)[0], 0)

    def test_host_event_readiness_queries_only_the_reserved_host_stream(self):
        result, queries = self.run_signal('events')
        self.assertEqual(result, 0)
        self.assertEqual(len(queries), 1)
        self.assertIn('application="host"', queries[0])
        self.assertIn('environment="host"', queries[0])
        self.assertIn('service="dragontools-host"', queries[0])

    def test_host_metrics_require_all_contract_signals_and_app_requires_payload(self):
        result, queries = self.run_signal('host')
        self.assertEqual(result, 0)
        self.assertEqual(len(queries), 3)
        for query, name in zip(queries, ('host_cpu_seconds_total', 'host_memory_total_bytes', 'host_filesystem_used_ratio')):
            self.assertIn(name + '{', query)
            self.assertIn('agent="vector"', query)
        result, queries = self.run_signal('app')
        self.assertEqual(result, 0)
        self.assertEqual(len(queries), 3)
        self.assertIn('up{', queries[0])
        self.assertIn('__name__!~"up|scrape_.*"', queries[2])
        self.assertIn('agent="vmagent",app="software"', queries[2])

    def test_station_unavailable_retries_but_invalid_responses_fail_deterministically(self):
        for status in (500, 502, 503, 504):
            with self.subTest(status=status):
                result, queries = self.run_signal('host', status=status)
                self.assertEqual(result, 75)
                self.assertEqual(len(queries), 1)
        for status in (400, 401, 403, 404, 429):
            with self.subTest(status=status):
                result, queries = self.run_signal('host', status=status)
                self.assertEqual(result, 1)
                self.assertEqual(len(queries), 1)
        self.assertEqual(self.run_signal('host', invalid=True)[0], 1)
        self.assertEqual(self.run_signal('host', oversized=True)[0], 1)


class StationTlsProof(unittest.TestCase):
    def test_only_explicit_client_certificate_alert_proves_mtls(self):
        namespace = {'__name__': 'fixture'}
        exec(compile((ROOT / 'src/monitoring/ingress_health.py').read_text(), 'ingress_health.py', 'exec'), namespace)
        class Alert(ssl.SSLError):
            reason = 'TLSV13_ALERT_CERTIFICATE_REQUIRED'
        class WrongAlert(ssl.SSLError):
            reason = 'TLSV1_ALERT_INTERNAL_ERROR'
        for outcome in (Alert(), WrongAlert(), ssl.SSLEOFError(), ssl.SSLCertVerificationError(), TimeoutError(), b'', b'H'):
            with self.subTest(outcome=type(outcome).__name__):
                def receive(_):
                    if isinstance(outcome, Exception):
                        raise outcome
                    return outcome
                peer = types.SimpleNamespace(recv=receive, sendall=lambda _: self.fail('write can obscure TLS 1.3 alert'))
                context = types.SimpleNamespace(wrap_socket=lambda raw, server_hostname: contextlib.nullcontext(peer))
                with patch('ssl.create_default_context', return_value=context), \
                     patch('socket.create_connection', return_value=contextlib.nullcontext()):
                    if isinstance(outcome, Alert):
                        namespace['tls'](Path('/public-fixture'), 'localhost', (9443, 9444))
                    else:
                        with self.assertRaises((ssl.SSLError, TimeoutError, ValueError)):
                            namespace['tls'](Path('/public-fixture'), 'localhost', (9443, 9444))


class ApplicationSignals(unittest.TestCase):
    def module(self):
        namespace = {'__name__': 'fixture'}
        exec(SIGNALS, namespace)
        return namespace

    def registration(self):
        return dict(REGISTRATION, services=['doers.service'], metrics_targets=[], applications=[dict(name='doers', environment='production', services=[dict(name='web', systemd='doers.service', logs=True, metrics_url='http://127.0.0.1:16005/metrics')])])

    def test_failed_scrape_is_valid_but_stale_absent_and_empty_success_are_not(self):
        for registration in (REGISTRATION, self.registration()):
            for up, fresh_up, payload, expected in (
                    (0, True, False, True), (1, True, True, True),
                    (1, True, False, False), (0, False, True, False),
                    (1, False, True, False), (None, False, False, False),
                    (2, True, True, False)):
                with self.subTest(application=bool(registration.get('applications')), up=up,
                                  fresh_up=fresh_up, payload=payload):
                    functions = self.module()
                    def metric(query):
                        if query.startswith('count((timestamp(up{'):
                            self.assertIn(' >= ' + str(float(SINCE)), query)
                            self.assertIn(' > time()-90)', query)
                            return fresh_up
                        if query.startswith('up{'):
                            return up == (1 if query.endswith(' == 1') else 0)
                        self.assertIn('__name__!~"up|scrape_.*"', query)
                        return payload
                    functions['metric'] = metric
                    self.assertEqual(functions['check']('app', registration, SINCE), expected)

    def test_all_checks_scope_application_environment_and_service(self):
        functions = self.module()
        metrics, logs = [], []
        functions['metric'] = lambda query: metrics.append(query) or True
        stamp = datetime.datetime.fromtimestamp(NOW, datetime.timezone.utc).isoformat()
        def request(port, path, fields):
            logs.append(fields['query'])
            identity=dict(host=REGISTRATION['host'],application='doers',environment='production',service='web')
            if 'service="dragontools-host"' in fields['query']: identity.update(application='host', environment='host',service='dragontools-host')
            stream='{'+','.join(k+'='+json.dumps(v) for k,v in sorted(identity.items()))+'}'
            return json.dumps(dict(identity,_time=stamp,_stream=stream)).encode()
        functions['request'] = request
        registration = self.registration()
        for mode in ('host', 'logs', 'app'):
            self.assertTrue(functions['check'](mode, registration, SINCE))
        self.assertEqual(len(metrics), 6)
        self.assertEqual(len(logs), 2)
        for query in metrics:
            self.assertIn('application="doers"', query)
            self.assertIn('environment="production"', query)
        self.assertIn('service="web"', metrics[-1])
        for identity in ('application="doers"', 'environment="production"', 'service="web"'):
            self.assertIn(identity, logs[1])
        functions['request'] = lambda *_: json.dumps(dict(host=REGISTRATION['host'], application='forged', environment='production', service='web', _time=stamp)).encode()
        with self.assertRaises(ValueError):
            functions['check']('logs', registration, SINCE)

    def test_log_identity_must_be_real_stream_fields_including_quiet_services(self):
        functions = self.module()
        identity = dict(host=REGISTRATION['host'], application='doers', environment='production', service='web')
        stream = '{application="doers",environment="production",host=' + json.dumps(REGISTRATION['host']) + ',service="web"}'
        stamp = datetime.datetime.fromtimestamp(NOW, datetime.timezone.utc).isoformat()
        row = dict(identity, _time=stamp, type='dragontools_stream', level='info')
        for actual in (None, '{}', stream[:-1] + ',path="/healthz"}'):
            functions['request'] = lambda *_, actual=actual: json.dumps(dict(row, _stream=actual)).encode()
            with self.assertRaises(ValueError): functions['log_ready'](identity, SINCE)
        functions['request'] = lambda *_: json.dumps(dict(row, _stream=stream)).encode()
        self.assertTrue(functions['log_ready'](identity, SINCE))
        functions['request'] = lambda *_: b''
        self.assertFalse(functions['log_ready'](identity, SINCE))

    def test_host_only_application_requires_host_event_stream_without_app_log_requests(self):
        functions = self.module()
        registration = self.registration()
        registration['applications'][0]['services'] = []
        functions['request'] = lambda *_: b''
        functions['metric'] = lambda *_: True
        self.assertTrue(functions['check']('host', registration, SINCE))
        self.assertFalse(functions['check']('logs', registration, SINCE))
        self.assertTrue(functions['check']('app', registration, SINCE))
        functions['metric'] = lambda *_: False
        self.assertFalse(functions['check']('host', registration, SINCE))

    def test_payload_names_survive_timestamp_and_result_is_bounded(self):
        functions = self.module()
        queries = []
        def request(port, path, fields):
            query = fields['query']
            queries.append(query)
            # VM rejects sum/count with identical remaining labels after their
            # names are stripped. The real pinned-process gate covers its API.
            if '__name__!~' in query:
                if query.count(' keep_metric_names') != 2:
                    raise ValueError('duplicate output timeseries')
                self.assertTrue(query.startswith('count(('))
                self.assertTrue(query.endswith(')) > 0'))
            return b'{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1800000000,"1"]}]}}'
        functions['request'] = request
        self.assertTrue(functions['check']('app', self.registration(), SINCE))
        self.assertEqual(len(queries), 3)


class MetricsDiagnostics(unittest.TestCase):
    def registration(self):
        return ApplicationSignals().registration()

    def execute(self, mode, body=b'', status=200, active=True, network_error=None):
        class Connection:
            def __init__(self, address, port, timeout):
                assert (address, port, timeout) == ('127.0.0.1', 8429, 5)
            def request(self, method, path):
                assert method == 'GET' and path in ('/api/v1/targets', '/metrics')
            def getresponse(self):
                return types.SimpleNamespace(status=status, read=lambda limit: body[:limit])
            def close(self):
                pass
        with patch('http.client.HTTPConnection', Connection), patch('time.time', return_value=NOW), \
             patch('socket.create_connection', side_effect=network_error, return_value=contextlib.nullcontext()), \
             patch('subprocess.check_output', return_value=b'ActiveState=active\nMainPID=123\n' if active else b'ActiveState=activating\nMainPID=0\n'):
            return entrypoint(METRICS, ['metrics_checks.py', mode, json.dumps(self.registration()), str(SINCE)])

    def target(self, health='up', stamp=NOW):
        app = self.registration()['applications'][0]
        service = app['services'][0]
        return dict(labels=dict(host=REGISTRATION['host'], agent='vmagent', application=app['name'], environment=app['environment'], service=service['name']),
                    scrapeUrl=service['metrics_url'], health=health, lastScrape=datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat(),
                    lastError='PRIVATE error that must never be printed')

    def source(self, targets):
        return self.execute('metrics_source_ready', json.dumps(dict(status='success', data=dict(activeTargets=targets))).encode())

    def test_completed_up_and_down_scrapes_are_valid_but_missing_or_stale_are_not(self):
        for state in ('up', 'down'):
            self.assertEqual(self.source([self.target(state)]), 0)
        self.assertEqual(self.source([]), 75)
        for stamp in (SINCE - 1, NOW - 91):
            self.assertEqual(self.source([self.target(stamp=stamp)]), 75)
        self.assertEqual(self.source([self.target('unknown')]), 75)

    def test_wrong_targets_duplicate_identities_and_malformed_responses_fail_closed(self):
        target = self.target()
        target['scrapeUrl'] = 'http://127.0.0.1:9999/metrics'
        self.assertEqual(self.source([target]), 1)
        self.assertEqual(self.source([self.target(), self.target()]), 1)
        self.assertEqual(self.execute('metrics_source_ready', b'PRIVATE invalid JSON'), 1)
        for status in (400, 401, 403, 404):
            self.assertEqual(self.execute('metrics_source_ready', b'PRIVATE', status), 1)
        self.assertEqual(self.execute('metrics_source_ready', b'PRIVATE', 503), 75)

    def test_successful_writes_required_but_old_failures_do_not_prevent_recovery(self):
        success = b'vmagent_remotewrite_requests_total{url="1:secret-url", status_code="2XX"} 207\n'
        self.assertEqual(self.execute('metrics_remote_write_accepted', success), 0)
        self.assertEqual(self.execute('metrics_remote_write_accepted', success + b'vmagent_remotewrite_errors_total{url="1:secret-url"} 3\n'), 0)
        for body in (b'', success.replace(b'207', b'0'), success.replace(b'2XX', b'4XX'), success.replace(b'207', b'1e999')):
            self.assertEqual(self.execute('metrics_remote_write_accepted', body), 75)

    def test_agent_absence_and_network_absence_retry_without_sensitive_output(self):
        self.assertEqual(self.execute('metrics_agent_active'), 0)
        self.assertEqual(self.execute('metrics_agent_active', active=False), 75)
        self.assertEqual(self.execute('metrics_station_reachable'), 0)
        for error in (socket.gaierror('PRIVATE'), ConnectionRefusedError('PRIVATE'), TimeoutError('PRIVATE')):
            self.assertEqual(self.execute('metrics_station_reachable', network_error=error), 75)


if __name__ == '__main__':
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=1).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    sys.exit(0 if result.wasSuccessful() else 1)
