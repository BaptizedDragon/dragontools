"""Exact generation ownership, atomic publication and read-only loaded-state proof.

Never query credential columns or print remote exceptions. Manifest files are not
inside either dashboard loader. A marker/digest alone does not authorize updates.
"""
import http.client
import os
import pwd
import sqlite3
import stat
import sys
import urllib.parse

ROOT_UID = 0
ROOT_GID = 0
DB_PATH = '/var/lib/dragontools/grafana/grafana.db'
LIMIT = 2 * 1024 * 1024


class Pending(Exception):
    pass


def node(path, directory=False, missing=False):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if missing:
            return None
        raise
    require((info.st_uid, info.st_gid) == (ROOT_UID, ROOT_GID))
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= LIMIT)
    require(stat.S_IMODE(info.st_mode) == (0o755 if directory else 0o644))
    return info


def parents(path, create=False, missing=False):
    # Every component under the already managed /etc/dragontools tree is checked.
    root = '/etc/dragontools'
    require(path.startswith(root + '/') or path == root)
    current = root
    node(current, True)
    changed = False
    for part in path[len(root):].split('/'):
        if not part:
            continue
        current += '/' + part
        if node(current, True, True) is None:
            if missing and not create:
                return False
            require(create)
            os.mkdir(current, 0o755)
            os.chmod(current, 0o755)
            changed = True
    return changed


def read(path):
    node(path)
    with open(path, 'rb') as handle:
        result = handle.read(LIMIT + 1)
    require(len(result) <= LIMIT)
    return result


def atomic(path, data):
    staged = path + '.next'  # never matches either *.json loader
    if os.path.lexists(staged):
        require(data.startswith(read(staged)))
    fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, 'wb', closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(staged, path)
    directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def manifest_path(config):
    return MANIFEST_ROOT + '/' + key(config) + '.manifest'


def manifest(config, previous=None):
    return {'schema': 1, 'config': config, 'previous': previous,
            'sha256': {k: hashlib.sha256(v).hexdigest() for k, v in render(config).items()}}


def inspect(config, complete=False):
    validate(config)
    path = manifest_path(config)
    old = None
    if node(path, missing=True) is not None:
        old = json.loads(read(path))
        require(old == manifest(old['config'], old['previous']))
        require(identity(old['config']) == identity(config))
        if old['previous'] is not None:
            require(identity(old['previous']) == identity(config))
    desired = render(config)
    choices = [] if old is None else [render(old['config'])]
    if old is not None and old['previous'] is not None:
        choices.append(render(old['previous']))
    for kind, filename in paths(config).items():
        parents(os.path.dirname(filename), missing=True)
        if node(filename, missing=True) is not None:
            require(any(read(filename) == generation[kind] for generation in choices))
        elif complete:
            raise Pending()
        if os.path.lexists(filename + '.next'):
            require(old is not None)
            partial = read(filename + '.next')
            require(any(generation[kind].startswith(partial) for generation in choices + [desired]))
        if complete:
            require(read(filename) == desired[kind])
    if complete:
        require(old is not None and old['config'] == config and old['previous'] is None)
    if os.path.lexists(path + '.next'):
        partial = read(path + '.next')
        candidates = [manifest(config)]
        if old is not None:
            candidates += [old, manifest(old['config']), manifest(config, old['config'])]
        require(any(encoded(value).startswith(partial) for value in candidates))
    return old


def grafana_owner():
    account = pwd.getpwnam('dt-grafana')
    return account.pw_uid, account.pw_gid


