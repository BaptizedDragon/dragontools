"""Read-only LogsQL reachability under Grafana's UID; no log values escape.

Official API: https://docs.victoriametrics.com/victorialogs/querying/
The bounded fields projection avoids retrieving application messages. This direct
backend check is separate from the authenticated Grafana plugin query.
"""
import http.client
import json
import sys
import urllib.parse

PARAMETERS = {"query": "* | fields _time", "limit": "1", "start": "-5m", "end": "now", "timeout": "4s"}


def validate(body):
    rows = body.splitlines()
    if len(rows) > 1:
        raise ValueError("Unexpected LogsQL response")
    for line in rows:
        row = json.loads(line)
        if not isinstance(row, dict) or set(row) != {"_time"} or not isinstance(row["_time"], str) or not row["_time"]:
            raise ValueError("Unexpected LogsQL response")


def main():
    connection = http.client.HTTPConnection("127.0.0.1", 9428, timeout=5)
    try:
        connection.request("GET", "/select/logsql/query?" + urllib.parse.urlencode(PARAMETERS))
        response = connection.getresponse()
        if response.status in (500, 502, 503, 504):
            return 75
        if response.status != 200:
            return 1
        body = response.read(4097)
        if len(body) > 4096:
            return 1
        validate(body)
        return 0
    except (OSError, http.client.HTTPException):
        return 75
    except Exception:
        return 1
    finally:
        connection.close()


if __name__ == "__main__":
    sys.exit(main())
