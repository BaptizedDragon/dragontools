"""Deterministic application-owned station documents and read-only ownership proof.

JSON is a YAML subset accepted by the pinned native tools. A marker is not proof:
manifest specifications must reproduce every owned file byte for byte. During an
interrupted update either exact generation is accepted; readers require current.
"""
import hashlib
import json
import os
import re
import stat

APP_ROOT = '/etc/dragontools/apps'
APP_FILES = ('logs.rules.yml', 'metrics.rules.yml', 'scrape.yml')
APP_GLOB = '/etc/dragontools/apps/*/scrape.yml'
APP_MAX_BYTES = 512 * 1024
APP_MAX_COUNT = 128
APP_METRICS = 'probe_success|probe_duration_seconds|probe_dns_lookup_time_seconds|probe_http_duration_seconds|probe_http_status_code|probe_http_ssl|probe_ssl_earliest_cert_expiry|probe_http_redirects|probe_ip_protocol'
APP_LABELS = '__name__|job|instance|probe|target|phase|managed_by|application|environment'


def app_json(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def app_require(value):
    if not value:
        raise ValueError('Application ownership conflict')


def app_identifier(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}', value) is not None


def app_duration(value):
    app_require(isinstance(value, str) and re.fullmatch(r'[1-9][0-9]*[smhd]', value))
    seconds = int(value[:-1]) * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[value[-1]]
    app_require(seconds <= 86400)
    return seconds


def app_identity(config):
    app_require(set(config) == {'application', 'environment', 'host', 'services', 'probes', 'alerts'})
    app_require(app_identifier(config['application']) and app_identifier(config['environment']))
    app_require(isinstance(config['host'], str) and re.fullmatch(r'dt-[0-9a-f]{32}', config['host']))
    return {key: config[key] for key in ('application', 'environment', 'host')}


def app_documents(config):
    identity = app_identity(config)
    app, environment = identity['application'], identity['environment']
    services, probes, alerts = config['services'], config['probes'], config['alerts']
    app_require(all(isinstance(items, list) and len(items) <= 64 for items in (services, probes, alerts)))
    for items in (services, probes, alerts):
        app_require(all(isinstance(item, dict) and app_identifier(item.get('name')) for item in items))
        app_require(len({item['name'] for item in items}) == len(items))
    labels = {'managed_by': 'dragontools', 'application': app, 'environment': environment}
    logs, metrics = [], []
    overrides = {}
    for alert in sorted(alerts, key=lambda item: item['name']):
        app_require(alert['severity'] in ('warning', 'critical'))
        if alert['source'] == 'probe':
            app_require(alert['probe'] not in overrides and any(p['name'] == alert['probe'] for p in probes))
            overrides[alert['probe']] = alert
            continue
        app_require(alert['source'] == 'logs' and alert['level'] in ('error', 'warn', 'warning', 'info', 'debug', 'critical', 'fatal'))
        window = alert['window']
        app_duration(window)
        app_require(type(alert['threshold']) is int and 0 < alert['threshold'] <= 1000000000)
        service = alert.get('service')
        selected = [s['name'] for s in services if s['logs'] and (service is None or s['name'] == service)]
        app_require(selected and (service is None or app_identifier(service)))
        # Exact filters and a finite allowlist prevent raw LogsQL injection.
        expr = '_time:' + window + ' application:=' + json.dumps(app) + ' environment:=' + json.dumps(environment)
        expr += ' service:in(' + ','.join(json.dumps(s) for s in sorted(selected)) + ') level:in(' + alert['level'] + ')'
        expr += ' | stats by (application, environment, host, service) count() as events | filter events:>=' + str(alert['threshold'])
        rule_labels = dict(labels, severity=alert['severity'], source='victorialogs')
        if service is not None:
            rule_labels['service'] = service
        logs.append({'alert': alert['name'], 'expr': expr, 'labels': rule_labels,
                     'annotations': {'summary': 'Application log threshold reached for {{ $labels.service }}',
                                     'description': 'Structured events in the configured window: {{ $value }}.'}})
    for probe in sorted(probes, key=lambda item: item['name']):
        override = overrides.get(probe['name'], {})
        duration = override.get('for_duration') or '2m'
        app_duration(duration)
        selector = ','.join(key + '=' + json.dumps(value) for key, value in
                            (('job', 'dragontools-app-' + app), ('application', app), ('environment', environment), ('probe', probe['name'])))
        metrics.append({'alert': override.get('name', 'ServiceProbeFailed'), 'expr': 'probe_success{' + selector + '} == 0',
                        'for': duration, 'labels': dict(labels, severity=override.get('severity', 'critical'), source='blackbox', probe=probe['name'], target=probe['url']),
                        'annotations': {'summary': 'HTTP probe {{ $labels.probe }} is failing',
                                        'description': 'Target {{ $labels.target }} failed HTTP/HTTPS availability checks.'}})
    jobs = []
    if probes:
        jobs.append({'job_name': 'dragontools-app-' + app, 'metrics_path': '/probe', 'params': {'module': ['http_2xx']},
                     'static_configs': [{'targets': [p['url']], 'labels': dict(labels, probe=p['name'], __scrape_interval__='30s', __scrape_timeout__='5s')} for p in sorted(probes, key=lambda item: item['name'])],
                     'relabel_configs': [{'source_labels': ['__address__'], 'target_label': '__param_target'},
                                         {'source_labels': ['__param_target'], 'target_label': 'target'},
                                         {'source_labels': ['probe'], 'target_label': 'instance'},
                                         {'target_label': '__address__', 'replacement': '127.0.0.1:9115'}],
                     'metric_relabel_configs': [{'source_labels': ['__name__'], 'regex': APP_METRICS, 'action': 'keep'},
                                                {'regex': APP_LABELS, 'action': 'labelkeep'}]})
    def group(kind, rules):
        return {'groups': [] if not rules else [{'name': 'dragontools-app-' + app + '-' + kind, 'type': 'vlogs' if kind == 'logs' else 'prometheus', 'interval': '30s', 'rules': rules}]}
    return {'logs.rules.yml': app_json(group('logs', logs)), 'metrics.rules.yml': app_json(group('metrics', metrics)), 'scrape.yml': app_json(jobs)}


def app_node(path, directory=False, missing=False, mode=None):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if missing:
            return None
        raise
    app_require(not stat.S_ISLNK(info.st_mode))
    app_require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
    app_require((info.st_uid, info.st_gid) == (0, 0))
    app_require(stat.S_IMODE(info.st_mode) == (mode if mode is not None else 0o755 if directory else 0o644))
    if not directory:
        app_require(info.st_size <= APP_MAX_BYTES)
    return info


def app_read(path):
    app_node(path)
    with open(path, 'rb') as handle:
        data = handle.read(APP_MAX_BYTES + 1)
    app_require(len(data) <= APP_MAX_BYTES)
    return data


def app_manifest(config, previous=None):
    documents = app_documents(config)
    return {'schema': 1, 'managed_by': 'dragontools', 'config': config, 'previous': previous,
            'sha256': {name: hashlib.sha256(data).hexdigest() for name, data in documents.items()}}


def app_inspect(name, complete=True, missing=False, candidate=None):
    app_require(app_identifier(name))
    if app_node(APP_ROOT, True, True) is None:
        if missing:
            return None
        raise ValueError('Application registration missing')
    directory = APP_ROOT + '/' + name
    if app_node(directory, True, True) is None:
        if missing:
            return None
        raise ValueError('Application registration missing')
    manifest = json.loads(app_read(directory + '/manifest.json'))
    app_require(set(manifest) == {'schema', 'managed_by', 'config', 'previous', 'sha256'})
    expected = app_manifest(manifest['config'], manifest['previous'])
    app_require(manifest == expected and manifest['config']['application'] == name)
    desired = app_documents(manifest['config'])
    previous = manifest['previous']
    old = app_documents(previous) if previous is not None else {}
    if previous is not None:
        app_require(app_identity(previous) == app_identity(manifest['config']))
    names = set(os.listdir(directory))
    allowed = set(APP_FILES) | {'manifest.json', '.next-manifest.json'} | {'.next-' + f for f in APP_FILES}
    app_require(names <= allowed)
    candidate_documents = app_documents(candidate) if candidate is not None else {}
    if candidate is not None:
        app_require(app_identity(candidate) == app_identity(manifest['config']))
    for filename, data in desired.items():
        path = directory + '/' + filename
        info = app_node(path, missing=not complete)
        if info is not None:
            actual = app_read(path)
            app_require(actual == data or (not complete and actual == old.get(filename)))
        staged = directory + '/.next-' + filename
        if os.path.lexists(staged):
            partial = app_read(staged)
            # Native globs never match .next-* names. A proven namespace and an
            # exact generated prefix permit retry after a short write; published
            # files always require the complete byte-for-byte generation.
            choices = [data, old.get(filename), candidate_documents.get(filename)]
            app_require(any(choice is not None and choice.startswith(partial) for choice in choices))
    staged_manifest = directory + '/.next-manifest.json'
    if os.path.lexists(staged_manifest):
        partial = app_read(staged_manifest)
        choices = [app_json(manifest), app_json(app_manifest(manifest['config']))]
        if candidate is not None:
            choices.extend([app_json(app_manifest(candidate)), app_json(app_manifest(candidate, manifest['config']))])
        app_require(any(choice.startswith(partial) for choice in choices))
    return manifest


def app_all():
    if app_node(APP_ROOT, True, True) is None:
        return []
    names = os.listdir(APP_ROOT)
    app_require(len(names) <= APP_MAX_COUNT)
    result = []
    for name in sorted(names):
        result.append(app_inspect(name))
    return result


APP_VM_CONFIG = '/etc/dragontools/victoriametrics/prometheus.yml'
APP_INCLUDE = "scrape_config_files: ['/etc/dragontools/apps/*/scrape.yml']\n"

def app_loader_config():
    """Accept only the exact prior/new DragonTools native scrape renderer."""
    text = app_read(APP_VM_CONFIG).decode()
    base = text.replace(APP_INCLUDE, '')
    app_require(text.count(APP_INCLUDE) <= 1)
    prefix = '# Managed by DragonTools\nglobal:\n  scrape_interval: 30s\n  scrape_timeout: 5s\n'
    app_require(base.startswith(prefix))
    suffix = base[len(prefix):]
    if suffix != 'scrape_configs: []\n':
        beginning = 'scrape_configs:\n  - job_name: dragontools-blackbox\n    metrics_path: /probe\n    params:\n      module: [http_2xx]\n    static_configs:\n'
        app_require(suffix.startswith(beginning))
        policy_index = suffix.find('    relabel_configs:\n')
        app_require(policy_index > 0)
        policy = suffix[policy_index:]
        expected_policy = '''    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: target
      - source_labels: [probe]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'METRICS'
        action: keep
      - regex: '__name__|job|instance|probe|target|phase'
        action: labelkeep
'''.replace('METRICS', APP_METRICS)
        app_require(policy == expected_policy)
        static = suffix[len(beginning):policy_index]
        pattern = r"      - targets: \[(.*?)\]\n        labels:\n          __scrape_interval__: 30s\n          __scrape_timeout__: 5s\n          probe: '(.*?)'\n"
        matches = list(re.finditer(pattern, static))
        app_require(matches and ''.join(match[0] for match in matches) == static and len(matches) <= 64)
        names = []
        for match in matches:
            url, name = match[1], match[2]
            app_require(app_identifier(name))
            names.append(name)
            # String spelling exactly matches the old Zig yamlString renderer.
            if url.startswith('"'):
                value = json.loads(url)
                app_require("'" in value and json.dumps(value, ensure_ascii=False, separators=(',', ':')) == url)
            else:
                app_require(url.startswith("'") and url.endswith("'") and "'" not in url[1:-1])
                value = url[1:-1]
            app_require(value.startswith(('http://', 'https://')) and not any(c in value for c in '\n\r?#'))
        app_require(names == sorted(set(names)))
    return text, prefix + APP_INCLUDE + suffix



def app_base_probes():
    actual, _ = app_loader_config()
    matches = re.finditer(r"      - targets: \[(.*?)\]\n        labels:\n          __scrape_interval__: 30s\n          __scrape_timeout__: 5s\n          probe: '(.*?)'\n", actual)
    return [{'name': match[2], 'url': json.loads(match[1]) if match[1].startswith('"') else match[1][1:-1]} for match in matches]
