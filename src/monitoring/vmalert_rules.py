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
    require(len(groups) == 1 and isinstance(groups[0], dict))
    group = groups[0]
    file = "/etc/dragontools/vmalert-" + kind + "/rules.yml"
    datasource = "vlogs" if kind == "logs" else "prometheus"
    require(group.get("name") == ("dragontools-logs" if kind == "logs" else "dragontools-probes"))
    require(group.get("file") == file and group.get("type") == datasource)
    require(group.get("interval") == (60 if kind == "logs" else 30))
    require(not group.get("params") and not group.get("headers") and not group.get("notifier_headers") and not group.get("labels"))
    expected = {
        "ServiceProbeFailed": ('probe_success{job="dragontools-blackbox"} == 0', 120, "critical", "blackbox"),
    } if kind == "metrics" else {
        "ErrorBurst": ("_time:5m level:in(error) | stats by (service) count() as errors | filter errors:>=5", 0, "warning", "victorialogs"),
        "CriticalLogEvent": ("_time:1m level:in(critical,fatal) | stats by (service) count() as events | filter events:>=1", 0, "critical", "victorialogs"),
    }
    annotations = {
        "ServiceProbeFailed": {"summary": "HTTP probe {{ $labels.probe }} is failing", "description": "Target {{ $labels.target }} has failed HTTP/HTTPS availability checks for two minutes."},
        "ErrorBurst": {"summary": "Error burst from service {{ $labels.service }}", "description": "Structured error events in the evaluation window: {{ $value }}."},
        "CriticalLogEvent": {"summary": "Critical or fatal event from service {{ $labels.service }}", "description": "Structured critical or fatal events in the evaluation window: {{ $value }}."},
    }
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
        require(rule.get("labels") == {"severity": severity, "source": source})
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
