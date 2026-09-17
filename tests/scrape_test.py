"""Local fixtures for native scraper state and publication, without remote hosts."""
import base64
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
READ = (ROOT / "src/monitoring/scrape.py").read_text()
MUTATE = (ROOT / "src/monitoring/scrape_mutate.py").read_text()
NOW = 1_800_000_000.0
PROBES = [{"name": "landing", "url": "https://example.com/healthz"}]


def load():
    namespace = {"__name__": "scrape_fixture"}
    exec(compile(READ + "\n" + MUTATE, "scrape_fixture", "exec"), namespace)
    namespace["time"] = types.SimpleNamespace(time=lambda: NOW)
    return namespace


def point(expected, value="1", name="landing", metric="probe_success"):
    return {"metric": {"__name__": metric, **expected[name]}, "value": [NOW, str(value)]}


def target(expected, **overrides):
    result = {"labels": expected["landing"], "scrapePool": "dragontools-blackbox",
              "scrapeUrl": "http://127.0.0.1:9115/probe?" + urllib.parse.urlencode({"module": "http_2xx", "target": expected["landing"]["target"]}),
              "discoveredLabels": {"__scrape_interval__": "30s", "__scrape_timeout__": "5s"},
              "health": "up", "lastError": "", "lastScrape": datetime.datetime.fromtimestamp(NOW - 2, datetime.timezone.utc).isoformat()}
    result.update(overrides)
    return result


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.n = load()
        self.expected = self.n["definitions"](PROBES)

    def query_values(self, success="1", age=2, up="1"):
        def query(expression):
            metric = "up" if "up{" in expression else "probe_success"
            value = NOW - age if expression.startswith("timestamp(") else up if metric == "up" else success
            return [point(self.expected, value, metric=metric)]
        self.n["query"] = query

    def test_target_failure_is_valid_fresh_telemetry(self):
        for value, state in [("1", "healthy"), ("0", "unhealthy")]:
            self.query_values(success=value)
            self.assertEqual(self.n["stored_states"](self.expected), {"landing": state})

    def test_missing_stale_or_future_samples_are_unknown(self):
        for age in (91, -6):
            self.query_values(age=age)
            self.assertEqual(self.n["stored_states"](self.expected)["landing"], "unknown")
        self.n["query"] = lambda _: []
        self.assertEqual(self.n["stored_states"](self.expected)["landing"], "unknown")

    def test_status_requires_recent_successful_scraping_not_only_a_previous_probe(self):
        self.query_values(success="1", up="0")
        self.assertEqual(self.n["stored_states"](self.expected, check_up=True)["landing"], "unknown")
        self.query_values(success="0", up="1")
        self.assertEqual(self.n["stored_states"](self.expected, check_up=True)["landing"], "unhealthy")

    def test_invalid_values_duplicate_labels_and_non_finite_samples_fail(self):
        for value in ("2", "-1", "NaN", "Inf"):
            self.query_values(success=value)
            with self.assertRaises(ValueError):
                self.n["stored_states"](self.expected)
        row = point(self.expected)
        with self.assertRaises(ValueError):
            self.n["sample_map"]([row, row], self.expected)
        row["value"] = [NOW, 1]
        with self.assertRaises(ValueError):
            self.n["sample_map"]([row], self.expected)

    def test_removed_target_samples_cannot_satisfy_a_new_definition(self):
        row = point(self.expected)
        row["metric"]["target"] = "https://old.example/healthz"
        self.assertEqual(self.n["sample_map"]([row], self.expected), {})

    def test_recent_removed_target_history_can_exceed_the_configured_probe_limit(self):
        rows = [point(self.expected)]
        for index in range(128):
            row = point(self.expected)
            row["metric"]["target"] = f"https://old.example/{index}"
            rows.append(row)
        self.n["json_response"] = lambda _: {"resultType": "vector", "result": rows}
        actual = self.n["query"]('last_over_time(probe_success[90s])')
        self.assertEqual(self.n["sample_map"](actual, self.expected), {"landing": 1.0})
        self.n["json_response"] = lambda _: {"resultType": "vector", "result": rows * 32}
        with self.assertRaises(ValueError):
            self.n["query"]('last_over_time(probe_success[90s])')

    def test_loaded_target_checks_module_url_identity_and_periods(self):
        good = target(self.expected)
        self.n["json_response"] = lambda _: {"activeTargets": [good]}
        self.assertTrue(self.n["targets_loaded"](self.expected, True))
        for altered in [target(self.expected, scrapePool="other"), target(self.expected, scrapeUrl="http://0.0.0.0:9115/probe"),
                        target(self.expected, discoveredLabels={"__scrape_interval__": "5m", "__scrape_timeout__": "5s"}),
                        target(self.expected, scrapeUrl=good["scrapeUrl"].replace("http_2xx", "tcp_connect"))]:
            self.n["json_response"] = lambda _, item=altered: {"activeTargets": [item]}
            with self.assertRaises(self.n["NotReady"]):
                self.n["targets_loaded"](self.expected, False)

    def test_unavailable_blackbox_is_monitoring_failure(self):
        self.n["json_response"] = lambda _: {"activeTargets": [target(self.expected, health="down", lastError="private remote failure")]}
        with self.assertRaises(self.n["NotReady"]):
            self.n["targets_loaded"](self.expected, True)
        self.assertTrue(self.n["targets_loaded"](self.expected, False))

    def test_readiness_requires_successful_reload_and_ready_api(self):
        self.n["targets_loaded"] = lambda *_args, **_kwargs: True
        self.n["loaded_policy"] = lambda _: None
        self.n["request"] = lambda path: b"OK" if path == "/ready" else b"vm_promscrape_config_last_reload_successful 0\n"
        with self.assertRaises(self.n["NotReady"]):
            self.n["scraper_ready"](self.expected)
        self.n["request"] = lambda path: b"OK" if path == "/ready" else b"vm_promscrape_config_last_reload_successful 1\n"
        self.n["scraper_ready"](self.expected)

    def test_same_targets_cannot_hide_a_stale_loaded_metric_policy(self):
        # Captured from an actual local yaml.v2 v2.4.0 Marshal invocation using
        # the v1.151.0 relevant Config/RelabelConfig tags and custom regex marshaler.
        # This fixture deliberately does not reuse the implementation constant.
        config = (ROOT / "tests/fixtures/victoriametrics-v1.151.0-loaded-scrape.yml").read_text()
        self.n["json_response"] = lambda _: {"yaml": config}
        self.n["loaded_policy"](self.expected)
        for altered in (config.replace("action: keep", "action: drop"),
                        config.replace("- phase\n", "- fingerprint\n"),
                        config.replace("replacement: 127.0.0.1:9115", "replacement: localhost:9115"),
                        config + "  honor_labels: true\n",
                        config + "- job_name: extra\n"):
            self.n["json_response"] = lambda _, value=altered: {"yaml": value}
            with self.assertRaises(self.n["NotReady"]):
                self.n["loaded_policy"](self.expected)
        self.n["json_response"] = lambda _: {"yaml": "global:\n  scrape_interval: 30s\n  scrape_timeout: 5s\n"}
        self.n["loaded_policy"]({})
        self.n["json_response"] = lambda _: {"yaml": config}
        with self.assertRaises(self.n["NotReady"]):
            self.n["loaded_policy"]({})

    def test_http_reads_are_loopback_bounded_and_never_probe_targets(self):
        calls = []
        class Response:
            status = 200
            def read(self, count):
                self_count = count
                self_outer.assertEqual(self_count, 1024 * 1024 + 1)
                return b'{"status":"success","data":{"resultType":"vector","result":[]}}'
        self_outer = self
        class Connection:
            def __init__(self, host, port, timeout):
                calls.append((host, port, timeout))
            def request(self, method, path):
                calls.append((method, path))
            def getresponse(self):
                return Response()
            def close(self):
                pass
        with patch.object(self.n["http"].client, "HTTPConnection", Connection):
            self.n["query"]("last_over_time(probe_success[90s])")
        self.assertEqual(calls[0], ("127.0.0.1", 8428, 5))
        self.assertEqual(calls[1][0], "GET")
        self.assertTrue(calls[1][1].startswith("/api/v1/query?"))
        self.assertIn("nocache=1", calls[1][1])
        self.assertNotIn("/probe?", calls[1][1])

    def test_read_main_suppresses_failures_and_status_only_emits_enum_values(self):
        self.query_values(success="0")
        argv = ["helper", "status", "unused", base64.b64encode(json.dumps(PROBES).encode()).decode()]
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", argv), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(self.n["read_main"](), 0)
        self.assertEqual(output.getvalue(), '["unhealthy"]')
        self.assertEqual(errors.getvalue(), "")
        with patch.object(sys, "argv", ["helper", "secret malformed args"]), contextlib.redirect_stderr(errors):
            self.assertEqual(self.n["read_main"](), 1)
        self.assertEqual(errors.getvalue(), "")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.n = load()
        parent = root / "etc" / "dragontools"
        parent.parent.mkdir()
        (root / "var").mkdir()
        self.n.update(CONFIG_PARENT=str(parent), CONFIG_DIR=str(parent / "victoriametrics"),
                      CONFIG=str(parent / "victoriametrics" / "prometheus.yml"),
                      LOCK=str(parent / "victoriametrics" / ".scrape.lock"), PENDING=str(root / "var" / "pending"))
        actual_node = self.n["node"]
        def virtual_root(path, kind, missing=False):
            value = actual_node(path, kind, missing)
            if value is None:
                return None
            return types.SimpleNamespace(st_uid=0, st_gid=0, st_mode=value.st_mode, st_nlink=value.st_nlink, st_size=value.st_size)
        self.n["node"] = virtual_root
        for name in ("chown", "fchown"):
            patcher = patch.object(os, name, lambda *_args, **_kwargs: None)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.n["sync_dir"] = lambda _: None
        self.n["validate_binary"] = lambda _: None
        self.n["loaded_policy"] = lambda _: None
        self.validations = []
        def validate(argv, **kwargs):
            self.validations.append((argv, kwargs))
            self.assertIn("-promscrape.config.dryRun", argv)
            self.assertEqual(kwargs["timeout"], 15)
            return types.SimpleNamespace(returncode=0)
        self.n["subprocess"] = types.SimpleNamespace(run=validate, DEVNULL=-3)
        self.config = "# Managed by DragonTools\nglobal:\n  scrape_interval: 30s\nscrape_configs: []\n"

    def test_first_install_reload_finalization_then_noop(self):
        self.assertTrue(self.n["prepare_config"](self.config, "pin"))
        self.assertTrue(Path(self.n["PENDING"]).exists())
        calls = []
        self.n["request"] = lambda path, method="GET": (calls.append((method, path)) or b"") if path == "/-/reload" else b"OK"
        self.assertTrue(self.n["reconcile_config"](self.config, {}))
        self.assertEqual(calls, [("POST", "/-/reload")])
        self.assertTrue(Path(self.n["PENDING"]).exists())
        self.n["finalize_config"](self.config)
        self.assertFalse(Path(self.n["PENDING"]).exists())
        before = Path(self.n["CONFIG"]).stat().st_mtime_ns
        self.n["targets_loaded"] = lambda *_args, **_kwargs: True
        self.n["config_reloaded"] = lambda: None
        self.assertFalse(self.n["prepare_config"](self.config, "pin"))
        self.assertFalse(self.n["reconcile_config"](self.config, {}))
        self.assertEqual(Path(self.n["CONFIG"]).stat().st_mtime_ns, before)
        self.assertEqual(len(self.validations), 1)
        self.assertEqual(len(calls), 1)

    def test_restart_intent_is_never_used_for_probe_add_or_remove(self):
        self.n["prepare_config"](self.config, "pin")
        self.n["finalize_config"](self.config)
        for suffix in ("# added probe\n", "# removed probe\n"):
            updated = self.config + suffix
            self.assertTrue(self.n["prepare_config"](updated, "pin"))
            self.assertEqual(Path(self.n["CONFIG"]).read_text(), updated)
            self.assertTrue(Path(self.n["PENDING"]).exists())
            self.n["finalize_config"](updated)
        self.assertNotIn("systemctl", MUTATE)
        self.assertNotIn("restart-required", READ + MUTATE)

    def test_publication_records_intent_before_replacement(self):
        replace = os.replace
        def checked_replace(source, target):
            self.assertTrue(Path(self.n["PENDING"]).exists())
            self.assertEqual(Path(source).read_text(), self.config)
            replace(source, target)
        with patch.object(os, "replace", checked_replace):
            self.n["prepare_config"](self.config, "pin")

    def test_dry_run_and_binary_failures_leave_current_file_and_intent_untouched(self):
        self.n["prepare_config"](self.config, "pin")
        self.n["finalize_config"](self.config)
        self.n["subprocess"].run = lambda *_args, **_kwargs: types.SimpleNamespace(returncode=1)
        with self.assertRaises(ValueError):
            self.n["prepare_config"](self.config + "# change\n", "pin")
        self.assertEqual(Path(self.n["CONFIG"]).read_text(), self.config)
        self.assertFalse(Path(self.n["PENDING"]).exists())
        def invalid(_):
            raise ValueError("checksum mismatch")
        self.n["validate_binary"] = invalid
        with self.assertRaises(ValueError):
            self.n["prepare_config"](self.config + "# change\n", "pin")
        self.assertEqual(Path(self.n["CONFIG"]).read_text(), self.config)

    def test_foreign_config_and_symlinks_are_preserved(self):
        Path(self.n["CONFIG_DIR"]).mkdir(parents=True)
        path = Path(self.n["CONFIG"])
        path.write_text("foreign config\n")
        with self.assertRaises(ValueError):
            self.n["prepare_config"](self.config, "pin")
        self.assertEqual(path.read_text(), "foreign config\n")
        path.unlink()
        path.symlink_to("missing")
        with self.assertRaises(ValueError):
            self.n["prepare_config"](self.config, "pin")
        self.assertTrue(path.is_symlink())

    def test_metadata_repair_does_not_request_reload(self):
        self.n["prepare_config"](self.config, "pin")
        self.n["finalize_config"](self.config)
        os.chmod(self.n["CONFIG"], 0o600)
        self.assertTrue(self.n["prepare_config"](self.config, "pin"))
        self.assertFalse(Path(self.n["PENDING"]).exists())
        self.assertEqual(len(self.validations), 1)
        self.assertEqual(stat.S_IMODE(os.stat(self.n["CONFIG"]).st_mode), 0o644)

    def test_actual_stale_loaded_definitions_are_reloaded_and_failure_preserves_intent(self):
        self.n["prepare_config"](self.config, "pin")
        self.n["finalize_config"](self.config)
        def not_ready(*_args, **_kwargs):
            raise self.n["NotReady"]()
        self.n["targets_loaded"] = not_ready
        self.n["request"] = not_ready
        with self.assertRaises(self.n["NotReady"]):
            self.n["reconcile_config"](self.config, {})
        self.assertTrue(Path(self.n["PENDING"]).exists())
        self.n["read_config"](self.config)
        self.assertTrue(Path(self.n["PENDING"]).exists())

    def test_failed_reload_gauge_is_reconciled_even_when_target_definitions_match(self):
        self.n["prepare_config"](self.config, "pin")
        self.n["finalize_config"](self.config)
        self.n["targets_loaded"] = lambda *_args, **_kwargs: True
        calls = []
        def request(path, method="GET"):
            calls.append((method, path))
            return b"vm_promscrape_config_last_reload_successful 0\n" if path == "/metrics" else b""
        self.n["request"] = request
        self.assertTrue(self.n["reconcile_config"](self.config, {}))
        self.assertIn(("POST", "/-/reload"), calls)
        self.assertTrue(Path(self.n["PENDING"]).exists())

    def test_stale_same_target_policy_is_reloaded_and_retains_intent_until_verified(self):
        self.n["prepare_config"](self.config, "pin")
        self.n["finalize_config"](self.config)
        self.n["targets_loaded"] = lambda *_args, **_kwargs: True
        self.n["config_reloaded"] = lambda: None
        def stale_policy(_):
            raise self.n["NotReady"]()
        self.n["loaded_policy"] = stale_policy
        calls = []
        self.n["request"] = lambda path, method="GET": calls.append((method, path)) or b"OK"
        self.assertTrue(self.n["reconcile_config"](self.config, {}))
        self.assertEqual(calls, [("POST", "/-/reload")])
        self.assertTrue(Path(self.n["PENDING"]).exists())


if __name__ == "__main__":
    unittest.main()
