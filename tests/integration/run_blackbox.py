#!/usr/bin/env python3
"""Observe an already-installed failed probe and its existing alert, read-only.

No target, rule, service or notification is created. Existing live evaluators may
independently notify configured receivers. Use only a supported disposable host.
"""
import argparse
import re
import shlex
import subprocess
import sys
import time


REMOTE = r'''
import datetime
import http.client
import json
import math
import sys
import time
import urllib.parse

def get_json(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=4)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        if response.status != 200:
            raise OSError()
        body = response.read(1048577)
        if len(body) > 1048576:
            raise ValueError()
        return json.loads(body)
    finally:
        connection.close()

def sample(expression, probe):
    path = "/api/v1/query?" + urllib.parse.urlencode({"query": expression, "nocache": "1", "timeout": "3s"})
    body = get_json(8428, path)
    if body.get("status") != "success" or body.get("data", {}).get("resultType") != "vector":
        raise ValueError()
    values = body["data"]["result"]
    if not values:
        return None
    if len(values) != 1:
        raise ValueError()
    metric = values[0]["metric"]
    if metric.get("probe") != probe or metric.get("instance") != probe or metric.get("job") != "dragontools-blackbox" or not metric.get("target"):
        raise ValueError()
    value = float(values[0]["value"][1])
    if not math.isfinite(value):
        raise ValueError()
    return value, metric["target"]

def observe(probe, now):
    selector = 'probe_success{job="dragontools-blackbox",probe=' + json.dumps(probe) + '}[90s]'
    value = sample("last_over_time(" + selector + ")", probe)
    stamp = sample("timestamp(" + selector + ")", probe)
    if value is None or stamp is None:
        return False
    if value[0] not in (0, 1) or value[1] != stamp[1]:
        raise ValueError()
    if value[0] != 0 or not -5 <= now - stamp[0] <= 90:
        return False
    body = get_json(8881, "/api/v1/rules")
    if body.get("status") != "success":
        raise ValueError()
    rules = [rule for group in body["data"]["groups"] if group.get("name") == "dragontools-probes" for rule in group["rules"] if rule.get("name") == "ServiceProbeFailed"]
    if len(rules) != 1:
        raise ValueError()
    rule = rules[0]
    if rule.get("query") != 'probe_success{job="dragontools-blackbox"} == 0' or rule.get("duration") != 120 or rule.get("labels") != {"severity": "critical", "source": "blackbox"}:
        raise ValueError()
    if rule.get("health") != "ok" or rule.get("lastError"):
        return False
    evaluated = datetime.datetime.fromisoformat(rule["lastEvaluation"].replace("Z", "+00:00")).timestamp()
    if not -5 <= now - evaluated <= 90:
        return False
    alerts = [alert for alert in rule.get("alerts", []) if alert.get("labels", {}).get("probe") == probe]
    if not alerts:
        return False
    if len(alerts) != 1:
        raise ValueError()
    alert = alerts[0]
    labels = alert["labels"]
    if labels.get("target") != value[1] or labels.get("severity") != "critical" or labels.get("source") != "blackbox":
        raise ValueError()
    active = datetime.datetime.fromisoformat(alert["activeAt"].replace("Z", "+00:00")).timestamp()
    return alert.get("state") == "firing" and now - active >= 120

if __name__ == "__main__":
    try:
        print("ready" if observe(sys.argv[1], time.time()) else "waiting")
    except (OSError, http.client.HTTPException):
        print("waiting")
    except Exception:
        sys.exit(1)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh-host", required=True, help="verified native OpenSSH alias")
    parser.add_argument("--probe", required=True, help="already-configured controlled failing probe name")
    parser.add_argument("--deadline", type=int, default=210, help="bounded observation seconds, 1..300 (default 210)")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,252}", args.ssh_host) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", args.probe) or not 1 <= args.deadline <= 300:
        parser.error("invalid observation arguments")
    command = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", args.ssh_host, shlex.join(["python3", "-I", "-B", "-c", REMOTE, args.probe])]
    deadline = time.monotonic() + args.deadline
    interval = 0.5
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print("FAIL: bounded probe/alert observation timed out.", file=sys.stderr)
            return 1
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=min(20, remaining), check=False)
        except subprocess.TimeoutExpired:
            continue
        except OSError:
            print("FAIL: read-only probe/alert observation failed.", file=sys.stderr)
            return 1
        if result.returncode or result.stdout not in (b"ready\n", b"waiting\n"):
            print("FAIL: read-only probe/alert observation failed.", file=sys.stderr)
            return 1
        if result.stdout == b"ready\n":
            print("PASS: fresh failed probe telemetry and an existing firing alert with a two-minute hold; read-only observation.")
            return 0
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
        interval = 1


if __name__ == "__main__":
    sys.exit(main())
