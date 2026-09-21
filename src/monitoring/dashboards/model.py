"""Versioned, narrow dashboard renderer. No arbitrary query/config input.

VMUI schema: VictoriaMetrics v1.151.0 app/vmselect/vmui.go.
Grafana file provider/schema: v13.2.2; VictoriaLogs datasource query: v0.32.0.
"""
import hashlib
import json
import re

VM_ROOT = '/etc/dragontools/victoriametrics/dashboards'
GRAFANA_ROOT = '/etc/dragontools/dashboards/grafana'
MANIFEST_ROOT = '/etc/dragontools/dashboards/manifests'
PROVIDER_PATH = '/etc/dragontools/grafana/provisioning/dashboards/dragontools.yaml'
PROVIDER = {'apiVersion': 1, 'providers': [{'name': 'dragontools', 'orgId': 1, 'type': 'file',
    'disableDeletion': True, 'allowUiUpdates': False, 'updateIntervalSeconds': 15,
    'options': {'path': GRAFANA_ROOT, 'foldersFromFilesStructure': True}}]}
METRICS = {'type': 'prometheus', 'uid': 'dragontools-metrics'}
LOGS = {'type': 'victoriametrics-logs-datasource', 'uid': 'dragontools-logs'}


def require(value):
    if not value:
        raise ValueError('Dashboard managed state refused')


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}', value)


def validate(config):
    if config == {'station': True}:
        return
    require(set(config) == {'application', 'environment', 'host', 'services', 'probes'})
    require(identifier(config['application']) and identifier(config['environment']))
    require(re.fullmatch(r'dt-[0-9a-f]{32}', config['host']))
    require(isinstance(config['services'], list) and len(config['services']) <= 64)
    require(isinstance(config['probes'], list) and len(config['probes']) <= 64)
    require(len({s['name'] for s in config['services']}) == len(config['services']))
    for service in config['services']:
        require(identifier(service['name']) and type(service['logs']) is bool)
        http = service.get('http')
        if http is None:
            continue
        require(set(http) == {'requests_total', 'duration_histogram', 'status_label', 'route_label'})
        require(http['requests_total'] or http['duration_histogram'])
        for key, value in http.items():
            if value is not None:
                require(isinstance(value, str) and len(value) <= 128 and not value.startswith('__'))
                require(re.fullmatch(r'[a-zA-Z_:][a-zA-Z0-9_:]*' if key in ('requests_total', 'duration_histogram') else r'[a-zA-Z_][a-zA-Z0-9_]*', value))
        require(not (http['status_label'] or http['route_label']) or http['requests_total'])
    require(all(identifier(p['name']) for p in config['probes']))


def identity(config):
    validate(config)
    return {'station': True} if 'station' in config else {k: config[k] for k in ('application', 'environment', 'host')}


def key(config):
    validate(config)
    return 'station' if 'station' in config else 'app-' + config['application']


def uid(config):
    # Grafana limits UIDs to 40 bytes; hash the complete identity, no truncation collisions.
    return 'dt-' + hashlib.sha256(encoded(identity(config))).hexdigest()[:32]


def paths(config):
    name = key(config)
    folder = 'Station' if name == 'station' else config['application']
    return {'vmui': VM_ROOT + '/dragontools-' + name + '.json',
            'grafana': GRAFANA_ROOT + '/DragonTools/' + folder + '/' + name + '.json'}


def selector(config, service=None, grafana=False):
    labels = {'application': config['application'], 'environment': config['environment'], 'host': config['host']}
    if service is not None:
        labels['service'] = service['name']
    result = ','.join(k + '=' + json.dumps(v) for k, v in labels.items())
    if grafana:
        result += ',service=~"${service:regex}"'
    return '{' + result + '}'


