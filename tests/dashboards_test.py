"""Portable real-file/SQLite fixtures; no service, SSH or Grafana deployment."""
import copy
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load():
    scope = {'__name__': 'dashboard_fixture'}
    for name in ('model', 'state', 'signals', 'source'):
        exec(compile((ROOT / 'src/monitoring/dashboards' / (name + '.py')).read_text(), name, 'exec'), scope)
    return scope


def config():
    return {'application': 'doers', 'environment': 'production', 'host': 'dt-' + 'a' * 32,
            'services': [{'name': 'doers', 'systemd': 'doers.service', 'logs': True,
                'http': {'requests_total': 'doers_http_requests_total', 'duration_histogram': 'doers_http_request_duration_seconds', 'status_label': 'status_class', 'route_label': 'route'}}],
            'probes': [{'name': 'website'}]}


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.n = load()
        self.config = config()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.n.update(VM_ROOT=str(root / 'vm'), GRAFANA_ROOT=str(root / 'grafana'), MANIFEST_ROOT=str(root / 'manifests'), DB_PATH=str(root / 'grafana.db'), ROOT_UID=os.getuid(), ROOT_GID=os.getgid())
        def parents(path, create=False, missing=False):
            parent = Path(path)
            self.assertTrue(parent.is_relative_to(root))
            current = root
            changed = False
            for part in parent.relative_to(root).parts:
                current /= part
                if not current.exists() and not current.is_symlink():
                    if missing and not create:
                        return False
                    self.assertTrue(create)
                    current.mkdir(mode=0o755)
                    current.chmod(0o755)
                    changed = True
                self.n['node'](str(current), True)
            return changed
        self.n['parents'] = parents
        self.n['grafana_owner'] = lambda: (os.getuid(), os.getgid())
        self.n['PROVIDER_PATH'] = str(root / 'dragontools.yaml')
        Path(self.n['PROVIDER_PATH']).write_bytes(self.n['encoded'](self.n['PROVIDER']))
        Path(self.n['PROVIDER_PATH']).chmod(0o644)
        for path in ('vm', 'grafana', 'manifests'):
            (root / path).mkdir(mode=0o755)
            (root / path).chmod(0o755)
        self.db = sqlite3.connect(self.n['DB_PATH'])
        self.addCleanup(self.db.close)
        self.db.executescript('CREATE TABLE resource("group" TEXT,resource TEXT,namespace TEXT,name TEXT,value TEXT,action INTEGER); CREATE TABLE dashboard(id INTEGER PRIMARY KEY,org_id INTEGER,uid TEXT,data TEXT); CREATE TABLE dashboard_provisioning(dashboard_id INTEGER,name TEXT,external_id TEXT);')
        os.chmod(self.n['DB_PATH'], 0o640)

    def provision(self, cfg=None):
        cfg = cfg or self.config
        model = json.loads(self.n['render'](cfg)['grafana'])
        self.db.execute('DELETE FROM dashboard')
        self.db.execute('DELETE FROM dashboard_provisioning')
        self.db.execute('DELETE FROM resource')
        resource = {'kind': 'Dashboard', 'apiVersion': 'dashboard.grafana.app/v0alpha1', 'metadata': {'name': model.pop('uid'), 'namespace': 'default', 'annotations': {'grafana.app/managedBy': 'classic-file-provisioning', 'grafana.app/managerId': 'dragontools', 'grafana.app/sourcePath': self.n['paths'](cfg)['grafana']}}, 'spec': model}
        self.db.execute('INSERT INTO resource VALUES (?,?,?,?,?,1)', ('dashboard.grafana.app', 'dashboards', 'default', self.n['uid'](cfg), json.dumps(resource)))
        self.db.commit()
        self.n['request'] = lambda port, path: {'dashboardsSettings': [json.loads(self.n['render'](cfg)['vmui'])]}

    def test_doers_contract_queries_and_deterministic_formats(self):
        first = self.n['render'](self.config)
        self.assertEqual(first, self.n['render'](copy.deepcopy(self.config)))
        queries = [e for p in self.n['panels'](self.config) for e in p['expr']]
        self.assertTrue(any('sum(rate(doers_http_requests_total{' in q for q in queries))
        for percentile in ('0.5', '0.95', '0.99'):
            self.assertTrue(any('histogram_quantile(' + percentile in q and 'doers_http_request_duration_seconds_bucket' in q and 'sum by (le)' in q for q in queries))
        self.assertTrue(any('sum by (status_class)' in q for q in queries))
        self.assertTrue(any('topk(20, sum by (route)' in q for q in queries))
        self.assertTrue(all('application="doers"' in q and 'environment="production"' in q for q in queries))
        doc = json.loads(first['grafana'])
        self.assertEqual({p['title'] for p in doc['panels'] if p['type'] == 'row'}, {'Overview', 'Host / probes', 'Resources', 'HTTP'})
        self.assertTrue(any(p['type'] == 'stat' and p['title'] == 'doers: Latency p95' for p in doc['panels']))
        self.assertEqual({v['name'] for v in doc['templating']['list']}, {'environment', 'host', 'service'})
        log = doc['panels'][-1]['targets'][0]
        self.assertEqual(log['datasource']['uid'], 'dragontools-logs')
        self.assertIn('level:in(warning,warn,error,critical,fatal)', log['expr'])
        self.assertIn('| fields _time,service,level,event,method,path,status,_msg', log['expr'])
        self.assertNotIn('info', log['expr'])
        vmui = json.loads(first['vmui'])
        self.assertEqual(set(vmui), {'title', 'rows'})
        self.assertTrue(all(isinstance(p['expr'], list) and p['width'] == 6 for row in vmui['rows'] for p in row['panels']))

    def test_absent_histogram_counter_and_optional_http(self):
        http = self.config['services'][0]['http']
        http['duration_histogram'] = None
        self.assertNotIn('histogram_quantile', json.dumps(self.n['render'](self.config)['grafana'].decode()))
        http.update(requests_total=None, status_label=None, route_label=None, duration_histogram='latency_seconds')
        document = self.n['render'](self.config)['vmui'].decode()
        self.assertIn('histogram_quantile', document)
        self.assertNotIn('Requests per second', document)
        self.config['services'][0]['http'] = None
        document = self.n['render'](self.config)['grafana'].decode()
        self.assertIn('Memory current', document)
        self.assertIn('Warning / error', document)
        self.assertNotIn('histogram_quantile', document)

    def test_invalid_metric_identifiers_cannot_inject_queries(self):
        for value in ('requests{app="other"}', 'sum(requests)', 'requests[5m]', '__name__', 'x\n', '1bad'):
            self.config['services'][0]['http']['requests_total'] = value
            with self.assertRaises(ValueError):
                self.n['render'](self.config)

    def test_publish_loaded_and_noop_preserve_manual_and_other_apps(self):
        manual = Path(self.n['VM_ROOT']) / 'manual.json'
        manual.write_bytes(b'{"title":"Manual","rows":[]}')
        self.assertTrue(self.n['publish'](self.config))
        self.provision()
        self.n['loaded'](self.config)
        self.n['finish'](self.config)
        paths = list(self.n['paths'](self.config).values()) + [self.n['manifest_path'](self.config)]
        before = {p: (Path(p).read_bytes(), Path(p).stat().st_mtime_ns) for p in paths}
        self.assertFalse(self.n['publish'](self.config))
        self.assertEqual(before, {p: (Path(p).read_bytes(), Path(p).stat().st_mtime_ns) for p in paths})
        self.assertEqual(b'{"title":"Manual","rows":[]}', manual.read_bytes())

    def test_unmanaged_uid_and_foreign_file_fail_without_replacement(self):
        self.db.execute('INSERT INTO dashboard VALUES (1,1,?,?)', (self.n['uid'](self.config), '{}'))
        self.db.commit()
        with self.assertRaises(ValueError):
            self.n['publish'](self.config)
        self.assertFalse(Path(self.n['manifest_path'](self.config)).exists())
        self.db.execute('DELETE FROM dashboard'); self.db.commit()
        path = Path(self.n['paths'](self.config)['vmui'])
        path.write_bytes(b'{"managed_by":"dragontools"}')
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            self.n['publish'](self.config)
        self.assertEqual(b'{"managed_by":"dragontools"}', path.read_bytes())

    def test_edited_dashboard_symlink_or_binding_cannot_be_adopted(self):
        self.n['publish'](self.config)
        path = Path(self.n['paths'](self.config)['vmui'])
        exact = path.read_bytes()
        path.write_bytes(exact + b' ')
        with self.assertRaises(ValueError): self.n['publish'](self.config)

        path.unlink(); path.symlink_to('/etc/passwd')
        with self.assertRaises(ValueError): self.n['publish'](self.config)
        path.unlink(); path.write_bytes(exact); path.chmod(0o644)
        self.config['environment'] = 'staging'
        with self.assertRaises(ValueError): self.n['publish'](self.config)

    def test_unified_uid_collision_and_changed_provider_are_refused_read_only(self):
        self.provision()  # Loaded UID, but no owned manifest or files.
        with self.assertRaises(ValueError): self.n['publish'](self.config)
        self.assertFalse(Path(self.n['manifest_path'](self.config)).exists())
        self.db.execute('DELETE FROM resource'); self.db.commit()
        self.n['publish'](self.config)
        self.provision()
        before = Path(self.n['DB_PATH']).read_bytes()
        self.n['loaded'](self.config)
        self.assertEqual(before, Path(self.n['DB_PATH']).read_bytes())
        raw = json.loads(self.db.execute('SELECT value FROM resource').fetchone()[0])
        raw['metadata']['annotations']['grafana.app/managerId'] = 'manual-provider'
        self.db.execute('UPDATE resource SET value=?', (json.dumps(raw),)); self.db.commit()
        with self.assertRaises(ValueError): self.n['loaded'](self.config)
        with self.assertRaises(ValueError): self.n['publish'](self.config)

    def test_service_free_app_still_has_valid_host_dashboard_and_no_fake_http(self):
        self.config.update(services=[], probes=[])
        rendered = self.n['render'](self.config)
        vmui = json.loads(rendered['vmui'])
        self.assertTrue(vmui['rows'][0]['panels'])
        self.assertNotIn(b'Latency', rendered['grafana'])
        self.assertNotIn(b'Warning / error logs', rendered['grafana'])

    def test_dashboard_generation_transition_survives_interruption(self):
        self.n['publish'](self.config)
        self.provision()
        previous = copy.deepcopy(self.config)
        self.config['services'][0]['http']['route_label'] = None
        original = self.n['atomic']
        def fail(path, data):
            if path == self.n['paths'](self.config)['grafana']:
                raise OSError('fixture interruption')
            return original(path, data)
        self.n['atomic'] = fail
        with self.assertRaises(OSError): self.n['publish'](self.config)
        self.n['atomic'] = original
        self.assertIsNotNone(self.n['inspect'](self.config)['previous'])
        self.n['publish'](self.config)
        self.n['request'] = lambda port, path: {'dashboardsSettings': [json.loads(self.n['render'](self.config)['vmui'])]}
        with self.assertRaises(self.n['Pending']): self.n['loaded'](self.config)
        self.provision()
        self.n['loaded'](self.config)
        self.n['finish'](self.config)
        self.assertFalse(self.n['publish'](self.config))
        self.assertNotEqual(self.n['render'](previous), self.n['render'](self.config))

    def test_first_publication_short_write_and_stale_grafana_retry(self):
        original = self.n['atomic']
        def fail(path, data):
            if path == self.n['paths'](self.config)['vmui']:
                Path(path + '.next').write_bytes(data[:12]); Path(path + '.next').chmod(0o644)
                raise OSError('short write')
            original(path, data)
        self.n['atomic'] = fail
        with self.assertRaises(OSError): self.n['publish'](self.config)
        self.n['atomic'] = original
        self.assertTrue(self.n['publish'](self.config))
        self.n['request'] = lambda port, path: {'dashboardsSettings': [json.loads(self.n['render'](self.config)['vmui'])]}
        with self.assertRaises(self.n['Pending']): self.n['loaded'](self.config)
        self.provision(); self.n['loaded'](self.config)

    def test_http_readiness_zero_requests_and_down_valid_missing_signal_fails(self):
        queries = []
        def query(expression):
            queries.append(expression)
            return not expression.startswith('(up')
        self.n['query'] = query
        self.assertTrue(self.n['http_ready'](self.config))
        self.assertTrue(any('_bucket' in q for q in queries))
        self.assertFalse(any('rate(' in q for q in queries))  # presence, never nonzero RPS
        self.n['query'] = lambda q: '_bucket' not in q and not q.startswith('(up')
        self.assertFalse(self.n['http_ready'](self.config))
        self.n['query'] = lambda q: q.startswith('(up')
        self.assertTrue(self.n['http_ready'](self.config))

    def test_actual_doers_family_contract_rejects_gauge_and_missing_bucket(self):
        text = (ROOT / 'tests/fixtures/doers-http-metrics.prom').read_text()
        mapping = self.config['services'][0]['http']
        self.assertTrue(self.n['families'](text, mapping))
        self.assertFalse(self.n['families'](text.replace(' histogram', ' gauge'), mapping))
        self.assertFalse(self.n['families']('\n'.join(line for line in text.splitlines() if '_bucket{' not in line), mapping))
        self.assertFalse(self.n['families'](text.replace(' counter', ' gauge'), mapping))

    def test_station_separate_and_sources_not_invented(self):
        docs = self.n['render']({'station': True})
        self.assertNotEqual(self.n['uid']({'station': True}), self.n['uid'](self.config))
        self.assertIn(b'process_cpu_seconds_total', docs['vmui'])
        self.assertIn(b'not currently scraped', docs['grafana'])
        self.assertNotIn(b'doers', docs['grafana'])


if __name__ == '__main__':
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout))
