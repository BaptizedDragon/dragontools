"""Read-only configured HTTP family checks; a down scrape target is valid."""
import http.client
import json
import sys
import urllib.parse


def query(expression):
    conn = http.client.HTTPConnection('127.0.0.1', 8428, timeout=3)
    try:
        conn.request('GET', '/api/v1/query?' + urllib.parse.urlencode({'query': expression}))
        response = conn.getresponse()
        if response.status in (500, 502, 503, 504):
            raise ConnectionError()
        require(response.status == 200)
        body = response.read(65537)
        require(len(body) <= 65536)
        result = json.loads(body)
        require(result.get('status') == 'success' and result['data']['resultType'] == 'vector')
        return bool(result['data']['result'])
    finally:
        conn.close()


def http_ready(config):
    validate(config)
    for service in config['services']:
        mapping = service.get('http')
        if not mapping:
            continue
        scope = selector(config, service)
        # Zero request counts are valid. Fresh failed scrape is also a successful
        # monitoring mechanism; do not make application downtime an apply failure.
        if query('(up' + scope + ' == 0) and (timestamp(up' + scope + ') > time()-90)'):
            continue
        names = []
        if mapping['requests_total']:
            names.append(mapping['requests_total'])
        if mapping['duration_histogram']:
            names += [mapping['duration_histogram'] + suffix for suffix in ('_bucket', '_sum', '_count')]
        for name in names:
            if not query('count(timestamp(' + name + scope + ') > time()-90) > 0'):
                return False
        for label in ('status_label', 'route_label'):
            if mapping[label]:
                labelled = scope[:-1] + ',' + mapping[label] + '!=""}'
                if not query('count(timestamp(' + mapping['requests_total'] + labelled + ') > time()-90) > 0'):
                    return False
    return True


def signal_main():
    try:
        return 0 if http_ready(json.loads(sys.argv[1])) else 75
    except (ConnectionError, TimeoutError, OSError):
        return 75
    except Exception:
        return 40
