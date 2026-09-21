"""Pinned Grafana credential operations. Input is a private stdin pipe only.

No credential files, command-line values, logging, shell interpolation or SQLite
writes. The supported CLI owns initialization/password changes; PUT /api/user
owns username changes. Only original local administrator ID 1 is managed.

Reviewed v13.2.2: pkg/cmd/grafana-cli/commands/{commands,reset_password_command}.go,
pkg/services/sqlstore/sqlstore.go, pkg/api/user.go. Grafana API authentication may
record its own last-seen metadata; credential verify makes only GET requests.
Logs verification adds the read-only datasource health and query APIs. Reviewed
VictoriaLogs datasource v0.32.0 pkg/plugin/{datasource,query,response_logs}.go.
"""
import base64
import contextlib
import http.client
import json
import os
import resource
import sqlite3
import stat
import subprocess
import sys
import time
import urllib.parse

HOME = "/opt/dragontools/components/grafana/current"
CONFIG = "/etc/dragontools/grafana/grafana.ini"
DATA = "/var/lib/dragontools/grafana"
DATABASE = DATA + "/grafana.db"
MAX_INPUT = 100000
LOGS_UID = "dragontools-logs"
LOGS_TYPE = "victoriametrics-logs-datasource"
LOGS_VERSION = "0.32.0"
LOGS_SETTINGS = "/api/plugins/" + LOGS_TYPE + "/settings"
LOGS_HEALTH = "/api/datasources/uid/" + LOGS_UID + "/health"
LOGS_QUERY = "/api/ds/query"


class Failure(Exception):
    def __init__(self, code):
        self.code = code


def require(ok, code=81):
    if not ok:
        raise Failure(code)


def credentials(stream):
    raw = stream.read(MAX_INPUT + 1)
    require(len(raw) <= MAX_INPUT, 80)
    value = json.loads(raw)
    require(isinstance(value, dict) and set(value) == {"username", "password"}, 80)
    username, password = value["username"], value["password"]
    require(isinstance(username, str) and isinstance(password, str), 80)
    require(0 < len(username.encode("utf-8")) <= 190, 80)
    require(username == username.strip() and ":" not in username, 80)
    require(not any(ord(c) < 32 or ord(c) == 127 for c in username), 80)
    # Pinned user/password.go's default (non-strong) policy requires four bytes.
    # Validate before CLI initialization, which precedes its reset validation.
    require(4 <= len(password.encode("utf-8")) <= 16384, 80)
    require(not any(c in password for c in "\r\n\0"), 80)
    return username, password


def database_users():
    """Read selected account metadata; never select passwords, salts or tokens."""
    if not os.path.lexists(DATABASE):
        return []
    info = os.lstat(DATABASE)
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
    require(info.st_uid == os.geteuid() and info.st_gid == os.getegid())
    require(stat.S_IMODE(info.st_mode) & 0o027 == 0)
    require(not os.path.lexists(DATABASE + "-wal") and not os.path.lexists(DATABASE + "-shm"))
    if os.path.lexists(DATABASE + "-journal"):
        journal = os.lstat(DATABASE + "-journal")
        require(stat.S_ISREG(journal.st_mode) and journal.st_nlink == 1 and journal.st_uid == info.st_uid)
    uri = "file:" + urllib.parse.quote(DATABASE, safe="/") + "?mode=ro"
    with contextlib.closing(sqlite3.connect(uri, uri=True, timeout=3)) as db:
        db.execute("PRAGMA query_only=ON")
        require(db.execute("PRAGMA journal_mode").fetchone() == ("delete",))
        allowed = {"id", "login", "email", "is_admin", "is_disabled", "is_service_account"}

        def authorize(action, first, second, database, trigger):
            if action == sqlite3.SQLITE_SELECT:
                return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_READ and database == "main":
                if first == "user" and second in allowed:
                    return sqlite3.SQLITE_OK
                if first == "user_auth" and second == "user_id":
                    return sqlite3.SQLITE_OK
            return sqlite3.SQLITE_DENY

        db.set_authorizer(authorize)
        try:
            rows = db.execute('SELECT id, login, email, is_admin, is_disabled, is_service_account FROM "user" ORDER BY id').fetchall()
        except sqlite3.OperationalError as error:
            # An interrupted first CLI initialization may not have made this table.
            if str(error) == "no such table: user":
                return []
            raise
        if rows:
            # Refuse an external identity before privileged password mutation.
            external = db.execute('SELECT user_id FROM user_auth WHERE user_id = 1').fetchall()
            require(not external)
        return rows


def original_admin(rows, desired):
    admins = [row for row in rows if row[0] == 1]
    require(len(admins) == 1)
    row = admins[0]
    require(row[3] == 1 and row[4] == 0 and row[5] == 0)
    current = row[1]
    require(isinstance(current, str) and current and ":" not in current)
    require(not any(ord(c) < 32 or ord(c) == 127 for c in current))
    for other in rows:
        if other[0] != 1:
            require(desired.casefold() not in (other[1].casefold(), (other[2] or "").casefold()))
    return current


