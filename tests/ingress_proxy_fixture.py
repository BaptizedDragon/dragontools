"""Local fixture adapters. The TLS stand-in is test-only, never installed.

Pass an actual pinned Caddy binary to exercise the production Caddyfile instead.
Both variants use the production Unix-socket authorization/normalization helper.
"""
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=4)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def start(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def forward(self):
        peer = self.connection.getpeercert()
        sans = peer.get('subjectAltName', ())
        def names(kind):
            return [value for tag, value in sans if tag == kind]
        cn = [value for rdn in peer['subject'] for key, value in rdn if key == 'commonName']
        headers = [(key, value) for key, value in self.headers.items() if not key.lower().startswith('x-dragontools-')]
        uri = names('URI')
        assertions = dict(Fingerprint=hashlib.sha256(self.connection.getpeercert(binary_form=True)).hexdigest(),
                          Subject='CN=' + ','.join(cn), URI=uri[0] if uri else '',
                          **{'Other-URI': uri[1] if len(uri) > 1 else '',
                             'DNS': ','.join(names('DNS')), 'IP': ','.join(names('IP Address')), 'Email': ','.join(names('email'))})
        headers.extend(('X-DragonTools-' + key, value) for key, value in assertions.items())
        connection = UnixConnection(self.server.upstream)
        try:
            connection.putrequest(self.command, self.path)
            for key, value in headers:
                connection.putheader(key, value)
            size = int(self.headers.get('Content-Length', '0'))
            # Oversize/ambiguous frames are rejected by the real helper before
            # reading. Forward only the header to avoid a blind fixture read.
            body = b'' if size > 4 * 1024 * 1024 or len(self.headers.get_all('Content-Length', [])) > 1 or 'Transfer-Encoding' in self.headers else self.rfile.read(size)
            connection.endheaders(body)
            response = connection.getresponse()
            response.read()
            self.send_response(response.status)
            self.send_header('Content-Length', '0')
            self.end_headers()
        finally:
            connection.close()
    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = forward


class TlsProxy(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, files, upstream):
        super().__init__(('127.0.0.1', 0), Proxy)
        self.upstream = upstream
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(str(files / 'ca.crt'))
        ctx.load_cert_chain(str(files / 'server.crt'), str(files / 'server.key'))
        self.socket = ctx.wrap_socket(self.socket, server_side=True)


class Harness:
    def __init__(self, root, files, registry, ingestion, backend_port, binary=None, ports=None):
        self.servers, self.threads = [], []
        self.process = None
        self.ports = dict(ports or {})
        sockets = {}
        for signal in ('metrics', 'logs'):
            path = root / (signal + '.sock')
            server = ingestion.Server(str(path), str(registry), signal, upstream_port=backend_port[signal] if isinstance(backend_port, dict) else backend_port)
            assert (path.stat().st_mode & 0o777) == 0o660
            self.servers.append(server); self.threads.append(start(server))
            sockets[signal] = path
        if binary is None:
            for signal in ('metrics', 'logs'):
                server = TlsProxy(files, sockets[signal])
                self.servers.append(server); self.threads.append(start(server))
                self.ports[signal] = server.server_port
        else:
            # Only fixture bind/credential/socket paths differ from production.
            config = (ROOT / 'src/monitoring/agents/Caddyfile').read_text()
            for signal, production in (('metrics', 9443), ('logs', 9444)):
                if signal not in self.ports:
                    with socket.socket() as reservation:
                        reservation.bind(('127.0.0.1', 0))
                        self.ports[signal] = reservation.getsockname()[1]
                config = config.replace(':' + str(production), ':' + str(self.ports[signal]))
                config = config.replace('/run/dragontools-ingress/' + signal + '.sock', str(sockets[signal]))
            config = config.replace('tcp4/0.0.0.0', 'tcp4/127.0.0.1')
            path = root / 'Caddyfile'; path.write_text(config)
            env = dict(os.environ, CREDENTIALS_DIRECTORY=str(files), HOME=str(root), XDG_DATA_HOME=str(root/'data'), XDG_CONFIG_HOME=str(root/'config'))
            result = subprocess.run([binary, 'adapt', '--config', str(path), '--adapter', 'caddyfile'], env=env, capture_output=True, check=True)
            value = json.loads(result.stdout)
            assert value['admin']['disabled'] is True
            servers = value['apps']['http']['servers']
            assert len(servers) == 2
            for spec in servers.values():
                assert spec['automatic_https']['disable'] is True
                assert spec['protocols'] == ['h1']
                assert spec['tls_connection_policies'][0]['client_authentication']['mode'] == 'require_and_verify'
            validated = subprocess.run([binary, 'validate', '--config', str(path), '--adapter', 'caddyfile'], env=env, capture_output=True)
            if validated.returncode:
                assert b'PRIVATE KEY' not in validated.stderr
                raise AssertionError(validated.stderr.decode())
            self.process = subprocess.Popen([binary, 'run', '--config', str(path), '--adapter', 'caddyfile'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 10
            for port in self.ports.values():
                while True:
                    if self.process.poll() is not None:
                        raise AssertionError('Caddy stopped during fixture startup')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise AssertionError('Caddy startup deadline')
                        time.sleep(0.02)  # Retry readiness, never a blind startup sleep.
        self.server_port = self.ports['metrics']

    def close(self):
        if self.process:
            self.process.terminate()
            out, err = self.process.communicate(timeout=10)
            assert b'PRIVATE KEY' not in out + err
        for server in self.servers:
            server.shutdown(); server.server_close()
        for thread in self.threads:
            thread.join(timeout=5)
