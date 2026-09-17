"""Real OpenSSL station signing/renewal fixtures; no SSH or service deployment."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("station_pki", REPO / "src/monitoring/agents/pki.py")
pki = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pki)
HOST = "dt-0123456789abcdef0123456789abcdef"
OTHER = "dt-fedcba9876543210fedcba9876543210"


class StationPKI(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        old_umask = os.umask(0o022)
        self.addCleanup(os.umask, old_umask)
        root = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="dragontools-station-pki-")))
        self.base, self.app, self.state = root / "station", root / "app", root / "state"
        for path in (self.base, self.app, self.state):
            path.mkdir(mode=0o755)
        uid, gid = os.getuid(), os.getgid()
        account = types.SimpleNamespace(pw_uid=uid, pw_gid=gid)
        original_read, original_directory = pki.read, pki.directory
        original_chown, original_fchown = os.chown, os.fchown
        self.stack.enter_context(patch.object(pki, "ROOT", uid))
        self.stack.enter_context(patch.object(pki, "BASE", str(self.base)))
        self.stack.enter_context(patch.object(pki, "STATE", str(self.state)))
        self.stack.enter_context(patch.object(pki.pwd, "getpwnam", return_value=account))
        self.stack.enter_context(patch.object(pki, "read", side_effect=lambda path, u, g, *a: original_read(path, u, gid if g == uid else g, *a)))
        self.stack.enter_context(patch.object(pki, "directory", side_effect=lambda path, mode, u, g, *a: original_directory(path, mode, u, gid if g == uid else g, *a)))
        self.stack.enter_context(patch.object(os, "chown", side_effect=lambda path, u, g: original_chown(path, u, gid if g == uid else g)))
        self.stack.enter_context(patch.object(os, "fchown", side_effect=lambda fd, u, g: original_fchown(fd, u, gid if g == uid else g)))
        self.value = dict(version=1, host=HOST, station="localhost", services=["one.service"], metrics_targets=[])
        self.assertEqual(pki.ensure(self.value), "changed")
        self.key = self.app / "client.key"
        self.key.write_bytes(pki.run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"))
        self.key.chmod(0o400)

    def csr(self, host=HOST, san=None, extensions=(), key=None):
        args = ["req", "-new", "-key", str(key or self.key), "-subj", "/CN=" + host,
                "-addext", "subjectAltName=URI:" + (san or pki.identity(host))]
        for extension in extensions:
            args += ["-addext", extension]
        return pki.run(*args).decode()

    def snapshot(self):
        return {str(path.relative_to(self.base)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.base.rglob("*") if path.is_file()}

    def record(self):
        return json.loads((self.base / "registry" / (HOST + ".json")).read_text())

    def save_record(self, value):
        pki._save_registry(HOST, value)

    def enroll(self):
        public = pki.stage(self.value, self.csr())
        self.assertEqual(pki.finalize(HOST, public["certificate_sha256"]), "changed")
        return public

    def issue_days(self, csr, days):
        original = pki.run
        def run(*args, **kwargs):
            args = list(args)
            if args[0] == "x509" and "-req" in args:
                args[args.index("-days") + 1] = str(days)
            return original(*args, **kwargs)
        with patch.object(pki, "run", side_effect=run):
            return pki.sign(csr, HOST, str(self.base / "pki/ca"))

    def test_valid_csr_locality_and_forced_extensions(self):
        public = pki.stage(self.value, self.csr())
        self.assertEqual(set(public), {"host", "station", "ca.crt", "client.crt", "certificate_sha256"})
        cert = self.app / "client.crt"
        cert.write_text(public["client.crt"])
        pki.validate_client_certificate(str(cert), HOST, str(self.base / "pki/ca/ca.crt"))
        self.assertEqual(pki.run("pkey", "-in", str(self.key), "-pubout"), pki.run("x509", "-in", str(cert), "-pubkey", "-noout"))
        self.assertFalse(any(path.name == "client.key" for path in self.base.rglob("*")))
        self.assertNotIn("PRIVATE KEY", json.dumps(public))
        self.assertTrue(all(b"PRIVATE KEY" not in data for path, (data, _) in self.snapshot().items() if path not in ("pki/ca/ca.key", "server/server.key")))
        with self.assertRaises(ValueError):
            pki.generate(str(self.base / "pki/ca"), "client", HOST)

    def test_malformed_oversized_and_bad_signature_csr_leave_registry_unchanged(self):
        self.enroll()
        before = self.snapshot()
        csr = self.csr()
        der = bytearray(pki.base64.b64decode("".join(csr.splitlines()[1:-1])))
        der[-1] ^= 1
        bad_signature = "-----BEGIN CERTIFICATE REQUEST-----\n" + pki.base64.b64encode(der).decode() + "\n-----END CERTIFICATE REQUEST-----\n"
        for invalid in ("PRIVATE KEY sentinel", "A" * 8193, csr + "trailer", bad_signature):
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                pki.stage(self.value, invalid)
            self.assertEqual(before, self.snapshot())

    def test_wrong_cn_san_extra_san_and_privilege_extensions_refused(self):
        for invalid in (self.csr(OTHER), self.csr(san=pki.identity(OTHER)),
                        self.csr(san=pki.identity(HOST) + ",DNS:localhost"),
                        self.csr(extensions=("extendedKeyUsage=serverAuth",)),
                        self.csr(extensions=("basicConstraints=critical,CA:TRUE",)),
                        self.csr(extensions=("1.2.3.4=ASN1:UTF8String:unexpected",))):
            with self.assertRaises(ValueError):
                pki.stage(self.value, invalid)
        self.assertEqual([], list((self.base / "registry").iterdir()))

    def test_rsa_and_wrong_curve_refused(self):
        for args in (("-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"),
                     ("-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384")):
            key = self.app / "other.key"
            key.write_bytes(pki.run("genpkey", *args))
            with self.assertRaises(ValueError):
                pki.stage(self.value, self.csr(key=key))

    def test_valid_lifetime_rerun_is_exact_noop(self):
        public = self.enroll()
        before = self.snapshot()
        with patch.object(pki, "sign", side_effect=AssertionError("Do not resign valid identity")):
            self.assertEqual(pki.ensure(self.value), "unchanged")
            self.assertEqual(pki.stage_registration(self.value), "unchanged")
            self.assertEqual(pki.finalize(HOST, public["certificate_sha256"]), "unchanged")
            pki.verify_station(self.value)
        self.assertEqual(before, self.snapshot())

    def test_interrupted_signing_and_finalization_reuse_same_certificate(self):
        public = pki.stage(self.value, self.csr())
        before = self.snapshot()
        with patch.object(pki, "sign", side_effect=AssertionError("Rerun must reuse certificate")):
            self.assertEqual(pki.stage(self.value, self.csr()), public)
            self.assertEqual(before, self.snapshot())
            pki.finalize(HOST, public["certificate_sha256"])
            finalized = self.snapshot()
            self.assertEqual(pki.stage(self.value, self.csr()), public)
            self.assertEqual(finalized, self.snapshot())

    def test_near_expiry_interrupted_candidate_is_renewed_with_same_key(self):
        csr = self.csr()
        cert = self.issue_days(csr, 20)
        self.save_record(dict(self.value, certificate_sha256=None, pending_certificate_pem=cert.decode(),
                              pending_certificate_sha256=pki.fingerprint(cert), pending_registration=self.value,
                              pending_expires_at=int(time.time()) + 86400))
        public = pki.stage(self.value, csr)
        self.assertNotEqual(public["client.crt"], cert.decode())
        self.assertEqual(pki.run("x509", "-pubkey", "-noout", data=cert), pki.run("x509", "-pubkey", "-noout", data=public["client.crt"].encode()))
        pki.finalize(HOST, public["certificate_sha256"])
        self.assertEqual(pki.stage_registration(self.value), "unchanged")

    def test_client_renewal_same_public_key_and_old_active_until_finalize(self):
        csr = self.csr()
        cert = self.issue_days(csr, 20)
        self.save_record(dict(self.value, certificate_sha256=pki.fingerprint(cert), certificate_identity=pki.identity(HOST), certificate_pem=cert.decode()))
        old_key = self.key.read_bytes()
        old = self.record()
        public = pki.stage(self.value, csr)
        during = self.record()
        self.assertEqual(during["certificate_sha256"], old["certificate_sha256"])
        self.assertEqual(during["certificate_pem"], old["certificate_pem"])
        self.assertNotEqual(public["certificate_sha256"], old["certificate_sha256"])
        self.assertEqual(self.key.read_bytes(), old_key)
        self.assertEqual(pki.run("x509", "-pubkey", "-noout", data=cert), pki.run("x509", "-pubkey", "-noout", data=public["client.crt"].encode()))
        pki.finalize(HOST, public["certificate_sha256"])
        self.assertEqual(pki.stage_registration(self.value), "unchanged")

    def test_sign_failure_preserves_active_registration(self):
        self.enroll()
        before = self.snapshot()
        self.key.chmod(0o600)
        self.key.write_bytes(pki.run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"))
        self.key.chmod(0o400)
        csr = self.csr()
        with patch.object(pki, "sign", side_effect=ValueError("fixed failure")), self.assertRaises(ValueError):
            pki.stage(self.value, csr)
        self.assertEqual(before, self.snapshot())

    def legacy(self, days=365):
        legacy_key = self.app / "legacy.key"
        legacy_key.write_bytes(pki.run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"))
        extensions = self.app / "legacy.extensions"
        extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n")
        csr = pki.run("req", "-new", "-key", str(legacy_key), "-subj", "/CN=" + HOST)
        cert = pki.run("x509", "-req", "-CA", str(self.base / "pki/ca/ca.crt"), "-CAkey", str(self.base / "pki/ca/ca.key"),
                       "-set_serial", "0x" + os.urandom(16).hex(), "-days", str(days), "-sha256", "-extfile", str(extensions), data=csr)
        pki.create_bundle(str(self.base / "clients" / HOST), pki.ROOT, pki.ROOT,
                          {"client.crt": cert, "client.key": legacy_key.read_bytes()})
        self.save_record(dict(self.value, certificate_sha256=pki.fingerprint(cert)))
        return self.base / "clients" / HOST / "client.key"

    def test_legacy_key_deleted_only_after_successful_finalize(self):
        key = self.legacy()
        original = key.read_bytes()
        self.assertTrue(pki.inspect_station(HOST, "localhost")["legacy"])
        public = pki.stage(self.value, self.csr())
        self.assertEqual(key.read_bytes(), original)
        with self.assertRaises(ValueError):
            pki.finalize(HOST, "0" * 64)
        self.assertEqual(key.read_bytes(), original)
        pki.finalize(HOST, public["certificate_sha256"])
        self.assertFalse(key.exists())
        self.assertFalse(pki.inspect_station(HOST, "localhost")["legacy"])
        pki.verify_station(self.value)
        self.assertEqual(pki.finalize(HOST, public["certificate_sha256"]), "unchanged")

    def test_expired_legacy_inspection_reports_expiry_without_accepting_it_as_healthy(self):
        key = self.legacy(days=0)
        before = self.snapshot()
        inspected = pki.inspect_station(HOST, "localhost")
        self.assertTrue(inspected["legacy"])
        self.assertTrue(inspected["legacy_expired"])
        self.assertTrue(inspected["legacy_active"])
        self.assertEqual(before, self.snapshot())
        with self.assertRaises(ValueError):
            pki.verify_station(self.value)
        public = pki.stage(self.value, self.csr())
        self.assertTrue(key.exists())
        pki.finalize(HOST, public["certificate_sha256"])
        self.assertFalse(key.exists())
        self.assertFalse(pki.inspect_station(HOST, "localhost")["legacy_expired"])

    def test_modern_expired_identity_with_legacy_key_does_not_require_legacy_handshake(self):
        key = self.legacy()
        expired = self.issue_days(self.csr(), 0)
        self.save_record(dict(self.value, certificate_sha256=pki.fingerprint(expired), certificate_identity=pki.identity(HOST), certificate_pem=expired.decode()))
        inspected = pki.inspect_station(HOST, "localhost")
        self.assertTrue(inspected["legacy"])
        self.assertFalse(inspected["legacy_active"])
        self.assertFalse(inspected["legacy_expired"])
        public = pki.stage(self.value, self.csr())
        self.assertTrue(key.exists())
        self.assertNotEqual(public["certificate_sha256"], pki.fingerprint(expired))
        pki.finalize(HOST, public["certificate_sha256"])
        self.assertFalse(key.exists())

    def test_interrupted_legacy_unlink_is_recoverable(self):
        key = self.legacy()
        public = pki.stage(self.value, self.csr())
        original = os.unlink
        def unlink(path, *args, **kwargs):
            if str(path) == str(key):
                raise OSError("simulated interruption")
            return original(path, *args, **kwargs)
        with patch.object(os, "unlink", side_effect=unlink), self.assertRaises(OSError):
            pki.finalize(HOST, public["certificate_sha256"])
        self.assertEqual(self.record()["certificate_sha256"], public["certificate_sha256"])
        self.assertTrue(key.exists())
        self.assertEqual(pki.finalize(HOST, public["certificate_sha256"]), "changed")
        self.assertFalse(key.exists())

    def test_pending_authorization_expires_without_committing(self):
        self.enroll()
        desired = dict(self.value, services=["one.service", "two.service"])
        previous = self.record()
        self.assertEqual(pki.stage_registration(desired), "changed")
        current = self.record()
        self.assertEqual(current["services"], previous["services"])
        self.assertEqual(current["pending_registration"], desired)
        with patch.object(time, "time", return_value=current["pending_expires_at"] + 1), self.assertRaises(ValueError):
            pki.finalize(HOST, current["certificate_sha256"])
        self.assertEqual(self.record(), current)
        self.assertEqual(pki.finalize(HOST, current["certificate_sha256"]), "changed")
        pki.verify_station(desired)

    def test_server_renewal_same_key_and_only_ingestion_intent(self):
        ca = self.base / "pki/ca"
        key = (self.base / "server/server.key").read_bytes()
        original = pki.run
        def run(*args, **kwargs):
            args = list(args)
            if args[0] == "x509" and "-req" in args:
                args[args.index("-days") + 1] = "20"
            return original(*args, **kwargs)
        with patch.object(pki, "run", side_effect=run):
            near = pki.generate(str(ca), "server", "localhost", "localhost", key)
        cert = self.base / "server/server.crt"
        cert.chmod(0o600)
        cert.write_bytes(near["server.crt"])
        cert.chmod(0o400)
        marker = self.state / "ingestion-restart-required"
        marker.unlink()
        ca_before = (ca / "ca.key").read_bytes(), (ca / "ca.crt").read_bytes()
        self.assertEqual(pki.ensure(self.value), "changed")
        self.assertEqual((self.base / "server/server.key").read_bytes(), key)
        self.assertNotEqual(cert.read_bytes(), near["server.crt"])
        self.assertEqual(ca_before, ((ca / "ca.key").read_bytes(), (ca / "ca.crt").read_bytes()))
        self.assertEqual([x.name for x in self.state.iterdir()], ["ingestion-restart-required"])
        self.assertEqual(pki.ensure(self.value), "unchanged")

    def test_hostname_change_adds_dns_san_retains_keys_old_names_and_noop(self):
        ca = self.base / "pki/ca"
        server = self.base / "server"
        before = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in (ca / "ca.key", ca / "ca.crt", server / "server.key", server / "endpoint")}
        cert = (server / "server.crt").read_bytes()
        changed = dict(self.value, station="monitoring.baptizeddragon.com")
        self.assertEqual(pki.ensure(changed), "changed")
        self.assertNotEqual((server / "server.crt").read_bytes(), cert)
        self.assertIn("DNS:monitoring.baptizeddragon.com", pki._extension(str(server / "server.crt"), "subjectAltName"))
        pki._station(changed["station"])
        pki._station(self.value["station"])
        self.assertEqual(before, {name: (Path(name).read_bytes(), Path(name).stat().st_mtime_ns) for name in before})
        snapshot = self.snapshot()
        self.assertEqual(pki.ensure(changed), "unchanged")
        self.assertEqual(pki.ensure(self.value), "unchanged")
        self.assertEqual(snapshot, self.snapshot())

    def test_hostname_reissue_failure_preserves_working_server_certificate(self):
        before = self.snapshot()
        with patch.object(pki, "generate", side_effect=ValueError("fixture signing failure")):
            with self.assertRaises(ValueError):
                pki.ensure(dict(self.value, station="new.example"))
        self.assertEqual(before, self.snapshot())
        pki._station(self.value["station"])

    def test_hostname_publication_interruption_retains_intent_and_does_not_reissue(self):
        changed = dict(self.value, station="next.example")
        original = pki._atomic
        def interrupted(*args, **kwargs):
            result = original(*args, **kwargs)
            if args[0].endswith('/server.crt'):
                raise OSError('fixture interruption after publication')
            return result
        with patch.object(pki, '_atomic', side_effect=interrupted):
            with self.assertRaises(OSError):
                pki.ensure(changed)
        self.assertTrue((self.state / 'ingestion-restart-required').exists())
        before = self.snapshot()
        with patch.object(pki, 'generate', side_effect=AssertionError('unexpected reissue')):
            self.assertEqual(pki.ensure(changed), 'unchanged')
        self.assertEqual(before, self.snapshot())
        pki._station(changed['station'])

    def test_missing_ca_on_existing_station_never_creates_replacement(self):
        ca = self.base / "pki/ca"
        os.rename(ca, self.base / "saved-ca")
        before = self.snapshot()
        with self.assertRaises(pki.CAMaintenanceRequired):
            pki.ensure(self.value)
        self.assertFalse(ca.exists())
        self.assertEqual(before, self.snapshot())

    def test_interrupted_server_publication_orphan_does_not_block_bundle(self):
        # Reproduce SIGKILL after the public temporary file is durable: unlike a
        # Python exception, real termination cannot execute _atomic's finally.
        orphan = self.base / ".public-interrupted"
        pki.write(str(orphan), (self.base / "server/server.crt").read_bytes(), pki.ROOT, pki.ROOT)
        before = self.snapshot()
        self.assertEqual(pki.ensure(self.value), "unchanged")
        self.assertEqual(before, self.snapshot())
        created = []
        original = pki.tempfile.mkstemp
        def mkstemp(*args, **kwargs):
            created.append(kwargs["dir"])
            return original(*args, **kwargs)
        with patch.object(pki.tempfile, "mkstemp", side_effect=mkstemp):
            pki._atomic(str(self.base / "server/server.crt"), b"public staging fixture", pki.ROOT, os.getgid(), 0o400, str(self.base))
        self.assertEqual(created, [str(self.base)])

    def test_ca_near_expiry_requires_maintenance_without_rotation(self):
        ca = self.base / "pki/ca"
        cert = pki.run("req", "-new", "-x509", "-key", str(ca / "ca.key"), "-sha256", "-days", "300",
                       "-subj", "/CN=DragonTools agent CA", "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                       "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        (ca / "ca.crt").chmod(0o600)
        (ca / "ca.crt").write_bytes(cert)
        (ca / "ca.crt").chmod(0o400)
        before = self.snapshot()
        with self.assertRaises(pki.CAMaintenanceRequired):
            pki.ensure(self.value)
        self.assertEqual(before, self.snapshot())

    def test_ca_key_unsafe_mode_symlink_and_unverified_endpoint_refused(self):
        key = self.base / "pki/ca/ca.key"
        key.chmod(0o440)
        with self.assertRaises(ValueError):
            pki.ensure(self.value)
        key.chmod(0o400)
        original = key.read_bytes()
        key.unlink()
        key.symlink_to(self.app / "client.key")
        with self.assertRaises(OSError):
            pki.ensure(self.value)
        key.unlink()
        key.write_bytes(original)
        key.chmod(0o400)
        with self.assertRaises(ValueError):
            pki._station("wrong.example")

    def test_entrypoint_errors_have_no_raw_diagnostics(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(pki.sys, "argv", ["pki", "stage", HOST, "localhost", json.dumps(self.value), "PRIVATE KEY sentinel"]), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(pki.main(), 86)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=1).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    sys.exit(0 if result.wasSuccessful() else 1)
