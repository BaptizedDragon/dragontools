#!/usr/bin/env python3
"""Read-only vmalert API fixtures, never contacts a datasource or notifier."""
import copy
import datetime
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "src/monitoring/vmalert_rules.py"
spec = importlib.util.spec_from_file_location("vmalert_rules", path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
NOW = 1_800_000_000


def fixture(kind="metrics"):
    file = f"/etc/dragontools/vmalert-{kind}/rules.yml"
    datasource = "prometheus" if kind == "metrics" else "vlogs"
    definitions = [
        ("ServiceProbeFailed", 'probe_success{job="dragontools-blackbox"} == 0', 120,
         "critical", "blackbox", "HTTP probe {{ $labels.probe }} is failing",
         "Target {{ $labels.target }} has failed HTTP/HTTPS availability checks for two minutes."),
    ] if kind == "metrics" else [
        ("ErrorBurst", "_time:5m level:in(error) | stats by (service) count() as errors | filter errors:>=5", 0,
         "warning", "victorialogs", "Error burst from service {{ $labels.service }}",
         "Structured error events in the evaluation window: {{ $value }}."),
        ("CriticalLogEvent", "_time:1m level:in(critical,fatal) | stats by (service) count() as events | filter events:>=1", 0,
         "critical", "victorialogs", "Critical or fatal event from service {{ $labels.service }}",
         "Structured critical or fatal events in the evaluation window: {{ $value }}."),
    ]
    rules = []
    for name, query, duration, severity, source, summary, description in definitions:
        rules.append(dict(name=name, query=query, duration=duration, type="alerting", datasourceType=datasource,
                          file=file, keep_firing_for=0, labels=dict(severity=severity, source=source),
                          annotations=dict(summary=summary, description=description), health="ok", lastError="",
                          lastEvaluation=datetime.datetime.fromtimestamp(NOW - 10, datetime.timezone.utc).isoformat(),
                          state="inactive"))
    return dict(status="success", data=dict(groups=[dict(name="dragontools-probes" if kind == "metrics" else "dragontools-logs",
                file=file, type=datasource, interval=30 if kind == "metrics" else 60, rules=rules)]))


class Rules(unittest.TestCase):
    def test_both_evaluators_loaded_and_evaluated(self):
        for kind in ("logs", "metrics"):
            helper.validate(fixture(kind), kind, NOW)

    def test_down_target_pending_or_firing_is_valid_station_health(self):
        for state in ("inactive", "pending", "firing"):
            value = fixture()
            value["data"]["groups"][0]["rules"][0]["state"] = state
            helper.validate(value, "metrics", NOW)

    def test_startup_and_datasource_errors_are_retryable(self):
        value = fixture()
        value["data"]["groups"] = []
        with self.assertRaises(helper.NotReady):
            helper.validate(value, "metrics", NOW)
        for changes in ({"health": "unknown"}, {"health": "err", "lastError": "PRIVATE"},
                        {"lastEvaluation": "0001-01-01T00:00:00Z"},
                        {"lastEvaluation": "2020-01-01T00:00:00Z"}):
            value = fixture()
            value["data"]["groups"][0]["rules"][0].update(changes)
            with self.assertRaises(helper.NotReady):
                helper.validate(value, "metrics", NOW)

    def test_rule_policy_mismatch_is_deterministic(self):
        for changes in ({"duration": 0}, {"query": "up == 0"}, {"datasourceType": "vlogs"},
                        {"labels": {"severity": "warning", "source": "blackbox"}},
                        {"annotations": {"summary": "foreign"}}, {"debug": True},
                        {"keep_firing_for": 600}, {"file": "/tmp/foreign.yml"}):
            value = fixture()
            value["data"]["groups"][0]["rules"][0].update(changes)
            with self.assertRaises(ValueError):
                helper.validate(value, "metrics", NOW)

    def test_group_policy_and_duplicate_rules_fail(self):
        for changes in ({"interval": 5}, {"type": "vlogs"}, {"params": {"extra_label": ["secret"]}},
                        {"headers": ["Authorization: secret"]}, {"labels": {"extra": "value"}}):
            value = fixture()
            value["data"]["groups"][0].update(changes)
            with self.assertRaises(ValueError):
                helper.validate(value, "metrics", NOW)
        value = fixture("logs")
        value["data"]["groups"][0]["rules"][1] = copy.deepcopy(value["data"]["groups"][0]["rules"][0])
        with self.assertRaises(ValueError):
            helper.validate(value, "logs", NOW)


if __name__ == "__main__":
    unittest.main()
