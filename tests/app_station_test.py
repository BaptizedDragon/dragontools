"""Real temporary-file ownership and native API fixtures; no SSH or notifications."""
import contextlib
import copy
import datetime
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NOW = 1800000000.0


def load():
    namespace = {'__name__': 'app_station_fixture'}
    for name in ('apps/station_model.py', 'scrape.py', 'vmalert_rules.py', 'apps/station_read.py', 'apps/station_mutate.py'):
        exec(compile((ROOT / 'src/monitoring' / name).read_text(), name, 'exec'), namespace)
    return namespace


def config(name='doers'):
    return {'application': name, 'environment': 'production', 'host': 'dt-' + 'a' * 32,
            'services': [{'name': 'api', 'systemd': 'api.service', 'logs': True, 'metrics_url': None}],
            'probes': [{'name': 'web', 'url': 'https://example.com/health'}],
            'alerts': [{'name': 'HighErrorRate', 'source': 'logs', 'severity': 'warning', 'service': 'api', 'level': 'error', 'window': '5m', 'threshold': 10}]}


class AppStationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.n = load()
        self.n['APP_ROOT'] = str(root / 'apps')
        self.n['APP_PENDING'] = {name: str(root / (name + '.pending')) for name in self.n['APP_FILES']}
        self.n['APP_VM_CONFIG'] = str(root / 'prometheus.yml')
        self.n['app_validate_native'] = lambda docs: None
        self.native = []
        self.n['app_exec'] = lambda argv: self.native.append(argv)
        node = self.n['app_node']
        def fixture_node(path, directory=False, missing=False, mode=None):
            try:
                info = os.lstat(path)
            except FileNotFoundError:
                if missing:
                    return None
                raise
            def rooted(_):
                return types.SimpleNamespace(st_mode=info.st_mode, st_nlink=info.st_nlink, st_size=info.st_size, st_uid=0, st_gid=0)
            with patch.object(os, 'lstat', rooted):
                return node(path, directory, missing, mode)
        self.n['app_node'] = fixture_node
        self.config = config()

    def app_path(self, filename, name='doers'):
        return Path(self.n['APP_ROOT']) / name / filename

    def snapshot(self, path):
        return {str(item.relative_to(path)): (item.read_bytes(), item.stat().st_mtime_ns) for item in path.rglob('*') if item.is_file()}

    def test_only_app_owned_files_change_other_app_manual_rules_and_assets_untouched(self):
        self.assertTrue(self.n['app_publish'](self.config))
        self.n['app_publish'](config('orderflow'))
        root = Path(self.temp.name)
        manual = root / 'manual.rules.yml'
        grafana = root / 'grafana.json'
        secret = root / 'telegram-token'
        for file in (manual, grafana, secret):
            file.write_text('administrator-owned')
        others = self.snapshot(Path(self.n['APP_ROOT']) / 'orderflow')
        old = self.snapshot(self.app_path('manifest.json').parent)
        self.config['alerts'] = []
        self.n['app_publish'](self.config)
        new = self.snapshot(self.app_path('manifest.json').parent)
        self.assertEqual(others, self.snapshot(Path(self.n['APP_ROOT']) / 'orderflow'))
        self.assertEqual(old['metrics.rules.yml'], new['metrics.rules.yml'])
        self.assertEqual(old['scrape.yml'], new['scrape.yml'])
        self.assertEqual(json.loads(new['logs.rules.yml'][0]), {'groups': []})
        for file in (manual, grafana, secret):
            self.assertEqual(file.read_text(), 'administrator-owned')

    def test_unchanged_publication_does_not_validate_rewrite_or_touch_markers(self):
        self.n['app_publish'](self.config)
        before = self.snapshot(Path(self.temp.name))
        self.n['app_validate_native'] = lambda _: self.fail('unchanged native dryRun')
        self.assertFalse(self.n['app_publish'](self.config))
        self.assertEqual(before, self.snapshot(Path(self.temp.name)))

    def test_alert_probe_and_endpoint_edits_only_dirty_affected_consumers(self):
        self.n['app_publish'](self.config)
        for path in self.n['APP_PENDING'].values():
            if os.path.exists(path):
                os.unlink(path)
        self.config['alerts'][0]['threshold'] = 20
        self.n['app_publish'](self.config)
        self.assertEqual({key for key, path in self.n['APP_PENDING'].items() if os.path.exists(path)}, {'logs.rules.yml'})
        for path in self.n['APP_PENDING'].values():
            if os.path.exists(path):
                os.unlink(path)
        self.config['services'][0]['metrics_url'] = 'http://127.0.0.1:16005/metrics'
        self.n['app_publish'](self.config)
        self.assertFalse(any(os.path.exists(path) for path in self.n['APP_PENDING'].values()))
        self.config['probes'].append({'name': 'api', 'url': 'https://example.com/api'})
        self.n['app_publish'](self.config)
        self.assertEqual({key for key, path in self.n['APP_PENDING'].items() if os.path.exists(path)}, {'metrics.rules.yml', 'scrape.yml'})

    def test_unmanaged_directory_marker_and_local_edits_cannot_be_adopted(self):
        root = Path(self.n['APP_ROOT'])
        root.mkdir()
        directory = root / 'doers'
        directory.mkdir()
        (directory / 'logs.rules.yml').write_text('# Managed by DragonTools\nmanual: true\n')
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.n['app_publish'](self.config)
        (directory / 'logs.rules.yml').unlink()
        directory.rmdir()
        self.n['app_publish'](self.config)
        self.app_path('logs.rules.yml').write_text('# Managed by DragonTools\nmanual: true\n')
        with self.assertRaises(ValueError):
            self.n['app_publish'](self.config)

    def test_namespace_environment_and_target_migration_fail_closed(self):
        self.n['app_publish'](self.config)
        for key, value in [('environment', 'staging'), ('host', 'dt-' + 'b' * 32)]:
            changed = copy.deepcopy(self.config)
            changed[key] = value
            with self.assertRaises(ValueError):
                self.n['app_preflight'](changed)

    def test_symlinks_hardlinks_and_extra_files_fail(self):
        self.n['app_publish'](self.config)
        path = self.app_path('scrape.yml')
        original = path.read_bytes()
        other = Path(self.temp.name) / 'outside'
        other.write_bytes(original)
        path.unlink()
        path.symlink_to(other)
        with self.assertRaises(ValueError):
            self.n['app_inspect']('doers')
        path.unlink()
        os.link(other, path)
        with self.assertRaises(ValueError):
            self.n['app_inspect']('doers')
        path.unlink()
        path.write_bytes(original)
        self.app_path('manual.yml').write_text('manual')
        with self.assertRaises(ValueError):
            self.n['app_inspect']('doers')

    def test_interrupted_publication_recovers_exact_previous_generation(self):
        self.n['app_publish'](self.config)
        updated = copy.deepcopy(self.config)
        updated['alerts'][0]['threshold'] = 99
        atomic = self.n['app_atomic']
        def interrupted(path, data):
            if path.endswith('/logs.rules.yml'):
                raise OSError('interrupted')
            atomic(path, data)
        self.n['app_atomic'] = interrupted
        with self.assertRaises(OSError):
            self.n['app_publish'](updated)
        self.assertTrue(Path(self.n['APP_PENDING']['logs.rules.yml']).exists())
        self.n['app_inspect']('doers', complete=False)
        with self.assertRaises(ValueError):
            self.n['app_inspect']('doers')
        self.n['app_atomic'] = atomic
        self.assertTrue(self.n['app_publish'](updated))
        self.assertFalse(self.n['app_publish'](updated))

    def test_partial_staging_writes_recover_new_and_existing_app(self):
        for existing in (False, True):
            for filename in ('logs.rules.yml', 'manifest.json'):
                name = ('old' if existing else 'new') + filename.split('.')[0]
                current = config(name)
                if existing:
                    self.n['app_publish'](current)
                current['alerts'][0]['threshold'] = 90
                atomic = self.n['app_atomic']
                failed = [False]
                def interrupted(path, data):
                    if path.endswith('/' + filename) and not failed[0]:
                        failed[0] = True
                        staged = Path(path).parent / ('.next-' + Path(path).name)
                        staged.write_bytes(data[:max(17, len(data) // 2)])
                        raise OSError('short temporary write')
                    atomic(path, data)
                self.n['app_atomic'] = interrupted
                with self.assertRaises(OSError):
                    self.n['app_publish'](current)
                self.n['app_atomic'] = atomic
                self.assertTrue(self.n['app_publish'](current))
                self.assertFalse(self.n['app_publish'](current))

    def test_first_generation_staging_is_outside_native_glob(self):
        atomic = self.n['app_atomic']
        def interrupted(path, data):
            atomic(path, data)
            if path.endswith('/scrape.yml'):
                raise OSError('interrupted before directory publication')
        self.n['app_atomic'] = interrupted
        with self.assertRaises(OSError):
            self.n['app_publish'](self.config)
        self.assertEqual(list(Path(self.n['APP_ROOT']).glob('*/scrape.yml')), [])
        self.assertEqual(self.n['app_all'](), [])
        self.n['app_atomic'] = atomic
        self.assertTrue(self.n['app_publish'](self.config))

    def test_empty_app_rule_documents_do_not_invoke_vmalert_empty_dryrun(self):
        value = config()
        value['alerts'] = []
        value['probes'] = []
        self.n['app_validate_native'] = load()['app_validate_native']
        self.n['app_validate_native'].__globals__['app_exec'] = lambda argv: self.native.append(argv)
        self.n['app_validate_native'](self.n['app_documents'](value))
        self.assertEqual(len(self.native), 1)
        self.assertIn('-promscrape.config.dryRun', self.native[0])

    def test_removal_updates_only_owned_rules_and_probe_override_is_single(self):
        value = copy.deepcopy(self.config)
        value['alerts'].append({'name': 'WebsiteDown', 'source': 'probe', 'severity': 'warning', 'probe': 'web', 'for_duration': '3m'})
        documents = self.n['app_documents'](value)
        metrics = json.loads(documents['metrics.rules.yml'])['groups'][0]['rules']
        self.assertEqual(len(metrics), 1)
        self.assertEqual(metrics[0]['alert'], 'WebsiteDown')
        self.assertEqual(metrics[0]['for'], '3m')
        self.assertEqual(metrics[0]['labels']['managed_by'], 'dragontools')
        logs = json.loads(documents['logs.rules.yml'])['groups'][0]['rules'][0]
        for field in ('application:="doers"', 'environment:="production"', 'service:in("api")', 'level:in(error)'):
            self.assertIn(field, logs['expr'])
        self.assertNotIn('message', logs['annotations']['description'])

    def test_shared_loader_upgrade_is_exact_preserves_station_probes_and_noop(self):
        original = '# Managed by DragonTools\nglobal:\n  scrape_interval: 30s\n  scrape_timeout: 5s\nscrape_configs: []\n'
        path = Path(self.n['APP_VM_CONFIG'])
        path.write_text(original)
        self.assertTrue(self.n['app_prepare_loader']())
        self.assertIn(self.n['APP_INCLUDE'], path.read_text())
        before = path.stat().st_mtime_ns
        self.assertFalse(self.n['app_prepare_loader']())
        self.assertEqual(path.stat().st_mtime_ns, before)
        path.write_text(original + '# manually changed\n')
        with self.assertRaises(ValueError):
            self.n['app_prepare_loader']()

    def test_probe_zero_valid_pipeline_and_stale_probe_pending(self):
        self.n['app_publish'](self.config)
        expected = self.n['application_definitions']()
        key = next(iter(expected))
        self.n['time'] = types.SimpleNamespace(time=lambda: NOW)
        def rows(expression):
            value = NOW - 2 if expression.startswith('timestamp(') else 1 if 'up{' in expression else 0
            metric = 'up' if 'up{' in expression else 'probe_success'
            return [{'metric': dict(expected[key], __name__=metric), 'value': [NOW, str(value)]}]
        self.n['query'] = rows
        self.assertEqual(self.n['stored_states'](expected, True), {key: 'unhealthy'})
        self.n['query'] = lambda expression: []
        self.assertEqual(self.n['stored_states'](expected, True), {key: 'unknown'})

    def test_readonly_app_rule_api_requires_exact_loaded_rules(self):
        spec = json.loads(self.n['app_documents'](self.config)['logs.rules.yml'])['groups'][0]
        file = '/etc/dragontools/apps/doers/logs.rules.yml'
        group = {'name': spec['name'], 'file': file, 'type': 'vlogs', 'interval': 30, 'rules': []}
        for rule in spec['rules']:
            group['rules'].append({'name': rule['alert'], 'file': file, 'type': 'alerting', 'datasourceType': 'vlogs', 'duration': 0,
                'query': rule['expr'], 'labels': rule['labels'], 'annotations': rule['annotations'], 'health': 'ok',
                'lastError': '', 'lastEvaluation': datetime.datetime.fromtimestamp(NOW - 3, datetime.timezone.utc).isoformat(), 'state': 'firing'})
        self.n['validate_application_group'](group, file, spec, NOW)
        group['rules'][0]['labels'] = {'managed_by': 'someone'}
        with self.assertRaises(ValueError):
            self.n['validate_application_group'](group, file, spec, NOW)


if __name__ == '__main__':
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output).run(unittest.defaultTestLoader.loadTestsFromTestCase(AppStationTests))
    print(output.getvalue(), end='')
    sys.exit(0 if result.wasSuccessful() else 1)
