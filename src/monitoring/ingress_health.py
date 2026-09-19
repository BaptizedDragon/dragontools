"""Read-only station health: no enrollment, client key, or telemetry required."""
import http.client
import socket
import ssl
import sys
from pathlib import Path


def authorization(paths):
    for path in paths:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(3)
            conn.connect(str(path))
            conn.sendall(b'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
            response = http.client.HTTPResponse(conn)
            response.begin()
            assert response.status == 403 and response.read(1) == b''


def tls(server, hostname, ports):
    # Native station-verify already proves exact managed PKI/profile/key pairing.
    # The TLS probe additionally proves Caddy serves that CA/hostname and demands
    # a certificate, without manufacturing or registering a station test client.
    hostname = hostname or (server / 'endpoint').read_text()
    context = ssl.create_default_context(cafile=str(server / 'ca.crt'))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    for port in ports:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=3) as raw:
                with context.wrap_socket(raw, server_hostname=hostname) as conn:
                    conn.sendall(b'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
                    conn.recv(1)  # TLS 1.3's client-auth alert follows its handshake.
        except ssl.SSLCertVerificationError:
            raise
        except ssl.SSLError as error:
            # TLS 1.3 and TLS 1.2 names are stable SSL alert semantics, not text.
            if error.reason not in ('TLSV13_ALERT_CERTIFICATE_REQUIRED', 'SSLV3_ALERT_HANDSHAKE_FAILURE'):
                raise
        else:
            raise ValueError('Client authentication not enforced')


def main():
    if sys.argv[1] == '--authorization':
        authorization([Path('/run/dragontools-ingress') / (signal + '.sock') for signal in ('metrics', 'logs')])
    else:
        tls(Path('/etc/dragontools/ingestion/server'), sys.argv[1], (9443, 9444))


if __name__ == '__main__':
    try:
        main()
    except ssl.SSLError:
        sys.exit(1)
    except (ConnectionError, TimeoutError, FileNotFoundError):
        sys.exit(75)
    except Exception:
        sys.exit(1)
