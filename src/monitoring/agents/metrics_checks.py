# Managed by DragonTools
"""Read-only vmagent diagnostics. Never expose targets, bodies or exceptions.

A completed failed scrape is valid monitoring telemetry, not an unhealthy
pipeline. Station signal checks still prove delivery after this process started.
"""
import datetime
import http.client
import json
import math
import re
import socket
import subprocess
import sys
import time
import urllib.parse


def response(path):
    conn = http.client.HTTPConnection('127.0.0.1', 8429, timeout=5)
    try:
        conn.request('GET', path)
        result = conn.getresponse()
        body = result.read(4 * 1024 * 1024 + 1)
        if result.status in (500, 502, 503, 504):
            raise ConnectionError()
        if result.status != 200 or len(body) > 4 * 1024 * 1024:
            raise ValueError('Invalid agent response')
        return body
    finally:
        conn.close()


def expected_targets(registration):
    base = dict(host=registration['host'], agent='vmagent')
    if registration.get('applications'):
        for app in registration['applications']:
            for service in app['services']:
                if service['metrics_url'] is not None:
                    yield service['metrics_url'], dict(base, application=app['name'],
                                                      environment=app['environment'], service=service['name'])
    else:
        for target in registration['metrics_targets']:
            yield target['url'], dict(base, app=target['name'])


def source_ready(registration, since):
    result = json.loads(response('/api/v1/targets'))
    if result.get('status') != 'success' or not isinstance(result.get('data', {}).get('activeTargets'), list):
        raise ValueError('Invalid target response')
    targets = result['data']['activeTargets']
    for url, labels in expected_targets(registration):
        matches = [target for target in targets if all(target.get('labels', {}).get(k) == v for k, v in labels.items())]
        if not matches:
            return False  # Target discovery/first scrape may still be starting.
        def location(value):
            parts = urllib.parse.urlsplit(value)
            return parts.scheme, parts.hostname, parts.port or (443 if parts.scheme == 'https' else 80), parts.path or '/', parts.query
        if len(matches) != 1 or location(matches[0]['scrapeUrl']) != location(url):
            raise ValueError('Unexpected scrape target')
        target = matches[0]
        if target.get('health') not in ('up', 'down'):
            return False
        stamp = datetime.datetime.fromisoformat(target['lastScrape'].replace('Z', '+00:00')).timestamp()
        if stamp < since or stamp <= time.time() - 90:
            return False
    return True


def check(mode, registration, since):
    if not math.isfinite(since) or since < 0:
        raise ValueError('Invalid process start')
    if mode == 'metrics_agent_active':
        result = subprocess.check_output(['systemctl', 'show', '--all', 'dragontools-vmagent.service'], stderr=subprocess.DEVNULL)
        properties = dict(line.split('=', 1) for line in result.decode().splitlines() if '=' in line)
        return properties.get('ActiveState') == 'active' and int(properties.get('MainPID', '0')) > 0
    if mode == 'metrics_source_ready':
        return source_ready(registration, since)
    if mode == 'metrics_station_reachable':
        with socket.create_connection((registration['station'], 9443), timeout=5):
            return True
    if mode == 'metrics_remote_write_accepted':
        # Current-process successful requests prove backend acceptance, without
        # requiring old error counters to reset or an always-empty disk queue.
        # The subsequent station query proves the selected application's data.
        for line in response('/metrics').decode().splitlines():
            match = re.fullmatch(r'vmagent_remotewrite_requests_total\{([^}]*)\} ([0-9.eE+\-]+)(?: [0-9]+)?', line)
            if match and re.search(r'(?:^|,\s*)status_code="2XX"(?:,|$)', match[1]):
                value = float(match[2])
                if math.isfinite(value) and value > 0:
                    return True
        return False
    raise ValueError('Invalid metrics check')


if __name__ == '__main__':
    try:
        if not check(sys.argv[1], json.loads(sys.argv[2]), float(sys.argv[3])):
            sys.exit(75)
    except (ConnectionError, TimeoutError, OSError):
        sys.exit(75)
    except Exception:
        sys.exit(1)
