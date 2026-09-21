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
    return dict(line.split('=', 1) for line in output('systemctl', 'show', '--all', unit).splitlines() if '=' in line)


def managed_account(spec):
    kind, owner = spec['kind'], spec['owner']
    account = pwd.getpwnam(owner)
    assert account.pw_uid != 0 and account.pw_shell == '/usr/sbin/nologin'
    assert account.pw_dir == '/var/lib/dragontools/' + kind
    assert output('id', '-gn', owner) == owner
    assert set(output('id', '-nG', owner).split()) <= ({owner, 'systemd-journal'} if kind == 'vector' else {owner})


def unit_path(spec):
    return '/etc/systemd/system/dragontools-' + spec.get('service', spec['kind']) + '.service'


def managed_unit(spec):
    assert regular(unit_path(spec)) == spec['unit'].encode()


def unit_properties(spec):
    # The generated unit is also the installer's desired state. Parse only its
    # controlled [Service] assignments, including repeated LoadCredential lines.
    desired, section = {}, ''
    for line in spec['unit'].splitlines():
        if line.startswith('['):
            section = line
        elif section == '[Service]' and '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            desired[key] = (desired.get(key, '') + ' ' + value).strip() if key == 'LoadCredential' else value
    return desired


def managed_systemd_properties(spec):
    desired = unit_properties(spec)
    values = properties('dragontools-' + spec.get('service', spec['kind']) + '.service')
    expected = {'FragmentPath': unit_path(spec), 'DropInPaths': '', 'LoadState': 'loaded',
                'NeedDaemonReload': 'no', 'UnitFileState': 'enabled'}
    scalar = ('User', 'Group', 'ProtectSystem', 'CapabilityBoundingSet', 'AmbientCapabilities',
              'StandardOutput', 'StandardError', 'UMask', 'NoNewPrivileges', 'PrivateTmp',
              'PrivateDevices', 'ProtectHome', 'ProtectKernelTunables', 'ProtectKernelModules',
              'ProtectControlGroups', 'RestrictSUIDSGID', 'LockPersonality')
    expected.update({key: desired[key] for key in scalar})
    sets = {'RestrictAddressFamilies': desired['RestrictAddressFamilies'],
            'ReadWritePaths': desired['ReadWritePaths'],
            'SupplementaryGroups': desired.get('SupplementaryGroups', '')}
    if spec['kind'] in ('caddy', 'ingestion'):
        sets['InaccessiblePaths'] = desired['InaccessiblePaths']
        expected['LimitCORE'] = desired['LimitCORE']
        if spec['kind'] == 'ingestion':
            expected.update({key: desired[key] for key in ('RuntimeDirectory', 'RuntimeDirectoryMode')})
    # --all preserves empty properties. Missing is never equivalent to empty.
    assert all(key in values and values[key] == value for key, value in expected.items())
    assert all(key in values and set(values[key].split()) == set(value.split()) for key, value in sets.items())


def managed_credentials(spec):
    # systemctl renders this structured property as [unprintable]. Read its
    # typed ID/source-path pairs, never a credential's contents. Exact mappings
    # still come from the same generated unit used by install and verification.
    assert spec['kind'] == spec['service'] == 'caddy'
    expected = dict(item.split(':', 1) for item in unit_properties(spec)['LoadCredential'].split())
    value = json.loads(output('busctl', '--system', '--json=short', 'get-property',
                              'org.freedesktop.systemd1',
                              '/org/freedesktop/systemd1/unit/dragontools_2dcaddy_2eservice',
                              'org.freedesktop.systemd1.Service', 'LoadCredential'))
    assert isinstance(value, dict) and value.get('type') == 'a(ss)'
    records = value['data']
    assert isinstance(records, list) and len(records) == len(expected)
    actual = {}
    for record in records:
        assert isinstance(record, list) and len(record) == 2 and all(isinstance(item, str) for item in record)
        name, path = record
        assert name not in actual
        actual[name] = path
    assert actual == expected


def directory(path, uid, gid, mode):
    st = os.lstat(path)
    assert stat.S_ISDIR(st.st_mode) and st.st_uid == uid and st.st_gid == gid and stat.S_IMODE(st.st_mode) == mode


def managed_directories(spec):
    kind = spec['kind']
    account = pwd.getpwnam(spec['owner'])
    for path in ('/opt/dragontools', '/opt/dragontools/components', '/etc/dragontools', '/var/lib/dragontools', '/etc/dragontools/' + kind):
        directory(path, 0, 0, 0o755)
    directory('/var/lib/dragontools/' + kind, account.pw_uid, account.pw_gid, 0o750)
    if kind == 'ingestion':
        directory('/opt/dragontools/ingress-auth', 0, 0, 0o755)
        for name in ('pki', 'clients'):
            directory('/etc/dragontools/ingestion/' + name, 0, 0, spec['ingress_private_directory_mode'])


def managed_registry(spec):
    directory('/etc/dragontools/ingestion/registry', 0, pwd.getpwnam(spec['owner']).pw_gid, spec['ingress_registry_mode'])


def managed_server_state(spec):
    # Metadata only; the native station verifier owns certificate/key validation.
    # The authorization process itself remains denied access to this directory.
    directory('/etc/dragontools/ingestion/server', 0, pwd.getpwnam(spec['owner']).pw_gid, spec['ingress_server_mode'])


def managed_helper(spec):
    for item in spec['files']:
        assert regular(item['path']) == item['content'].encode()


def managed_binary(spec):
    root = '/opt/dragontools/components/' + spec['kind']
    for path in (root, root + '/' + spec['version']):
        directory(path, 0, 0, 0o755)
    assert os.readlink(root + '/current') == spec['version']
    data = regular(root + '/' + spec['version'] + '/' + spec['binary'], mode=0o755)
    assert hashlib.sha256(data).hexdigest() == spec['digest']


def managed(spec):
    managed_account(spec)
    managed_unit(spec)
    managed_systemd_properties(spec)
    if spec['kind'] == 'caddy':
        managed_credentials(spec)
    managed_directories(spec)
    managed_helper(spec)
    kind = spec['kind']
    if kind == 'ingestion':
        managed_registry(spec)
        managed_server_state(spec)
    else:
        managed_binary(spec)


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
        {'managed': managed, 'managed_account': managed_account, 'managed_unit': managed_unit,
         'managed_helper': managed_helper, 'managed_directories': managed_directories,
         'managed_registry': managed_registry, 'managed_server_state': managed_server_state,
         'managed_systemd_properties': managed_systemd_properties,
         'caddy_account': managed_account, 'caddy_binary': managed_binary, 'caddy_unit': managed_unit,
         'caddy_systemd_properties': managed_systemd_properties, 'caddy_config': managed_helper,
         'caddy_credentials': managed_credentials, 'caddy_directories': managed_directories,
         'active': runtime, 'http': health}[action](spec)
    except (ssl.SSLCertVerificationError, ssl.SSLError):
        sys.exit(1)
    except socket.gaierror as error:
        sys.exit(75 if error.errno == socket.EAI_AGAIN else 1)
    except (ConnectionError, TimeoutError, socket.timeout, http.client.RemoteDisconnected, http.client.IncompleteRead):
        sys.exit(75)
    except Exception:
        sys.exit(1)
