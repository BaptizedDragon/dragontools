"""Temporary-filesystem journald lifecycle fixtures; never invoke host systemd."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import tempfile
import types
import unittest


ROOT = Path(__file__).resolve().parents[1]


class JournalFixture:
    def __init__(self, base):
        self.base = Path(base)
        self.main = self.base / "etc/systemd/journald.conf"
        self.dropins = self.main.parent / "journald.conf.d"
        self.main.parent.mkdir(parents=True)
        self.main.write_text("# Existing administrator configuration\n[Journal]\nStorage=auto\n")
        self.dropins.mkdir(mode=0o755)
        self.marker = self.base / "var/lib/dragontools/journald-restart-required"
        self.marker.parent.mkdir(parents=True)
        self.managed = self.dropins / "90-dragontools.conf"
        self.calls = []
        self.fail_restart = False
        self.fail_verify = False
        spec = importlib.util.spec_from_file_location("journald_fixture", ROOT / "src/monitoring/agents/journald.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.module.PATH = str(self.managed)
        self.module.MARKER = str(self.marker)
        self.module.run = self.run
        self.module.capacity = self.capacity
        # The helper runs as root remotely. Map ownership of our unprivileged
        # temporary fixture only, retaining actual type/mode/link metadata. Do
        # not replace filesystem operations or production validation logic.
        self.module.os = types.SimpleNamespace(**vars(os))
        self.module.os.lstat = self.lstat

    def lstat(self, path):
        value = os.lstat(path)
        assert Path(path).is_relative_to(self.base), "fixture escaped temporary root"
        fields = {name: getattr(value, name) for name in dir(value) if name.startswith("st_")}
        fields.update(st_uid=0, st_gid=0)
        return types.SimpleNamespace(**fields)

    def capacity(self, path):
        return {"/var/log": 10 * 1024**3, "/run": 1024**3}[path]

    def effective_text(self):
        files = [self.main, *sorted(self.dropins.glob("*.conf"))]
        return "\n".join("# " + str(path) + "\n" + path.read_text() for path in files)

    def run(self, *args):
        self.calls.append(args)
        if args == ("systemd-analyze", "cat-config", "systemd/journald.conf"):
            return self.effective_text()
        if args == ("systemctl", "restart", "systemd-journald.service"):
            if self.fail_restart:
                raise RuntimeError("fixture restart failed")
            return ""
        if args == ("systemctl", "is-active", "systemd-journald.service"):
            if self.fail_verify:
                raise RuntimeError("fixture service inactive")
            return "active\n"
        if args == ("journalctl", "--disk-usage"):
            return "Archived and active journals take up 1.0M in the file system.\n"
        raise AssertionError("unexpected command: " + repr(args))

    def invoke(self, mode):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.module.check(mode)
        return output.getvalue()

    def write_admin(self, name, values):
        path = self.dropins / name
        path.write_text("# Owned by administrator\n[Journal]\n" + values)
        return path

    def restarts(self):
        return self.calls.count(("systemctl", "restart", "systemd-journald.service"))

    def snapshot(self):
        return {str(path.relative_to(self.base)): (path.read_bytes(), stat.S_IMODE(path.stat().st_mode), path.stat().st_ino)
                for path in self.base.rglob("*") if path.is_file()}


class JournalLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dragontools-journald-")
        self.fixture = JournalFixture(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_existing_stricter_bounds_require_no_managed_dropin_or_restart(self):
        f = self.fixture
        f.write_admin("10-admin.conf", "SystemMaxUse=32M\nRuntimeMaxUse=4M\nMaxRetentionSec=1day\n")
        before = f.snapshot()
        self.assertEqual("unchanged", f.invoke("install"))
        self.assertEqual("", f.invoke("verify"))
        self.assertEqual(before, f.snapshot())
        self.assertFalse(f.managed.exists())
        self.assertEqual(0, f.restarts())

    def test_bounded_but_inactive_journal_fails_install_without_mutation(self):
        f = self.fixture
        f.write_admin("10-admin.conf", "SystemMaxUse=32M\nRuntimeMaxUse=4M\nMaxRetentionSec=1day\n")
        f.fail_verify = True
        before = f.snapshot()
        with self.assertRaisesRegex(RuntimeError, "inactive"):
            f.invoke("install")
        self.assertEqual(before, f.snapshot())
        self.assertFalse(f.managed.exists())
        self.assertFalse(f.marker.exists())
        self.assertEqual(0, f.restarts())

    def test_missing_bounds_create_only_managed_dropin_then_rerun_is_noop(self):
        f = self.fixture
        f.write_admin("20-admin.conf", "RateLimitIntervalSec=30s\nRateLimitBurst=500\n")
        before = f.snapshot()
        self.assertEqual("changed", f.invoke("install"))
        self.assertEqual(1, f.restarts())
        self.assertFalse(f.marker.exists())
        self.assertEqual({"SystemMaxUse": 512 * 1024**2, "RuntimeMaxUse": 1024**3 * 2 // 100,
                          "MaxRetentionSec": 604800}, f.module.effective(f.managed.read_text()))
        after = f.snapshot()
        self.assertEqual(set(before) | {str(f.managed.relative_to(f.base))}, set(after))
        self.assertEqual(before, {key: after[key] for key in before})
        self.assertEqual(0o644, stat.S_IMODE(f.managed.stat().st_mode))
        self.assertEqual("unchanged", f.invoke("install"))
        self.assertEqual(after, f.snapshot())
        self.assertEqual(1, f.restarts())

    def test_missing_field_is_filled_without_weakening_stricter_admin_bounds(self):
        f = self.fixture
        admin = f.write_admin("20-admin.conf", "SystemMaxUse=16M\nMaxRetentionSec=1day\n")
        original = admin.read_bytes()
        self.assertEqual("changed", f.invoke("install"))
        actual = f.module.effective(f.managed.read_text())
        self.assertEqual(16 * 1024**2, actual["SystemMaxUse"])
        self.assertEqual(86400, actual["MaxRetentionSec"])
        self.assertEqual(1024**3 * 2 // 100, actual["RuntimeMaxUse"])
        self.assertEqual(original, admin.read_bytes())

    def test_later_override_refuses_before_creating_file_marker_or_restart(self):
        f = self.fixture
        f.write_admin("99-admin.conf", "SystemMaxUse=4G\nRuntimeMaxUse=1G\nMaxRetentionSec=30day\n")
        before = f.snapshot()
        with self.assertRaisesRegex(ValueError, "later journald override"):
            f.invoke("install")
        self.assertEqual(before, f.snapshot())
        self.assertFalse(f.managed.exists())
        self.assertFalse(f.marker.exists())
        self.assertEqual(0, f.restarts())

    def test_restart_failure_retains_intent_and_rerun_finalizes_without_rewriting(self):
        f = self.fixture
        f.fail_restart = True
        with self.assertRaisesRegex(RuntimeError, "restart failed"):
            f.invoke("install")
        self.assertTrue(f.marker.exists())
        installed = f.managed.read_bytes(), f.managed.stat().st_ino
        f.fail_restart = False
        self.assertEqual("changed", f.invoke("install"))
        self.assertEqual(installed, (f.managed.read_bytes(), f.managed.stat().st_ino))
        self.assertFalse(f.marker.exists())
        self.assertEqual(2, f.restarts())
        self.assertEqual("unchanged", f.invoke("install"))
        self.assertEqual(2, f.restarts())

    def test_failed_post_restart_verification_retains_intent(self):
        f = self.fixture
        f.fail_verify = True
        with self.assertRaisesRegex(RuntimeError, "inactive"):
            f.invoke("install")
        self.assertTrue(f.marker.exists())
        f.fail_verify = False
        self.assertEqual("changed", f.invoke("install"))
        self.assertFalse(f.marker.exists())
        self.assertEqual(2, f.restarts())

    def test_standalone_verify_is_readonly_even_with_pending_restart(self):
        f = self.fixture
        with self.assertRaisesRegex(ValueError, "unbounded"):
            f.invoke("verify")
        self.assertFalse(f.managed.exists())
        f.write_admin("10-admin.conf", "SystemMaxUse=32M\nRuntimeMaxUse=4M\nMaxRetentionSec=1day\n")
        f.marker.write_bytes(b"")
        before = f.snapshot()
        self.assertEqual("", f.invoke("verify"))
        self.assertEqual(before, f.snapshot())
        self.assertEqual(0, f.restarts())

    def test_unmanaged_conflict_preserved_when_a_write_would_be_needed(self):
        f = self.fixture
        f.managed.write_text("# Local configuration\n[Journal]\nSystemMaxUse=4G\n")
        before = f.snapshot()
        with self.assertRaisesRegex(ValueError, "unmanaged journald drop-in"):
            f.invoke("install")
        self.assertEqual(before, f.snapshot())
        self.assertEqual(0, f.restarts())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(JournalLifecycleTests)
    result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=2).run(suite)
    if not result.wasSuccessful():
        for test, details in result.errors + result.failures:
            print(str(test) + "\n" + details)
        raise SystemExit(1)
    print(f"PASS: {result.testsRun} temporary-filesystem journald lifecycle tests")
