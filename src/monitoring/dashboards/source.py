"""Validate explicit HTTP family mappings against bounded Prometheus text.

Only semantic exit status escapes. Application payloads/labels never reach logs.
No redirects; endpoints have already passed the strict private-target validator.
"""
import http.client
import json
import re
import sys
import urllib.parse


def families(text, mapping):
    types = {}
    samples = set()
    for line in text.splitlines():
        match = re.fullmatch(r'# TYPE ([a-zA-Z_:][a-zA-Z0-9_:]*) (counter|gauge|histogram|summary|untyped)', line)
        if match:
            if match[1] in types and types[match[1]] != match[2]:
                return False
            types[match[1]] = match[2]
        elif line and not line.startswith('#'):
            match = re.match(r'([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{|\s)', line)
            if match:
                samples.add(match[1])
    counter = mapping.get('requests_total')
    if counter and (types.get(counter) != 'counter' or counter not in samples):
        return False
    histogram = mapping.get('duration_histogram')
    if histogram and (types.get(histogram) != 'histogram' or not all(histogram + suffix in samples for suffix in ('_bucket', '_sum', '_count'))):
        return False
    return True


def source_main():
    try:
        config = json.loads(sys.argv[1])
        for service in config['services']:
            if not service.get('http'):
                continue
            url = urllib.parse.urlsplit(service['metrics_url'])
            conn = (http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection)(url.hostname, url.port, timeout=3)
            try:
                conn.request('GET', url.path or '/')
                response = conn.getresponse()
                if response.status != 200:
                    continue  # station check requires fresh up=0 or mapped samples
                body = response.read(4 * 1024 * 1024 + 1)
                if len(body) > 4 * 1024 * 1024 or not families(body.decode(), service['http']):
                    return 40
            except (OSError, http.client.HTTPException):
                continue
            finally:
                conn.close()
        return 0
    except Exception:
        return 40
