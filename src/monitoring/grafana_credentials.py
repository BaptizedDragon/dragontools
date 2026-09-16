"""Pinned Grafana credential operations. Input is a private stdin pipe only.

No credential files, command-line values, logging, shell interpolation or SQLite
writes. The supported CLI owns initialization/password changes; PUT /api/user
owns username changes. Only original local administrator ID 1 is managed.

Reviewed v13.2.2: pkg/cmd/grafana-cli/commands/{commands,reset_password_command}.go,
pkg/services/sqlstore/sqlstore.go, pkg/api/user.go. Grafana API authentication may
record its own last-seen metadata; verify makes only GET requests.
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


def request(method, username, password, body=None, timeout=5):
    """Direct fixed loopback HTTP: no proxies, redirects, cookies or URL secrets."""
    connection = http.client.HTTPConnection("127.0.0.1", 3000, timeout=timeout)
    headers = {"Authorization": "Basic " + base64.b64encode((username + ":" + password).encode("utf-8")).decode("ascii"),
               "Accept": "application/json", "Content-Type": "application/json"}
    try:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8") if body is not None else None
        connection.request(method, "/api/user", body=encoded, headers=headers)
        response = connection.getresponse()
        data = response.read(65537)
        require(len(data) <= 65536, 83)
        if response.status == 401:
            return None
        if response.status in (500, 502, 503, 504):
            raise Failure(84)
        require(response.status == 200, 83)
        value = json.loads(data)
        require(isinstance(value, dict), 83)
        return value
    except (OSError, http.client.HTTPException):
        raise Failure(84) from None
    finally:
        connection.close()
        headers.clear()


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
        require(len(sys.argv) == 2 and sys.argv[1] in ("bootstrap", "reconcile", "verify"), 80)
        result = bootstrap(username, password) if sys.argv[1] == "bootstrap" else reconcile(username, password, sys.argv[1] == "verify")
        sys.stdout.write(result)
        return 0
    except Failure as error:
        return error.code
    except Exception:
        # Never expose exceptions, response bodies, SQL output or child stderr.
        return 83


if __name__ == "__main__":
    sys.exit(main())
