#!/usr/bin/env python3
"""Real native helper in an isolated Linux filesystem; no SSH/systemd/network.

Requires root for chroot and distinct root/dt-ingest ownership. Portable native
PKI and lock tests run independently on both Linux and macOS in zig build test.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument("--agent", type=Path, required=True)
args = parser.parse_args()
AGENT = args.agent.resolve()
HOSTNAME = "monitoring.baptizeddragon.com"
INGEST = 1001


@unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0,
                     "Linux root required for isolated ownership/chroot fixture")
class StationBootstrap(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dragontools-station-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory("etc/dragontools", 0o755)
        self.directory("var/lib/dragontools", 0o755)
        self.directory("dev", 0o755)
        # The embedded crypto entropy provider opens the OS random device.
        os.mknod(self.root / "dev/random", stat.S_IFCHR | 0o600, os.makedev(1, 8))
        (self.root / "etc/passwd").write_text(
            "root:x:0:0:root:/root:/bin/false\n"
            f"dt-ingest:x:{INGEST}:{INGEST}:ingress:/nonexistent:/bin/false\n")
        shutil.copyfile(AGENT, self.root / "dragontool-agent")
        (self.root / "dragontool-agent").chmod(0o755)
        self.base = self.root / "etc/dragontools/ingestion"

    def directory(self, path, mode, uid=0, gid=0):
        value = self.root / path
        value.mkdir(parents=True, exist_ok=True)
        value.chmod(mode)
        os.chown(value, uid, gid)
        return value

    def skeleton(self, registry_mode=0o750):
        self.directory("etc/dragontools/ingestion", 0o755)
        for name in ("pki", "clients"):
            self.directory(f"etc/dragontools/ingestion/{name}", 0o700)
        self.directory("etc/dragontools/ingestion/registry", registry_mode, 0, INGEST)
        self.directory("var/lib/dragontools/ingestion", 0o750, INGEST, INGEST)

    def call(self, action="station-ensure", hostname=HOSTNAME, code=0,
             output=b"changed", stage=None, reason=None):
        def isolate():
            os.chroot(self.root)
            os.chdir("/")
        result = subprocess.run(
            ["/dragontool-agent", "internal", "--stdin", "--diagnostics"],
            input=json.dumps({"action": action, "args": [hostname]}).encode(),
            capture_output=True, timeout=30, preexec_fn=isolate,
            env={"PATH": "/nonexistent"})
        # Assertions never include captured private contents in failure output.
        safe_stage = next((name for name in (
            "native_initialization", "operation_lock", "ingestion_root", "pki_directory",
            "clients_directory", "registry_directory", "state_directory", "ca_state",
            "ca_key_generation", "ca_certificate_generation", "ca_certificate_validation",
            "ca_key_serialization", "ca_publication", "server_state", "server_key_generation",
            "server_certificate_generation", "server_certificate_validation",
            "server_key_serialization", "server_publication")
            if f"AgentStage: {name}\n".encode() in result.stderr), "unrecognized")
        self.assertEqual(result.returncode, code, f"safe failure stage: {safe_stage}")
        self.assertTrue(result.stdout == output, "unexpected native response")
        expected = b"" if stage is None else f"AgentStage: {stage}\nAgentError: {reason}\n".encode()
        self.assertTrue(result.stderr == expected, "unexpected safe diagnostic")
        self.assertNotIn(b"PRIVATE KEY", result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {str(p.relative_to(self.root)):
                (hashlib.sha256(p.read_bytes()).digest(), p.stat().st_mtime_ns,
                 p.stat().st_mode, p.stat().st_uid, p.stat().st_gid)
                for p in self.base.rglob("*") if p.is_file()}

    def converged(self):
        self.call()
        self.assertTrue((self.base / "pki/ca/ca.key").is_file())
        self.assertTrue((self.base / "server/server.key").is_file())
        self.assertEqual((self.base / "server/endpoint").read_text(), HOSTNAME)
        self.assertFalse((self.root / "etc/dragontools/apps").exists())
        for name in ("clients", "registry"):
            self.assertEqual(list((self.base / name).iterdir()), [])
        before = self.snapshot()
        self.call("station-verify", output=b"unchanged")
        self.call(output=b"unchanged")
        self.assertEqual(before, self.snapshot())

    def test_exact_empty_production_tree_then_noop(self):
        self.skeleton()
        self.converged()

    def test_absent_ingestion_tree(self):
        self.converged()

    def test_interrupted_parents(self):
        self.directory("etc/dragontools/ingestion", 0o755)
        self.directory("etc/dragontools/ingestion/pki", 0o700)
        self.converged()

    def test_registry_previous_generation_migrates(self):
        self.skeleton(0o700)
        self.converged()
        self.assertEqual((self.base / "registry").stat().st_mode & 0o7777, 0o750)

    def test_unknown_registry_mode_refused(self):
        self.skeleton(0o710)
        self.call(code=89, output=b"", stage="registry_directory", reason="RegistryPermissions")
        self.assertFalse((self.base / "pki/ca").exists())
        self.assertEqual((self.base / "registry").stat().st_mode & 0o7777, 0o710)

    def test_free_lock_and_contention_are_distinct(self):
        self.skeleton()
        fd = os.open(self.root / "etc/dragontools", os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.call(code=96, output=b"", stage="operation_lock", reason="OperationBusy")
            self.assertEqual(list((self.base / "pki").iterdir()), [])
        finally:
            os.close(fd)
        self.converged()

    def test_wrong_owner_is_not_empty_bootstrap(self):
        self.skeleton()
        os.chown(self.base / "pki", INGEST, INGEST)
        self.call(code=86, output=b"", stage="pki_directory", reason="InvalidManagedState")
        self.assertEqual((self.base / "pki").stat().st_uid, INGEST)

    def test_symlink_is_not_empty_bootstrap(self):
        self.skeleton()
        (self.base / "pki").rmdir()
        (self.base / "pki").symlink_to("clients")
        self.call(code=86, output=b"", stage="pki_directory", reason="UnexpectedSymlink")
        self.assertTrue((self.base / "pki").is_symlink())
        self.assertEqual(list((self.base / "clients").iterdir()), [])

    def test_invalid_existing_ca_preserved_and_redacted(self):
        self.skeleton()
        self.converged()
        certificate = self.base / "pki/ca/ca.crt"
        certificate.write_bytes((self.base / "pki/ca/ca.key").read_bytes())
        before = self.snapshot()
        self.call(code=86, output=b"", stage="ca_certificate_validation",
                  reason="CertificateValidationFailed")
        self.assertEqual(before, self.snapshot())

    def test_configured_hostname_is_verified(self):
        self.skeleton()
        self.converged()
        before = self.snapshot()
        self.call("station-verify", hostname="other.example", code=86, output=b"",
                  stage="server_certificate_validation", reason="CertificateValidationFailed")
        self.assertEqual(before, self.snapshot())


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
