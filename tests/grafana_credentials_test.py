"""Executable isolated fixtures; no Grafana, 1Password or remote host required."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
path = Path(__file__).resolve().parents[1] / "src/monitoring/grafana_credentials.py"
spec = importlib.util.spec_from_file_location("credentials", path)
credentials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credentials)
USER = "private-user-sentinel"
PASSWORD = "private-password-sentinel'$(not-a-command)"


def profile(login=USER):
    return {"id": 1, "login": login, "isGrafanaAdmin": True, "isDisabled": False,
            "email": "operator@example.invalid", "name": "Preserved Name", "theme": "dark"}


def logs_frame(rows=0):
    # v0.32.0 response_logs.go creates these fields, even for zero log rows.
    # Its SDK v0.296.4 data/frame_json.go writes each zero-length column as [];
    # backend/data.go assigns the response map's RefID to the unnamed frame.
    fields = [("Time", "time"), ("Line", "string"), ("id", "string"),
              ("labels", "other"), ("streams", "other"), ("streamId", "string")]
    return {"results": {"A": {"status": 200, "frames": [{
        "schema": {"refId": "A", "fields": [{"name": name, "type": kind} for name, kind in fields]},
        "data": {"values": [[1700000000000] * rows, [""] * rows, [""] * rows,
                            [{}] * rows, [None] * rows, [""] * rows]},
    }]}}}


def logs_plugin():
    return {"id": "victoriametrics-logs-datasource", "type": "datasource",
            "info": {"version": "0.32.0"}, "signature": "valid"}


class CredentialsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dragontools-credentials-")
        self.addCleanup(self.temp.cleanup)
        self.database = Path(self.temp.name) / "grafana.db"
        self.patch = mock.patch.object(credentials, "DATABASE", str(self.database))
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def database_file(self, login="admin", extra=None, external=False):
        with contextlib.closing(sqlite3.connect(self.database)) as db, db:
            db.execute('CREATE TABLE "user" (id INTEGER, login TEXT, email TEXT, is_admin INTEGER, is_disabled INTEGER, is_service_account INTEGER, password TEXT)')
            db.execute('CREATE TABLE user_auth (user_id INTEGER, auth_token TEXT)')
            db.execute('INSERT INTO "user" VALUES (1, ?, ?, 1, 0, 0, ?)', (login, "admin@localhost", "never-read-password-hash"))
            if extra:
                db.execute('INSERT INTO "user" VALUES (?, ?, ?, ?, ?, ?, ?)', extra)
            if external:
                db.execute('INSERT INTO user_auth VALUES (1, ?)', ("never-read-auth-token",))
        self.database.chmod(0o640)

    def test_stdin_validation(self):
        self.assertEqual((USER, PASSWORD), credentials.credentials(io.BytesIO(json.dumps({"username": USER, "password": PASSWORD}).encode())))
        for username, password in [("", PASSWORD), ("bad:user", PASSWORD), (" spaced", PASSWORD), (USER, ""), (USER, "abc"), (USER, "line\nline"), (USER, "line\rline"), (USER, "nul\0")]:
            with self.subTest(username=username, password=password), self.assertRaises(credentials.Failure) as error:
                credentials.credentials(io.BytesIO(json.dumps({"username": username, "password": password}).encode()))
            self.assertEqual(error.exception.code, 80)
            self.assertNotIn(PASSWORD, str(error.exception))

    def test_readonly_metadata_never_reads_hashes_or_mutates_database(self):
        self.database_file()
        before = self.database.read_bytes()
        before_mtime = self.database.stat().st_mtime_ns
        self.assertEqual("admin", credentials.original_admin(credentials.database_users(), USER))
        self.assertEqual(before, self.database.read_bytes())
        self.assertEqual(before_mtime, self.database.stat().st_mtime_ns)
        self.assertEqual(["grafana.db"], sorted(os.listdir(self.temp.name)))
        self.assertNotIn("password", repr(credentials.database_users()))

    def test_metadata_refuses_symlinks_hardlinks_and_external_accounts(self):
        target = Path(self.temp.name) / "target"
        target.write_text("untouched")
        self.database.symlink_to(target)
        with self.assertRaises(credentials.Failure):
            credentials.database_users()
        self.database.unlink()
        self.database_file(external=True)
        with self.assertRaises(credentials.Failure):
            credentials.database_users()
        self.database.unlink()
        os.link(target, self.database)
        with self.assertRaises(credentials.Failure):
            credentials.database_users()
        self.assertEqual("untouched", target.read_text())

    def test_wrong_or_conflicting_admin_fails_before_reset(self):
        self.database_file(extra=(2, USER.upper(), "other@localhost", 0, 0, 0, "hash"))
        with mock.patch.object(credentials, "reset") as reset, self.assertRaises(credentials.Failure) as error:
            credentials.reconcile(USER, PASSWORD)
        self.assertEqual(81, error.exception.code)
        reset.assert_not_called()

    def test_fresh_bootstrap_uses_desired_environment_only_in_cli(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, {**kwargs, "env": dict(kwargs.get("env", {}))}))
            self.assertNotIn(USER, repr(argv))
            self.assertNotIn(PASSWORD, repr(argv))
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            if argv[0] == "systemctl":
                return subprocess.CompletedProcess(argv, 0, b"inactive\n")
            self.assertEqual(kwargs["env"]["GF_SECURITY_ADMIN_USER"], USER)
            self.assertEqual(kwargs["env"]["GF_SECURITY_ADMIN_PASSWORD"], PASSWORD)
            self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
            self.assertEqual(kwargs["input"], (PASSWORD + "\n").encode())
            self.database_file(USER)
            return subprocess.CompletedProcess(argv, 0)

        with mock.patch.object(credentials.subprocess, "run", side_effect=run):
            self.assertEqual("changed", credentials.bootstrap(USER, PASSWORD))
            self.assertEqual("unchanged", credentials.bootstrap(USER, PASSWORD))
        self.assertEqual(2, len(calls))
        argv = calls[1][0]
        self.assertEqual(credentials.HOME + "/bin/grafana", argv[0])
        self.assertIn("--homepath=" + credentials.HOME, argv)
        self.assertIn("--config=" + credentials.CONFIG, argv)
        self.assertIn("--password-from-stdin", argv)
        self.assertEqual(credentials.DATA, calls[1][1]["cwd"])
        self.assertEqual(["grafana.db"], sorted(os.listdir(self.temp.name)))

    def test_fresh_active_service_is_refused_and_partial_schema_recovers(self):
        with mock.patch.object(credentials.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"active\n")), mock.patch.object(credentials, "reset") as reset:
            with self.assertRaises(credentials.Failure) as error:
                credentials.bootstrap(USER, PASSWORD)
            self.assertEqual(85, error.exception.code)
            reset.assert_not_called()
        # The supported CLI, not Python, completes interrupted migrations.
        with contextlib.closing(sqlite3.connect(self.database)) as db, db:
            db.execute("CREATE TABLE migration_log (id INTEGER)")
        self.database.chmod(0o640)
        self.assertEqual([], credentials.database_users())

    def test_valid_credentials_are_noop_and_verify_never_resets(self):
        self.database_file(USER)
        with mock.patch.object(credentials, "request", return_value=profile()) as request, mock.patch.object(credentials, "reset") as reset:
            self.assertEqual("unchanged", credentials.reconcile(USER, PASSWORD))
            self.assertEqual("unchanged", credentials.reconcile(USER, PASSWORD))
            self.assertEqual("unchanged", credentials.reconcile(USER, PASSWORD, readonly=True))
            reset.assert_not_called()
            self.assertTrue(all(call.args[0] == "GET" for call in request.call_args_list))

    def test_existing_manual_password_reset_and_supported_rename_then_noop(self):
        self.database_file()
        state = {"login": "admin", "password": "manually-changed", "resets": 0, "renames": 0}

        def request(method, username, password, body=None, timeout=5):
            if username != state["login"] or password != state["password"]:
                return None
            if method == "PUT":
                self.assertEqual({"login": USER, "email": "operator@example.invalid", "name": "Preserved Name", "theme": "dark"}, body)
                state["login"] = body["login"]
                state["renames"] += 1
                with contextlib.closing(sqlite3.connect(self.database)) as db, db:
                    db.execute('UPDATE "user" SET login=? WHERE id=1', (USER,))
                return {"message": "User updated"}
            return profile(state["login"])

        def reset(username, password, bootstrap=False):
            self.assertFalse(bootstrap)
            state["password"] = password
            state["resets"] += 1

        with mock.patch.object(credentials, "request", side_effect=request), mock.patch.object(credentials, "reset", side_effect=reset):
            self.assertEqual("changed", credentials.reconcile(USER, PASSWORD))
            self.assertEqual("unchanged", credentials.reconcile(USER, PASSWORD))
        self.assertEqual(1, state["resets"])
        self.assertEqual(1, state["renames"])

    def test_reset_has_no_secret_environment_for_existing_database(self):
        def run(argv, **kwargs):
            self.assertNotIn(PASSWORD, repr(argv))
            self.assertNotIn(USER, repr(argv))
            self.assertNotIn(PASSWORD, repr(kwargs["env"]))
            self.assertNotIn(USER, repr(kwargs["env"]))
            self.assertEqual(kwargs["input"], (PASSWORD + "\n").encode())
            return subprocess.CompletedProcess(argv, 0)

        with mock.patch.object(credentials.subprocess, "run", side_effect=run):
            credentials.reset(USER, PASSWORD)

    def test_cli_stdin_preserves_password_whitespace_and_suppresses_child_failure(self):
        password = "  leading and trailing\t "
        def run(argv, **kwargs):
            self.assertEqual((password + "\n").encode(), kwargs["input"])
            self.assertNotIn(password, repr(argv))
            self.assertEqual(subprocess.DEVNULL, kwargs["stdout"])
            self.assertEqual(subprocess.DEVNULL, kwargs["stderr"])
            return subprocess.CompletedProcess(argv, 1, USER + password, USER + password)
        with mock.patch.object(credentials.subprocess, "run", side_effect=run), self.assertRaises(credentials.Failure) as error:
            credentials.reset(USER, password)
        self.assertEqual(82, error.exception.code)
        self.assertNotIn(USER, str(error.exception))
        self.assertNotIn(password, str(error.exception))
        self.assertEqual([], os.listdir(self.temp.name))

    def test_interrupted_rename_does_not_repeat_completed_password_reset(self):
        self.database_file()
        def request(method, username, password, body=None, timeout=5):
            if username == USER:
                return None
            if method == "PUT":
                raise credentials.Failure(84)
            return profile("admin")
        with mock.patch.object(credentials, "request", side_effect=request), mock.patch.object(credentials, "reset") as reset:
            for _ in range(2):
                with self.assertRaises(credentials.Failure):
                    credentials.reconcile(USER, PASSWORD)
            reset.assert_not_called()
        self.assertEqual(["grafana.db"], sorted(os.listdir(self.temp.name)))

    def test_verify_with_bad_password_is_readonly_failure(self):
        self.database_file(USER)
        before = self.database.read_bytes()
        with mock.patch.object(credentials, "request", return_value=None), mock.patch.object(credentials, "reset") as reset:
            with self.assertRaises(credentials.Failure) as error:
                credentials.reconcile(USER, PASSWORD, readonly=True)
            self.assertEqual(83, error.exception.code)
            reset.assert_not_called()
        self.assertEqual(before, self.database.read_bytes())

    def test_delayed_api_readiness_and_timeout(self):
        tick = [0]
        sleeps = []
        def sleep(seconds):
            sleeps.append(seconds)
            tick[0] += seconds
        with mock.patch.object(credentials.time, "monotonic", side_effect=lambda: tick[0]), mock.patch.object(credentials.time, "sleep", side_effect=sleep):
            with mock.patch.object(credentials, "request", side_effect=[credentials.Failure(84), credentials.Failure(84), profile()]):
                self.assertEqual(profile(), credentials.authenticated(USER, PASSWORD))
            self.assertEqual([0.5, 1], sleeps)
            with mock.patch.object(credentials, "request", side_effect=credentials.Failure(84)):
                with self.assertRaises(credentials.Failure) as error:
                    credentials.authenticated(USER, PASSWORD)
                self.assertEqual(84, error.exception.code)
        self.assertEqual(31.5, tick[0])

    def test_wrong_authenticated_identity_fails_immediately(self):
        invalid = profile()
        invalid["id"] = 2
        with mock.patch.object(credentials, "request", return_value=invalid) as request, mock.patch.object(credentials.time, "sleep") as sleep:
            with self.assertRaises(credentials.Failure):
                credentials.authenticated(USER, PASSWORD)
            request.assert_called_once()
            sleep.assert_not_called()

    def test_http_request_is_loopback_without_redirects_or_credential_url(self):
        connection = mock.Mock()
        captured_headers = {}
        def send(method, url, *, body, headers):
            captured_headers.update(headers)
        connection.request.side_effect = send
        response = connection.getresponse.return_value
        response.status = 200
        response.read.return_value = json.dumps(profile()).encode()
        with mock.patch.object(credentials.http.client, "HTTPConnection", return_value=connection) as create:
            self.assertEqual(profile(), credentials.request("GET", USER, PASSWORD))
        create.assert_called_once_with("127.0.0.1", 3000, timeout=5)
        self.assertEqual(("GET", "/api/user"), connection.request.call_args.args)
        self.assertTrue(captured_headers["Authorization"].startswith("Basic "))
        self.assertEqual({}, connection.request.call_args.kwargs["headers"])
        response.status = 302
        with mock.patch.object(credentials.http.client, "HTTPConnection", return_value=connection), self.assertRaises(credentials.Failure):
            credentials.request("GET", USER, PASSWORD)

    def test_main_never_exposes_exception_credentials(self):
        output = io.StringIO()
        errors = io.StringIO()
        stdin = mock.Mock(buffer=io.BytesIO(json.dumps({"username": USER, "password": PASSWORD}).encode()))
        with mock.patch.object(credentials.sys, "stdin", stdin), mock.patch.object(credentials.sys, "argv", ["helper", "verify"]), mock.patch.object(credentials, "reconcile", side_effect=ValueError(USER + PASSWORD)), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(83, credentials.main())
        self.assertEqual("", output.getvalue() + errors.getvalue())

    def test_no_secret_file_unit_or_ini_generated(self):
        root = path.parents[2]
        for relative in ["src/components/grafana_config.zig", "src/components/grafana_unit.zig"]:
            text = (root / relative).read_text()
            self.assertNotIn(USER, text)
            self.assertNotIn(PASSWORD, text)
            self.assertNotIn("GF_SECURITY_ADMIN_PASSWORD", text)
            self.assertNotIn("EnvironmentFile=", text)

    def test_logs_query_matches_pinned_upstream_and_is_bounded_readonly(self):
        body = credentials.logs_query_body()
        self.assertEqual("now-5m", body["from"])
        self.assertEqual("now", body["to"])
        self.assertEqual(1, len(body["queries"]))
        query = body["queries"][0]
        self.assertEqual({"uid": "dragontools-logs", "type": "victoriametrics-logs-datasource"}, query["datasource"])
        self.assertEqual("instant", query["queryType"])
        self.assertEqual("* | fields _time", query["expr"])
        self.assertEqual(1, query["maxLines"])
        self.assertNotIn(USER, repr(body))
        self.assertNotIn(PASSWORD, repr(body))

    def test_logs_verification_accepts_valid_zero_rows_without_mutation(self):
        for rows in (0, 1):
            with mock.patch.object(credentials, "request", side_effect=[logs_plugin(), {"status": "OK"}, logs_frame(rows)]) as request, mock.patch.object(credentials, "reset") as reset, mock.patch.object(credentials, "database_users") as database, mock.patch.object(credentials.subprocess, "run") as process:
                self.assertEqual("unchanged", credentials.logs_verify(USER, PASSWORD))
                self.assertEqual(["GET", "GET", "POST"], [call.args[0] for call in request.call_args_list])
                self.assertEqual([credentials.LOGS_SETTINGS, credentials.LOGS_HEALTH, credentials.LOGS_QUERY], [call.kwargs["path"] for call in request.call_args_list])
                reset.assert_not_called()
                database.assert_not_called()
                process.assert_not_called()
        self.assertEqual([], os.listdir(self.temp.name))

    def test_logs_delayed_health_and_query_readiness(self):
        tick, sleeps = [0], []
        def sleep(seconds):
            sleeps.append(seconds)
            tick[0] += seconds
        delayed_query = {"results": {"A": {"status": 500, "error": "private backend error"}}}
        responses = [logs_plugin(), credentials.Failure(84), {"status": "ERROR"}, {"status": "OK"},
                     delayed_query, delayed_query, logs_frame()]
        with mock.patch.object(credentials.time, "monotonic", side_effect=lambda: tick[0]), mock.patch.object(credentials.time, "sleep", side_effect=sleep), mock.patch.object(credentials, "request", side_effect=responses) as request:
            self.assertEqual("unchanged", credentials.logs_verify(USER, PASSWORD))
            self.assertEqual(7, request.call_count)
        self.assertEqual([0.5, 1, 0.5, 1], sleeps)

    def test_logs_timeout_is_failure_and_auth_failure_is_not_retried(self):
        tick = [0]
        def sleep(seconds):
            tick[0] += seconds
        with mock.patch.object(credentials.time, "monotonic", side_effect=lambda: tick[0]), mock.patch.object(credentials.time, "sleep", side_effect=sleep), mock.patch.object(credentials, "request", side_effect=credentials.Failure(84)):
            with self.assertRaises(credentials.Failure) as error:
                credentials.logs_ready(USER, PASSWORD)
            self.assertEqual(87, error.exception.code)
        self.assertEqual(45, tick[0])
        with mock.patch.object(credentials, "request", return_value=None) as request, mock.patch.object(credentials.time, "sleep") as sleep:
            with self.assertRaises(credentials.Failure) as error:
                credentials.logs_verify(USER, PASSWORD)
            self.assertEqual(83, error.exception.code)
            request.assert_called_once()
            sleep.assert_not_called()

    def test_loaded_plugin_version_signature_and_missing_plugin_fail_immediately(self):
        invalid = [{}, credentials.Failure(84)]
        for key, value in [("signature", "unsigned"), ("signature", "modified"), ("id", "other"),
                           ("type", "app"), ("info", {"version": "0.31.0"})]:
            plugin = logs_plugin()
            plugin[key] = value
            invalid.append(plugin)
        for plugin in invalid:
            replacement = mock.Mock(side_effect=plugin) if isinstance(plugin, Exception) else mock.Mock(return_value=plugin)
            with self.subTest(plugin=plugin), mock.patch.object(credentials, "request", replacement), mock.patch.object(credentials.time, "sleep") as sleep:
                with self.assertRaises(credentials.Failure) as error:
                    credentials.logs_verify(USER, PASSWORD)
                self.assertEqual(88, error.exception.code)
                replacement.assert_called_once()
                sleep.assert_not_called()

    def test_logs_invalid_data_is_not_success_or_retried(self):
        invalid = [{}, {"results": {}}, {"error": "private error"}, {"results": {"A": {"frames": []}}},
                   {"results": {"A": {"status": 400, "error": "invalid LogsQL"}}}, logs_frame(2)]
        missing_column = logs_frame()
        missing_column["results"]["A"]["frames"][0]["data"]["values"].pop()
        invalid.append(missing_column)
        wrong_schema = logs_frame()
        wrong_schema["results"]["A"]["frames"][0]["schema"]["fields"][0]["type"] = "string"
        invalid.append(wrong_schema)
        for response in invalid:
            with self.subTest(response=response), mock.patch.object(credentials, "request", return_value=response) as request, mock.patch.object(credentials.time, "sleep") as sleep:
                with self.assertRaises(credentials.Failure) as error:
                    credentials.logs_ready(USER, PASSWORD, query=True)
                self.assertEqual(86, error.exception.code)
                request.assert_called_once()
                sleep.assert_not_called()

    def test_logs_http_uses_org_one_and_retries_only_recognized_runtime_responses(self):
        connection = mock.Mock()
        headers = {}
        connection.request.side_effect = lambda method, path, **kwargs: headers.update(kwargs["headers"])
        response = connection.getresponse.return_value
        cases = [
            (200, {"status": "OK"}, credentials.LOGS_HEALTH, None),
            (400, {"status": "ERROR", "message": USER + PASSWORD}, credentials.LOGS_HEALTH, 84),
            (400, {"error": "bad request"}, credentials.LOGS_HEALTH, 86),
            (400, {"results": {"A": {"status": 500, "error": USER + PASSWORD}}}, credentials.LOGS_QUERY, 84),
            (400, {"results": {"A": {"status": 400, "error": USER + PASSWORD}}}, credentials.LOGS_QUERY, 86),
            (403, {"message": USER}, credentials.LOGS_QUERY, 86),
            (302, {}, credentials.LOGS_QUERY, 86),
        ]
        for status, body, endpoint, code in cases:
            response.status = status
            response.read.return_value = json.dumps(body).encode()
            method = "GET" if endpoint == credentials.LOGS_HEALTH else "POST"
            with self.subTest(status=status, endpoint=endpoint), mock.patch.object(credentials.http.client, "HTTPConnection", return_value=connection) as create:
                if code:
                    with self.assertRaises(credentials.Failure) as error:
                        credentials.request(method, USER, PASSWORD, path=endpoint)
                    self.assertEqual(code, error.exception.code)
                    self.assertNotIn(USER, str(error.exception))
                    self.assertNotIn(PASSWORD, str(error.exception))
                else:
                    self.assertEqual(body, credentials.request(method, USER, PASSWORD, path=endpoint))
                create.assert_called_once_with("127.0.0.1", 3000, timeout=5)
                self.assertEqual((method, endpoint), connection.request.call_args.args)
                self.assertEqual("1", headers["X-Grafana-Org-Id"])
                self.assertEqual({}, connection.request.call_args.kwargs["headers"])

    def test_logs_main_outputs_only_fixed_token_and_suppresses_errors(self):
        for result, code in [("unchanged", 0), (credentials.Failure(86), 86), (ValueError(USER + PASSWORD), 86)]:
            output, errors = io.StringIO(), io.StringIO()
            stdin = mock.Mock(buffer=io.BytesIO(json.dumps({"username": USER, "password": PASSWORD}).encode()))
            replacement = mock.Mock(side_effect=result) if isinstance(result, Exception) else mock.Mock(return_value=result)
            with mock.patch.object(credentials.sys, "stdin", stdin), mock.patch.object(credentials.sys, "argv", ["helper", "logs_verify"]), mock.patch.object(credentials, "logs_verify", replacement), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(code, credentials.main())
            self.assertEqual("unchanged" if code == 0 else "", output.getvalue())
            self.assertEqual("", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
