# Managed by DragonTools
"""Read-only checks; exit 75 is reserved for runtime absence, never drift."""
import hashlib
import http.client
import json
import os
import pwd
import shlex
import socket
import ssl
import stat
import subprocess
import sys


def output(*argv):
    return subprocess.check_output(argv, stderr=subprocess.DEVNULL, timeout=10).decode().strip()


def regular(path, uid=0, mode=0o644):
    st = os.lstat(path)
    assert stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == uid and st.st_gid == 0 and stat.S_IMODE(st.st_mode) == mode
    return open(path, 'rb').read()


def properties(unit):
    return dict(line.split('=', 1) for line in output('systemctl', 'show', unit).splitlines() if '=' in line)


def managed(spec):
    kind, owner = spec['kind'], spec['owner']
    account = pwd.getpwnam(owner)
    assert account.pw_uid != 0 and account.pw_shell == '/usr/sbin/nologin'
    assert account.pw_dir == '/var/lib/dragontools/' + kind
    assert output('id', '-gn', owner) == owner
    assert set(output('id', '-nG', owner).split()) <= ({owner, 'systemd-journal'} if kind == 'vector' else {owner})
    unit = 'dragontools-' + spec.get('service', kind) + '.service'
    path = '/etc/systemd/system/' + unit
    assert regular(path) == spec['unit'].encode()
    values = properties(unit)
    expected = {'User': owner, 'Group': owner, 'FragmentPath': path, 'DropInPaths': '',
                'LoadState': 'loaded', 'NeedDaemonReload': 'no', 'UnitFileState': 'enabled',
                'ProtectSystem': 'strict', 'CapabilityBoundingSet': '', 'AmbientCapabilities': '',
                'StandardOutput': 'null', 'StandardError': 'null', 'UMask': '0077',
                'ReadWritePaths': '/run/dragontools-ingress' if kind == 'ingestion' else '/var/lib/dragontools/' + kind}
    expected.update({key: 'yes' for key in ('NoNewPrivileges', 'PrivateTmp', 'PrivateDevices', 'ProtectHome',
                     'ProtectKernelTunables', 'ProtectKernelModules', 'ProtectControlGroups', 'RestrictSUIDSGID', 'LockPersonality')})
    assert all(values.get(key) == value for key, value in expected.items())
    assert set(values['RestrictAddressFamilies'].split()) == {'AF_INET', 'AF_INET6', 'AF_UNIX'}
    assert set(values.get('SupplementaryGroups', '').split()) == ({'systemd-journal'} if kind == 'vector' else {'dt-ingest'} if kind == 'caddy' else set())
    if kind in ('caddy', 'ingestion'):
        assert set(values.get('InaccessiblePaths', '').split()) == {
            '/etc/dragontools/ingestion/pki', '/etc/dragontools/ingestion/clients', '/etc/dragontools/ingestion/server'}
        assert values.get('LimitCORE') == '0'
        if kind == 'caddy':
            assert set(values.get('LoadCredential', '').split()) == {
                name + ':/etc/dragontools/ingestion/server/' + name for name in ('ca.crt', 'server.crt', 'server.key')}
        else:
            assert values.get('RuntimeDirectory') == 'dragontools-ingress'
            assert values.get('RuntimeDirectoryMode') == '0750'
    for path in ('/opt/dragontools', '/opt/dragontools/components', '/etc/dragontools', '/var/lib/dragontools', '/etc/dragontools/' + kind):
        st = os.lstat(path)
        assert stat.S_ISDIR(st.st_mode) and st.st_uid == st.st_gid == 0 and stat.S_IMODE(st.st_mode) == 0o755
    st = os.lstat('/var/lib/dragontools/' + kind)
    assert stat.S_ISDIR(st.st_mode) and st.st_uid == account.pw_uid and st.st_gid == account.pw_gid and stat.S_IMODE(st.st_mode) == 0o750
    for item in spec['files']:
        assert regular(item['path']) == item['content'].encode()
    if kind != 'ingestion':
        root = '/opt/dragontools/components/' + kind
        for path in (root, root + '/' + spec['version']):
            st = os.lstat(path)
            assert stat.S_ISDIR(st.st_mode) and st.st_uid == st.st_gid == 0 and stat.S_IMODE(st.st_mode) == 0o755
        assert os.readlink(root + '/current') == spec['version']
        data = regular(root + '/' + spec['version'] + '/' + spec['binary'], mode=0o755)
        assert hashlib.sha256(data).hexdigest() == spec['digest']