def database(config, old, loaded=False, allow_absent=False):
    try:
        info = os.lstat(DB_PATH)
    except FileNotFoundError:
        if allow_absent:
            return
        raise Pending()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) & 0o027 == 0)
    require((info.st_uid, info.st_gid) == grafana_owner())
    require(not os.path.lexists(DB_PATH + '-wal') and not os.path.lexists(DB_PATH + '-shm'))
    if os.path.lexists(DB_PATH + '-journal'):
        journal = os.lstat(DB_PATH + '-journal')
        require(stat.S_ISREG(journal.st_mode) and journal.st_nlink == 1 and journal.st_uid == info.st_uid)
    db = sqlite3.connect('file:' + urllib.parse.quote(DB_PATH, safe='/') + '?mode=ro', uri=True, timeout=2)
    try:
        db.execute('PRAGMA query_only=ON')
        require(db.execute('PRAGMA journal_mode').fetchone() == ('delete',))
        allowed = {'resource': {'value', 'action', 'group', 'resource', 'namespace', 'name'},
                   'dashboard': {'id', 'uid', 'org_id', 'data'},
                   'dashboard_provisioning': {'dashboard_id', 'name', 'external_id'}}
        def authorize(action, table, column, database, trigger):
            if action == sqlite3.SQLITE_SELECT or action == sqlite3.SQLITE_READ and database == 'main' and column in allowed.get(table, set()):
                return sqlite3.SQLITE_OK
            return sqlite3.SQLITE_DENY
        db.set_authorizer(authorize)
        # Only public dashboard state and its provider/path are read, never users,
        # datasource secrets or credential storage. No database writes.
        # Grafana 13.2.2 defaults to unified dashboard storage. Do not confuse
        # its empty legacy dashboard table with an unoccupied UID. Verified with
        # the pinned binary and pkg/storage/unified/sql/backend.go.
        rows = db.execute('SELECT value,action FROM resource WHERE "group"=? AND resource=? AND namespace=? AND name=?',
                          ('dashboard.grafana.app', 'dashboards', 'default', uid(config))).fetchall()
        legacy = db.execute('SELECT d.data,p.name,p.external_id FROM dashboard d LEFT JOIN dashboard_provisioning p ON p.dashboard_id=d.id WHERE d.org_id=1 AND d.uid=?', (uid(config),)).fetchall()
        require(len(rows) <= 1 and len(legacy) <= 1)
        if not rows:
            # An unmanaged legacy UID is still a collision, including during a
            # schema migration. Never enable provisioning over it.
            require(not legacy)
            if loaded:
                raise Pending()
            return
        require(old is not None)
        raw, action = rows[0]
        require(action in (1, 2) and len(raw) <= LIMIT)
        resource = json.loads(raw)
        require(resource.get('kind') == 'Dashboard' and resource.get('apiVersion') == 'dashboard.grafana.app/v0alpha1')
        metadata = resource['metadata']
        require(metadata['name'] == uid(config) and metadata['namespace'] == 'default')
        annotations = metadata.get('annotations', {})
        require(annotations.get('grafana.app/managedBy') == 'classic-file-provisioning')
        require(annotations.get('grafana.app/managerId') == 'dragontools')
        require(annotations.get('grafana.app/sourcePath') == paths(config)['grafana'])
        actual = dict(resource['spec'], uid=metadata['name'])
        candidates = [config] if loaded else [old['config']] + ([old['previous']] if old['previous'] is not None else [])
        def matches(candidate):
            expected = json.loads(render(candidate)['grafana'])
            # Grafana adds IDs/version and schema migration defaults. Verify
            # identity plus the complete executable panel/query/variable policy.
            return all(actual.get(k) == expected[k] for k in ('uid', 'title', 'panels', 'templating', 'tags', 'editable'))
        if not any(matches(candidate) for candidate in candidates):
            if loaded and any(matches(candidate) for candidate in [old['config']] + ([old['previous']] if old['previous'] is not None else [])):
                raise Pending()
            require(False)
    finally:
        db.close()


