"""Explicit isolated Linux process fixture; not a systemd/disposable-host test.

Run with a read-only /fixture containing reviewed arm64 binaries, disposable
certificates, full.yaml and prometheus.yml. No download or external request occurs.
The caller must isolate networking: all fixture services use local loopback.
"""
import hashlib
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
PINS = {
    "victoria-metrics-prod": "d6fc7e82108e1352bf300cab5c7f2ea7a05c23f09c47e0b566b53c18c07406d1",
    "victoria-logs-prod": "2d279a10a3358f7bbad054a0210fb4cd8dbcf6aa2a601ce295146632a8bf615e",
    "vmagent": "da7046c7310c39ce3a93dc67f8f9562fa77a7fc9ec3d95b0cf8d9dcb6321679d",
}


def prepare_credentials(fixture):
    """Generate only disposable localhost test identities; never export a real CA."""
    os.umask(0o077)
    certs = fixture / "certs"
    certs.mkdir(mode=0o700)
    def run(*args):
        subprocess.run(["openssl", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=20)
    run("req", "-new", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "2",
        "-keyout", str(certs / "ca.key"), "-out", str(certs / "ca.crt"), "-subj", "/CN=Disposable fixture CA",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    for name, subject, extensions in (("server", "localhost", "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n"),
                                      ("client", "application-one", "extendedKeyUsage=clientAuth\n")):
        run("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", str(certs / (name + ".key")),
            "-out", str(certs / (name + ".csr")), "-subj", "/CN=" + subject)
        (certs / "extensions").write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n" + extensions)
        run("x509", "-req", "-in", str(certs / (name + ".csr")), "-CA", str(certs / "ca.crt"), "-CAkey", str(certs / "ca.key"),
            "-set_serial", "0x" + os.urandom(16).hex(), "-days", "2", "-extfile", str(certs / "extensions"), "-out", str(certs / (name + ".crt")))
    print("Disposable localhost fixture credentials prepared.")


def request(port, method, path, body=None, context=None, headers=None):
    connection = (http.client.HTTPSConnection("localhost", port, timeout=3, context=context) if context else
                  http.client.HTTPConnection("127.0.0.1", port, timeout=3))
    try:
        connection.request(method, path, body, headers or {})
        response = connection.getresponse()
        result = response.read(1024 * 1024)
        assert 200 <= response.status < 300
        return result
    finally:
        connection.close()


def until(check, seconds=45):
    deadline = time.monotonic() + seconds
    while True:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, AssertionError):
            pass
        if time.monotonic() >= deadline:
            raise AssertionError("Bounded fixture verification timed out")
        time.sleep(min(0.5, deadline - time.monotonic()))


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def field(number, data):
    return varint(number * 8 + 2) + varint(len(data)) + data


def sample():
    labels = b"".join(field(1, field(1, name.encode()) + field(2, value.encode())) for name, value in
                       (("__name__", "dragontools_identity_fixture"), ("host", "forged-host")))
    point = b"\x09" + struct.pack("<d", 1.0) + b"\x10" + varint(int(time.time() * 1000))
    protobuf = field(1, labels + field(2, point))
    # A standards-compliant Snappy literal-only block avoids any fixture dependency.
    length = len(protobuf)
    if length < 61:
        tag = bytes([(length - 1) << 2])
    else:
        size = (length - 1).bit_length() + 7 >> 3
        tag = bytes([(59 + size) << 2]) + (length - 1).to_bytes(size, "little")
    return varint(length) + tag + protobuf


class Application(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"# TYPE fixture_requests_total counter\nfixture_requests_total{host=\"forged-application\",application=\"forged\",environment=\"forged\",service=\"forged\"} 7\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    fixture = Path(sys.argv[1])
    applications = "--applications" in sys.argv
    for name, expected in PINS.items():
        assert hashlib.sha256((fixture / name).read_bytes()).hexdigest() == expected
    # Vector pin comes from the production component's reviewed binary digest.
    source = (ROOT / "src/components/vector.zig").read_text()
    assert hashlib.sha256((fixture / "vector").read_bytes()).hexdigest() in source
    spec = importlib.util.spec_from_file_location("ingestion", ROOT / "src/monitoring/agents/ingestion.py")
    ingestion = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ingestion)
    ingestion.ROOT = os.getuid()
    spec = importlib.util.spec_from_file_location("signals", ROOT / "src/monitoring/agents/signals.py")
    signals = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signals)
    children, servers = [], []
    with tempfile.TemporaryDirectory(prefix="dragontools-pipeline-") as temporary:
        temp = Path(temporary)
        registry = temp / "registry"
        registry.mkdir()
        cert = (fixture / "certs/client.crt").read_text()
        record = {"version": 1, "host": "application-one", "station": "localhost",
                  "services": ["doers.service", "orderflow.service"],
                  "metrics_targets": [{"name": "software", "url": "http://127.0.0.1:16000/metrics"}],
                  "certificate_sha256": hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest()}
        if applications:
            record = dict(json.loads((fixture / "apps-registration.json").read_text()), certificate_sha256=record["certificate_sha256"])
        record_path = registry / "application-one.json"
        record_path.write_text(json.dumps(record))
        record_path.chmod(0o640)
        def start(args, input_stream=False):
            child = subprocess.Popen(args, stdin=subprocess.PIPE if input_stream else subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            children.append(child)
            return child
        def query(expression):
            data = json.loads(request(8428, "GET", "/api/v1/query?" + urllib.parse.urlencode({"query": expression})))
            return data.get("data", {}).get("result", [])
        try:
            start([str(fixture / "victoria-metrics-prod"), "-httpListenAddr=127.0.0.1:8428", "-storageDataPath=" + str(temp / "vm"),
                   "-memory.allowedBytes=67108864", "-search.latencyOffset=0s"])
            start([str(fixture / "victoria-logs-prod"), "-httpListenAddr=127.0.0.1:9428", "-storageDataPath=" + str(temp / "vl"),
                   "-memory.allowedBytes=67108864"])
            until(lambda: request(8428, "GET", "/health") is not None)
            until(lambda: request(9428, "GET", "/health") is not None)
            proxy = ingestion.Server(("127.0.0.1", 9443), ingestion.context(str(fixture / "certs")), str(registry))
            servers.append(proxy)
            threading.Thread(target=proxy.serve_forever, daemon=True).start()
            tls = ssl.create_default_context(cafile=str(fixture / "certs/ca.crt"))
            tls.load_cert_chain(str(fixture / "certs/client.crt"), str(fixture / "certs/client.key"))
            request(9443, "GET", "/health", context=tls)
            request(9443, "POST", "/api/v1/write", sample(), tls, {"Content-Encoding": "snappy"})
            values = until(lambda: query('dragontools_identity_fixture{host="application-one"}'))
            assert values[0]["metric"]["host"] == "application-one"
            assert not query('dragontools_identity_fixture{host="forged-host"}')
            print("PASS: real VictoriaMetrics v1.151.0 enforces authenticated host over duplicate submitted label", flush=True)

            config = (fixture / ("apps-vector.yaml" if applications else "full.yaml")).read_text()
            begin = config.index("  journal:\n")
            end = config.index("  stream_0:\n", begin)
            # This process fixture has no systemd/journal. Retain production VRL,
            # host/internal sources, metadata, TLS, batching and bounded buffers.
            config = config[:begin] + "  journal:\n    type: stdin\n    decoding:\n      codec: json\n" + config[end:]
            config = config.replace("/var/lib/dragontools/vector", str(temp / "vector"))
            config = config.replace("/etc/dragontools/vector", str(fixture / "certs"))
            config = config.replace("monitor.example", "localhost")
            (temp / "vector").mkdir()
            (temp / "vector.yaml").write_text(config)
            vector_since = time.time()
            # First validate the exact production renderer output (before the
            # journald-to-stdin fixture substitution) with the pinned executable.
            subprocess.run([str(fixture / "vector"), "validate", "--no-environment", "--skip-healthchecks", str(fixture / ("apps-vector.yaml" if applications else "full.yaml"))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            vector = start([str(fixture / "vector"), "--config", str(temp / "vector.yaml")], input_stream=applications)
            if applications:
                event = {"_SYSTEMD_UNIT": "doers.service", "message": json.dumps(dict(message="structured fixture", application="forged", environment="forged", service="forged", host="forged", request_id="fixture-request", level="info")), "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "PRIORITY": "6"}
                vector.stdin.write((json.dumps(event) + "\n").encode()); vector.stdin.flush()
            until(lambda: query('host_cpu_seconds_total{host="application-one"}'))
            until(lambda: signals.check("host", record, vector_since))
            assert not signals.check("host", record, time.time() + 3600)
            assert vector.poll() is None
            print("PASS: real Vector v0.58.0 host metrics traverse mTLS into real VictoriaMetrics", flush=True)
            def streams():
                result = request(9428, "POST", "/select/logsql/query",
                                 urllib.parse.urlencode({"query": 'host:="application-one" type:="dragontools_stream" | fields service'}),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
                names = {json.loads(line)["service"] for line in result.splitlines()}
                return names == ({"web"} if applications else {"doers.service", "orderflow.service"})
            until(streams)
            until(lambda: signals.check("logs", record, vector_since))
            assert not signals.check("logs", record, time.time() + 3600)
            print("PASS: selected-service Vector metadata traverses mTLS into real VictoriaLogs v1.52.0", flush=True)
            if applications:
                def trusted_event():
                    result = request(9428, "POST", "/select/logsql/query", urllib.parse.urlencode({"query": 'request_id:="fixture-request" | limit 1'}), headers={"Content-Type": "application/x-www-form-urlencoded"})
                    if not result.strip(): return False
                    event = json.loads(result.splitlines()[0])
                    assert all(event.get(key) == value for key, value in dict(application="doers", environment="production", service="web", host="application-one").items())
                    return True
                until(trusted_event)
                for app in record["applications"]:
                    assert query('host_cpu_seconds_total{application=' + json.dumps(app['name']) + ',environment=' + json.dumps(app['environment']) + ',host="application-one"}')
                host_only = next(app for app in record['applications'] if app['name'] == 'hostonly')
                assert not host_only['services']
                print("PASS: native application logs override forged identities; three host scopes include a service-free application", flush=True)

            application = http.server.ThreadingHTTPServer(("127.0.0.1", 16000), Application)
            servers.append(application)
            threading.Thread(target=application.serve_forever, daemon=True).start()
            vmagent_since = time.time()
            vmagent = start([str(fixture / "vmagent"), "-httpListenAddr=127.0.0.1:8429",
                            "-promscrape.config=" + str(fixture / ("apps-prometheus.yml" if applications else "prometheus.yml")),
                            "-remoteWrite.url=https://localhost:9443/api/v1/write", "-remoteWrite.forcePromProto=true",
                            "-remoteWrite.tlsCAFile=" + str(fixture / "certs/ca.crt"),
                            "-remoteWrite.tlsCertFile=" + str(fixture / "certs/client.crt"),
                            "-remoteWrite.tlsKeyFile=" + str(fixture / "certs/client.key"),
                            "-remoteWrite.tmpDataPath=" + str(temp / "vmagent"), "-remoteWrite.maxDiskUsagePerURL=1GiB"])
            until(lambda: query('fixture_requests_total{host="application-one",application="doers",environment="production",service="web"}' if applications else 'fixture_requests_total{host="application-one",app="software"}'))
            until(lambda: signals.check("app", record, vmagent_since))
            assert not signals.check("app", record, time.time() + 3600)
            assert vmagent.poll() is None
            assert not query('fixture_requests_total{host="forged-application"}')
            if applications:
                assert query('fixture_requests_total{application="orderflow",environment="staging",service="web"}')
                assert not query('fixture_requests_total{application="forged"}')
            print("PASS: real vmagent v1.152.0 application metrics traverse mTLS with trusted host identity", flush=True)
            print("PASS: production host/log/app signal queries accept fresh arrivals and reject pre-start samples", flush=True)
        finally:
            for child in reversed(children):
                child.terminate()
            for child in reversed(children):
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            for server in reversed(servers):
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--prepare-credentials":
        prepare_credentials(Path(sys.argv[2]))
    else:
        main()
