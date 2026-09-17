# Managed by DragonTools
"""Authoritative per-application signal manifests. No credentials or station policy."""
import json
import ipaddress
import urllib.parse
import os
import re
import stat
import sys
import tempfile

BASE = '/etc/dragontools/agent-apps'
ROOT = 0
GID = 0
MARKER = b'DragonTools application agent manifests v1\n'
LIMIT = 196608


def require(value):
    if not value:
        raise ValueError('Application agent ownership conflict')


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == ROOT and st.st_gid == GID and stat.S_IMODE(st.st_mode) == 0o600 and st.st_size <= LIMIT)
        return os.read(fd, LIMIT + 1)
    finally:
        os.close(fd)


def directory(path):
    st = os.lstat(path)
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == ROOT and st.st_gid == GID and stat.S_IMODE(st.st_mode) == 0o755)


def metrics_url(value):
    require(isinstance(value, str) and 0 < len(value) <= 2048)
    require(all(32 < ord(byte) < 127 and byte not in '\\<>"{}|^`?#' for byte in value))
    for escape in re.finditer('%', value):
        pair = value[escape.start()+1:escape.start()+3]
        require(bool(re.fullmatch('[0-9A-Fa-f]{2}', pair)))
        require(int(pair, 16) >= 32 and int(pair, 16) != 127)
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme.lower() in ('http', 'https') and parsed.netloc and parsed.hostname)
    require(parsed.username is None and parsed.password is None and not parsed.query and not parsed.fragment)
    require('%' not in parsed.netloc and not parsed.netloc.endswith(':') and parsed.port != 0)
    if parsed.hostname.lower() == 'localhost':
        return
    address = ipaddress.ip_address(parsed.hostname)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    blocks = ('127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16') if address.version == 4 else ('::1/128', 'fc00::/7', 'fe80::/10')
    require(any(address in ipaddress.ip_network(block) for block in blocks))


def scope(value):
    require(set(value) == {'name', 'environment', 'services'})
    for key in ('name', 'environment'):
        require(isinstance(value[key], str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}', value[key]))
    require(isinstance(value['services'], list) and len(value['services']) <= 64)
    names, units = set(), set()
    for service in value['services']:
        require(set(service) == {'name', 'systemd', 'logs', 'metrics_url'})
        require(isinstance(service['name'], str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}', service['name']))
        require(isinstance(service['systemd'], str) and len(service['systemd']) <= 253 and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@:-]*[.]service', service['systemd']))
        require(type(service['logs']) is bool)
        if service['metrics_url'] is not None:
            metrics_url(service['metrics_url'])
        require(service['name'] not in names and service['systemd'] not in units)
        names.add(service['name']); units.add(service['systemd'])
    value['services'].sort(key=lambda entry: entry['name'])
    return value


def reconcile(desired, host, station, mutate):
    desired = scope(desired)
    directory(os.path.dirname(BASE))
    existing = []
    present = os.path.lexists(BASE)
    if present:
        directory(BASE)
        require(read(BASE + '/.dragontools-managed') == MARKER)
        entries = os.listdir(BASE)
        require(len(entries) <= 65)
        for filename in sorted(entries):
            if filename == '.dragontools-managed':
                continue
            if re.fullmatch(r'[.][A-Za-z0-9][A-Za-z0-9_-]{0,62}[.]pending', filename):
                # Reserved private staging belongs to the managed directory, not
                # to the published manifest set. An interrupted write may be any
                # prefix of its intended JSON; never parse/adopt it as state.
                read(BASE + '/' + filename)
                continue
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}[.]json', filename))
            raw = read(BASE + '/' + filename)
            value = json.loads(raw)
            require(set(value) == {'version', 'host', 'station', 'application'} and value['version'] == 1 and value['host'] == host and value['station'] == station)
            require(scope(value['application'])['name'] + '.json' == filename)
            require(raw == encoded(value))
            existing.append(value['application'])
    else:
        # Existing raw-agent state cannot be silently adopted by an application.
        require(not any(os.path.lexists(os.path.dirname(BASE) + '/' + path) for path in ('vector/vector.yaml', 'vmagent/prometheus.yml', 'vector/.agent-identity', 'vmagent/.agent-identity')))
        require(mutate)
    previous = next((app for app in existing if app['name'] == desired['name']), None)
    require(mutate or previous == desired)
    merged = sorted([app for app in existing if app['name'] != desired['name']] + [desired], key=lambda app: app['name'])
    require(len(merged) <= 32 and sum(len(app['services']) for app in merged) <= 64)
    units = set()
    for app in merged:
        for service in app['services']:
            require(service['systemd'] not in units)
            units.add(service['systemd'])
    result = dict(version=1, host=host, station=station, applications=merged,
                  services=sorted(service['systemd'] for app in merged for service in app['services'] if service['logs']), metrics_targets=[])
    require(len(encoded(result)) <= LIMIT)
    pending = BASE + '/.' + desired['name'] + '.pending'
    recovered = False
    if mutate and present and os.path.lexists(pending):
        read(pending)  # Metadata refusal still applies to partial staging.
        os.unlink(pending)
        recovered = True
    changed = previous != desired
    if mutate and changed:
        if not present:
            # Publish the directory and ownership evidence together. An interrupted
            # creation never produces an unmarked directory requiring adoption.
            stage = tempfile.mkdtemp(prefix='.agent-apps-', dir=os.path.dirname(BASE))
            try:
                with open(stage + '/.dragontools-managed', 'xb') as output:
                    os.chmod(output.name, 0o600); output.write(MARKER)
                os.chmod(stage, 0o755)
                os.rename(stage, BASE)
            finally:
                if os.path.isdir(stage):
                    import shutil
                    shutil.rmtree(stage)
        temporary = pending
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(encoded(dict(version=1, host=host, station=station, application=desired)))
                output.flush(); os.fsync(output.fileno())
            os.replace(temporary, BASE + '/' + desired['name'] + '.json')
        finally:
            if os.path.lexists(temporary): os.unlink(temporary)
    return result, changed or recovered


if __name__ == '__main__':
    try:
        value, changed = reconcile(json.loads(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[1] == 'apply')
        sys.stdout.write(('changed\n' if changed else 'unchanged\n') + encoded(value).decode())
    except Exception:
        sys.exit(40)
