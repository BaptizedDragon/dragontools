#!/usr/bin/env python3
"""Observed station metadata with the real renderer, verifier and activation.

Local fakes only: no SSH, systemd, sockets, keys or real host mutations.
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
UNIT = 'dragontools-ingress-auth.service'
UNIT_PATH = '/etc/systemd/system/' + UNIT
HELPER = '/opt/dragontools/ingress-auth/authorize.py'
BASE = '/etc/dragontools/ingestion'
PENDING = '/var/lib/dragontools/ingress-auth-restart-required'
# Values captured read-only on the affected station, including unequal uid/gid.
PROPERTIES = dict(
    User='dt-ingest', Group='dt-ingest', SupplementaryGroups='',
    FragmentPath=UNIT_PATH, DropInPaths='', LoadState='loaded',
    NeedDaemonReload='no', UnitFileState='enabled', ProtectSystem='strict',
    CapabilityBoundingSet='', AmbientCapabilities='', StandardOutput='null',
    StandardError='null', UMask='0077', ReadWritePaths='/run/dragontools-ingress',
    NoNewPrivileges='yes', PrivateTmp='yes', PrivateDevices='yes', ProtectHome='yes',
    ProtectKernelTunables='yes', ProtectKernelModules='yes', ProtectControlGroups='yes',
    RestrictSUIDSGID='yes', LockPersonality='yes',
    RestrictAddressFamilies='AF_INET AF_INET6 AF_UNIX',
    InaccessiblePaths=BASE + '/pki ' + BASE + '/clients ' + BASE + '/server',
    LimitCORE='0', RuntimeDirectory='dragontools-ingress', RuntimeDirectoryMode='0750')


def metadata(mode, uid=0, gid=0):
    return types.SimpleNamespace(st_mode=mode, st_uid=uid, st_gid=gid, st_nlink=1)


class ManagedIngress(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = os.environ.get('DRAGONTOOLS_PKI_FIXTURE', str(ROOT / 'zig-out/bin/dragontool-pki-fixture'))
        result = subprocess.run([fixture, 'ingress-checks'],
                                capture_output=True, check=True, text=True)
        assert result.stderr == ''
        cls.rendered = json.loads(result.stdout)

    def setUp(self):
        self.spec = json.loads(self.rendered['spec'])
        self.account = types.SimpleNamespace(pw_uid=981, pw_gid=975,
                                           pw_shell='/usr/sbin/nologin', pw_dir='/var/lib/dragontools/ingestion')
        self.props = copy.copy(PROPERTIES)
        self.calls = []
        self.files = {UNIT_PATH: self.spec['unit'].encode(),
                      **{item['path']: item['content'].encode() for item in self.spec['files']}}
        self.paths = {name: metadata(stat.S_IFDIR | 0o755) for name in (
            '/opt/dragontools', '/opt/dragontools/components', '/opt/dragontools/ingress-auth',
            '/etc/dragontools', '/var/lib/dragontools', BASE)}
        self.paths.update({name: metadata(stat.S_IFREG | 0o644) for name in self.files})
        self.paths.update({BASE + '/' + name: metadata(stat.S_IFDIR | 0o700) for name in ('pki', 'clients')})
        self.paths.update({BASE + '/' + name: metadata(stat.S_IFDIR | 0o750, gid=975) for name in ('registry', 'server')})
        self.paths['/var/lib/dragontools/ingestion'] = metadata(stat.S_IFDIR | 0o750, uid=981, gid=975)

    def output(self, argv, **_):
        self.calls.append(argv)
        if argv[:2] == ('systemctl', 'show'):
            assert argv[-1] == UNIT
            # systemctl show omits empty values unless --all is requested.
            return ''.join(key + '=' + value + '\n' for key, value in self.props.items()
                           if value or '--all' in argv).encode()
        if argv in (('id', '-gn', 'dt-ingest'), ('id', '-nG', 'dt-ingest')):
            return b'dt-ingest\n'
        raise AssertionError('unexpected subprocess')

    def read(self, path, *_):
        # Any private-key read, directory traversal or unrelated read fails.
        return io.BytesIO(self.files[path])

    def verify(self, action='managed', source=CHECKS):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, 'argv', ['checks.py', action, json.dumps(self.spec)]), \
             patch('subprocess.check_output', side_effect=self.output), \
             patch('pwd.getpwnam', return_value=self.account), \
             patch('os.lstat', side_effect=lambda path: self.paths[path]), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                exec(source, {'__name__': '__main__', 'open': self.read})
                result = 0
            except SystemExit as error:
                result = error.code
        self.assertEqual(stdout.getvalue(), '')
        self.assertEqual(stderr.getvalue(), '')
        return result

    def test_exact_production_state_is_valid_with_complete_properties(self):
        self.assertEqual(len(self.files[UNIT_PATH]), 953)
        self.assertEqual(hashlib.sha256(self.files[UNIT_PATH]).hexdigest(),
                         '657b327b45f377b1080021e8afad12c9d078a694031087f8dce6a6724aedd331')
        self.assertEqual(hashlib.sha256(self.files[HELPER]).hexdigest(),
                         '1df08d3a2d4ca7bd6113a008000c8689a4e751483468d30da46ba2d8122bf74c')
        self.assertEqual(self.verify(), 0)

    def test_omitting_empty_properties_reproduces_the_previous_failure(self):
        legacy = SOURCE.replace("output('systemctl', 'show', '--all', unit)",
                                "output('systemctl', 'show', unit)")
        self.assertNotEqual(legacy, SOURCE)
        self.assertEqual(self.verify('managed_systemd_properties', compile(legacy, 'legacy-checks.py', 'exec')), 1)
        self.assertEqual(self.verify('managed_systemd_properties'), 0)

    def test_empty_is_valid_but_missing_or_nonempty_security_properties_fail(self):
        for key in ('DropInPaths', 'CapabilityBoundingSet', 'AmbientCapabilities', 'SupplementaryGroups'):
            for value in (None, 'unexpected'):
                with self.subTest(key=key, value=value):
                    self.props = copy.copy(PROPERTIES)
                    if value is None:
                        del self.props[key]
                    else:
                        self.props[key] = value
                    self.calls.clear()
                    self.assertEqual(self.verify('managed_systemd_properties'), 1)
                    self.assertEqual(len(self.calls), 1)
        self.props = copy.copy(PROPERTIES)
        self.assertEqual(self.verify('managed_systemd_properties'), 0)

    def test_systemd_expected_values_come_from_the_rendered_unit(self):
        self.spec['unit'] = self.spec['unit'].replace('UMask=0077', 'UMask=0027')
        self.assertEqual(self.verify('managed_systemd_properties'), 1)
        self.props['UMask'] = '0027'
        self.assertEqual(self.verify('managed_systemd_properties'), 0)
        for key in ('InaccessiblePaths', 'RestrictAddressFamilies'):
            self.props[key] = ' '.join(reversed(self.props[key].split()))
        self.assertEqual(self.verify('managed_systemd_properties'), 0)
        self.props['InaccessiblePaths'] = BASE + '/pki ' + BASE + '/clients'
        self.assertEqual(self.verify('managed_systemd_properties'), 1)

    def test_distinct_read_only_checks_refuse_only_the_affected_invariant(self):
        mutations = {
            'managed_account': lambda: setattr(self.account, 'pw_uid', 0),
            'managed_unit': lambda: self.files.update({UNIT_PATH: b'local unit edit'}),
            'managed_helper': lambda: self.files.update({HELPER: b'local helper edit'}),
            'managed_directories': lambda: setattr(self.paths[BASE + '/pki'], 'st_mode', stat.S_IFDIR | 0o755),
            'managed_registry': lambda: setattr(self.paths[BASE + '/registry'], 'st_gid', 981),
            'managed_server_state': lambda: setattr(self.paths[BASE + '/server'], 'st_uid', 981),
            'managed_systemd_properties': lambda: self.props.update(CapabilityBoundingSet='cap_net_admin'),
        }
        for check, mutate in mutations.items():
            with self.subTest(check=check):
                self.setUp()
                self.assertEqual(self.verify(check), 0)
                mutate()
                self.assertEqual(self.verify(check), 1)
                # In particular, failures never print file contents or tracebacks.
                self.assertEqual(self.verify(check), 1)

    def test_directory_symlink_owner_group_and_mode_mismatches_remain_failures(self):
        for name, check in (('registry', 'managed_registry'), ('server', 'managed_server_state')):
            for field, value in (('st_mode', stat.S_IFLNK | 0o750), ('st_mode', stat.S_IFREG | 0o750),
                                 ('st_mode', stat.S_IFDIR | 0o700), ('st_uid', 981), ('st_gid', 0)):
                with self.subTest(name=name, field=field, value=value):
                    self.setUp()
                    setattr(self.paths[BASE + '/' + name], field, value)
                    self.assertEqual(self.verify(check), 1)

    def test_retained_restart_intent_converges_then_activation_is_a_no_op(self):
        with tempfile.TemporaryDirectory(prefix='dragontools-ingress-checks-') as tmp:
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

            # Exact desired files/metadata need no repair; only retained restart
            # intent requires activation. Failed verification must retain it.
            self.assertEqual(self.verify(), 0)
            self.assertEqual(activate(), 'changed')
            self.props['CapabilityBoundingSet'] = 'cap_net_admin'
            self.assertEqual(self.verify(), 1)
            self.assertTrue(pending.exists())
            self.props['CapabilityBoundingSet'] = ''
            self.assertEqual(self.verify(), 0)
            # remote.quote always single-quotes, even simple paths.
            final = self.rendered['finalize'].replace("'" + PENDING + "'", shlex.quote(str(pending)))
            self.assertNotIn(PENDING, final)
            result = subprocess.run(['/bin/sh', '-eu', '-c', final], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout + result.stderr, '')
            self.assertFalse(pending.exists())
            self.assertEqual(self.verify(), 0)
            self.assertEqual(activate(), 'unchanged')
            self.assertEqual(calls.read_text().splitlines(), [UNIT])


if __name__ == '__main__':
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout, verbosity=2))
