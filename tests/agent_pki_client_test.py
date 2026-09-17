"""Real OpenSSL host-local enrollment/renewal/migration; no SSH/systemd hosts."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
HOST = 'dt-' + '1' * 32
ENDPOINT = 'station.example.test'


def load(client=False):
    module = types.ModuleType('client_fixture' if client else 'station_fixture')
    source = (REPO / 'src/monitoring/agents/pki.py').read_text()
    if client:
        source += '\n' + (REPO / 'src/monitoring/agents/client_pki.py').read_text()
    exec(compile(source, '<embedded-pki-fixture>', 'exec'), module.__dict__)
    return module


def snapshot(path):
    return {str(file.relative_to(path)): (file.read_bytes(), file.stat().st_mtime_ns)
            for file in path.rglob('*') if file.is_file()}


class ClientLifecycle(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.tmp = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix='dragontools-local-client-')))
        self.station, self.client = load(), load(True)
        uid, gid = os.getuid(), os.getgid()
        account = types.SimpleNamespace(pw_uid=uid, pw_gid=gid)
        real_chown, real_fchown = os.chown, os.fchown
        self.stack.enter_context(patch.object(os, 'chown', side_effect=lambda path, u, g: real_chown(path, u, gid if g == uid else g)))
        self.stack.enter_context(patch.object(os, 'fchown', side_effect=lambda fd, u, g: real_fchown(fd, u, gid if g == uid else g)))
        self.stack.enter_context(patch.object(self.station.pwd, 'getpwnam', return_value=account))
        for name, module in [('station', self.station), ('app', self.client)]:
            etc, state = self.tmp / name / 'etc', self.tmp / name / 'state'
            etc.mkdir(parents=True)
            state.mkdir()
            etc.chmod(0o755)
            state.chmod(0o755)
            module.ROOT, module.ETC, module.STATE = uid, str(etc), str(state)
            module.BASE = str(etc / 'ingestion')
            real_read, real_directory = module.read, module.directory
            self.stack.enter_context(patch.object(module, 'read', side_effect=lambda path, u, g, *a, real=real_read: real(path, u, gid if g == uid else g, *a)))
            self.stack.enter_context(patch.object(module, 'directory', side_effect=lambda path, mode, u, g, *a, real=real_directory: real(path, mode, u, gid if g == uid else g, *a)))
        Path(self.station.BASE).mkdir(mode=0o755)
        for kind in ('vector', 'vmagent'):
            (Path(self.client.ETC) / kind).mkdir(mode=0o755)
        self.commands, self.active = [], {'vector': True, 'vmagent': True}
        real_run = subprocess.run

        def run(argv, **kwargs):
            if argv[0] != 'systemctl':
                return real_run(argv, **kwargs)
            kind = argv[-1].removeprefix('dragontools-').removesuffix('.service')
            if argv[1] == 'is-active':
                return types.SimpleNamespace(returncode=0 if self.active[kind] else 3, stdout=b'active\n' if self.active[kind] else b'inactive\n')
            self.commands.append((argv[1], kind))
            self.active[kind] = argv[1] != 'stop'
            return types.SimpleNamespace(returncode=0, stdout=b'')

        self.stack.enter_context(patch.object(subprocess, 'run', side_effect=run))
        self.value = dict(version=1, host=HOST, station=ENDPOINT, services=['app.service'], metrics_targets=[])
        self.assertEqual(self.station.ensure(self.value), 'changed')
        self.root = Path(self.client.client_path())

    def prepare(self):
        return self.client.client_prepare(HOST, ENDPOINT, self.station.inspect_station(HOST, ENDPOINT))

    def sign(self, csr, days=365, legacy=False):
        with tempfile.TemporaryDirectory(dir=self.tmp) as temporary:
            ext = Path(temporary) / 'extensions'
            content = 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n'
            if not legacy:
                content += 'subjectAltName=URI:dragontools://hosts/' + HOST + '\n'
            ext.write_text(content)
            return self.station.run('x509', '-req', '-CA', self.station.BASE + '/pki/ca/ca.crt', '-CAkey', self.station.BASE + '/pki/ca/ca.key',
                                    '-set_serial', '0x' + os.urandom(16).hex(), '-days', str(days), '-sha256', '-extfile', str(ext), data=csr.encode())

    def stage(self, prepared=None, days=365):
        prepared = prepared or self.prepare()
        with patch.object(self.station, 'sign', side_effect=lambda csr, *_: self.sign(csr, days)):
            payload = self.station.stage(self.value, prepared['csr'])
        self.assertNotIn('PRIVATE KEY', json.dumps(payload))
        self.client.client_stage(payload)
        return payload

    def install(self, kinds=('vector', 'vmagent')):
        for kind in kinds:
            self.client.client_install(kind, HOST, ENDPOINT)
            # Model the separate normal activation operation.
            self.active[kind] = True

    def commit(self, payload):
        self.station.finalize(HOST, payload['certificate_sha256'])
        self.client.client_commit(HOST, ENDPOINT)

    def enroll(self, days=365):
        payload = self.stage(days=days)
        self.install()
        self.commit(payload)
        self.commands.clear()
        return payload

    def legacy(self, days=365):
        client_dir = Path(self.station.BASE) / 'clients' / HOST
        key = self.station.run('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256')
        with tempfile.TemporaryDirectory(dir=self.tmp) as temporary:
            key_path = Path(temporary) / 'key'
            key_path.write_bytes(key)
            csr = self.station.run('req', '-new', '-key', str(key_path), '-subj', '/CN=' + HOST).decode()
            cert = self.sign(csr, days=days, legacy=True)
        self.station.create_bundle(str(client_dir), self.station.ROOT, self.station.ROOT, {'client.key': key, 'client.crt': cert})
        self.station._save_registry(HOST, dict(self.value, certificate_sha256=self.station.fingerprint(cert)))
        for kind in ('vector', 'vmagent'):
            directory = Path(self.client.ETC) / kind
            values = {'ca.crt': (Path(self.station.BASE) / 'pki/ca/ca.crt').read_bytes(), 'client.crt': cert, 'client.key': key,
                      '.agent-identity': self.client.encoded(dict(host=HOST, station=ENDPOINT)), '.dragontools-credentials': self.client.MARKER}
            for name, value in values.items():
                self.client.write(str(directory / name), value, self.client.ROOT, self.client.ROOT)
        return key, cert

    def test_new_identity_locality_and_second_apply_noop(self):
        prepared = self.prepare()
        self.assertEqual(prepared['action'], 'enroll')
        self.assertIn('CERTIFICATE REQUEST', prepared['csr'])
        self.assertNotIn('PRIVATE KEY', json.dumps(prepared))
        key = (self.root / '.pending/client.key').read_bytes()
        payload = self.stage(prepared)
        self.assertEqual((self.root / '.pending/client.key').read_bytes(), key)
        self.assertFalse(list(Path(self.station.BASE).rglob('client.key')))
        self.install()
        self.commit(payload)
        self.assertEqual((self.root / 'client.key').read_bytes(), key)
        for kind in ('vector', 'vmagent'):
            self.assertEqual((Path(self.client.ETC) / kind / 'client.key').read_bytes(), key)
            self.assertEqual((Path(self.client.ETC) / kind / 'client.key').stat().st_mode & 0o777, 0o400)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.commands.clear()
        before_app, before_station = snapshot(Path(self.client.ETC)), snapshot(Path(self.station.BASE))
        original = self.client.run
        def readonly(*args, **kw):
            self.assertNotIn(args[0], ('genpkey', 'req'))
            return original(*args, **kw)
        with patch.object(self.client, 'run', side_effect=readonly):
            self.assertEqual(self.prepare()['action'], 'unchanged')
            self.install()
            self.assertEqual(self.client.client_commit(HOST, ENDPOINT), 'unchanged')
        self.assertEqual(self.station.stage_registration(self.value), 'unchanged')
        self.assertEqual(self.station.finalize(HOST, payload['certificate_sha256']), 'unchanged')
        self.assertEqual(before_app, snapshot(Path(self.client.ETC)))
        self.assertEqual(before_station, snapshot(Path(self.station.BASE)))
        self.assertEqual(self.commands, [])

    def test_hostname_change_preserves_client_identity_and_public_registration_finalizes(self):
        first = self.enroll()
        before = snapshot(Path(self.client.ETC))
        endpoint = "monitoring.baptizeddragon.com"
        changed = dict(self.value, station=endpoint)
        self.assertEqual(self.station.ensure(changed), "changed")
        inspection = self.station.inspect_station(HOST, endpoint)
        prepared = self.client.client_prepare(HOST, endpoint, inspection)
        self.assertEqual(prepared['action'], 'unchanged')
        self.assertIsNone(prepared['csr'])
        self.assertEqual(self.station.stage_registration(changed), "changed")
        # Interrupted staged registration is readable and repeatable before commit.
        self.assertEqual(self.station.stage_registration(changed), "unchanged")
        for kind in ('vector', 'vmagent'):
            self.assertEqual(self.client.client_install(kind, HOST, endpoint), "unchanged")
            self.client.verify_credentials(kind, HOST, endpoint)
        self.assertEqual(before, snapshot(Path(self.client.ETC)))
        self.assertEqual(self.commands, [])
        self.station.finalize(HOST, first['certificate_sha256'])
        self.station.verify_station(changed)
        self.assertEqual(self.client.client_commit(HOST, endpoint), "unchanged")
        after = snapshot(Path(self.station.BASE))
        self.assertEqual(self.station.ensure(changed), "unchanged")
        self.assertEqual(self.station.stage_registration(changed), "unchanged")
        self.assertEqual(after, snapshot(Path(self.station.BASE)))
        self.assertEqual(before, snapshot(Path(self.client.ETC)))
        # A name change never grants permission to change the trust root.
        with self.assertRaises(ValueError):
            self.client.client_prepare(HOST, endpoint, dict(inspection, **{'ca.crt': 'foreign CA'}))
        self.assertEqual(before, snapshot(Path(self.client.ETC)))

    def test_renewal_after_hostname_change_reuses_key_and_recovers(self):
        self.enroll(days=30)
        key = (self.root / 'client.key').read_bytes()
        endpoint = "renewed.example"
        changed = dict(self.value, station=endpoint)
        self.station.ensure(changed)
        prepared = self.client.client_prepare(HOST, endpoint, self.station.inspect_station(HOST, endpoint))
        self.assertEqual(prepared['action'], 'renew')
        payload = self.station.stage(changed, prepared['csr'])
        self.client.client_stage(payload)
        for kind in ('vector', 'vmagent'):
            self.client.client_install(kind, HOST, endpoint)
        # A rollback preserves the old generation and retry uses the same key.
        self.client.client_rollback(HOST, endpoint)
        for kind in ('vector', 'vmagent'):
            self.client.client_install(kind, HOST, endpoint)
        self.station.finalize(HOST, payload['certificate_sha256'])
        self.client.client_commit(HOST, endpoint)
        self.assertEqual((self.root / 'client.key').read_bytes(), key)
        self.assertEqual(self.client.client_prepare(HOST, endpoint, self.station.inspect_station(HOST, endpoint))['action'], 'unchanged')

    def test_renewal_keeps_key_and_only_changes_installed_consumer(self):
        first = self.enroll(days=30)
        key = (self.root / 'client.key').read_bytes()
        prepared = self.prepare()
        self.assertEqual(prepared['action'], 'renew')
        self.assertEqual((self.root / '.pending/client.key').read_bytes(), key)
        payload = self.stage(prepared)
        self.assertNotEqual(first['client.crt'], payload['client.crt'])
        self.assertEqual((self.root / 'client.crt').read_text(), first['client.crt'])
        self.install(('vector',))
        self.assertEqual(self.commands, [('stop', 'vector')])
        self.assertEqual((Path(self.client.ETC) / 'vmagent/client.crt').read_text(), first['client.crt'])
        self.commit(payload)
        self.assertEqual((self.root / 'client.key').read_bytes(), key)
        self.assertEqual((self.root / 'client.crt').read_text(), payload['client.crt'])

    def test_signing_failure_retains_working_legacy_credentials(self):
        old_key, old_cert = self.legacy()
        before = snapshot(Path(self.client.ETC) / 'vector')
        prepared = self.prepare()
        self.assertEqual(prepared['action'], 'migrate')
        self.assertNotEqual((self.root / '.pending/client.key').read_bytes(), old_key)
        with patch.object(self.station, 'sign', side_effect=ValueError('fixed test failure')):
            with self.assertRaises(ValueError):
                self.station.stage(self.value, prepared['csr'])
        self.assertEqual(before, snapshot(Path(self.client.ETC) / 'vector'))
        self.assertEqual(self.prepare(), prepared)
        self.assertTrue((Path(self.station.BASE) / 'clients' / HOST / 'client.key').exists())
        self.assertEqual(self.commands, [])
        self.assertEqual(self.client.client_rollback(HOST, ENDPOINT), 'unchanged')

    def test_failed_new_certificate_does_not_replace_working_credentials(self):
        self.legacy()
        before = snapshot(Path(self.client.ETC) / 'vector')
        prepared = self.prepare()
        payload = self.station.stage(self.value, prepared['csr'])
        payload['client.crt'] = payload['ca.crt']
        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
            self.client.client_stage(payload)
        self.assertEqual(before, snapshot(Path(self.client.ETC) / 'vector'))
        self.assertEqual(self.commands, [])

    def test_migration_rollback_retry_finalization_and_noop(self):
        old_key, old_cert = self.legacy()
        prepared = self.prepare()
        payload = self.stage(prepared)
        self.install()
        self.assertEqual(self.station.read_registration(HOST)[1], self.station.fingerprint(old_cert))
        self.assertTrue((Path(self.station.BASE) / 'clients' / HOST / 'client.key').exists())
        self.assertEqual(self.client.client_rollback(HOST, ENDPOINT), 'changed')
        for kind in ('vector', 'vmagent'):
            self.assertEqual((Path(self.client.ETC) / kind / 'client.key').read_bytes(), old_key)
            self.assertTrue(self.active[kind])
            self.assertTrue((Path(self.client.STATE) / (kind + '-restart-required')).exists())
        self.assertEqual(self.prepare(), prepared)
        retry = self.stage(prepared)
        self.assertEqual(retry, payload)
        self.install()
        self.commit(payload)
        self.assertFalse((Path(self.station.BASE) / 'clients' / HOST / 'client.key').exists())
        self.assertNotEqual((self.root / 'client.key').read_bytes(), old_key)
        self.assertEqual(self.prepare()['action'], 'unchanged')

    def test_interrupt_after_station_finalize_reuses_candidate(self):
        self.legacy()
        prepared = self.prepare()
        payload = self.stage(prepared)
        self.install()
        self.station.finalize(HOST, payload['certificate_sha256'])
        self.assertEqual(self.prepare(), prepared)
        station_before = snapshot(Path(self.station.BASE))
        retry = self.stage(prepared)
        self.assertEqual(retry, payload)
        self.assertEqual(station_before, snapshot(Path(self.station.BASE)))
        self.commit(payload)
        self.assertEqual(self.prepare()['action'], 'unchanged')

    def test_interrupted_consumer_publication_recovers_from_exact_backup(self):
        old_key, _ = self.legacy()
        prepared = self.prepare()
        payload = self.stage(prepared)
        real_replace = self.client.client_replace
        count = 0
        def interrupt(*args, **kwargs):
            nonlocal count
            real_replace(*args, **kwargs)
            count += 1
            if count == 1:
                raise RuntimeError('interrupted')
        with patch.object(self.client, 'client_replace', side_effect=interrupt):
            with self.assertRaises(RuntimeError):
                self.client.client_install('vector', HOST, ENDPOINT)
        self.assertEqual((Path(self.client.ETC) / 'vector/client.key').read_bytes(), old_key)
        self.assertEqual(self.client.client_install('vector', HOST, ENDPOINT), 'changed')
        self.install(('vmagent',))
        self.commit(payload)
        self.assertEqual(self.prepare()['action'], 'unchanged')

    def test_interrupted_canonical_commit_recovers(self):
        payload = self.stage()
        prepared = self.prepare()
        self.install()
        self.station.finalize(HOST, payload['certificate_sha256'])
        real_replace = self.client.client_replace
        def interrupt(*args, **kwargs):
            real_replace(*args, **kwargs)
            raise RuntimeError('interrupted')
        with patch.object(self.client, 'client_replace', side_effect=interrupt):
            with self.assertRaises(RuntimeError):
                self.client.client_commit(HOST, ENDPOINT)
        self.assertEqual(self.prepare(), prepared)
        self.assertEqual(self.client.client_commit(HOST, ENDPOINT), 'changed')
        self.assertEqual(self.prepare()['action'], 'unchanged')

    def test_interrupted_backup_cleanup_recovers(self):
        payload = self.stage()
        self.install()
        self.station.finalize(HOST, payload['certificate_sha256'])
        with patch.object(self.client, 'client_clean_completed', side_effect=RuntimeError('interrupted')):
            with self.assertRaises(RuntimeError):
                self.client.client_commit(HOST, ENDPOINT)
        (self.root / '.completed/request.csr').unlink()
        self.assertEqual(self.prepare()['action'], 'unchanged')
        self.assertEqual(self.client.client_commit(HOST, ENDPOINT), "changed")
        self.assertFalse((self.root / '.completed').exists())
        self.client.verify_credentials('vector', HOST, ENDPOINT)

    def test_missing_key_symlink_and_changed_identity_fail_closed(self):
        self.enroll()
        key = (self.root / 'client.key').read_bytes()
        (self.root / 'client.key').unlink()
        recovered = self.prepare()
        self.assertTrue(recovered["recovered_key"])
        self.assertEqual((self.root / "client.key").read_bytes(), key)
        (self.root / "client.key").unlink()
        (self.root / 'client.key').symlink_to(Path(self.client.ETC) / 'vector/client.key')
        with self.assertRaises(OSError):
            self.prepare()
        (self.root / 'client.key').unlink()
        self.client.write(str(self.root / 'client.key'), key, self.client.ROOT, self.client.ROOT)
        with self.assertRaises(ValueError):
            self.client.client_prepare('dt-' + '2' * 32, ENDPOINT, self.station.inspect_station(HOST, ENDPOINT))
        self.assertEqual(self.commands, [])

    def test_disabled_consumer_can_rejoin_after_renewal(self):
        first = self.enroll(days=30)
        self.active['vmagent'] = False
        payload = self.stage()
        self.install(('vector',))
        self.commit(payload)
        self.assertEqual((Path(self.client.ETC) / 'vmagent/client.crt').read_text(), first['client.crt'])
        self.commands.clear()
        self.assertEqual(self.client.client_install('vmagent', HOST, ENDPOINT), 'changed')
        self.client.verify_credentials('vmagent', HOST, ENDPOINT)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.client.client_install('vmagent', HOST, ENDPOINT), 'unchanged')

    def test_disabled_legacy_consumer_can_rejoin_after_migration(self):
        old_key, _ = self.legacy()
        self.active['vmagent'] = False
        payload = self.stage()
        self.install(('vector',))
        self.commit(payload)
        self.assertEqual((Path(self.client.ETC) / 'vmagent/client.key').read_bytes(), old_key)
        self.assertEqual(self.client.client_install('vmagent', HOST, ENDPOINT), 'changed')
        self.assertNotEqual((Path(self.client.ETC) / 'vmagent/client.key').read_bytes(), old_key)
        self.client.verify_credentials('vmagent', HOST, ENDPOINT)

    def test_expired_managed_identity_renews_but_verify_rejects(self):
        self.enroll()
        key = (self.root / 'client.key').read_bytes()
        csr = self.client.run('req', '-new', '-key', str(self.root / 'client.key'), '-subj', '/CN=' + HOST,
                              '-addext', 'subjectAltName=URI:dragontools://hosts/' + HOST).decode()
        expired = self.sign(csr, days=0)
        identity = json.loads((self.root / 'identity.json').read_bytes())
        self.client.client_replace(str(self.root / 'client.crt'), expired, self.client.ROOT, self.client.ROOT)
        self.client.client_replace(str(self.root / 'identity.json'), self.client.client_identity(HOST, ENDPOINT, expired, identity['previous_consumers']), self.client.ROOT, self.client.ROOT)
        for kind in ('vector', 'vmagent'):
            self.client.client_replace(str(Path(self.client.ETC) / kind / 'client.crt'), expired, self.client.ROOT, self.client.ROOT)
        self.station._save_registry(HOST, dict(self.value, certificate_sha256=self.station.fingerprint(expired),
                                               certificate_pem=expired.decode(), certificate_identity=self.station.identity(HOST)))
        with self.assertRaises(subprocess.CalledProcessError):
            self.client.verify_credentials('vector', HOST, ENDPOINT)
        self.assertEqual(self.prepare()['action'], 'renew')
        payload = self.stage()
        self.install()
        self.commit(payload)
        self.assertEqual((self.root / 'client.key').read_bytes(), key)
        self.client.verify_credentials('vector', HOST, ENDPOINT)

    def test_expired_legacy_identity_migrates_retaining_old_until_commit(self):
        old_key, _ = self.legacy(days=0)
        inspection = self.station.inspect_station(HOST, ENDPOINT)
        self.assertTrue(inspection['legacy_expired'])
        prepared = self.prepare()
        self.assertEqual(prepared['action'], 'migrate')
        payload = self.stage(prepared)
        self.install()
        self.assertTrue((Path(self.station.BASE) / 'clients' / HOST / 'client.key').exists())
        self.commit(payload)
        self.assertNotEqual((self.root / 'client.key').read_bytes(), old_key)
        self.assertFalse((Path(self.station.BASE) / 'clients' / HOST / 'client.key').exists())

    def test_missing_all_matching_local_keys_reenrolls_with_fresh_local_key(self):
        self.enroll()
        old_key = (self.root / "client.key").read_bytes()
        old_cert = (self.root / "client.crt").read_bytes()
        for path in (self.root / 'client.key', Path(self.client.ETC) / 'vector/client.key', Path(self.client.ETC) / 'vmagent/client.key'):
            path.unlink()
        prepared = self.prepare()
        self.assertEqual(prepared["action"], "reenroll")
        self.assertNotEqual((self.root / ".pending/client.key").read_bytes(), old_key)
        self.assertEqual((self.root / "client.crt").read_bytes(), old_cert)
        self.assertEqual(self.commands, [])
        payload = self.stage(prepared)
        self.install()
        self.commit(payload)
        self.client.verify_credentials("vector", HOST, ENDPOINT)
        self.assertEqual(self.prepare()["action"], "unchanged")

    def test_interrupted_signed_publication_recovers_without_partial_files(self):
        prepared = self.prepare()
        payload = self.station.stage(self.value, prepared['csr'])
        real_replace = self.client.client_replace
        count = 0
        def interrupt(*args, **kwargs):
            nonlocal count
            real_replace(*args, **kwargs)
            count += 1
            if count == 1:
                raise RuntimeError('interrupted after atomic CA publication')
        with patch.object(self.client, 'client_replace', side_effect=interrupt):
            with self.assertRaises(RuntimeError):
                self.client.client_stage(payload)
        self.assertFalse((self.root / '.pending/client.crt').exists())
        self.assertEqual(self.prepare(), prepared)
        self.assertEqual(self.client.client_stage(payload), 'changed')
        self.install()
        self.commit(payload)

    def pending_reissue(self, expired, interrupt):
        self.legacy()
        prepared = self.prepare()
        payload = self.stage(prepared, days=20 if not expired else 365)
        self.install(('vector',))
        key = (self.root / '.pending/client.key').read_bytes()
        if expired:
            expired_cert = self.sign(prepared['csr'], days=0)
            metadata = json.loads((self.root / '.pending/identity.json').read_bytes())
            self.client.client_replace(str(self.root / '.pending/client.crt'), expired_cert, self.client.ROOT, self.client.ROOT)
            self.client.client_replace(str(self.root / '.pending/identity.json'), self.client.client_identity(HOST, ENDPOINT, expired_cert, metadata['previous_consumers']), self.client.ROOT, self.client.ROOT)
            self.client.client_replace(str(Path(self.client.ETC) / 'vector/client.crt'), expired_cert, self.client.ROOT, self.client.ROOT)
            registry = self.station._registry(HOST)
            registry.update(pending_certificate_pem=expired_cert.decode(), pending_certificate_sha256=self.station.fingerprint(expired_cert))
            self.station._save_registry(HOST, registry)
        self.assertEqual(self.prepare(), prepared)
        fresh = self.station.stage(self.value, prepared['csr'])
        self.assertNotEqual(fresh['client.crt'], payload['client.crt'])
        if interrupt:
            real_replace = self.client.client_replace
            def interrupted(path, *args, **kwargs):
                real_replace(path, *args, **kwargs)
                if path.endswith('.reissues.json'):
                    raise RuntimeError('interrupted after journal before certificate')
            with patch.object(self.client, 'client_replace', side_effect=interrupted):
                with self.assertRaises(RuntimeError):
                    self.client.client_stage(fresh)
            self.assertEqual(self.prepare(), prepared)
        self.client.client_stage(fresh)
        self.install()
        self.commit(fresh)
        self.assertEqual((self.root / 'client.key').read_bytes(), key)
        self.assertEqual(self.prepare()['action'], 'unchanged')

    def test_near_expiry_pending_reissues_same_key(self):
        self.pending_reissue(expired=False, interrupt=False)

    def test_expired_pending_reissue_journal_recovers(self):
        self.pending_reissue(expired=True, interrupt=True)

    def test_missing_canonical_key_recovers_from_same_key_historical_consumer(self):
        self.enroll(days=30)
        key = (self.root / 'client.key').read_bytes()
        self.active['vmagent'] = False
        payload = self.stage()
        self.install(('vector',))
        self.commit(payload)
        (self.root / 'client.key').unlink()
        (Path(self.client.ETC) / 'vector/client.key').unlink()
        prepared = self.prepare()
        self.assertEqual(prepared['action'], 'unchanged')
        self.assertTrue(prepared['recovered_key'])
        self.assertEqual((self.root / 'client.key').read_bytes(), key)
        self.assertEqual(self.client.client_install('vector', HOST, ENDPOINT), 'changed')
        self.client.verify_credentials('vector', HOST, ENDPOINT)

    def test_reenrollment_accepts_proven_historical_disabled_consumer(self):
        self.legacy()
        self.active['vmagent'] = False
        payload = self.stage()
        self.install(('vector',))
        self.commit(payload)
        key = (self.root / 'client.key').read_bytes()
        (self.root / 'client.key').unlink()
        (Path(self.client.ETC) / 'vector/client.key').unlink()
        prepared = self.prepare()
        self.assertEqual(prepared['action'], 'reenroll')
        self.assertNotEqual((self.root / '.pending/client.key').read_bytes(), key)
        payload = self.stage(prepared)
        self.install()
        self.commit(payload)
        self.assertEqual(self.prepare()['action'], 'unchanged')

    def test_oversized_public_response_and_key_in_response_refused(self):
        prepared = self.prepare()
        payload = self.station.stage(self.value, prepared['csr'])
        with self.assertRaises(ValueError):
            self.client.client_stage(dict(payload, **{'client.key': 'PRIVATE KEY'}))
        with self.assertRaises(ValueError):
            self.client.client_stage(dict(payload, **{'client.crt': 'x' * 16385}))
        self.assertFalse((self.root / '.pending/client.crt').exists())
        self.assertEqual(self.commands, [])


if __name__ == '__main__':
    suite = (unittest.defaultTestLoader.loadTestsFromNames(['__main__.ClientLifecycle.' + name for name in sys.argv[1:]])
             if len(sys.argv) > 1 else unittest.defaultTestLoader.loadTestsFromTestCase(ClientLifecycle))
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=1).run(suite)
    sys.exit(not result.wasSuccessful())
