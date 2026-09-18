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

    def ca_certificate(self, basic="basicConstraints=critical,CA:TRUE,pathlen:0", usage="keyUsage=critical,keyCertSign,cRLSign", days=3650):
        key = str(self.base / "pki/ca/ca.key")
        csr = pki.run("req", "-new", "-key", key, "-subj", "/CN=DragonTools agent CA")
        extensions = self.app / "ca-extensions"
        extensions.write_text("\n".join(value for value in (basic, usage) if value) + "\n")
        return pki.run("x509", "-req", "-signkey", key, "-days", str(days), "-sha256",
                       "-extfile", str(extensions), data=csr)

    def replace_ca(self, name, data):
        path = self.base / "pki/ca" / name
        path.chmod(0o600)
        path.write_bytes(data)
        path.chmod(0o400)

    def assert_ca_refused(self):
        before = self.snapshot()
        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
            pki._validate_ca()
        self.assertEqual(before, self.snapshot())

    @contextlib.contextmanager
    def empty_station(self, registry_mode=None):
        with tempfile.TemporaryDirectory(dir=self.app) as temporary:
            base, state = Path(temporary) / "ingestion", Path(temporary) / "state"
            for path in (base, state):
                path.mkdir(mode=0o755)
                path.chmod(0o755)
            with patch.object(pki, "BASE", str(base)), patch.object(pki, "STATE", str(state)), patch.object(self, "base", base):
                if registry_mode is not None:
                    pki.directory(str(base / "pki"), 0o700, pki.ROOT, pki.ROOT, True)
                    pki.directory(str(base / "clients"), 0o700, pki.ROOT, pki.ROOT, True)
                    pki.directory(str(base / "registry"), registry_mode, pki.ROOT, os.getgid(), True)
                yield base

    def ensure_entrypoint(self, expected):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(pki.sys, "argv", ["pki", "ensure", HOST, "localhost", json.dumps(self.value)]), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = pki.main()
        self.assertEqual(result, expected)
        self.assertEqual(stdout.getvalue(), "changed" if expected == 0 else "")
        self.assertEqual(stderr.getvalue(), "")

    def test_bootstrap_under_private_umask_from_absent_or_empty_parents_and_rerun(self):
        # Include the exact failed production layout, including the registry's
        # mode after mkdir(0750) under the entrypoint's umask 077.
        for registry_mode in (None, 0o750, 0o700):
            with self.subTest(registry_mode=registry_mode), self.empty_station(registry_mode) as base:
                if registry_mode is not None:
                    self.assertEqual(set(path.name for path in base.iterdir()), {"pki", "clients", "registry"})
                    self.assertTrue(all(not list(path.iterdir()) for path in base.iterdir()))
                self.ensure_entrypoint(0)
                self.assertEqual((base / "registry").stat().st_mode & 0o777, 0o750)
                self.assertTrue((base / "pki/ca/ca.key").is_file())
                self.assertTrue((base / "server/server.key").is_file())
                self.assertFalse(list(base.rglob("client.key")))
                pki._station("localhost")
                before = self.snapshot()
                with patch.object(pki, "generate", side_effect=AssertionError("No silent rotation on rerun")):
                    self.assertEqual(pki.ensure(self.value), "unchanged")
                self.assertEqual(before, self.snapshot())

    def test_new_ca_validation_failure_leaves_empty_parents_and_retry_bootstraps(self):
        with self.empty_station(0o750) as base:
            original = pki.run
            attempts = []
            def fail_verification(*args, **kwargs):
                if args[0] == "verify":
                    attempts.append(((base / "pki/ca").exists(), Path(args[2]).parent.parent))
                    raise subprocess.CalledProcessError(2, ["openssl", *args], stderr=b"PRIVATE KEY sentinel")
                return original(*args, **kwargs)
            with patch.object(pki, "run", side_effect=fail_verification):
                self.ensure_entrypoint(86)
            self.assertEqual(attempts, [(False, base / "pki")])
            self.assertEqual(set(path.name for path in base.iterdir()), {"pki", "clients", "registry"})
            self.assertTrue(all(not list(path.iterdir()) for path in base.iterdir()))
            self.ensure_entrypoint(0)
            pki._station("localhost")
            before = self.snapshot()
            self.assertEqual(pki.ensure(self.value), "unchanged")
            self.assertEqual(before, self.snapshot())

    def test_registry_migration_preserves_populated_station_and_correct_mode_is_noop(self):
        self.enroll()
        registry = self.base / "registry"
        (registry / "manual-sentinel").write_bytes(b"preserve")
        registry.chmod(0o700)
        before = self.snapshot()
        self.ensure_entrypoint(0)
        self.assertEqual(registry.stat().st_mode & 0o777, 0o750)
        self.assertEqual(before, self.snapshot())
        pki.verify_station(self.value)
        metadata = registry.stat()
        with patch.object(pki.os, "fchmod", side_effect=AssertionError("Correct registry mode must be a no-op")):
            self.assertFalse(pki.registry_directory(reconcile=True))
            self.assertEqual(pki.ensure(self.value), "unchanged")
        self.assertEqual(before, self.snapshot())
        self.assertEqual(metadata, registry.stat())

    def test_registry_verification_is_readonly_and_reports_permissions_without_output(self):
        self.enroll()
        registry = self.base / "registry"
        registry.chmod(0o700)
        before = self.snapshot()
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(pki.sys, "argv", ["pki", "verify", HOST, "localhost", json.dumps(self.value)]), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(pki.main(), 89)
        self.assertEqual((stdout.getvalue(), stderr.getvalue()), ("", ""))
        self.assertEqual(registry.stat().st_mode & 0o777, 0o700)
        self.assertEqual(before, self.snapshot())

    def test_registry_rejects_wrong_owner_and_group_without_repair(self):
        registry = self.base / "registry"
        registry.chmod(0o700)
        original = os.fstat
        expected = registry.stat()
        for field in ("st_uid", "st_gid"):
            def fstat(fd):
                st = original(fd)
                if (st.st_dev, st.st_ino) == (expected.st_dev, expected.st_ino):
                    values = dict(st_mode=st.st_mode, st_uid=st.st_uid, st_gid=st.st_gid)
                    values[field] += 1
                    return types.SimpleNamespace(**values)
                return st
            with self.subTest(field=field), patch.object(os, "fstat", side_effect=fstat), patch.object(os, "fchmod", side_effect=AssertionError("Never repair foreign ownership")):
                self.ensure_entrypoint(89)
            self.assertEqual(registry.stat(), expected)

    def test_registry_rejects_symlinks_files_and_fifo_without_touching_destination(self):
        for kind in ("symlink", "file", "fifo"):
            with self.subTest(kind=kind), self.empty_station() as base:
                outside = base.parent / "outside"
                outside.mkdir(mode=0o700)
                (outside / "sentinel").write_bytes(b"preserve")
                metadata = outside.stat()
                registry = base / "registry"
                if kind == "symlink":
                    registry.symlink_to(outside, target_is_directory=True)
                elif kind == "file":
                    registry.write_bytes(b"preserve")
                else:
                    os.mkfifo(registry)
                self.ensure_entrypoint(89)
                self.assertEqual(outside.stat(), metadata)
                self.assertEqual((outside / "sentinel").read_bytes(), b"preserve")
                self.assertEqual(set(path.name for path in base.iterdir()), {"registry"})
                if kind == "file":
                    self.assertEqual(registry.read_bytes(), b"preserve")

    def test_registry_refuses_symlinked_owned_tree_escape(self):
        with self.empty_station() as base:
            alias = self.app / "tree-alias"
            alias.symlink_to(base.parent, target_is_directory=True)
            with patch.object(pki, "BASE", str(alias / base.name)):
                self.ensure_entrypoint(89)
            self.assertEqual(list(base.iterdir()), [])

    def test_existing_invalid_ca_is_preserved_without_rotation(self):
        self.replace_ca("ca.key", self.key.read_bytes())
        before = self.snapshot()
        with patch.object(pki, "generate", side_effect=AssertionError("Never rotate an existing CA")):
            self.ensure_entrypoint(86)
        self.assertEqual(before, self.snapshot())

    def test_ca_valid_extensions_der_key_matching_and_explicit_self_signature(self):
        for encoding in ("pkey", "ec"):
            with self.subTest(encoding=encoding):
                self.replace_ca("ca.crt", self.ca_certificate())
                # EC and PKCS#8 private key PEM encodings must normalize to the
                # same SubjectPublicKeyInfo DER as the certificate public key.
                key = str(self.base / "pki/ca/ca.key")
                self.replace_ca("ca.key", pki.run(encoding, "-in", key, "-outform", "PEM"))
                before = self.snapshot()
                with patch.object(pki, "run", wraps=pki.run) as run:
                    values = pki._validate_ca()
                self.assertEqual(values["ca.crt"], (self.base / "pki/ca/ca.crt").read_bytes())
                run.assert_any_call("pkey", "-in", key, "-pubout", "-outform", "DER")
                cert = str(self.base / "pki/ca/ca.crt")
                self.assertEqual(run.call_args.args, ("verify", "-CAfile", cert, "-purpose", "any", "-check_ss_sig", cert))
                self.assertEqual(before, self.snapshot())

    def test_ca_non_ca_missing_and_malformed_basic_constraints_refused_before_verify(self):
        for basic in ("basicConstraints=critical,CA:FALSE", None, "2.5.29.19=critical,DER:01:01:FF",
                      "basicConstraints=critical,CA:TRUE", "basicConstraints=critical,CA:TRUE,pathlen:1"):
            with self.subTest(basic=basic):
                self.replace_ca("ca.crt", self.ca_certificate(basic=basic))
                with patch.object(pki, "run", wraps=pki.run) as run:
                    self.assert_ca_refused()
                self.assertFalse(any(call.args[0] == "verify" for call in run.call_args_list))

    def test_ca_missing_signing_usage_and_malformed_usage_refused_before_verify(self):
        for usage in ("keyUsage=critical,digitalSignature,cRLSign", None, "keyUsage=critical,keyCertSign",
                      "keyUsage=critical,digitalSignature,keyCertSign,cRLSign",
                      "2.5.29.15=critical,DER:04:02:02:04", "2.5.29.15=critical,DER:03:02:07:04"):
            with self.subTest(usage=usage):
                self.replace_ca("ca.crt", self.ca_certificate(usage=usage))
                with patch.object(pki, "run", wraps=pki.run) as run:
                    self.assert_ca_refused()
                self.assertFalse(any(call.args[0] == "verify" for call in run.call_args_list))

    def test_ca_malformed_pem_refused(self):
        for cert in (b"not an X.509 certificate\n",
                     b"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"):
            with self.subTest(cert=cert):
                self.replace_ca("ca.crt", cert)
                self.assert_ca_refused()

    def test_ca_mismatched_private_key_refused(self):
        self.replace_ca("ca.key", self.key.read_bytes())
        self.assert_ca_refused()

    def test_ca_requires_parseable_private_key(self):
        key = str(self.base / "pki/ca/ca.key")
        public_only = pki.run("pkey", "-in", key, "-pubout")
        for invalid in (b"not a private key\n", public_only):
            with self.subTest(invalid=invalid):
                self.replace_ca("ca.key", invalid)
                self.assert_ca_refused()

    def test_ca_not_self_issued_refused(self):
        ca = self.base / "pki/ca"
        csr = pki.run("req", "-new", "-key", str(ca / "ca.key"), "-subj", "/CN=Different CA")
        self.ca_certificate()  # Write the same exact CA extension fixture.
        cert = pki.run("x509", "-req", "-CA", str(ca / "ca.crt"), "-CAkey", str(ca / "ca.key"),
                       "-set_serial", "1", "-days", "3650", "-sha256", "-extfile", str(self.app / "ca-extensions"), data=csr)
        self.replace_ca("ca.crt", cert)
        self.assert_ca_refused()

    def test_ca_expired_certificate_refused(self):
        # x509 -req permits zero days: notAfter is already reached, without sleep.
        self.replace_ca("ca.crt", self.ca_certificate(days=0))
        self.assert_ca_refused()

    def test_ca_corrupted_self_signature_refused(self):
        cert = (self.base / "pki/ca/ca.crt").read_bytes()
        der = bytearray(pki.run("x509", "-inform", "PEM", "-outform", "DER", data=cert))
        der[-1] ^= 1
        # Keep the certificate and extensions parseable, changing only signature.
        pki._ca_extensions(bytes(der))
        self.replace_ca("ca.crt", pki.run("x509", "-inform", "DER", "-outform", "PEM", data=bytes(der)))
        with patch.object(pki, "run", wraps=pki.run) as run:
            self.assert_ca_refused()
        self.assertEqual(run.call_args.args[0], "verify")
        self.assertIn("-check_ss_sig", run.call_args.args)

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
