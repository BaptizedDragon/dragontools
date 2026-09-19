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


def check(mode, registration, since=0):
    host = json.dumps(registration['host'])
    def fresh(selector):
        stamp = 'timestamp(' + selector + ')'
        return metric('(' + stamp + ' >= ' + str(float(since)) + ') and (' + stamp + ' > time()-90)')
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
    applications = registration.get('applications', [])
    if applications:
        for application in applications:
            identity = ',application=' + json.dumps(application['name']) + ',environment=' + json.dumps(application['environment'])
            if mode == 'host':
                for name in ('host_cpu_seconds_total', 'host_memory_total_bytes', 'host_filesystem_used_ratio'):
                    if not fresh(name + '{host=' + host + ',agent="vector"' + identity + '}'):
                        return False
            elif mode == 'logs':
                for service in application['services']:
                    if not service['logs']:
                        continue
                    query = '_time:2m host:' + host + ' application:' + json.dumps(application['name']) + ' environment:' + json.dumps(application['environment']) + ' service:' + json.dumps(service['name']) + ' | sort by (_time) desc limit 1'
                    lines = request(9428, '/select/logsql/query', {'query': query}).splitlines()
                    if not lines:
                        return False
                    entry = json.loads(lines[0])
                    if any(entry.get(key) != value for key, value in (('host', registration['host']), ('application', application['name']), ('environment', application['environment']), ('service', service['name']))):
                        raise ValueError('unexpected log stream')
                    stamp = entry.get('_time')
                    if not isinstance(stamp, str):
                        raise ValueError('missing event time')
                    if datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp() < since:
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
    if mode == 'host':
        # Versioned Vector contract, scoped to trusted agent labels and freshness.
        for name in ('host_cpu_seconds_total', 'host_memory_total_bytes', 'host_filesystem_used_ratio'):
            if not fresh(name + '{host=' + host + ',agent="vector"}'):
                return False
        return True
    if mode == 'logs':
        for service in registration['services']:
            query = '_time:2m host:' + host + ' service:' + json.dumps(service) + ' | sort by (_time) desc limit 1'
            lines = request(9428, '/select/logsql/query', {'query': query}).splitlines()
            if not lines:
                return False
            entry = json.loads(lines[0])
            if entry.get('host') != registration['host'] or entry.get('service') != service:
                raise ValueError('unexpected log stream')
            stamp = entry.get('_time')
            if not isinstance(stamp, str):
                raise ValueError('missing event time')
            if datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp() < since:
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
