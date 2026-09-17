"""Read-only pinned vmalert v1.152.0 rule API verification, no notifications.

Schema: app/vmalert/rule/web.go and app/vmalert/web.go at that exact tag.
Exclude alert instances so arbitrary target/log labels never leave the evaluator.
"""
import datetime
import http.client
import json
import sys
import time


class NotReady(Exception):
    pass


def require(condition):
    if not condition:
        raise ValueError("vmalert rule policy mismatch")


def validate(value, kind, now=None):
    now = time.time() if now is None else now
    require(kind in ("logs", "metrics"))
    require(isinstance(value, dict) and value.get("status") == "success")
    groups = value.get("data", {}).get("groups")
    require(isinstance(groups, list))
    if not groups:
        raise NotReady()
    expected_groups = {"dragontools-logs"} if kind == "logs" else {"dragontools-probes", "dragontools-hosts"}
    applications = {}
    for manifest in app_all() if "app_all" in globals() else []:
        app_config = manifest["config"]
        file = APP_ROOT + "/" + app_config["application"] + "/" + kind + ".rules.yml"
        for group in json.loads(app_documents(app_config)[kind + ".rules.yml"])["groups"]:
            applications[group["name"]] = (file, group)
    require(len(groups) == len(expected_groups) + len(applications))
    require(all(isinstance(group, dict) for group in groups))
    require({group.get("name") for group in groups} == expected_groups | set(applications))
    file = "/etc/dragontools/vmalert-" + kind + "/rules.yml"
    datasource = "vlogs" if kind == "logs" else "prometheus"
    for group in groups:
        if group["name"] in applications:
            app_file, expected = applications[group["name"]]
            validate_application_group(group, app_file, expected, now)
        else:
            validate_group(group, kind, file, datasource, now)


def validate_group(group, kind, file, datasource, now):
    require(group.get("file") == file and group.get("type") == datasource)
    require(group.get("interval") == (60 if kind == "logs" else 30))
    require(not group.get("params") and not group.get("headers") and not group.get("notifier_headers") and not group.get("labels"))
    expected = {
        "ServiceProbeFailed": ('probe_success{job="dragontools-blackbox"} == 0', 120, "critical", "blackbox"),
    } if group["name"] == "dragontools-probes" else {
        "CPUHigh": ('100 * (1 - avg by (application, environment, host) (rate(host_cpu_seconds_total{agent="vector",mode="idle"}[5m]))) > 90', 600, "warning", "vector"),
        "MemoryPressure": ('100 * (1 - host_memory_available_bytes{agent="vector"} / host_memory_total_bytes{agent="vector"}) > 90', 300, "warning", "vector"),
        "DiskWarning": ('100 * host_filesystem_used_ratio{agent="vector"} >= 70', 300, "warning", "vector"),
        "DiskCritical": ('100 * host_filesystem_used_ratio{agent="vector"} >= 80', 300, "critical", "vector"),
        "InodesCritical": ('(100 * host_filesystem_inodes_used_ratio{agent="vector"} >= 90) and (host_filesystem_inodes_total{agent="vector"} > 0)', 300, "critical", "vector"),
    } if group["name"] == "dragontools-hosts" else {
        "ErrorBurst": ("_time:5m level:in(error) | stats by (application, environment, host, service) count() as errors | filter errors:>=5", 0, "warning", "victorialogs"),
        "CriticalLogEvent": ("_time:1m level:in(critical,fatal) | stats by (application, environment, host, service) count() as events | filter events:>=1", 0, "critical", "victorialogs"),
    }
    annotations = {
        "ServiceProbeFailed": {"summary": "HTTP probe {{ $labels.probe }} is failing", "description": "Target {{ $labels.target }} has failed HTTP/HTTPS availability checks for two minutes."},
        "ErrorBurst": {"summary": "Error burst from service {{ $labels.service }}", "description": "Structured error events in the evaluation window: {{ $value }}."},
        "CriticalLogEvent": {"summary": "Critical or fatal event from service {{ $labels.service }}", "description": "Structured critical or fatal events in the evaluation window: {{ $value }}."},
    }
    annotations.update({
        "CPUHigh": {"summary": "High CPU on {{ $labels.host }}", "description": "CPU utilization is above the managed host threshold."},
        "MemoryPressure": {"summary": "Memory pressure on {{ $labels.host }}", "description": "Available host memory is below the managed threshold."},
        "DiskWarning": {"summary": "Disk warning on {{ $labels.host }}", "description": "Filesystem {{ $labels.mountpoint }} is above the warning threshold."},
        "DiskCritical": {"summary": "Disk critical on {{ $labels.host }}", "description": "Filesystem {{ $labels.mountpoint }} is above the critical threshold."},
        "InodesCritical": {"summary": "Inodes critical on {{ $labels.host }}", "description": "Filesystem {{ $labels.mountpoint }} is above the inode threshold."},
    })
    rules = group.get("rules")
    require(isinstance(rules, list) and len(rules) == len(expected))
    seen = set()
    for rule in rules:
        require(isinstance(rule, dict) and rule.get("name") in expected and rule["name"] not in seen)
        seen.add(rule["name"])
        query, duration, severity, source = expected[rule["name"]]
        require(rule.get("query", "").strip() == query and rule.get("duration") == duration)
        require(rule.get("type") == "alerting" and rule.get("datasourceType") == datasource)
        require(rule.get("file") == file and rule.get("keep_firing_for", 0) == 0)
        require(rule.get("labels") == {"severity": severity, "source": source, "managed_by": "dragontools"})
        require(rule.get("annotations") == annotations[rule["name"]])
        require(not rule.get("debug"))
        health = rule.get("health")
        require(health in ("ok", "err", "unknown"))
        if health != "ok" or rule.get("lastError"):
            raise NotReady()
        stamp = rule.get("lastEvaluation")
        require(isinstance(stamp, str))
        if stamp.startswith("0001-"):
            raise NotReady()
        evaluated = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
        if not -5 <= now - evaluated <= 120:
            raise NotReady()
        # Pending/firing is valid monitoring state, never an install failure.
        require(rule.get("state") in ("inactive", "pending", "firing"))