def publish(config, allow_absent=False):
    for path in (MANIFEST_ROOT, VM_ROOT, os.path.dirname(paths(config)['grafana'])):
        parents(path, True)
    old = inspect(config)
    database(config, old, allow_absent=allow_absent)
    if old is not None and old['config'] == config:
        changed = old['previous'] is not None
        for kind, data in render(config).items():
            path = paths(config)[kind]
            if not os.path.lexists(path) or read(path) != data:
                atomic(path, data)
                changed = True
        # Retain the prior generation until consumers have actually loaded this
        # one, including across repeated interrupted publication attempts.
        return changed
    if old is not None and old['previous'] is not None:
        # Finish the already authorized generation before accepting another edit.
        # Do not discard the proof for a still-loaded previous dashboard.
        raise Pending()
    transition = manifest(config, old['config'] if old is not None else None)
    atomic(manifest_path(config), encoded(transition))
    for kind, data in render(config).items():
        path = paths(config)[kind]
        if not os.path.lexists(path) or read(path) != data:
            atomic(path, data)
    # Keep previous until both consumers show the desired generation.
    return True


def finish(config):
    old = inspect(config)
    require(old is not None and old['config'] == config)
    if old['previous'] is not None:
        atomic(manifest_path(config), encoded(manifest(config)))


def request(port, path):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        conn.request('GET', path)
        response = conn.getresponse()
        if response.status in (500, 502, 503, 504):
            raise Pending()
        require(response.status == 200)
        data = response.read(LIMIT + 1)
        require(len(data) <= LIMIT)
        return json.loads(data)
    finally:
        conn.close()


def loaded(config):
    parents(os.path.dirname(PROVIDER_PATH))
    require(read(PROVIDER_PATH) == encoded(PROVIDER))
    old = inspect(config)
    require(old is not None and old['config'] == config)
    for kind, data in render(config).items():
        require(read(paths(config)[kind]) == data)
    response = request(8428, '/vmui/custom-dashboards')
    expected = json.loads(render(config)['vmui'])
    dashboards = response.get('dashboardsSettings') or []
    same = [item for item in dashboards if item.get('title') == expected['title']]
    if not same:
        raise Pending()
    require(len(same) == 1 and same[0] == expected)
    database(config, old, loaded=True)


def main():
    try:
        mode, raw = sys.argv[1:3]
        config = json.loads(raw)
        changed = False
        if mode == 'setup-vm':
            changed = publish({'station': True}, allow_absent=True)
        elif mode == 'setup-grafana':
            parents(os.path.dirname(PROVIDER_PATH))
            if node(PROVIDER_PATH, missing=True) is None:
                # Persist intent before publication; interruption cannot leave a
                # newly written provider invisible to an already running Grafana.
                # Station installation owns initial provider activation.
                marker = '/var/lib/dragontools/grafana-restart-required'
                if os.path.lexists(marker):
                    info = os.lstat(marker)
                    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size == 0 and info.st_uid == 0 and info.st_gid == 0 and stat.S_IMODE(info.st_mode) == 0o600)
                fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    os.fchmod(fd, 0o600)
                    os.fsync(fd)
                finally:
                    os.close(fd)
                directory = os.open(os.path.dirname(marker), os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
                atomic(PROVIDER_PATH, encoded(PROVIDER))
                changed = True
            else:
                require(read(PROVIDER_PATH) == encoded(PROVIDER))
        elif mode in ('preflight', 'publish'):
            parents(MANIFEST_ROOT)
            parents(VM_ROOT)
            parents(GRAFANA_ROOT)
            require(read(PROVIDER_PATH) == encoded(PROVIDER))
            old = inspect(config)
            database(config, old)
            if mode == 'publish':
                changed = publish(config)
        elif mode == 'loaded':
            loaded(config)
        elif mode == 'finish':
            finish(config)
        else:
            require(False)
        if mode in ('setup-vm', 'setup-grafana', 'publish'):
            print('changed' if changed else 'unchanged', end='')
        return 0
    except (Pending, ConnectionError, TimeoutError):
        return 75
    except sqlite3.OperationalError as error:
        return 75 if getattr(error, 'sqlite_errorcode', None) in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED) else 40
    except Exception:
        return 40
