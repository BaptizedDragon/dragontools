"""Local fixtures: real certificates/TLS, fake Victoria HTTP backends; no hosts."""
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
import subprocess
import tempfile
import threading
import types
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pki = load("agent_pki", "src/monitoring/agents/pki.py")
ingestion = load("agent_ingestion", "src/monitoring/agents/ingestion.py")


def refused(call):
    try:
        call()
    except (ValueError, FileNotFoundError, OSError, subprocess.CalledProcessError):
        return
    raise AssertionError("Expected rejection")


class Backend(http.server.BaseHTTPRequestHandler):
    requests = []

    def do_POST(self):
        size = int(self.headers["Content-Length"])
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
    uid, gid = os.getuid(), os.getgid()
    account = types.SimpleNamespace(pw_uid=uid, pw_gid=gid)
    real_read, real_directory = pki.read, pki.directory
    real_chown, real_fchown = os.chown, os.fchown
    real_run = subprocess.run
    stops = []

    def command(args, **kwargs):
        if args[0] == "systemctl":
            if args[1] == "is-active":
                return types.SimpleNamespace(returncode=0, stdout=b"active\n")
            stops.append(args[-1])
            return types.SimpleNamespace(returncode=0)
        return real_run(args, **kwargs)

    with tempfile.TemporaryDirectory(prefix="dragontools-agent-ingestion-") as temporary, contextlib.ExitStack() as stack:
        path = Path(temporary)
        etc, state = path / "etc", path / "state"
        etc.mkdir(mode=0o755)
        state.mkdir(mode=0o755)
        base = etc / "ingestion"
        base.mkdir(mode=0o755)
        for kind in ("vector", "vmagent"):
            (etc / kind).mkdir(mode=0o755)
        # Model root metadata using this unprivileged fixture user's UID/GID.
        stack.enter_context(patch.object(pki, "ROOT", uid))
        stack.enter_context(patch.object(ingestion, "ROOT", uid))
        stack.enter_context(patch.object(pki, "BASE", str(base)))
        stack.enter_context(patch.object(pki, "ETC", str(etc)))
        stack.enter_context(patch.object(pki, "STATE", str(state)))
        stack.enter_context(patch.object(pki.pwd, "getpwnam", return_value=account))
        stack.enter_context(patch.object(pki, "read", side_effect=lambda path, u, g, *a: real_read(path, u, gid if g == uid else g, *a)))
        stack.enter_context(patch.object(pki, "directory", side_effect=lambda path, mode, u, g, *a: real_directory(path, mode, u, gid if g == uid else g, *a)))
        stack.enter_context(patch.object(os, "chown", side_effect=lambda path, u, g: real_chown(path, u, gid if g == uid else g)))
        stack.enter_context(patch.object(os, "fchown", side_effect=lambda fd, u, g: real_fchown(fd, u, gid if g == uid else g)))
        stack.enter_context(patch.object(subprocess, "run", side_effect=command))
        registration = {"version": 1, "host": "application-one", "station": "localhost",
                        "services": ["one.service", "two.service"], "metrics_targets": []}
        pki.registration(registration)
        assert pki.ensure(registration) == "changed"
        before = {str(x): (x.read_bytes(), x.stat().st_mtime_ns) for x in base.rglob("*") if x.is_file()}
        assert pki.ensure(registration) == "unchanged"
        assert before == {str(x): (x.read_bytes(), x.stat().st_mtime_ns) for x in base.rglob("*") if x.is_file()}
        pki.verify_station(registration)
        refused(lambda: pki.ensure(dict(registration, station="different.example")))
        assert pki.ensure(registration) == "unchanged"
        public, fingerprint = pki.read_registration("application-one")
        assert public == registration and "certificate_sha256" not in public
        payload = json.loads(pki.export("application-one"))
        assert pki.import_credentials("vector", payload) == "changed"
        assert stops == ["dragontools-vector.service"]
        assert not (state / "vmagent-restart-required").exists()
        with patch.object(pki.tempfile, "TemporaryDirectory", side_effect=AssertionError("No-op must not stage secrets")):
            assert pki.import_credentials("vector", payload) == "unchanged"
        assert stops == ["dragontools-vector.service"]
        pki.verify_credentials("vector", "application-one", "localhost")
        assert pki.import_credentials("vmagent", payload) == "changed"
        pki.verify_credentials("vmagent", "application-one", "localhost")
        for kind in ("vector", "vmagent"):
            for name in pki.SECRET_FILES:
                assert (etc / kind / name).stat().st_mode & 0o777 == 0o400
        wrong = dict(payload, host="different-host")
        refused(lambda: pki.import_credentials("vector", wrong))
        assert len(stops) == 2
        refused(lambda: pki.verify_credentials("vector", "application-one", "another-station"))
        key = etc / "vector/client.key"
        saved = key.read_bytes()
        key.unlink()
        key.symlink_to(etc / "vmagent/client.key")
        refused(lambda: pki.import_credentials("vector", payload))
        key.unlink()
        key.write_bytes(saved)
        key.chmod(0o400)

        application_registration = dict(registration, host="application-two", services=["one.service"], applications=[dict(name="doers", environment="production", services=[dict(name="web", systemd="one.service", logs=True, metrics_url=None)])])
        pki.registration(application_registration)
        assert pki.ensure(application_registration) == "changed"
        pki.verify_station(application_registration)
        assert pki.ensure(application_registration) == "unchanged"
        forged = b'{"journal_unit":"one.service","service":"forged","application":"forged","environment":"forged","host":"forged"}'
        trusted = json.loads(ingestion.log_body(forged, application_registration))
        assert trusted == dict(service="web", application="doers", environment="production", host="application-two")
        refused(lambda: ingestion.log_body(b'{"journal_unit":"two.service","service":"web"}', application_registration))
        refused(lambda: pki.registration(dict(application_registration, services=["two.service"])))
        refused(lambda: pki.ensure(dict(application_registration, host="application-one")))
        refused(lambda: pki.ensure(dict(registration, host="application-two")))
        assert pki.ensure(registration) == "unchanged"

        backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        backend_thread = serve(backend)
        server = ingestion.Server(("127.0.0.1", 0), ingestion.context(str(base / "server")), str(base / "registry"),
                                  metrics_port=backend.server_port, logs_port=backend.server_port)
        server_thread = serve(server)
        try:
            tls = ssl.create_default_context(cafile=str(etc / "vector/ca.crt"))
            tls.load_cert_chain(str(etc / "vector/client.crt"), str(etc / "vector/client.key"))

            def request(method, route, body=b"", headers=None, context=tls):
                connection = http.client.HTTPSConnection("localhost", server.server_port, context=context, timeout=3)
                try:
                    connection.request(method, route, body, headers or {})
                    response = connection.getresponse()
                    response.read()
                    return response.status
                finally:
                    connection.close()

            assert request("GET", "/health") == 204
            assert not Backend.requests
            body = b'{"service":"one.service","host":"spoof","message":"hello","timestamp":"2026-01-01T00:00:00Z"}\n'
            assert request("POST", "/insert/jsonline", body) == 204
            route, headers, received = Backend.requests[-1]
            assert route == "/insert/jsonline?_stream_fields=host,service&_time_field=timestamp&_msg_field=message"
            assert json.loads(received)["host"] == "application-one"
            assert request("POST", "/api/v1/write", b"snappy-fixture", {"Content-Encoding": "snappy", "Authorization": "must-not-forward"}) == 204
            route, headers, received = Backend.requests[-1]
            assert route == "/api/v1/write?extra_label=host%3Dapplication-one"
            assert "Authorization" not in headers and received == b"snappy-fixture"
            count = len(Backend.requests)
            assert request("GET", "/api/v1/query?query=up") == 405
            assert request("POST", "/api/v1/write?extra_label=host=other", b"test") == 404
            assert request("POST", "/insert/jsonline", b'{"service":"other.service"}') == 403
            assert request("POST", "/insert/jsonline", b"bad-json") == 403
            assert request("POST", "/api/v1/write", b"test", {"Content-Encoding": "zstd"}) == 400
            assert request("POST", "/api/v1/write", b"\xff\xff\xff\xff\x0f", {"Content-Encoding": "snappy"}) == 403
            assert request("PUT", "/health") == 405
            assert request("POST", "/insert/jsonline", b"test", {"Content-Length": str(ingestion.BODY_LIMIT + 1)}) == 413
            assert len(Backend.requests) == count
            # Duplicate lengths and transfer encoding are rejected before a body read.
            for name, value in (("Content-Length", "4"), ("Transfer-Encoding", "chunked")):
                connection = http.client.HTTPSConnection("localhost", server.server_port, context=tls, timeout=3)
                connection.putrequest("POST", "/insert/jsonline")
                connection.putheader("Content-Length", "4")
                connection.putheader(name, value)
                connection.endheaders(b"test")
                response = connection.getresponse()
                assert response.status == 400
                response.read()
                connection.close()
            assert len(Backend.requests) == count
            unauthenticated = ssl.create_default_context(cafile=str(etc / "vector/ca.crt"))
            try:
                request("GET", "/health", context=unauthenticated)
            except (ssl.SSLError, OSError, http.client.RemoteDisconnected):
                pass
            else:
                raise AssertionError("Client certificate was not required")
            record = base / "registry/application-one.json"
            previous = record.read_bytes()
            record.chmod(0o600)
            record.write_bytes(previous.replace(fingerprint.encode(), b"0" * 64))
            record.chmod(0o640)
            assert request("GET", "/health") == 403
            assert len(Backend.requests) == count
            record.chmod(0o600)
            record.write_bytes(previous)
            record.chmod(0o640)
            assert request("GET", "/health") == 204
        finally:
            server.shutdown()
            backend.shutdown()
            server.server_close()
            backend.server_close()
            server_thread.join()
            backend_thread.join()

        # Entrypoint failures never reveal input bytes or Python exception text.
        result = real_run(["python3", "-I", "-B", str(ROOT / "src/monitoring/agents/pki.py"), "import", "vector"],
                          input=b'{"client.key":"secret-sentinel"}', stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode == 86 and result.stdout == result.stderr == b""
    print("Agent mTLS, restricted routes, credential ownership/no-op and failure-redaction fixtures passed.")


if __name__ == "__main__":
    main()
