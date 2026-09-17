"""Read-only application station verification, using native loaded APIs."""
import sys


def app_binary_preflight(pins):
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(os.uname().machine)
    app_require(arch is not None)
    for component, version, filename, pin in (('victoriametrics', 'v1.151.0', 'victoria-metrics-prod', pins['vm_' + arch]),
                                                ('vmalert', 'v1.152.0', 'vmalert-prod', pins['alert_' + arch])):
        parent = '/opt/dragontools/components/' + component
        for directory in ('/opt/dragontools', '/opt/dragontools/components', parent, parent + '/' + version):
            app_node(directory, True)
        link = parent + '/current'
        info = os.lstat(link)
        app_require(stat.S_ISLNK(info.st_mode) and (info.st_uid, info.st_gid) == (0, 0) and os.readlink(link) == version)
        path = parent + '/' + version + '/' + filename
        info = os.lstat(path)
        app_require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (0, 0, 0o755))
        digest = hashlib.sha256()
        with open(path, 'rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
        app_require(digest.hexdigest() == pin)


def app_shared_preflight(shared):
    for directory in ('/etc/dragontools', '/etc/dragontools/victoriametrics', '/etc/systemd/system'):
        app_node(directory, True)
    # This one-time integration may update only an exact generated unit/rule
    # generation. The ordinary station workflow retains its existing semantics.
    for kind in ('logs', 'metrics'):
        unit = app_read('/etc/systemd/system/dragontools-vmalert-' + kind + '.service').decode()
        desired = shared[kind + '_unit']
        prior = desired.replace(' -rule=/etc/dragontools/apps/*/' + kind + '.rules.yml', '')
        app_require(unit in (desired, prior))
        rules = app_read('/etc/dragontools/vmalert-' + kind + '/rules.yml').decode()
        desired_rules = shared[kind + '_rules']
        prior_rules = desired_rules.replace('          managed_by: dragontools\n', '').replace('avg by (application, environment, host)', 'avg by (host)').replace('stats by (application, environment, host, service)', 'stats by (service)')
        app_require(rules in (desired_rules, prior_rules))
    app_loader_config()


def app_managed(config):
    manifest = app_inspect(config['application'])
    app_require(manifest['config'] == config and manifest['previous'] is None)
    actual, expected = app_loader_config()
    app_require(actual == expected)


def app_probe_ready():
    base = definitions(app_base_probes())
    scraper_ready(base)
    expected = application_definitions()
    if any(state == 'unknown' for state in stored_states(expected, check_up=True).values()):
        raise NotReady()


def app_rules_ready():
    # Native rule API validator includes the fixed shared packs and all proven
    # app files, so additional or stale rule groups cannot hide in the response.
    for kind in ('logs', 'metrics'):
        connection = http.client.HTTPConnection('127.0.0.1', 8880 if kind == 'logs' else 8881, timeout=5)
        try:
            connection.request('GET', '/api/v1/rules?exclude_alerts=true')
            response = connection.getresponse()
            if response.status in (500, 502, 503, 504):
                raise NotReady()
            app_require(response.status == 200)
            body = response.read(1048577)
            app_require(len(body) <= 1048576)
            validate(json.loads(body), kind)
        finally:
            connection.close()


def app_read_main():
    try:
        mode, payload = sys.argv[1:3]
        data = json.loads(payload)
        config = data['config']
        if mode == 'preflight':
            identity = app_identity(config)
            manifest = app_inspect(identity['application'], complete=False, missing=True, candidate=config)
            if manifest is not None:
                app_require(app_identity(manifest['config']) == identity)
            app_binary_preflight(data['pins'])
            app_shared_preflight(data['shared'])
            # All native glob inputs must have proven ownership, even if another
            # application is interrupted. Never adopt a manual glob match.
            for name in os.listdir(APP_ROOT) if os.path.isdir(APP_ROOT) else []:
                app_inspect(name, complete=False, candidate=config if name == config['application'] else None)
        elif mode == 'managed':
            app_managed(config)
        elif mode == 'probes':
            app_managed(config)
            app_probe_ready()
        elif mode == 'rules':
            app_managed(config)
            app_rules_ready()
        elif mode == 'status':
            app_managed(config)
            try:
                app_probe_ready()
                app_rules_ready()
                print('ready', end='')
            except (NotReady, OSError, http.client.HTTPException):
                print('pending', end='')
        else:
            raise ValueError('Unsupported application station check')
        return 0
    except NotReady:
        return 75
    except (OSError, http.client.HTTPException):
        return 75 if mode in ('probes', 'rules') else 1
    except Exception:
        return 40