def validate_application_group(group, file, expected, now):
    require(group.get("file") == file and group.get("type") == expected["type"] and group.get("interval") == 30)
    require(not group.get("params") and not group.get("headers") and not group.get("notifier_headers") and not group.get("labels"))
    actual = group.get("rules")
    require(isinstance(actual, list) and len(actual) == len(expected["rules"]))
    # Same default alert name is valid for distinct probe label sets.
    wanted = {(rule["alert"], json.dumps(rule["labels"], sort_keys=True)): rule for rule in expected["rules"]}
    seen = set()
    for rule in actual:
        require(isinstance(rule, dict))
        key = (rule.get("name"), json.dumps(rule.get("labels"), sort_keys=True))
        require(key in wanted and key not in seen)
        seen.add(key)
        spec = wanted[key]
        require(rule.get("query", "").strip() == spec["expr"])
        require(rule.get("duration") == (app_duration(spec["for"]) if "for" in spec else 0))
        require(rule.get("type") == "alerting" and rule.get("datasourceType") == expected["type"] and rule.get("file") == file)
        require(rule.get("annotations") == spec["annotations"] and rule.get("keep_firing_for", 0) == 0 and not rule.get("debug"))
        health = rule.get("health")
        require(health in ("ok", "err", "unknown"))
        if health != "ok" or rule.get("lastError"):
            raise NotReady()
        stamp = rule.get("lastEvaluation")
        require(isinstance(stamp, str))
        if stamp.startswith("0001-"):
            raise NotReady()
        evaluated = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
        if not -5 <= now - evaluated <= 120:
            raise NotReady()
        require(rule.get("state") in ("inactive", "pending", "firing"))

def main():
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ("logs", "metrics"))
        kind = sys.argv[1]
        connection = http.client.HTTPConnection("127.0.0.1", 8880 if kind == "logs" else 8881, timeout=5)
        try:
            connection.request("GET", "/api/v1/rules?exclude_alerts=true")
            response = connection.getresponse()
            if response.status in (500, 502, 503, 504):
                raise NotReady()
            require(response.status == 200)
            body = response.read(1048577)
            require(len(body) <= 1048576)
            validate(json.loads(body), kind)
        finally:
            connection.close()
        return 0
    except (NotReady, OSError, http.client.HTTPException):
        return 75
    except Exception:
        return 1


if __name__ == "__main__":
    sys.exit(main())
