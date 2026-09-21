"""Isolated protocol fixtures: no real VictoriaLogs or remote operations."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest import mock
import urllib.parse

path = Path(__file__).resolve().parents[1] / "src/monitoring/grafana_logs_backend.py"
spec = importlib.util.spec_from_file_location("logs_backend", path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class LogsBackendTests(unittest.TestCase):
    def run_probe(self, status=200, body=b"", failure=None):
        connection = mock.Mock()
        connection.getresponse.return_value.status = status
        connection.getresponse.return_value.read.return_value = body
        connection.request.side_effect = failure
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(probe.http.client, "HTTPConnection", return_value=connection) as create, contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = probe.main()
        create.assert_called_once_with("127.0.0.1", 9428, timeout=5)
        connection.close.assert_called_once()
        self.assertEqual("", output.getvalue() + errors.getvalue())
        return result, connection

    def test_empty_and_one_row_are_successful_without_returning_log_data(self):
        for body in (b"", b'{"_time":"2026-09-16T12:00:00Z"}\n'):
            result, connection = self.run_probe(body=body)
            self.assertEqual(0, result)
            method, target = connection.request.call_args.args
            self.assertEqual("GET", method)
            url = urllib.parse.urlsplit(target)
            self.assertEqual("/select/logsql/query", url.path)
            self.assertEqual({key: [value] for key, value in probe.PARAMETERS.items()}, urllib.parse.parse_qs(url.query))
            self.assertEqual("* | fields _time", probe.PARAMETERS["query"])
            self.assertEqual("1", probe.PARAMETERS["limit"])
            self.assertEqual("4s", probe.PARAMETERS["timeout"])

    def test_only_runtime_unavailability_is_transient(self):
        for code in (500, 502, 503, 504):
            self.assertEqual(75, self.run_probe(status=code)[0])
        self.assertEqual(75, self.run_probe(failure=OSError("never-print-this"))[0])
        for code in (301, 400, 401, 403, 404):
            self.assertEqual(1, self.run_probe(status=code, body=b"private response")[0])

    def test_invalid_or_excessive_response_fails_without_logging(self):
        for body in (b"<html>not logs</html>", b"[]", b"{}", b'{"_time":0}', b'{"_time":""}', b'{"_time":"valid","_msg":"private"}', b'{}\n{}\n', b"x" * 4097):
            self.assertEqual(1, self.run_probe(body=body)[0])


if __name__ == "__main__":
    unittest.main()
