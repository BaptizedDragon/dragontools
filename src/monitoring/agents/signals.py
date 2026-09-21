# Managed by DragonTools
"""Read-only station queries. No generated errors, probe requests, or notifications."""
import datetime
import http.client
import json
import sys
import urllib.parse


def request(port, path, fields):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        conn.request('POST', path, urllib.parse.urlencode(fields), {'Content-Type': 'application/x-www-form-urlencoded'})
        response = conn.getresponse()
        body = response.read(1024 * 1024 + 1)
        if response.status in (500, 502, 503, 504):
            raise ConnectionError()
        if response.status != 200 or len(body) > 1024 * 1024:
            raise ValueError('invalid query response')
        return body
    finally:
        conn.close()


def metric(query):
    result = json.loads(request(8428, '/api/v1/query', {'query': query}))
    if result.get('status') != 'success' or result.get('data', {}).get('resultType') != 'vector':
        raise ValueError('invalid metrics response')
    return bool(result['data']['result'])


def log_ready(identity, since):
    # A stream selector proves these are indexed stream fields, not merely JSON
    # keys in an opaque message. No application-specific payload is required:
    # the existing quiet-service metadata follows the same trusted stream path.
    stream = '{' + ','.join(key + '=' + json.dumps(value) for key, value in sorted(identity.items())) + '}'
    query = stream + ' _time:2m | sort by (_time) desc limit 1'
    lines = request(9428, '/select/logsql/query', {'query': query}).splitlines()
    if not lines:
        return False
    entry = json.loads(lines[0])
    if any(entry.get(key) != value for key, value in identity.items()) or entry.get('_stream') != stream:
        raise ValueError('unexpected log stream')
    stamp = entry.get('_time')
    if not isinstance(stamp, str):
        raise ValueError('missing event time')
    return datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp() >= since


def check(mode, registration, since=0):
    host = json.dumps(registration['host'])
    def fresh(selector):
        # Multiple names can share every other label (e.g. histogram sum/count).
        # Dropping __name__ makes that valid payload a duplicate-output query
        # error. Keep names through the timestamp transform and bound the result
        # to one existence value instead of returning application series/labels.
        stamp = 'timestamp(' + selector + ') keep_metric_names'
        return metric('count((' + stamp + ' >= ' + str(float(since)) + ') and (' + stamp + ' > time()-90)) > 0')
    def scrape_ready(labels):
        # A fresh failed scrape proves vmagent -> station delivery while the
        # application is down. Missing/stale/pre-restart samples prove nothing.
        # A successful scrape must still contain real application payload.
        up = 'up' + labels + '}'
        if not fresh(up):
            return False
        if metric(up + ' == 1'):
            return fresh(labels + ',__name__!~"up|scrape_.*"}')
        return metric(up + ' == 0')
    if mode == 'events':
        return log_ready(dict(application='host', environment='host', host=registration['host'], service='dragontools-host'), since)
    if mode == 'logs' and not log_ready(dict(application='host', environment='host', host=registration['host'], service='dragontools-host'), since):
        return False
    applications = registration.get('applications', [])
    if applications:
        for application in applications:
            identity = ',application=' + json.dumps(application['name']) + ',environment=' + json.dumps(application['environment'])
            if mode == 'host':
                for name in ('host_cpu_seconds_total', 'host_memory_total_bytes', 'host_filesystem_used_ratio'):
                    if not fresh(name + '{host=' + host + ',agent="vector"' + identity + '}'):
                        return False
            elif mode == 'service':
                for service in application['services']:
                    labels = '{host=' + host + identity + ',service=' + json.dumps(service['name']) + '}'
                    available = 'dragontools_service_cgroup_available' + labels
                    if not fresh(available):
                        return False
                    # A stopped service is an observed state, not broken monitoring.
                    if metric(available + ' == 0'):
                        continue
                    for name in ('cpu_seconds_total', 'memory_current_bytes', 'tasks_supported'):
                        if not fresh('dragontools_service_' + name + labels):
                            return False
                    if metric('dragontools_service_tasks_supported' + labels + ' == 1') and not fresh('dragontools_service_tasks_current' + labels):
                        return False
            elif mode == 'logs':
                for service in application['services']:
                    if not service['logs']:
                        continue
                    identity = dict(host=registration['host'], application=application['name'], environment=application['environment'], service=service['name'])
                    if not log_ready(identity, since):
                        return False
            elif mode == 'app':
                for service in application['services']:
                    if service['metrics_url'] is None:
                        continue
                    labels = '{host=' + host + ',agent="vmagent"' + identity + ',service=' + json.dumps(service['name'])
                    if not scrape_ready(labels):
                        return False
            else:
                raise ValueError('invalid signal check')
        return True
    if mode == 'service':
        return True
    if mode == 'host':
        # Versioned Vector contract, scoped to trusted agent labels and freshness.
        for name in ('host_cpu_seconds_total', 'host_memory_total_bytes', 'host_filesystem_used_ratio'):
            if not fresh(name + '{host=' + host + ',agent="vector"}'):
                return False
        return True
    if mode == 'logs':
        for service in registration['services']:
            if not log_ready(dict(host=registration['host'], service=service), since):
                return False
        return True
    if mode == 'app':
        for target in registration['metrics_targets']:
            labels = '{host=' + host + ',agent="vmagent",app=' + json.dumps(target['name'])
            if not scrape_ready(labels):
                return False
        return True
    raise ValueError('invalid signal check')


if __name__ == '__main__':
    try:
        if not check(sys.argv[1], json.loads(sys.argv[2]), float(sys.argv[3]) if len(sys.argv) == 4 else 0):
            sys.exit(75)
    except (ConnectionError, TimeoutError, OSError):
        sys.exit(75)
    except Exception:
        sys.exit(1)
