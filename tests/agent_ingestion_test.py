"""Real local TLS authorization/routes. Independent of enrollment mutations.

Certificates are generated in this fixture's client directories. No station
helper receives client private keys and no SSH/real monitoring host is used.
"""
import contextlib
import hashlib
import http.client
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import ssl
import socket
import subprocess
import tempfile
import threading
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HOST = 'dt-' + 'a' * 32
OTHER_HOST = 'dt-' + 'b' * 32
IDENTITY = 'dragontools://hosts/' + HOST


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ingestion = load('agent_ingestion', 'src/monitoring/agents/ingestion.py')
native = load('native_pki', 'tests/native_pki.py')


class Endpoint:
    @staticmethod
    def check(hostname, directory, port):
        return native.endpoint(hostname, directory, port, HOST)


endpoint = Endpoint()


def refused(call):
    try:
        call()
    except (ValueError, FileNotFoundError, OSError, subprocess.CalledProcessError):
        return
    raise AssertionError('Expected rejection')


def issue(root, ca, name, cn, san=None, purpose='clientAuth', days='365'):
    directory = root / name
    directory.mkdir(mode=0o700)
    if days == '0':
        kind = 'expired'
    elif purpose == 'serverAuth':
        kind = 'server' if cn == 'localhost' else 'wrong_purpose'
    elif san is None:
        kind = 'legacy'
    elif ',DNS:' in san:
        kind = 'extra_san'
    elif san != 'URI:dragontools://hosts/' + cn:
        kind = 'wrong_san'
    else:
        kind = 'client'
    native.issue(ca, directory, kind, cn)
    return directory


def fingerprint(directory):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert((directory / 'client.crt').read_text())).hexdigest()


class Backend(http.server.BaseHTTPRequestHandler):
    requests = []

    def do_POST(self):
        size = int(self.headers['Content-Length'])
        self.requests.append((self.path, dict(self.headers), self.rfile.read(size)))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


def serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def main():
    with tempfile.TemporaryDirectory(prefix='dragontools-agent-ingestion-') as temporary, contextlib.ExitStack() as stack:
        root = Path(temporary)
        ca = root / 'station-ca'
        ca.mkdir(mode=0o700)
        native.ca(ca)
        server_files = issue(root, ca, 'station-server', 'localhost', 'DNS:localhost', 'serverAuth')
        (server_files / 'server.crt').write_bytes((server_files / 'client.crt').read_bytes())
        (server_files / 'server.key').write_bytes((server_files / 'client.key').read_bytes())
        clients = {
            'active': issue(root, ca, 'app-active', HOST, 'URI:' + IDENTITY),
            'candidate': issue(root, ca, 'app-candidate', HOST, 'URI:' + IDENTITY),
            'unregistered': issue(root, ca, 'app-unregistered', HOST, 'URI:' + IDENTITY),
            'wrong_san': issue(root, ca, 'app-wrong-san', HOST, 'URI:dragontools://hosts/' + OTHER_HOST),
            'other_host': issue(root, ca, 'app-other-host', OTHER_HOST, 'URI:dragontools://hosts/' + OTHER_HOST),
            'extra_san': issue(root, ca, 'app-extra-san', HOST, 'URI:' + IDENTITY + ',DNS:extra.example'),
            'wrong_purpose': issue(root, ca, 'app-server-purpose', HOST, 'URI:' + IDENTITY, 'serverAuth'),
            'expired': issue(root, ca, 'app-expired', HOST, 'URI:' + IDENTITY, days='0'),
            'legacy': issue(root, ca, 'app-legacy', HOST),
        }
        registry = root / 'station-registry'
        registry.mkdir(mode=0o750)
        record = registry / (HOST + '.json')
        registration = dict(version=1, host=HOST, station='localhost', services=['one.service', 'two.service'], metrics_targets=[])
        def register(which='active', modern=True, **fields):
            value = dict(registration, certificate_sha256=fingerprint(clients[which]))
            if modern:
                value['certificate_identity'] = IDENTITY
            value.update(fields)
            record.write_text(json.dumps(value))
            record.chmod(0o640)
        register()
        stack.enter_context(patch.object(ingestion, 'ROOT', os.getuid()))
        backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
        backend_thread = serve(backend)
        server = ingestion.Server(('127.0.0.1', 0), ingestion.context(str(server_files)), str(registry), metrics_port=backend.server_port, logs_port=backend.server_port)
        server_thread = serve(server)
        def tls_for(which):
            tls = ssl.create_default_context(cafile=str(ca / 'ca.crt'))
            if which is not None:
                tls.load_cert_chain(str(clients[which] / 'client.crt'), str(clients[which] / 'client.key'))
            return tls
        def request(method, route, body=b'', headers=None, which='active'):
            connection = http.client.HTTPSConnection('localhost', server.server_port, context=tls_for(which), timeout=3)
            try:
                connection.request(method, route, body, headers or {})
                response = connection.getresponse()
                response.read()
                return response.status
            finally:
                connection.close()
        try:
            assert endpoint.check('/', str(clients['active']), server.server_port) == 91
            with socket.socket() as unavailable:
                unavailable.bind(('127.0.0.1', 0))
                # Bound but not listening: refused without a race for a free port.
                assert endpoint.check('localhost', str(clients['active']), unavailable.getsockname()[1]) == 92
            assert request('GET', '/health') == 204
            assert endpoint.check('localhost', str(clients['active']), server.server_port) == 0
            # CA signature alone, mismatched identities and extra identities fail.
            assert request('GET', '/health', which='unregistered') == 403
            assert request('GET', '/health', which='other_host') == 403
            for which in ('wrong_san', 'extra_san'):
                register(which)
                assert request('GET', '/health', which=which) == 403
            for which in ('wrong_purpose', 'expired'):
                register(which)
                refused(lambda: request('GET', '/health', which=which))
                assert endpoint.check('localhost', str(clients[which]), server.server_port) == 94
            register()
            assert endpoint.check('127.0.0.1', str(clients['active']), server.server_port) == 93
            assert endpoint.check('localhost', str(clients['unregistered']), server.server_port) == 94
            refused(lambda: request('GET', '/health', which=None))
            # Explicitly enrolled candidate and old active credentials coexist.
            pending = dict(registration, services=['candidate.service'])
            register(pending_certificate_sha256=fingerprint(clients['candidate']), pending_registration=pending, pending_expires_at=int(time.time()) + 86400)
            assert request('GET', '/health') == request('GET', '/health', which='candidate') == 204
            assert request('POST', '/insert/jsonline', b'{"service":"candidate.service"}', which='candidate') == 204
            assert request('POST', '/insert/jsonline', b'{"service":"one.service"}', which='candidate') == 403
            assert request('POST', '/insert/jsonline', b'{"service":"one.service"}') == 204
            # Metadata-only enrollment reuses the active certificate but must
            # authorize the pending scope so new telemetry can be verified.
            register(pending_certificate_sha256=fingerprint(clients['active']), pending_registration=pending, pending_expires_at=int(time.time()) + 86400)
            assert request('POST', '/insert/jsonline', b'{"service":"candidate.service"}') == 204
            assert request('POST', '/insert/jsonline', b'{"service":"one.service"}') == 403
            register(pending_certificate_sha256=fingerprint(clients['candidate']), pending_registration=pending, pending_expires_at=int(time.time()) - 1)
            assert request('GET', '/health', which='candidate') == 403
            register(pending_certificate_sha256=fingerprint(clients['candidate']), pending_registration=pending, pending_expires_at=int(time.time()) + 172800)
            assert request('GET', '/health', which='candidate') == 403
            register(certificate_sha256=None, pending_certificate_sha256=fingerprint(clients['candidate']), pending_registration=pending, pending_expires_at=int(time.time()) + 86400)
            assert request('GET', '/health') == 403
            assert request('GET', '/health', which='candidate') == 204
            register('legacy', modern=False)
            assert request('GET', '/health', which='legacy') == 204
            register('active', modern=False)
            assert request('GET', '/health') == 403
            register()
            assert request('GET', '/health', which='legacy') == 403
            # Existing fixed routes, body bounds and trusted-label rewriting.
            body = b'{"service":"one.service","host":"spoof","message":"hello"}\n'
            assert request('POST', '/insert/jsonline', body) == 204
            route, headers, received = Backend.requests[-1]
            assert route == '/insert/jsonline?_stream_fields=host,service&_time_field=timestamp&_msg_field=message'
            assert json.loads(received)['host'] == HOST
            assert request('POST', '/api/v1/write', b'snappy-fixture', {'Content-Encoding': 'snappy', 'Authorization': 'must-not-forward'}) == 204
            route, headers, received = Backend.requests[-1]
            assert route == '/api/v1/write?extra_label=host%3D' + HOST
            assert 'Authorization' not in headers and received == b'snappy-fixture'
            count = len(Backend.requests)
            assert request('GET', '/api/v1/query?query=up') == 405
            assert request('POST', '/api/v1/write?extra_label=host=other', b'test') == 404
            assert request('POST', '/insert/jsonline', b'{"service":"other.service"}') == 403
            assert request('POST', '/insert/jsonline', b'bad-json') == 403
            assert request('POST', '/api/v1/write', b'test', {'Content-Encoding': 'zstd'}) == 400
            assert request('POST', '/api/v1/write', b'\xff\xff\xff\xff\x0f', {'Content-Encoding': 'snappy'}) == 403
            assert request('PUT', '/health') == 405
            assert request('POST', '/insert/jsonline', b'test', {'Content-Length': str(ingestion.BODY_LIMIT + 1)}) == 413
            assert len(Backend.requests) == count
            for name, value in (('Content-Length', '4'), ('Transfer-Encoding', 'chunked')):
                connection = http.client.HTTPSConnection('localhost', server.server_port, context=tls_for('active'), timeout=3)
                connection.putrequest('POST', '/insert/jsonline')
                connection.putheader('Content-Length', '4')
                connection.putheader(name, value)
                connection.endheaders(b'test')
                response = connection.getresponse()
                assert response.status == 400
                response.read()
                connection.close()
            app = dict(name='doers', environment='production', services=[dict(name='web', systemd='one.service', logs=True, metrics_url=None)])
            registered = dict(registration, services=['one.service'], applications=[app])
            forged = b'{"journal_unit":"one.service","service":"forged","application":"forged","environment":"forged","host":"forged"}'
            assert json.loads(ingestion.log_body(forged, registered)) == dict(service='web', application='doers', environment='production', host=HOST)
            refused(lambda: ingestion.log_body(b'{"journal_unit":"two.service"}', registered))
            record.chmod(0o600)
            assert request('GET', '/health') == 403
        finally:
            server.shutdown()
            backend.shutdown()
            server.server_close()
            backend.server_close()
            server_thread.join()
            backend_thread.join()
    print('Gateway real TLS identity/purpose/expiry/rollout, endpoint diagnostics and fixed-route fixtures passed.')


if __name__ == '__main__':
    main()
