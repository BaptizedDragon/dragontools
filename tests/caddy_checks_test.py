#!/usr/bin/env python3
"""Observed Caddy metadata/display with actual generated policy; local fakes only.

No SSH, services or credential contents. Executable bytes stand in for the pinned
binary; its real digest, unit and configuration are checked separately below.
"""
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/monitoring/agents/checks.py').read_text()
CHECKS = compile(SOURCE, 'checks.py', 'exec')
UNIT = 'dragontools-caddy.service'
UNIT_PATH = '/etc/systemd/system/' + UNIT
CONFIG = '/etc/dragontools/caddy/Caddyfile'
BINARY_ROOT = '/opt/dragontools/components/caddy'
BINARY = BINARY_ROOT + '/v2.11.4/caddy'
PENDING = '/var/lib/dragontools/caddy-restart-required'
CREDENTIALS = dict(type='a(ss)', data=[
    ['ca.crt', '/etc/dragontools/ingestion/server/ca.crt'],
    ['server.crt', '/etc/dragontools/ingestion/server/server.crt'],
    ['server.key', '/etc/dragontools/ingestion/server/server.key']])
# Captured from systemd 259.5 on the affected Ubuntu 26.04 station. The display
# placeholder is not the value of its correctly populated a(ss) D-Bus property.
PROPERTIES = dict(
    User='dt-caddy', Group='dt-caddy', SupplementaryGroups='dt-ingest',
    FragmentPath=UNIT_PATH, DropInPaths='', LoadState='loaded',
    NeedDaemonReload='no', UnitFileState='enabled', ProtectSystem='strict',
    CapabilityBoundingSet='', AmbientCapabilities='', StandardOutput='null',
    StandardError='null', UMask='0077', ReadWritePaths='/var/lib/dragontools/caddy',
    NoNewPrivileges='yes', PrivateTmp='yes', PrivateDevices='yes', ProtectHome='yes',
    ProtectKernelTunables='yes', ProtectKernelModules='yes', ProtectControlGroups='yes',
    RestrictSUIDSGID='yes', LockPersonality='yes',
    RestrictAddressFamilies='AF_INET AF_INET6 AF_UNIX',
    InaccessiblePaths='/etc/dragontools/ingestion/pki /etc/dragontools/ingestion/clients /etc/dragontools/ingestion/server',
    LoadCredential='[unprintable]', LimitCORE='0', RuntimeDirectory='', RuntimeDirectoryMode='0755')


def metadata(mode, uid=0, gid=0):
    return types.SimpleNamespace(st_mode=mode, st_uid=uid, st_gid=gid, st_nlink=1)


class CaddyChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = os.environ.get('DRAGONTOOLS_PKI_FIXTURE', str(ROOT / 'zig-out/bin/dragontool-pki-fixture'))
        result = subprocess.run([fixture, 'caddy-checks'], capture_output=True, text=True, check=True)
        assert result.stderr == ''
        cls.rendered = json.loads(result.stdout)

    def setUp(self):
        self.spec = json.loads(self.rendered['spec'])
        self.pin = self.spec['digest']
        self.binary = b'local stand-in for verified Caddy executable'
        self.spec['digest'] = hashlib.sha256(self.binary).hexdigest()
        self.account = types.SimpleNamespace(pw_uid=980, pw_gid=974,
                                           pw_shell='/usr/sbin/nologin', pw_dir='/var/lib/dragontools/caddy')
        self.props = copy.copy(PROPERTIES)
        self.credentials = copy.deepcopy(CREDENTIALS)
        self.bus_error = False
        self.calls = []
        self.link = 'v2.11.4'
        self.files = {UNIT_PATH: self.spec['unit'].encode(), BINARY: self.binary,
                      **{item['path']: item['content'].encode() for item in self.spec['files']}}
        self.paths = {path: metadata(stat.S_IFDIR | 0o755) for path in (
            '/opt/dragontools', '/opt/dragontools/components', '/etc/dragontools',
            '/var/lib/dragontools', '/etc/dragontools/caddy', BINARY_ROOT, BINARY_ROOT + '/v2.11.4')}
        self.paths.update({path: metadata(stat.S_IFREG | (0o755 if path == BINARY else 0o644)) for path in self.files})
        self.paths['/var/lib/dragontools/caddy'] = metadata(stat.S_IFDIR | 0o750, uid=980, gid=974)

    def output(self, argv, **_):
        self.calls.append(argv)
        if argv == ('systemctl', 'show', '--all', UNIT):
            return ''.join(key + '=' + value + '\n' for key, value in self.props.items()).encode()
        if argv in (('id', '-gn', 'dt-caddy'), ('id', '-nG', 'dt-caddy')):
            return b'dt-caddy\n'
        if argv == ('busctl', '--system', '--json=short', 'get-property', 'org.freedesktop.systemd1',
                    '/org/freedesktop/systemd1/unit/dragontools_2dcaddy_2eservice',
                    'org.freedesktop.systemd1.Service', 'LoadCredential'):
            if self.bus_error:
                raise subprocess.CalledProcessError(1, argv, stderr=b'PRIVATE-OUTPUT-SENTINEL')
            return (self.credentials if isinstance(self.credentials, str) else json.dumps(self.credentials)).encode()
        raise AssertionError('unexpected subprocess')

    def verify(self, action='managed'):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, 'argv', ['checks.py', action, json.dumps(self.spec)]), \
             patch('subprocess.check_output', side_effect=self.output), \
             patch('pwd.getpwnam', return_value=self.account), \
             patch('os.lstat', side_effect=lambda path: self.paths[path]), \
             patch('os.readlink', side_effect=lambda path: self.link if path == BINARY_ROOT + '/current' else None), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                # Reject every read except the exact unit, config and binary.
                exec(CHECKS, {'__name__': '__main__', 'open': lambda path, *_: io.BytesIO(self.files[path])})
                result = 0
            except SystemExit as error:
                result = error.code
        self.assertEqual(stdout.getvalue(), '')
        self.assertEqual(stderr.getvalue(), '')
        return result

    def test_observed_healthy_caddy_with_unprintable_credentials_passes(self):
        self.assertEqual(self.pin, 'b7105518e3ed1c0761f232e44fc09345535533c9cb0abf0e12809416c7ac64d9')
        self.assertEqual(hashlib.sha256(self.files[UNIT_PATH]).hexdigest(),
                         '4feaa42d22b56e5f145f5f9121350a60658d2fa1bdc780c525d801810b7c62ff')
        self.assertEqual(hashlib.sha256(self.files[CONFIG]).hexdigest(),
                         'ac60cb630da25bc5ca32ff00e537db98d0aba34090ea071ea3f878cea59903c7')
        self.assertEqual(self.verify(), 0)

    def test_credential_comparison_is_typed_unordered_and_uses_rendered_policy(self):
        for display in ('[unprintable]', '', 'a different display representation'):
            self.props['LoadCredential'] = display
            self.credentials['data'].reverse()
            self.assertEqual(self.verify('caddy_credentials'), 0)
        # The effective credential query, not systemctl's display, is required.
        self.props.pop('LoadCredential')
        self.assertEqual(self.verify(), 0)
        self.spec['unit'] = self.spec['unit'].replace('server/server.crt', 'server/other.crt')
        self.assertEqual(self.verify('caddy_credentials'), 1)
        for record in self.credentials['data']:
            if record[0] == 'server.crt':
                record[1] = '/etc/dragontools/ingestion/server/other.crt'
        self.assertEqual(self.verify('caddy_credentials'), 0)

    def test_missing_extra_duplicate_wrong_source_and_malformed_credentials_fail_once(self):
        cases = [
            {'type': 'as', 'data': CREDENTIALS['data']},
            {'type': 'a(ss)', 'data': []},
            {'type': 'a(ss)', 'data': CREDENTIALS['data'][:-1]},
            {'type': 'a(ss)', 'data': CREDENTIALS['data'] + [['ca.key', '/not-allowed']]},
            {'type': 'a(ss)', 'data': [CREDENTIALS['data'][0]] * 3},
            {'type': 'a(ss)', 'data': [CREDENTIALS['data'][0], CREDENTIALS['data'][1], ['server.key', '/wrong/key']]},
            {'type': 'a(ss)', 'data': [CREDENTIALS['data'][0], CREDENTIALS['data'][1], ['client.key', CREDENTIALS['data'][2][1]]]},
            {'type': 'a(ss)', 'data': [['server.key', 123], *CREDENTIALS['data'][:2]]},
            {'type': 'a(ss)', 'data': [['server.key'], *CREDENTIALS['data'][:2]]},
            {'type': 'a(ss)', 'data': None}, {}, [], 'not JSON',
        ]
        for index, value in enumerate(cases):
            with self.subTest(case=index):
                self.credentials = value
                self.calls.clear()
                self.assertEqual(self.verify('caddy_credentials'), 1)
                self.assertEqual(len(self.calls), 1)
        self.bus_error = True
        self.assertEqual(self.verify('caddy_credentials'), 1)

    def test_each_managed_failure_has_a_separate_read_only_entrypoint(self):
        mutations = {
            'caddy_account': lambda: setattr(self.account, 'pw_uid', 0),
            'caddy_binary': lambda: self.files.update({BINARY: b'corrupt'}),
            'caddy_unit': lambda: self.files.update({UNIT_PATH: b'local edit'}),
            'caddy_systemd_properties': lambda: self.props.update(SupplementaryGroups=''),
            'caddy_config': lambda: self.files.update({CONFIG: b'PRIVATE-OUTPUT-SENTINEL'}),
            'caddy_credentials': lambda: self.credentials['data'].pop(),
            'caddy_directories': lambda: setattr(self.paths['/var/lib/dragontools/caddy'], 'st_gid', 980),
        }
        for check, mutate in mutations.items():
            with self.subTest(check=check):
                self.setUp()
                self.assertEqual(self.verify(check), 0)
                mutate()
                self.assertEqual(self.verify(check), 1)
                self.assertEqual(self.verify(check), 1)

    def test_symlink_modes_and_security_properties_remain_strict(self):
        self.link = 'v0.0.0'
        self.assertEqual(self.verify('caddy_binary'), 1)
        for path, check in ((BINARY, 'caddy_binary'), (UNIT_PATH, 'caddy_unit'), (CONFIG, 'caddy_config')):
            for field, value in (('st_mode', stat.S_IFLNK | 0o777), ('st_uid', 980), ('st_nlink', 2)):
                with self.subTest(path=path, field=field):
                    self.setUp()
                    setattr(self.paths[path], field, value)
                    self.assertEqual(self.verify(check), 1)
        for key in ('DropInPaths', 'CapabilityBoundingSet', 'AmbientCapabilities', 'InaccessiblePaths', 'ReadWritePaths', 'SupplementaryGroups'):
            for missing in (False, True):
                with self.subTest(property=key, missing=missing):
                    self.setUp()
                    if missing:
                        del self.props[key]
                    else:
                        self.props[key] = 'wrong'
                    self.assertEqual(self.verify('caddy_systemd_properties'), 1)

    def test_existing_pending_restart_verifies_finalizes_and_next_activation_is_no_op(self):
        with tempfile.TemporaryDirectory(prefix='dragontools-caddy-checks-') as tmp:
            pending, calls = Path(tmp) / 'pending', Path(tmp) / 'calls'
            pending.touch(mode=0o600)
            wrapper = '''
stat() { printf '0:0'; }
systemctl() {
  case "$1" in
    is-enabled) printf enabled;;
    is-active) return 0;;
    show) case "$3" in NeedDaemonReload) printf no;; LoadState) printf loaded;; *) return 1;; esac;;
    restart) printf '%s\\n' "$2" >> "$fixture_calls";;
    *) return 1;;
  esac
}
'''
            def activate():
                script = 'fixture_calls=' + shlex.quote(str(calls)) + '\n' + wrapper
                script += self.rendered['activate'].replace(PENDING, shlex.quote(str(pending)))
                result = subprocess.run(['/bin/sh', '-eu', '-c', script], capture_output=True, text=True, check=True)
                self.assertEqual(result.stderr, '')
                return result.stdout

            self.assertEqual(self.verify(), 0)
            self.assertEqual(activate(), 'changed')
            self.bus_error = True
            self.assertEqual(self.verify('caddy_credentials'), 1)
            self.assertTrue(pending.exists())
            self.bus_error = False
            self.assertEqual(self.verify(), 0)
            finalize = self.rendered['finalize'].replace("'" + PENDING + "'", shlex.quote(str(pending)))
            self.assertNotIn(PENDING, finalize)
            result = subprocess.run(['/bin/sh', '-eu', '-c', finalize], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout + result.stderr, '')
            self.assertFalse(pending.exists())
            self.assertEqual(self.verify(), 0)
            self.assertEqual(activate(), 'unchanged')
            self.assertEqual(calls.read_text().splitlines(), [UNIT])


if __name__ == '__main__':
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout, verbosity=2))