def runtime(spec):
    unit = 'dragontools-' + spec.get('service', spec['kind']) + '.service'
    props = properties(unit)
    pid = int(props.get('MainPID', '0'))
    listeners = output('ss', '-H', '-ltnp').splitlines()
    kind = spec['kind']
    allowed = {'0.0.0.0:9443', '0.0.0.0:9444'} if kind == 'caddy' else set() if kind == 'ingestion' else {spec['listener']}
    # A public/foreign listener on the owned port fails immediately, even while
    # the expected process has not started.
    ports = {address.rsplit(':', 1)[1] for address in allowed}
    owned = []
    for line in listeners:
        parts = line.split()
        if len(parts) < 5:
            raise ValueError('invalid listener record')
        address = parts[3]
        if address.rsplit(':', 1)[-1] in ports:
            assert address in allowed and pid > 0 and 'pid=' + str(pid) + ',' in line
        if pid > 0 and 'pid=' + str(pid) + ',' in line:
            assert address in allowed
            owned.append(address)
    if pid == 0 or not os.path.isdir('/proc/' + str(pid)):
        sys.exit(75)
    base = '/proc/' + str(pid)
    account = pwd.getpwnam(spec['owner'])
    assert os.stat(base).st_uid == account.pw_uid and os.stat(base).st_gid == account.pw_gid
    for line in output('ss', '-H', '-lunp').splitlines():
        assert 'pid=' + str(pid) + ',' not in line
    with open(base + '/cmdline', 'rb') as stream:
        actual = stream.read().rstrip(b'\0').split(b'\0')
    assert actual == [part.encode() for part in shlex.split(spec['command'])]
    if spec['kind'] != 'ingestion':
        with open(base + '/exe', 'rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == spec['digest']
    if kind == 'ingestion':
        st = os.lstat('/run/dragontools-ingress')
        assert stat.S_ISDIR(st.st_mode) and st.st_uid == account.pw_uid and st.st_gid == account.pw_gid and stat.S_IMODE(st.st_mode) == 0o750
        expected = {'/run/dragontools-ingress/metrics.sock', '/run/dragontools-ingress/logs.sock'}
        seen = set()
        for line in output('ss', '-H', '-lxnp').splitlines():
            if 'pid=' + str(pid) + ',' in line:
                paths = set(line.split()) & expected
                assert len(paths) == 1
                seen.update(paths)
        for path in expected:
            if not os.path.lexists(path):
                sys.exit(75)
            st = os.lstat(path)
            assert stat.S_ISSOCK(st.st_mode) and st.st_uid == account.pw_uid and st.st_gid == account.pw_gid and stat.S_IMODE(st.st_mode) == 0o660
        if seen != expected:
            sys.exit(75)
    if props.get('ActiveState') != 'active' or set(owned) != allowed:
        sys.exit(75)
    if kind == 'caddy':
        for port in (9443, 9444):
            with socket.create_connection(('127.0.0.1', port), timeout=3):
                pass


def health(spec):
    runtime(spec)
    conn = http.client.HTTPConnection('127.0.0.1', int(spec['listener'].rsplit(':', 1)[1]), timeout=4)
    conn.request('GET', '/metrics' if spec['kind'] == 'vector' else '/health')
    response = conn.getresponse()
    body = response.read(2 * 1024**2 + 1)
    if response.status != 200 or len(body) > 2 * 1024**2:
        sys.exit(75)
    if spec['kind'] == 'vector' and not body:
        sys.exit(75)


if __name__ == '__main__':
    try:
        action, data = sys.argv[1:]
        spec = json.loads(data)
        {'managed': managed, 'active': runtime, 'http': health}[action](spec)
    except (ssl.SSLCertVerificationError, ssl.SSLError):
        sys.exit(1)
    except socket.gaierror as error:
        sys.exit(75 if error.errno == socket.EAI_AGAIN else 1)
    except (ConnectionError, TimeoutError, socket.timeout, http.client.RemoteDisconnected, http.client.IncompleteRead):
        sys.exit(75)
    except Exception:
        sys.exit(1)
