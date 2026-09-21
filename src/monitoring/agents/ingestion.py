# Managed by DragonTools
"""Private Caddy authorization/normalization sockets, never a public TLS server.

Caddy validates TLS and overwrites all identity headers. Socket directory 0750
and sockets 0660 permit only dt-ingest and Caddy (supplementary dt-ingest group).
No request, peer, payload or exception logging. Each socket has one fixed backend.
"""
import http.client
import http.server
import json
import os
import re
import socket
import stat
import threading
import time
import urllib.parse
import socketserver

BASE = "/etc/dragontools/ingestion"
BODY_LIMIT = 4 * 1024 * 1024
CONCURRENCY = 16
TIMEOUT = 10
ROOT = 0
REGISTRY_LIMIT = 393216


def registered_peer(headers, registry):
    # Chain, validity and clientAuth have been checked by pinned Caddy. These
    # headers are trusted only on our permission-protected Unix sockets; Caddy
    # replaces every one (including empty SANs), never appends caller input.
    def field(name):
        values = headers.get_all('X-DragonTools-' + name, [])
        if len(values) != 1 or len(values[0]) > 256:
            raise ValueError('Invalid peer assertion')
        return values[0]
    subject, fingerprint = field('Subject'), field('Fingerprint')
    if not re.fullmatch(r'CN=dt-[0-9a-f]{32}', subject) or not re.fullmatch(r'[0-9a-f]{64}', fingerprint):
        raise ValueError('Invalid peer assertion')
    host = subject[3:]
    identity = 'dragontools://hosts/' + host
    uri = field('URI')
    extra = any(field(key) for key in ('Other-URI', 'DNS', 'IP', 'Email'))
    modern_identity = uri == identity and not extra
    legacy_identity = not uri and not extra
    # Direct lookup stays bounded even as host registrations grow. Entries are
    # root-owned; the unprivileged listener never mutates registration.
    path = os.path.join(registry, host + ".json")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not (stat.S_ISREG(info.st_mode) and info.st_uid == ROOT and info.st_nlink == 1
                and stat.S_IMODE(info.st_mode) == 0o640 and info.st_size <= REGISTRY_LIMIT):
            raise ValueError("Invalid registration")
        value = json.loads(os.read(fd, REGISTRY_LIMIT + 1))
    finally:
        os.close(fd)
    if not isinstance(value, dict) or value.get("host") != host:
        raise ValueError("Unregistered identity")
    expires = value.get("pending_expires_at")
    now = time.time()
    pending = value.get("pending_registration")
    if (value.get("pending_certificate_sha256") == fingerprint and modern_identity
            and type(expires) is int and now < expires <= now + 86405
            and isinstance(pending, dict) and pending.get("host") == host):
        # Only an explicitly enrolled candidate gets this finite rollout lease.
        # The old active registration remains available until finalization.
        return pending
    if value.get("certificate_sha256") == fingerprint:
        if "certificate_identity" in value:
            if value["certificate_identity"] == identity and modern_identity:
                return value
        elif legacy_identity:
            # Exact active fingerprint plus the previous CN-only format is the
            # sole legacy exception. Enrollment replaces it after verification.
            return value
    raise ValueError("Unregistered identity")


def log_body(body, registration):
    lines = body.splitlines()
    if not lines or len(lines) > 10000:
        raise ValueError("Invalid batch")
    output = []
    for line in lines:
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError("Unregistered service")
        applications = registration.get("applications", [])
        if value.get("type") == "dragontools_host":
            if value.get("event") not in ("host_reboot_required", "host_reboot_requirement_cleared", "host_stream_ready"):
                raise ValueError("Unknown host event")
            value.update(application="host", environment="host", service="dragontools-host")
            value.pop("journal_unit", None)
        elif applications:
            matches = [(app, service) for app in applications for service in app["services"]
                       if service["logs"] and service["systemd"] == value.get("journal_unit")]
            if len(matches) != 1:
                raise ValueError("Unregistered service")
            app, service = matches[0]
            value["application"] = app["name"]
            value["environment"] = app["environment"]
            value["service"] = service["name"]
            value.pop("journal_unit", None)
        elif value.get("service") not in registration["services"]:
            raise ValueError("Unregistered service")
        # Host identity is derived from authenticated registration, never app JSON.
        value["host"] = registration["host"]
        value.pop("_stream", None)
        output.append(json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode())
    result = b"\n".join(output) + b"\n"
    if len(result) > BODY_LIMIT * 2:
        raise ValueError("Invalid batch")
    return result