def panels(config, grafana=False):
    validate(config)
    result = []
    def add(title, unit, expressions, row='Resources'):
        result.append({'title': title, 'unit': unit, 'expr': expressions, 'row': row})
    if 'station' in config:
        # Only VM is currently self-scraped. Do not invent observations for the
        # other station processes or enable Caddy's public metrics/admin API.
        for title, unit, expr in [('VictoriaMetrics CPU cores', 'cores', 'rate(process_cpu_seconds_total{job="victoria-metrics"}[5m])'),
                                  ('VictoriaMetrics resident memory', 'bytes', 'process_resident_memory_bytes{job="victoria-metrics"}'),
                                  ('VictoriaMetrics stored data', 'bytes', 'sum(vm_data_size_bytes{job="victoria-metrics"})'),
                                  ('VictoriaMetrics free disk', 'bytes', 'vm_free_disk_space_bytes{job="victoria-metrics"}')]:
            add(title, unit, [expr], 'Station')
        return result
    add('Host CPU cores (all services)', 'cores', ['sum(rate(host_cpu_seconds_total{application=' + json.dumps(config['application']) + ',environment=' + json.dumps(config['environment']) + ',host=' + json.dumps(config['host']) + ',mode!="idle"}[5m]))'], 'Overview')
    if config['probes']:
        sel = '{application=' + json.dumps(config['application']) + ',environment=' + json.dumps(config['environment']) + ',job=' + json.dumps('dragontools-app-' + config['application']) + '}'
        add('Probe availability (0 = target down)', 'none', ['probe_success' + sel], 'Overview')
    for service in sorted(config['services'], key=lambda s: s['name']):
        scope = selector(config, service, grafana)
        prefix = service['name'] + ': '
        def resource(name):
            return 'dragontools_service_' + name + scope
        add(prefix + 'cgroup available', 'none', [resource('cgroup_available')])
        add(prefix + 'CPU cores', 'cores', ['rate(' + resource('cpu_seconds_total') + '[5m])'])
        host_scope = selector(config)[:-1] + ',mode="idle"}'
        add(prefix + 'CPU % of host capacity', 'percent', ['100 * sum(rate(' + resource('cpu_seconds_total') + '[5m])) / count(host_cpu_seconds_total' + host_scope + ')'])
        add(prefix + 'CPU user / system cores', 'cores', ['rate(' + resource(n) + '[5m])' for n in ('cpu_user_seconds_total', 'cpu_system_seconds_total')])
        add(prefix + 'CPU throttling seconds/s', 's', ['rate(' + resource('cpu_throttled_seconds_total') + '[5m])'])
        add(prefix + 'Memory current / peak / finite limit', 'bytes', [resource(n) for n in ('memory_current_bytes', 'memory_peak_bytes', 'memory_limit_bytes')])
        add(prefix + 'Memory % of finite limit', 'percent', ['100 * ' + resource('memory_current_bytes') + ' / ' + resource('memory_limit_bytes')])
        add(prefix + 'Tasks / finite limit (includes threads)', 'short', [resource(n) for n in ('tasks_current', 'tasks_limit')])
        add(prefix + 'I/O read / write bytes/s', 'Bps', ['rate(' + resource(n) + '[5m])' for n in ('io_read_bytes_total', 'io_write_bytes_total')])
        add(prefix + 'OOM / OOM kills in 5m', 'short', ['increase(' + resource(n) + '[5m])' for n in ('oom_total', 'oom_kill_total')])
        http = service.get('http') or {}
        counter, histogram = http.get('requests_total'), http.get('duration_histogram')
        if counter:
            rate = 'rate(' + counter + scope + '[5m])'
            add(prefix + 'Requests per second', 'reqps', ['sum(' + rate + ')'], 'HTTP')
            for label in ('status_label', 'route_label'):
                if http.get(label):
                    expr = 'sum by (' + http[label] + ') (' + rate + ')'
                    # route_label is explicitly a bounded template contract. Also
                    # cap rendered series; never create a route dashboard variable.
                    if label == 'route_label':
                        expr = 'topk(20, ' + expr + ')'
                    add(prefix + ('Status rate' if label == 'status_label' else 'Top bounded routes'), 'reqps', [expr], 'HTTP')
        if histogram:
            for quantile in (50, 95, 99):
                expr = 'histogram_quantile(' + str(quantile / 100) + ', sum by (le) (rate(' + histogram + '_bucket' + scope + '[5m])))'
                add(prefix + 'Latency p' + str(quantile), 's', [expr], 'HTTP')
    return result


