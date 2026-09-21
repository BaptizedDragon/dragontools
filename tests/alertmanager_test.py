"""Local protected-file and API fixtures; never contact systemd or Telegram."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "src/monitoring" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


secrets = load("alertmanager_secrets")
runtime = load("alertmanager_runtime")
template = load("telegram_template")
TOKEN = "123456:fixture-private-token"
CHAT = "-1001234567890"
PAYLOAD = {"token": TOKEN, "chat_id": CHAT}
SERVICE_ID = 12345


class ProtectedFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dragontools-alertmanager-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name) / "alertmanager"
        self.base.mkdir(mode=0o755)
        self.base.chmod(0o755)
        self.pending = Path(self.tmp.name) / "restart-required"
        for key, value in [("BASE", str(self.base)), ("DIRECTORY", str(self.base / "secrets")), ("PENDING", str(self.pending))]:
            patch = mock.patch.object(secrets, key, value)
            patch.start()
            self.addCleanup(patch.stop)
        # Real temporary files exercise open/replace/rename/modes and bytes. Only
        # ownership is modeled, so this test does not require root or a service UID.
        self.owners = {}
        original_lstat, original_fstat = os.lstat, os.fstat

        def metadata(value):
            uid, gid = self.owners.get((value.st_dev, value.st_ino), (0, 0))
            fields = {key: getattr(value, key) for key in dir(value) if key.startswith("st_")}
            return types.SimpleNamespace(**{**fields, "st_uid": uid, "st_gid": gid})

        def chown(path, uid, gid):
            value = original_lstat(path)
            self.owners[(value.st_dev, value.st_ino)] = (uid, gid)

        def fchown(fd, uid, gid):
            value = original_fstat(fd)
            self.owners[(value.st_dev, value.st_ino)] = (uid, gid)

        for name, function in [("lstat", lambda *a, **k: metadata(original_lstat(*a, **k))),
                               ("fstat", lambda *a, **k: metadata(original_fstat(*a, **k))),
                               ("chown", chown), ("fchown", fchown)]:
            patch = mock.patch.object(os, name, function)
            patch.start()
            self.addCleanup(patch.stop)
        self.calls = []
        self.active = False

        def run(argv, **kwargs):
            self.assertNotIn(TOKEN, repr(argv))
            self.assertNotIn(CHAT, repr(argv))
            self.assertEqual(subprocess.DEVNULL, kwargs["stderr"])
            self.assertTrue(self.pending.exists(), "restart intent precedes any service action")
            self.calls.append(argv)
            if argv[1] == "is-active":
                return subprocess.CompletedProcess(argv, 0 if self.active else 3, b"active\n" if self.active else b"inactive\n")
            self.assertEqual(["systemctl", "stop", "dragontools-alertmanager.service"], argv)
            self.assertEqual(subprocess.DEVNULL, kwargs["stdout"])
            self.active = False
            return subprocess.CompletedProcess(argv, 0)

        patch = mock.patch.object(subprocess, "run", side_effect=run)
        patch.start()
        self.addCleanup(patch.stop)

    def install(self, payload=PAYLOAD):
        return secrets.install(payload, SERVICE_ID, SERVICE_ID)

    def state(self):
        return [(p.name, p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_ino, stat.S_IMODE(p.stat().st_mode))
                for p in sorted((self.base / "secrets").iterdir())]

    def test_fresh_publication_and_unchanged_rerun_preserve_bytes_metadata_and_process(self):
        self.assertEqual("changed", self.install())
        self.assertEqual([TOKEN.encode(), CHAT.encode()], secrets.inspect(SERVICE_ID, SERVICE_ID))
        for name in secrets.FILES:
            value = os.lstat(self.base / "secrets" / name)
            self.assertEqual((SERVICE_ID, SERVICE_ID, 0o400), (value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)))
        directory = os.lstat(self.base / "secrets")
        self.assertEqual((0, SERVICE_ID, 0o750), (directory.st_uid, directory.st_gid, stat.S_IMODE(directory.st_mode)))
        self.pending.unlink()
        before, calls = self.state(), len(self.calls)
        self.assertEqual("unchanged", self.install())
        self.assertEqual(before, self.state())
        self.assertEqual(calls, len(self.calls))
        self.assertFalse(self.pending.exists())
        self.assertEqual(["secrets"], sorted(os.listdir(self.base)))

    def test_rotation_stops_only_alertmanager_and_partial_publication_recovers(self):
        self.install()
        self.pending.unlink()
        self.active = True
        changed = {"token": "123456:rotated-private-token", "chat_id": "-2001234567890"}
        replace = os.replace

        def interrupt(source, destination):
            self.assertFalse(self.active)
            self.assertTrue(self.pending.exists())
            if destination.endswith("telegram-chat-id"):
                raise OSError("fixture interruption")
            replace(source, destination)

        with mock.patch.object(os, "replace", side_effect=interrupt), self.assertRaises(OSError):
            self.install(changed)
        self.assertTrue(self.pending.exists())
        self.assertEqual([changed["token"].encode(), CHAT.encode()], secrets.inspect(SERVICE_ID, SERVICE_ID))
        self.assertEqual(1, sum(call[1] == "stop" for call in self.calls))
        self.assertEqual(["secrets"], os.listdir(self.base))
        self.assertEqual("changed", self.install(changed))
        self.assertEqual("unchanged", self.install(changed))
        self.assertEqual([changed["token"].encode(), changed["chat_id"].encode()], secrets.inspect(SERVICE_ID, SERVICE_ID))

    def test_foreign_or_unsafe_files_are_never_adopted(self):
        directory = self.base / "secrets"
        directory.mkdir(mode=0o750)
        os.chown(directory, 0, SERVICE_ID)
        foreign = directory / "telegram-bot-token"
        foreign.write_bytes(b"keep exactly")
        with self.assertRaises((ValueError, OSError)):
            self.install()
        self.assertEqual(b"keep exactly", foreign.read_bytes())
        self.assertFalse(self.pending.exists())
        foreign.unlink()
        directory.rmdir()
        self.install()
        token = directory / "telegram-bot-token"
        token.chmod(0o600)
        with self.assertRaises(ValueError):
            self.install()
        token.chmod(0o400)
        target = self.base / "unrelated"
        target.write_bytes(b"do not follow")
        token.unlink()
        token.symlink_to(target)
        with self.assertRaises(OSError):
            self.install()
        self.assertEqual(b"do not follow", target.read_bytes())
        token.unlink()
        os.link(target, token)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(b"do not follow", target.read_bytes())

    def test_only_proven_private_staging_can_be_cleaned(self):
        stage = self.base / ".telegram.abcdefgh"
        stage.mkdir(mode=0o700)
        secrets.write(str(stage / ".dragontools-managed"), secrets.MARKER, 0, 0)
        secrets.write(str(stage / "telegram-bot-token"), TOKEN.encode(), SERVICE_ID, SERVICE_ID)
        # Also recover a fresh stage interrupted after final directory metadata
        # was applied but before its atomic rename.
        os.chown(stage, 0, SERVICE_ID)
        stage.chmod(0o750)
        self.install()
        self.assertFalse(stage.exists())
        stage.mkdir(mode=0o700)
        (stage / "foreign").write_bytes(b"preserve")
        with self.assertRaises((ValueError, OSError)):
            self.install()
        self.assertEqual(b"preserve", (stage / "foreign").read_bytes())

    def test_standalone_verify_is_readonly_and_errors_emit_no_secret(self):
        self.install()
        self.pending.unlink()
        before, calls = self.state(), len(self.calls)
        account = types.SimpleNamespace(pw_uid=SERVICE_ID, pw_gid=SERVICE_ID)
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(secrets.pwd, "getpwnam", return_value=account), mock.patch.object(sys, "argv", ["helper", "verify"]), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(0, secrets.main())
        self.assertEqual(before, self.state())
        self.assertEqual(calls, len(self.calls))
        self.assertFalse(self.pending.exists())
        invalid = types.SimpleNamespace(buffer=io.BytesIO(json.dumps({"token": TOKEN + " invalid", "chat_id": CHAT}).encode()))
        with mock.patch.object(secrets.pwd, "getpwnam", return_value=account), mock.patch.object(sys, "argv", ["helper", "install"]), mock.patch.object(sys, "stdin", invalid), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(86, secrets.main())
        self.assertEqual("", stdout.getvalue() + stderr.getvalue())
        self.assertEqual(before, self.state())

    def test_config_verification_accepts_only_exact_generated_regular_root_file(self):
        path = self.base / "alertmanager.yml"
        path.write_text("enabled fixture")
        path.chmod(0o644)
        with mock.patch.object(runtime, "CONFIG", str(path)):
            self.assertTrue(runtime.configured("disabled fixture", "enabled fixture"))
            before = path.read_bytes(), path.stat().st_mtime_ns
            self.assertTrue(runtime.configured("disabled fixture", "enabled fixture"))
            self.assertEqual(before, (path.read_bytes(), path.stat().st_mtime_ns))
            path.write_text("enabled fixture\n# local edit")
            with self.assertRaises(ValueError):
                runtime.configured("disabled fixture", "enabled fixture")
            path.write_text("enabled fixture")
            path.chmod(0o600)
            with self.assertRaises(ValueError):
                runtime.configured("disabled fixture", "enabled fixture")
            path.chmod(0o644)
            other = self.base / "other"
            os.link(path, other)
            with self.assertRaises(ValueError):
                runtime.configured("disabled fixture", "enabled fixture")
            other.unlink()
            path.rename(other)
            path.symlink_to(other)
            with self.assertRaises(OSError):
                runtime.configured("disabled fixture", "enabled fixture")


class ManagedTemplate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dragontools-template-')
        self.addCleanup(self.tmp.cleanup)
        parent = Path(self.tmp.name)
        parent.chmod(0o755)
        self.base = parent / 'alertmanager'
        self.base.mkdir(mode=0o755)
        self.base.chmod(0o755)
        self.path = self.base / 'templates/telegram.tmpl'
        self.pending = parent / 'restart-required'
        self.expected = (ROOT / 'src/monitoring/telegram.tmpl').read_bytes()
        for name, value in [('BASE', self.base), ('PENDING', self.pending)]:
            patch = mock.patch.object(template, name, value)
            patch.start(); self.addCleanup(patch.stop)
        # Exercise real files, modes, links and atomic replace without root.
        lstat = Path.lstat
        self.owner = (0, 0)
        def metadata(path):
            value = lstat(path)
            fields = {key: getattr(value, key) for key in dir(value) if key.startswith('st_')}
            return types.SimpleNamespace(**{**fields, 'st_uid': self.owner[0], 'st_gid': self.owner[1]})
        patch = mock.patch.object(Path, 'lstat', metadata)
        patch.start(); self.addCleanup(patch.stop)

    def test_atomic_publication_preserves_other_templates_and_unchanged_rerun(self):
        self.path.parent.mkdir(mode=0o755)
        self.path.parent.chmod(0o755)
        other = self.path.parent / 'manual.tmpl'
        other.write_bytes(b'preserve this unrelated template')
        replace = os.replace
        def publish(source, destination):
            self.assertTrue(self.pending.exists(), 'intent must precede publication')
            self.assertEqual(stat.S_IMODE(os.stat(source).st_mode), 0o644)
            self.assertEqual(Path(source).read_bytes(), self.expected)
            replace(source, destination)
        with mock.patch.object(os, 'replace', side_effect=publish):
            self.assertTrue(template.reconcile(self.expected, True))
        self.pending.unlink()
        before = self.path.stat()
        self.assertFalse(template.reconcile(self.expected, True))
        self.assertFalse(template.reconcile(self.expected, False))
        self.assertEqual((before.st_ino, before.st_mtime_ns), (self.path.stat().st_ino, self.path.stat().st_mtime_ns))
        self.assertFalse(self.pending.exists())
        self.assertEqual(other.read_bytes(), b'preserve this unrelated template')
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), ['manual.tmpl', 'telegram.tmpl'])

    def test_failed_update_retains_old_file_and_restart_intent_then_recovers(self):
        template.reconcile(self.expected, True)
        self.pending.unlink()
        updated = self.expected + b'{{/* next managed version */}}\n'
        with mock.patch.object(os, 'replace', side_effect=OSError('fixture interruption')), self.assertRaises(OSError):
            template.reconcile(updated, True)
        self.assertEqual(self.path.read_bytes(), self.expected)
        self.assertTrue(self.pending.exists())
        self.assertEqual([p.name for p in self.path.parent.iterdir()], ['telegram.tmpl'])
        self.assertTrue(template.reconcile(updated, True))
        self.assertFalse(template.reconcile(updated, True))
        self.assertTrue(self.pending.exists(), 'only controller finalization clears intent')

    def test_readonly_missing_or_mismatched_template_never_writes(self):
        with self.assertRaises(ValueError): template.reconcile(self.expected, False)
        self.assertFalse(self.path.parent.exists())
        template.reconcile(self.expected, True)
        self.pending.unlink()
        with self.assertRaises(ValueError): template.reconcile(self.expected + b'changed', False)
        self.assertEqual(self.path.read_bytes(), self.expected)
        self.assertFalse(self.pending.exists())

    def test_refuses_foreign_owner_modes_files_and_links_without_mutation(self):
        template.reconcile(self.expected, True)
        self.pending.unlink()
        self.path.write_bytes(b'manual template')
        with self.assertRaises(ValueError): template.reconcile(self.expected, True)
        self.assertEqual(self.path.read_bytes(), b'manual template')
        self.path.write_bytes(self.expected)
        self.path.chmod(0o600)
        with self.assertRaises(ValueError): template.reconcile(self.expected, True)
        self.path.chmod(0o644)
        self.owner = (123, 456)
        with self.assertRaises(ValueError): template.reconcile(self.expected, True)
        self.owner = (0, 0)
        other = self.base / 'unrelated'
        self.path.rename(other)
        for link in (lambda: self.path.symlink_to(other), lambda: os.link(other, self.path)):
            link()
            with self.assertRaises((ValueError, OSError)): template.reconcile(self.expected, True)
            self.path.unlink()
        self.path.mkdir()
        with self.assertRaises(ValueError): template.reconcile(self.expected, True)
        self.assertFalse(self.pending.exists())
        self.assertEqual(other.read_bytes(), self.expected)

    def test_transport_bounds_payload_and_suppresses_raw_errors(self):
        for payload in (b'not managed', template.MARKER + b'x' * template.LIMIT):
            stdout, stderr = io.StringIO(), io.StringIO()
            with mock.patch.object(sys, 'argv', ['helper', 'install']), mock.patch.object(sys, 'stdin', types.SimpleNamespace(buffer=io.BytesIO(payload))), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(template.main(), 40)
            self.assertEqual(stdout.getvalue() + stderr.getvalue(), '')
            self.assertFalse(self.path.parent.exists())


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.enabled = True
        self.status = {"versionInfo": {"version": "0.34.1"}, "cluster": {"status": "disabled"}, "config": {"original": ""}}
        self.update_config()

        def request(method, path, body=None):
            self.requests.append((method, path, body))
            if path == "/api/v2/status":
                return self.status
            if path == "/api/v2/receivers":
                return [{"name": name} for name in (["discard", "telegram", "telegram-host-events"] if self.enabled else ["discard"])]
            self.assertEqual(("POST", "/api/v2/alerts"), (method, path))
            self.assertEqual("critical", body[0]["labels"]["severity"])
            self.assertEqual("DragonToolsNotificationTest", body[0]["labels"]["alertname"])
            self.assertNotIn(TOKEN, repr(body))
            self.assertNotIn(CHAT, repr(body))
            return None

        for name, function in [("request", request), ("configured", lambda *_: self.enabled)]:
            patch = mock.patch.object(runtime, name, function)
            patch.start()
            self.addCleanup(patch.stop)

    def update_config(self):
        self.status["config"]["original"] = "telegram_configs:\n  bot_token_file: /etc/dragontools/alertmanager/secrets/telegram-bot-token\n  chat_id_file: /etc/dragontools/alertmanager/secrets/telegram-chat-id\n  parse_mode: HTML\n  send_resolved: true\n  send_resolved: false\n  host-maintenance: event_id\n  message: dragontools.telegram.message\ntemplates: [/etc/dragontools/alertmanager/templates/telegram.tmpl]\n  matchers: ['severity=~\"warning|critical\"']\n" if self.enabled else "receivers:\n- name: discard\n"

    def call(self, mode):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["helper", mode, "disabled", "enabled"]), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = runtime.main()
        self.assertEqual("", stderr.getvalue())
        if mode != "check":
            self.assertEqual("", stdout.getvalue())
        return code

    def test_health_gets_only_and_explicit_notify_posts_exactly_once(self):
        self.assertEqual(0, self.call("health"))
        self.assertTrue(all(method == "GET" for method, _, _ in self.requests))
        self.requests.clear()
        self.assertEqual(0, self.call("notify"))
        self.assertEqual(["GET", "GET", "POST"], [method for method, _, _ in self.requests])

    def test_disabled_receiver_never_posts(self):
        self.enabled = False
        self.update_config()
        self.assertEqual(0, self.call("health"))
        self.assertEqual(1, self.call("notify"))
        self.assertTrue(all(method == "GET" for method, _, _ in self.requests))

    def test_runtime_mismatch_is_deterministic_and_no_error_content_escapes(self):
        for field, value in [("versionInfo", {"version": "unknown"}), ("cluster", {"status": "ready"}), ("config", {"original": "bot_token: " + TOKEN + "\nchat_id: " + CHAT})]:
            with self.subTest(field=field), mock.patch.dict(self.status, {field: value}):
                self.assertEqual(1, self.call("health"))
        with mock.patch.object(runtime, "request", side_effect=ConnectionError(TOKEN + CHAT)):
            self.assertEqual(75, self.call("health"))


if __name__ == "__main__":
    unittest.main()
