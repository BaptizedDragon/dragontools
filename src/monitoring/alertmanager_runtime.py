"""Concrete Alertmanager API probes. Read-only except explicit notify mode."""
import datetime
import http.client
import json
import os
import stat
import sys

CONFIG = "/etc/dragontools/alertmanager/alertmanager.yml"


def require(ok):
    if not ok:
        raise ValueError("Alertmanager policy mismatch")


def configured(disabled, enabled):
    fd = os.open(CONFIG, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == 0 and st.st_gid == 0 and stat.S_IMODE(st.st_mode) == 0o644)
        data = os.read(fd, 65537).decode()
        require(data in (disabled, enabled))
        return data == enabled
    finally:
        os.close(fd)


def request(method, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", 9093, timeout=5)
    try:
        conn.request(method, path, body=None if body is None else json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        response = conn.getresponse()
        data = response.read(1048577)
        require(len(data) <= 1048576)
        if response.status in (500, 502, 503, 504):
            raise ConnectionError("not ready")
        require(response.status == 200)
        return json.loads(data) if data else None
    finally:
        conn.close()


def health(enabled):
    status = request("GET", "/api/v2/status")
    require(status["versionInfo"]["version"] == "0.34.1")
    require(status["cluster"]["status"] == "disabled")
    receivers = request("GET", "/api/v2/receivers")
    require({v["name"] for v in receivers} == ({"discard", "telegram", "telegram-host-events"} if enabled else {"discard"}))
    original = status["config"]["original"]
    # Upstream serializes defaults into its status configuration; compare the
    # unique generated receiver contract without ever returning the raw config.
    require("bot_token:" not in original and "chat_id:" not in original)
    require(("telegram_configs:" in original) == enabled)
    if enabled:
        require("bot_token_file: /etc/dragontools/alertmanager/secrets/telegram-bot-token" in original)
        require("chat_id_file: /etc/dragontools/alertmanager/secrets/telegram-chat-id" in original)
        require('severity=~"warning|critical"' in original)
        require('parse_mode: HTML' in original and 'send_resolved: true' in original)
        require('/etc/dragontools/alertmanager/templates/telegram.tmpl' in original)
        require('dragontools.telegram.message' in original)
        require('send_resolved: false' in original and 'host-maintenance' in original and 'event_id' in original)


def notify():
    now = datetime.datetime.now(datetime.timezone.utc)
    end = now + datetime.timedelta(minutes=5)
    request("POST", "/api/v2/alerts", [{
        "labels": {"alertname": "DragonToolsNotificationTest", "severity": "critical", "source": "dragontools-test",
                   "probe": "notification-test-" + now.strftime("%Y%m%d%H%M%S%f")},
        "annotations": {"summary": "DragonTools explicit notification test", "description": "This is an operator-requested notification test."},
        "startsAt": now.isoformat(), "endsAt": end.isoformat(),
    }])


def main():
    try:
        require(len(sys.argv) == 4 and sys.argv[1] in ("check", "health", "notify"))
        enabled = configured(sys.argv[2], sys.argv[3])
        if sys.argv[1] == "check":
            sys.stdout.write("enabled" if enabled else "disabled")
        else:
            health(enabled)
            if sys.argv[1] == "notify":
                require(enabled)
                notify()
        return 0
    except (OSError, http.client.HTTPException):
        return 75
    except Exception:
        return 1


if __name__ == "__main__":
    sys.exit(main())
