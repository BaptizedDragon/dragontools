"""Silent, ordered ingestion diagnostics. Return only fixed semantic exit codes.

The same helper checks a staged credential before publication and an installed
credential during read-only verification. No key bytes are read into Python or
returned; OpenSSL loads them directly into the TLS context.
"""
import http.client
import socket
import ssl
import threading
import time

DNS_UNRESOLVED = 91
TCP_UNREACHABLE = 92
SERVER_TLS_INVALID = 93
CLIENT_CERTIFICATE_REJECTED = 94
INGESTION_REJECTED = 95
ENDPOINT_TIMEOUT = 4.0


def _endpoint_dns(endpoint, port):
    # libc resolver timeouts can exceed the remote readiness budget. A daemon
    # worker bounds this one operation without sleeping or keeping exit alive.
    result = []
    def resolve():
        try:
            result.append(socket.getaddrinfo(endpoint, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP))
        except Exception:
            result.append(None)
    worker = threading.Thread(target=resolve, daemon=True)
    worker.start()
    worker.join(ENDPOINT_TIMEOUT)
    return result[0] if result else None


def _endpoint_client_alert(error):
    reason = getattr(error, 'reason', '')
    return reason in {
        'TLSV13_ALERT_CERTIFICATE_REQUIRED', 'TLSV1_ALERT_UNKNOWN_CA',
        'SSLV3_ALERT_BAD_CERTIFICATE', 'SSLV3_ALERT_UNSUPPORTED_CERTIFICATE',
        'SSLV3_ALERT_CERTIFICATE_REVOKED', 'SSLV3_ALERT_CERTIFICATE_EXPIRED',
        'SSLV3_ALERT_CERTIFICATE_UNKNOWN', 'TLSV1_ALERT_ACCESS_DENIED',
    }


def check(endpoint, credential_directory, port=9443):
    """DNS -> TCP -> validated server TLS -> client auth -> authenticated health."""
    addresses = _endpoint_dns(endpoint, port)
    if not addresses:
        return DNS_UNRESOLVED
    # The managed gateway listens on IPv4. Prefer A records so an unreachable
    # AAAA record cannot consume the whole TCP budget before trying that listener.
    addresses = sorted(addresses, key=lambda entry: entry[0] != socket.AF_INET)
    connection = None
    deadline = time.monotonic() + ENDPOINT_TIMEOUT
    for family, kind, protocol, _, address in addresses[:16]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        attempt = None
        try:
            attempt = socket.socket(family, kind, protocol)
            attempt.settimeout(remaining)
            attempt.connect(address)
            connection = attempt
            break
        except OSError:
            if attempt is not None:
                attempt.close()
    if connection is None:
        return TCP_UNREACHABLE
    tls = None
    try:
        try:
            context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=credential_directory + '/ca.crt')
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            # Hostname verification remains enabled, even when TCP used an IP.
            context.check_hostname = True
            context.verify_mode = ssl.CERT_REQUIRED
        except Exception:
            return SERVER_TLS_INVALID
        try:
            context.load_cert_chain(credential_directory + '/client.crt', credential_directory + '/client.key')
        except Exception:
            return CLIENT_CERTIFICATE_REJECTED
        try:
            connection.settimeout(ENDPOINT_TIMEOUT)
            tls = context.wrap_socket(connection, server_hostname=endpoint)
        except ssl.SSLCertVerificationError:
            return SERVER_TLS_INVALID
        except ssl.SSLError as error:
            return CLIENT_CERTIFICATE_REJECTED if _endpoint_client_alert(error) else SERVER_TLS_INVALID
        except OSError:
            return SERVER_TLS_INVALID
        try:
            # HTTPConnection emits a bounded ordinary HTTP request over the
            # already validated socket. No second DNS/TCP/TLS attempt occurs.
            request = http.client.HTTPConnection(endpoint, port, timeout=ENDPOINT_TIMEOUT)
            request.sock = tls
            try:
                request.request('GET', '/health')
                response = request.getresponse()
                body = response.read(1025)
                if response.status in (401, 403):
                    return CLIENT_CERTIFICATE_REJECTED
                return 0 if response.status == 204 and not body else INGESTION_REJECTED
            finally:
                request.close()
        except ssl.SSLError as error:
            return CLIENT_CERTIFICATE_REJECTED if _endpoint_client_alert(error) else INGESTION_REJECTED
        except (OSError, http.client.HTTPException):
            return INGESTION_REJECTED
    finally:
        if tls is not None:
            tls.close()
        connection.close()