def render(config):
    vm_panels = panels(config)
    title = 'DragonTools / Station' if 'station' in config else 'DragonTools / ' + config['application'] + ' / ' + config['environment']
    vmui = {'title': title, 'rows': [{'title': row, 'panels': [dict(title=p['title'], expr=p['expr'], unit=p['unit'], width=6, showLegend=True) for p in vm_panels if p['row'] == row]} for row in ('Overview', 'Resources', 'HTTP', 'Station') if any(p['row'] == row for p in vm_panels)]}
    grafana = {'uid': uid(config), 'title': title, 'schemaVersion': 39, 'version': 1, 'editable': False,
               'tags': ['dragontools-managed'], 'timezone': 'browser', 'refresh': '30s',
               'time': {'from': 'now-1h', 'to': 'now'}, 'panels': [], 'templating': {'list': []}}
    detailed = panels(config, True)
    overview = [p for p in detailed if any(label in p['title'] for label in ('Probe availability', 'cgroup available', 'Requests per second', 'Latency p'))]
    y = 0
    sections = [('Overview', overview, True)] if overview else []
    sections += [(row, [p for p in detailed if p['row'] == row], False) for row in ('Overview', 'Resources', 'HTTP', 'Station')]
    for row, members, stats in sections:
        if not members:
            continue
        grafana['panels'].append({'id': len(grafana['panels']) + 1, 'title': row if stats or row != 'Overview' else 'Host / probes',
            'type': 'row', 'collapsed': False, 'panels': [], 'gridPos': {'x': 0, 'y': y, 'w': 24, 'h': 1}})
        y += 1
        columns, height = (4, 4) if stats else (2, 8)
        for i, panel in enumerate(members):
            item = {'id': len(grafana['panels']) + 1, 'title': panel['title'], 'type': 'stat' if stats else 'timeseries', 'datasource': METRICS,
                'gridPos': {'x': (i % columns) * (24 // columns), 'y': y + (i // columns) * height, 'w': 24 // columns, 'h': height},
                'fieldConfig': {'defaults': {'unit': 'suffix: cores' if panel['unit'] == 'cores' else panel['unit'], 'min': 0}, 'overrides': []},
                'targets': [{'refId': chr(65 + j), 'datasource': METRICS, 'expr': expression, 'range': not stats, 'instant': stats} for j, expression in enumerate(panel['expr'])]}
            if stats:
                item['options'] = {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': '', 'values': False}, 'colorMode': 'value', 'graphMode': 'none', 'textMode': 'auto'}
            grafana['panels'].append(item)
        y += ((len(members) + columns - 1) // columns) * height
    if 'station' not in config:
        for name, values in (('environment', [config['environment']]), ('host', [config['host']]), ('service', sorted(s['name'] for s in config['services']))):
            if not values:
                continue
            grafana['templating']['list'].append({'name': name, 'label': name, 'type': 'custom', 'query': ','.join(values),
                'multi': name == 'service', 'includeAll': name == 'service', 'allValue': None,
                'current': {'text': 'All' if name == 'service' else values[0], 'value': '$__all' if name == 'service' else values[0]},
                'options': [{'text': v, 'value': v, 'selected': name != 'service'} for v in values]})
        logged = sorted(s['name'] for s in config['services'] if s['logs'])
        if logged:
            query = '{application=' + json.dumps(config['application']) + ',environment=' + json.dumps(config['environment']) + ',host=' + json.dumps(config['host']) + '} service:in(' + ','.join(json.dumps(s) for s in logged) + ') service:~"^(${service:regex})$" level:in(warning,warn,error,critical,fatal) | fields _time,service,level,event,method,path,status,_msg'
            grafana['panels'].append({'id': len(grafana['panels']) + 1, 'title': 'Warning / error logs', 'type': 'logs', 'datasource': LOGS,
                'gridPos': {'x': 0, 'y': y, 'w': 24, 'h': 12},
                'options': {'showTime': True, 'showLabels': False, 'showCommonLabels': False, 'wrapLogMessage': True, 'sortOrder': 'Descending', 'enableLogDetails': True},
                'targets': [{'refId': 'A', 'datasource': LOGS, 'expr': query, 'queryType': 'instant', 'editorMode': 'code', 'maxLines': 100, 'fields': ['_time', 'service', 'level', 'event', 'method', 'path', 'status', '_msg']}]})
    else:
        grafana['panels'].append({'id': len(grafana['panels']) + 1, 'title': 'Station signal coverage', 'type': 'text', 'gridPos': {'x': 0, 'y': y, 'w': 24, 'h': 5},
            'options': {'mode': 'markdown', 'content': 'VictoriaMetrics self-scrape is available. VictoriaLogs, VictoriaTraces, Grafana, Alertmanager, vmalert and Caddy process resource series are not currently scraped; their health remains checked by `monitoring verify`. No synthetic resource series are shown.'}})
    return {'vmui': encoded(vmui), 'grafana': encoded(grafana)}