def bounded_snappy(body):
    # Remote-write uses a raw Snappy block with a decoded-size varint. Bound the
    # decoded size before the trusted backend allocates/decompresses the block.
    size = 0
    for index, byte in enumerate(body[:5]):
        size |= (byte & 127) << (index * 7)
        if byte < 128:
            if 0 < size <= 16 * 1024 * 1024:
                return
            break
    raise ValueError("Invalid remote-write block size")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "DragonTools"
    sys_version = ""

    def log_message(self, *_):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(code if code in (400, 403, 404, 405, 413, 431, 501, 505) else 400)

    def reply(self, code):
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        try:
            if self.path != "/health":
                self.reply(405)
                return
            registered_peer(self.headers, self.server.registry)
            self.reply(204)
        except Exception:
            self.reply(403)

    do_HEAD = do_GET
    def unsupported(self):
        self.reply(405)
    do_PUT = unsupported
    do_DELETE = unsupported
    do_OPTIONS = unsupported
    do_PATCH = unsupported

    def do_POST(self):
        upstream = None
        try:
            if self.path != self.server.route:
                self.reply(404)
                return
            if self.headers.get_all("Transfer-Encoding") or self.headers.get_all("Expect"):
                self.reply(400)
                return
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,8}", lengths[0]):
                self.reply(400)
                return
            size = int(lengths[0])
            if not 0 < size <= BODY_LIMIT:
                self.reply(413)
                return
            identity = registered_peer(self.headers, self.server.registry)
            body = self.rfile.read(size)
            if len(body) != size:
                self.reply(400)
                return
            if self.path == "/insert/jsonline":
                if self.headers.get("Content-Encoding", "identity") != "identity":
                    self.reply(400)
                    return
                body = log_body(body, identity)
                port = self.server.upstream_port
                path = "/insert/jsonline?_stream_fields=" + "application,environment,host,service" + "&_time_field=timestamp&_msg_field=message"
                headers = {"Content-Type": "application/stream+json"}
            else:
                if self.headers.get("Content-Encoding") != "snappy":
                    self.reply(400)
                    return
                bounded_snappy(body)
                port = self.server.upstream_port
                # v1.151.0 appends extra_labels after submitted labels and
                # lib/storage/metric_name.go sortTags keeps the last duplicate.
                # The station's default sortLabels=false preserves that order.
                path = "/api/v1/write?" + urllib.parse.urlencode({"extra_label": "host=" + identity["host"]})
                headers = {"Content-Type": "application/x-protobuf", "Content-Encoding": "snappy",
                           "X-Prometheus-Remote-Write-Version": "0.1.0"}
            # Destination and headers are fixed; incoming URLs/headers cannot select a backend.
            upstream = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
            upstream.request("POST", path, body=body, headers=headers)
            response = upstream.getresponse()
            self.reply(204 if 200 <= response.status < 300 else 503)
        except (ValueError, KeyError, TypeError):
            self.reply(403)
        except Exception:
            self.reply(503)
        finally:
            if upstream is not None:
                upstream.close()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 32
    slots = threading.BoundedSemaphore(CONCURRENCY)

    def __init__(self, address, registry, signal, upstream_port=None):
        if signal not in ('metrics', 'logs'):
            raise ValueError('Unsupported signal')
        self.registry = registry
        self.route = '/api/v1/write' if signal == 'metrics' else '/insert/jsonline'
        self.upstream_port = upstream_port or (8428 if signal == 'metrics' else 9428)
        # Never unlink an unexpected path. systemd owns and cleans RuntimeDirectory.
        super().__init__(address, Handler)
        os.chmod(address, 0o660)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            request.close()

    def process_request_thread(self, request, address):
        timer = None
        try:
            request.settimeout(TIMEOUT)
            def expire():
                try:
                    request.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            timer = threading.Timer(TIMEOUT, expire)
            timer.daemon = True
            timer.start()
            super().process_request_thread(request, address)
        except Exception:
            request.close()
        finally:
            if timer is not None:
                timer.cancel()
            self.slots.release()

    def handle_error(self, *_):
        pass


if __name__ == '__main__':
    # The service has no server/CA key access and no TCP listener. Only the two
    # fixed Caddy upstream sockets exist; paths/ports cannot be supplied by users.
    try:
        metrics = Server('/run/dragontools-ingress/metrics.sock', BASE + '/registry', 'metrics')
        logs = Server('/run/dragontools-ingress/logs.sock', BASE + '/registry', 'logs')
        thread = threading.Thread(target=metrics.serve_forever, daemon=True)
        thread.start()
        logs.serve_forever()
    except Exception:
        raise SystemExit(1)
