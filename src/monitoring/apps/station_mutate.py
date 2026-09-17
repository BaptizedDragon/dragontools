"""Application station publication. Imported only for mutating commands."""
import fcntl
import subprocess
import tempfile

APP_PENDING = {'scrape.yml': '/var/lib/dragontools/victoriametrics-scrape-reload-required',
               'logs.rules.yml': '/var/lib/dragontools/vmalert-logs-restart-required',
               'metrics.rules.yml': '/var/lib/dragontools/vmalert-metrics-restart-required'}
APP_VM_CONFIG = '/etc/dragontools/victoriametrics/prometheus.yml'
APP_VM_BINARY = '/opt/dragontools/components/victoriametrics/current/victoria-metrics-prod'
APP_ALERT_BINARY = '/opt/dragontools/components/vmalert/current/vmalert-prod'
APP_INCLUDE = "scrape_config_files: ['/etc/dragontools/apps/*/scrape.yml']\n"


def app_sync(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def app_mark(path):
    info = app_node(path, missing=True, mode=0o600)
    if info is not None:
        app_require(info.st_size == 0)
        return
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    app_sync(os.path.dirname(path))


def app_atomic(path, data):
    staging = os.path.dirname(path) + '/.next-' + os.path.basename(path)
    if os.path.lexists(staging):
        app_node(staging)
        app_require(data.startswith(app_read(staging)))
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, 'wb', closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(staging, path)
    app_sync(os.path.dirname(path))


def app_exec(argv):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=15, env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C'})
    app_require(result.returncode == 0)


def app_validate_native(documents):
    # A private temporary directory, no includes or notifier startup in dryRun.
    with tempfile.TemporaryDirectory(prefix='dragontools-app-') as directory:
        for name, data in documents.items():
            path = directory + '/' + name
            with open(path, 'wb') as handle:
                handle.write(data)
            # vmalert -dryRun rejects an entirely empty rule collection. The
            # generated exact groups:[] has no expressions/templates to validate;
            # runtime always includes the nonempty shared pack alongside it.
            if name != 'scrape.yml' and json.loads(data)['groups']:
                app_exec([APP_ALERT_BINARY, '-dryRun', '-rule=' + path, '-loggerLevel=ERROR'])
        path = directory + '/scrape-main.yml'
        with open(path, 'wb') as handle:
            handle.write(app_json({'global': {'scrape_interval': '30s', 'scrape_timeout': '5s'}, 'scrape_config_files': [directory + '/scrape.yml']}))
        app_exec([APP_VM_BINARY, '-promscrape.config=' + path, '-promscrape.config.dryRun', '-loggerLevel=ERROR'])


def app_preflight(config):
    identity = app_identity(config)
    app_documents(config)
    manifest = app_inspect(identity['application'], complete=False, missing=True, candidate=config)
    if manifest is not None:
        app_require(app_identity(manifest['config']) == identity)
    # A conflict in an existing namespace is detected before target mutation.
    return manifest


def app_publish(config):
    existing = app_preflight(config)
    documents = app_documents(config)
    name = config['application']
    if existing is not None and existing['config'] == config and existing['previous'] is None:
        app_inspect(name)
        return False
    app_validate_native(documents)
    if app_node(APP_ROOT, True, True) is None:
        os.mkdir(APP_ROOT, 0o755)
        os.chmod(APP_ROOT, 0o755)
    directory = APP_ROOT + '/' + name
    if existing is None:
        # Go filepath.Glob includes dot names. Stage outside the native app glob.
        staging = os.path.dirname(APP_ROOT) + '/.apps-creating-' + name
        if os.path.lexists(staging):
            app_node(staging, True)
            app_require(set(os.listdir(staging)) <= set(APP_FILES) | {'manifest.json'} | {'.next-' + f for f in APP_FILES} | {'.next-manifest.json'})
            for item in os.listdir(staging):
                data = app_read(staging + '/' + item)
                filename = item.removeprefix('.next-')
                expected = app_json(app_manifest(config)) if filename == 'manifest.json' else documents[filename]
                app_require(expected.startswith(data))
        else:
            os.mkdir(staging, 0o755)
            os.chmod(staging, 0o755)
        for filename, data in documents.items():
            app_atomic(staging + '/' + filename, data)
        app_atomic(staging + '/manifest.json', app_json(app_manifest(config)))
        # Mark before publishing even the first generation. Only nonempty rules
        # and scrape jobs need activating, but empty rules are native-valid.
        for filename in APP_FILES:
            if json.loads(documents[filename]) not in ({'groups': []}, []):
                app_mark(APP_PENDING[filename])
        os.rename(staging, directory)
        app_sync(APP_ROOT)
        return True
    old = existing['config']
    # A transition proves all bytes that may exist after an interruption.
    # Finish an existing interrupted transition before starting another one.
    if existing['previous'] is not None:
        old_docs = app_documents(old)
        for filename, data in old_docs.items():
            if not os.path.lexists(directory + '/' + filename) or app_read(directory + '/' + filename) != data:
                app_mark(APP_PENDING[filename])
                app_atomic(directory + '/' + filename, data)
        app_atomic(directory + '/manifest.json', app_json(app_manifest(old)))
    previous_documents = app_documents(old)
    changed = [filename for filename in APP_FILES if previous_documents[filename] != documents[filename]]
    for filename in changed:
        app_mark(APP_PENDING[filename])
    app_atomic(directory + '/manifest.json', app_json(app_manifest(config, old)))
    for filename in changed:
        app_atomic(directory + '/' + filename, documents[filename])
    app_atomic(directory + '/manifest.json', app_json(app_manifest(config)))
    return True




def app_prepare_loader():
    actual, desired = app_loader_config()
    if actual == desired:
        return False
    # Validated by native dryRun before publication, preserving all station probes.
    with tempfile.NamedTemporaryFile(prefix='dragontools-loader-', mode='w') as handle:
        handle.write(desired)
        handle.flush()
        app_exec([APP_VM_BINARY, '-promscrape.config=' + handle.name, '-promscrape.config.dryRun', '-loggerLevel=ERROR'])
    app_mark(APP_PENDING['scrape.yml'])
    app_atomic(APP_VM_CONFIG, desired.encode())
    return True


def app_mutate_main():
    try:
        mode, payload = sys.argv[1:3]
        data = json.loads(payload)
        config = data['config']
        if mode == 'publish':
            app_binary_preflight(data['pins'])
            app_shared_preflight(data['shared'])
            changed = app_publish(config)
            changed = app_prepare_loader() or changed
        elif mode == 'activate':
            app_managed(config)
            pending = app_node(APP_PENDING['scrape.yml'], missing=True, mode=0o600) is not None
            if not pending:
                try:
                    base = definitions(app_base_probes())
                    config_reloaded()
                    loaded_policy(base)
                    targets_loaded(base, False)
                except NotReady:
                    pending = True
            changed = pending
            if pending:
                app_mark(APP_PENDING['scrape.yml'])
                request('/-/reload', method='POST')
        elif mode == 'finalize':
            app_managed(config)
            if app_node(APP_PENDING['scrape.yml'], missing=True, mode=0o600) is not None:
                os.unlink(APP_PENDING['scrape.yml'])
                app_sync(os.path.dirname(APP_PENDING['scrape.yml']))
            return 0
        else:
            raise ValueError('Unsupported application station mutation')
        print('changed' if changed else 'unchanged', end='')
        return 0
    except Exception:
        return 40