def reset(username, password, bootstrap=False):
    # A minimal environment excludes inherited GF_* overrides and proxy/loader
    # settings. Secrets exist only in the bootstrap child process environment;
    # password resets on initialized databases receive the password only on stdin.
    env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": DATA, "LANG": "C.UTF-8",
           "GF_LOG_MODE": "console", "GF_LOG_LEVEL": "error"}
    if bootstrap:
        env["GF_SECURITY_ADMIN_USER"] = username
        env["GF_SECURITY_ADMIN_PASSWORD"] = password
    argv = [HOME + "/bin/grafana", "cli", "--homepath=" + HOME,
            "--config=" + CONFIG, "admin", "reset-admin-password",
            "--password-from-stdin", "--user-id", "1"]
    try:
        result = subprocess.run(argv, input=(password + "\n").encode("utf-8"),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env=env, cwd=DATA, timeout=60, check=False)
        require(result.returncode == 0, 82)
    except (OSError, subprocess.TimeoutExpired):
        raise Failure(82) from None
    finally:
        env.clear()


def request(method, username, password, body=None, timeout=5, path="/api/user"):
    """Direct fixed loopback HTTP: no proxies, redirects, cookies or URL secrets."""
    require((method, path) in (("GET", "/api/user"), ("PUT", "/api/user"),
                              ("GET", LOGS_SETTINGS), ("GET", LOGS_HEALTH), ("POST", LOGS_QUERY)), 86)
    logs = path != "/api/user"
    failure = 86 if logs else 83
    connection = http.client.HTTPConnection("127.0.0.1", 3000, timeout=timeout)
    headers = {"Authorization": "Basic " + base64.b64encode((username + ":" + password).encode("utf-8")).decode("ascii"),
               "Accept": "application/json", "Content-Type": "application/json"}
    if logs:
        # Use the provisioned org without mutating the administrator's active org.
        headers["X-Grafana-Org-Id"] = "1"
    try:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8") if body is not None else None
        connection.request(method, path, body=encoded, headers=headers)
        response = connection.getresponse()
        data = response.read(65537)
        require(len(data) <= 65536, failure)
        if response.status == 401:
            return None
        if response.status in (500, 502, 503, 504):
            raise Failure(84)
        try:
            value = json.loads(data)
        except (ValueError, UnicodeError):
            raise Failure(failure) from None
        require(isinstance(value, dict), failure)
        # Pinned Grafana maps a plugin's failed health check to HTTP 400. The
        # datasource's URL/configuration and pinned bytes were checked already;
        # plugin/backend availability can still be catching up after restart.
        if response.status == 400 and path == LOGS_HEALTH and value.get("status") == "ERROR":
            raise Failure(84)
        # QueryData's backend error can be carried in an HTTP 400 envelope.
        if response.status == 400 and path == LOGS_QUERY:
            logs_query_result(value)
        require(response.status == 200, failure)
        return value
    except (OSError, http.client.HTTPException):
        raise Failure(84) from None
    finally:
        connection.close()
        headers.clear()


def logs_query_body():
    # Upstream instant queries use /select/logsql/query, with explicit start/end
    # and maxLines translated to limit. Select only the timestamp: query checks
    # need no application messages/labels, and no log ingestion is performed.
    return {"from": "now-5m", "to": "now", "queries": [{
        "refId": "A", "datasource": {"uid": LOGS_UID, "type": LOGS_TYPE},
        "queryType": "instant", "expr": "* | fields _time", "maxLines": 1,
        "maxDataPoints": 1, "intervalMs": 1000,
    }]}


def logs_query_result(value):
    """Accept the pinned plugin's valid empty logs frame, never a missing result."""
    require(not value.get("error"), 86)
    results = value.get("results")
    require(isinstance(results, dict) and set(results) == {"A"}, 86)
    result = results["A"]
    require(isinstance(result, dict), 86)
    status = result.get("status", 200)
    if status in (500, 502, 503, 504) and result.get("error"):
        raise Failure(84)
    require(status == 200 and not result.get("error"), 86)
    frames = result.get("frames")
    # v0.32.0 always emits one logs frame, including for an empty backend body.
    require(isinstance(frames, list) and len(frames) == 1, 86)
    frame = frames[0]
    require(isinstance(frame, dict), 86)
    schema, data = frame.get("schema"), frame.get("data")
    require(isinstance(schema, dict) and isinstance(data, dict), 86)
    require(schema.get("refId") == "A", 86)
    fields, values = schema.get("fields"), data.get("values")
    require(isinstance(fields, list) and isinstance(values, list), 86)
    require(len(fields) == len(values) and len(fields) >= 2, 86)
    require(all(isinstance(field, dict) for field in fields), 86)
    types = {field.get("name"): field.get("type") for field in fields}
    require(types.get("Time") == "time" and types.get("Line") == "string", 86)
    require(all(isinstance(column, list) and len(column) == len(values[0]) for column in values), 86)
    require(len(values[0]) <= 1, 86)


