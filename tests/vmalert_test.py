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
        ("ErrorBurst", "_time:5m level:in(error) | stats by (application, environment, host, service) count() as errors | filter errors:>=5", 0,
         "warning", "victorialogs", "Error burst from service {{ $labels.service }}",
         "Structured error events in the evaluation window: {{ $value }}."),
        ("CriticalLogEvent", "_time:1m level:in(critical,fatal) | stats by (application, environment, host, service) count() as events | filter events:>=1", 0,
         "critical", "victorialogs", "Critical or fatal event from service {{ $labels.service }}",
         "Structured critical or fatal events in the evaluation window: {{ $value }}."),
    ]
    rules = []
    for name, query, duration, severity, source, summary, description in definitions:
        rules.append(dict(name=name, query=query, duration=duration, type="alerting", datasourceType=datasource,
                          file=file, keep_firing_for=0, labels=dict(severity=severity, source=source, managed_by="dragontools"),
                          annotations=dict(summary=summary, description=description), health="ok", lastError="",
                          lastEvaluation=datetime.datetime.fromtimestamp(NOW - 10, datetime.timezone.utc).isoformat(),
                          state="inactive"))
    result = dict(status="success", data=dict(groups=[dict(name="dragontools-probes" if kind == "metrics" else "dragontools-logs",
                file=file, type=datasource, interval=30 if kind == "metrics" else 60, rules=rules)]))

    if kind == "metrics":
        group = dict(name="dragontools-hosts", file=file, type=datasource, interval=30, rules=[])
        rows = [
            ("CPUHigh", '100 * (1 - avg by (application, environment, host) (rate(host_cpu_seconds_total{agent="vector",mode="idle"}[5m]))) > 90', 600, "warning", "High CPU on {{ $labels.host }}", "CPU utilization is above the managed host threshold."),
            ("MemoryPressure", '100 * (1 - host_memory_available_bytes{agent="vector"} / host_memory_total_bytes{agent="vector"}) > 90', 300, "warning", "Memory pressure on {{ $labels.host }}", "Available host memory is below the managed threshold."),
            ("DiskWarning", '100 * host_filesystem_used_ratio{agent="vector"} >= 70', 300, "warning", "Disk warning on {{ $labels.host }}", "Filesystem {{ $labels.mountpoint }} is above the warning threshold."),
            ("DiskCritical", '100 * host_filesystem_used_ratio{agent="vector"} >= 80', 300, "critical", "Disk critical on {{ $labels.host }}", "Filesystem {{ $labels.mountpoint }} is above the critical threshold."),
            ("InodesCritical", '(100 * host_filesystem_inodes_used_ratio{agent="vector"} >= 90) and (host_filesystem_inodes_total{agent="vector"} > 0)', 300, "critical", "Inodes critical on {{ $labels.host }}", "Filesystem {{ $labels.mountpoint }} is above the inode threshold."),
        ]
        for name, query, duration, severity, summary, description in rows:
            rule = copy.deepcopy(rules[0])
            rule.update(name=name, query=query, duration=duration, labels=dict(severity=severity, source="vector", managed_by="dragontools"), annotations=dict(summary=summary, description=description))
            group["rules"].append(rule)
        result["data"]["groups"].append(group)
    return result


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

    def test_verified_host_rules_require_exact_contract_and_healthy_evaluation(self):
        value = fixture()
        value["data"]["groups"].reverse()
        helper.validate(value, "metrics", NOW)
        for changes in ({"query": "node_memory_available_bytes > 0"}, {"duration": 0}, {"labels": {"source": "vector", "severity": "info"}}):
            value = fixture()
            value["data"]["groups"][1]["rules"][0].update(changes)
            with self.assertRaises(ValueError):
                helper.validate(value, "metrics", NOW)
        value = fixture()
        value["data"]["groups"][1]["rules"][0]["health"] = "unknown"
        with self.assertRaises(helper.NotReady):
            helper.validate(value, "metrics", NOW)
        for missing in (0, 1):
            value = fixture()
            value["data"]["groups"].pop(missing)
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
