"""Local fixtures for the opt-in read-only integration observer; no SSH or probes."""
import datetime
from pathlib import Path
import runpy
import unittest
import urllib.parse


SCRIPT = runpy.run_path(str(Path(__file__).parent / "integration/run_blackbox.py"))["REMOTE"]


class ObserveTest(unittest.TestCase):
    def setUp(self):
        self.namespace = {"__name__": "fixture"}
        exec(compile(SCRIPT, "probe-observer", "exec"), self.namespace)
        self.now = 1800000000
        self.value = 0
        self.stamp = self.now - 10
        self.calls = []
        iso = lambda stamp: datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat()
        self.rule = {
            "name": "ServiceProbeFailed",
            "query": 'probe_success{job="dragontools-blackbox"} == 0',
            "duration": 120,
            "labels": {"severity": "critical", "source": "blackbox"},
            "health": "ok",
            "lastError": "",
            "lastEvaluation": iso(self.now - 20),
            "alerts": [{"state": "firing", "activeAt": iso(self.now - 150), "labels": {
                "probe": "controlled-down", "target": "https://example.com/healthz",
                "severity": "critical", "source": "blackbox",
            }}],
        }
        self.namespace["get_json"] = self.response

    def response(self, port, path):
        self.calls.append((port, path))
        if port == 8881:
            self.assertEqual(path, "/api/v1/rules")
            return {"status": "success", "data": {"groups": [{"name": "dragontools-probes", "rules": [self.rule]}]}}
        self.assertEqual(port, 8428)
        self.assertTrue(path.startswith("/api/v1/query?"))
        expression = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)["query"][0]
        selector = 'probe_success{job="dragontools-blackbox",probe="controlled-down"}[90s]'
        self.assertIn(expression, ["last_over_time(" + selector + ")", "timestamp(" + selector + ")"])
        value = self.stamp if expression.startswith("timestamp(") else self.value
        return {"status": "success", "data": {"resultType": "vector", "result": [{
            "metric": {"probe": "controlled-down", "instance": "controlled-down", "job": "dragontools-blackbox", "target": "https://example.com/healthz"},
            "value": [self.now, str(value)],
        }]}}

    def observe(self):
        return self.namespace["observe"]("controlled-down", self.now)

    def test_failed_telemetry_and_firing_alert_succeed_without_target_requests(self):
        self.assertTrue(self.observe())
        self.assertEqual(len(self.calls), 3)

    def test_healthy_or_stale_sample_is_not_failure_evidence(self):
        self.value = 1
        self.assertFalse(self.observe())
        self.value = 0
        self.stamp = self.now - 91
        self.assertFalse(self.observe())
        self.assertTrue(all(port == 8428 for port, _ in self.calls))

    def test_pending_or_insufficient_hold_is_not_firing_evidence(self):
        self.rule["alerts"][0]["state"] = "pending"
        self.assertFalse(self.observe())
        self.rule["alerts"][0]["state"] = "firing"
        self.rule["alerts"][0]["activeAt"] = datetime.datetime.fromtimestamp(self.now - 119, datetime.timezone.utc).isoformat()
        self.assertFalse(self.observe())

    def test_wrong_rule_or_identity_fails(self):
        self.rule["duration"] = 0
        with self.assertRaises(ValueError):
            self.observe()
        self.rule["duration"] = 120
        self.rule["alerts"][0]["labels"]["target"] = "https://other.example.com/"
        with self.assertRaises(ValueError):
            self.observe()


if __name__ == "__main__":
    unittest.main()