def logs_ready(username, password, query=False):
    deadline = time.monotonic() + 45
    delay = 0.5
    while True:
        try:
            left = deadline - time.monotonic()
            require(left > 0, 87)
            value = request("POST" if query else "GET", username, password,
                            logs_query_body() if query else None,
                            timeout=min(5, left), path=LOGS_QUERY if query else LOGS_HEALTH)
            require(value is not None, 83)
            if query:
                logs_query_result(value)
            else:
                if value.get("status") == "ERROR":
                    raise Failure(84)
                require(value.get("status") == "OK", 86)
            require(time.monotonic() < deadline, 87)
            return
        except Failure as error:
            if error.code != 84:
                raise
            left = deadline - time.monotonic()
            require(left > 0, 87)
            time.sleep(min(delay, left))
            delay = 1


def logs_verify(username, password):
    # Called only after the read-only/reconciled identity check. No password reset,
    # account API mutation, SQLite access or service operation belongs here.
    # Pinned Grafana's GetPluginSettingByID exposes the loaded version/signature.
    # A loader/signature error produces HTTP 500 before the DTO; never retry this
    # deterministic gate or confuse bytes on disk with a loaded valid plugin.
    try:
        plugin = request("GET", username, password, path=LOGS_SETTINGS)
    except Failure:
        raise Failure(88) from None
    require(plugin is not None, 83)
    require(plugin.get("id") == LOGS_TYPE and plugin.get("type") == "datasource", 88)
    require(isinstance(plugin.get("info"), dict) and plugin["info"].get("version") == LOGS_VERSION, 88)
    require(plugin.get("signature") == "valid", 88)
    logs_ready(username, password)
    logs_ready(username, password, query=True)
    return "unchanged"


def authenticated(username, password):
    # Only runtime unavailability is retried. 401 is a definite failed credential
    # check, and malformed/mismatching user identity is an immediate failure.
    deadline = time.monotonic() + 30
    delay = 0.5
    while True:
        try:
            left = deadline - time.monotonic()
            require(left > 0, 84)
            value = request("GET", username, password, timeout=min(5, left))
            if value is None:
                return None
            require(value.get("id") == 1 and value.get("isGrafanaAdmin") is True, 81)
            require(isinstance(value.get("login"), str) and not value.get("isDisabled", False), 81)
            require(not value.get("isExternal", False), 81)
            return value
        except Failure as error:
            if error.code != 84:
                raise
            left = deadline - time.monotonic()
            require(left > 0, 84)
            time.sleep(min(delay, left))
            delay = 1


def bootstrap(username, password):
    rows = database_users()
    if rows:
        original_admin(rows, username)
        return "unchanged"
    state = subprocess.run(["systemctl", "show", "-p", "ActiveState", "--value", "dragontools-grafana.service"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=False)
    require(state.returncode == 0 and state.stdout.strip() in (b"inactive", b"failed"), 85)
    reset(username, password, bootstrap=True)
    require(original_admin(database_users(), username) == username, 85)
    return "changed"


def reconcile(username, password, readonly=False):
    # The bootstrap account, not an arbitrary administrator with working
    # credentials, is the sole supported management target.
    current = original_admin(database_users(), username)
    desired_profile = authenticated(username, password)
    if desired_profile is not None and desired_profile["login"] == username:
        return "unchanged"
    require(not readonly, 83)
    # An interrupted rename may already have applied the password. Reuse it
    # rather than resetting the same hash again on the recovery run.
    current_profile = desired_profile
    if current_profile is None and current != username:
        current_profile = authenticated(current, password)
    if current_profile is None:
        reset(username, password)
        current_profile = authenticated(current, password)
        require(current_profile is not None, 83)
    require(current_profile["login"] == current, 81)
    if current != username:
        body = {key: current_profile.get(key, "") for key in ("email", "name", "theme")}
        body["login"] = username
        require(request("PUT", current, password, body) is not None, 83)
    final = authenticated(username, password)
    require(final is not None and final["login"] == username, 83)
    return "changed"


def main():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.umask(0o027)
        username, password = credentials(sys.stdin.buffer)
        require(len(sys.argv) == 2 and sys.argv[1] in ("bootstrap", "reconcile", "verify", "logs_verify"), 80)
        if sys.argv[1] == "logs_verify":
            result = logs_verify(username, password)
        else:
            result = bootstrap(username, password) if sys.argv[1] == "bootstrap" else reconcile(username, password, sys.argv[1] == "verify")
        sys.stdout.write(result)
        return 0
    except Failure as error:
        return error.code
    except Exception:
        # Never expose exceptions, response bodies, SQL output or child stderr.
        return 86 if len(sys.argv) == 2 and sys.argv[1] == "logs_verify" else 83


if __name__ == "__main__":
    sys.exit(main())
