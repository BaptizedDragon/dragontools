"""Dedicated protected Telegram file transport; never print input or exceptions."""
import json
import os
import pwd
import re
import resource
import shutil
import stat
import subprocess
import sys
import tempfile

BASE = "/etc/dragontools/alertmanager"
DIRECTORY = BASE + "/secrets"
PENDING = "/var/lib/dragontools/alertmanager-restart-required"
MARKER = b"DragonTools Telegram secrets v1\n"
FILES = ("telegram-bot-token", "telegram-chat-id")


def require(value):
    if not value:
        raise ValueError("Protected Telegram state refused")


def regular(path, uid, mode=None, limit=2048, gid=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == uid)
        if gid is not None:
            require(st.st_gid == gid)
        if mode is not None:
            require(stat.S_IMODE(st.st_mode) == mode)
        require(st.st_size <= limit)
        data = os.read(fd, limit + 1)
        require(len(data) <= limit)
        return data
    finally:
        os.close(fd)


def values(value):
    require(isinstance(value, dict) and set(value) == {"token", "chat_id"})
    token, chat = value["token"], value["chat_id"]
    require(isinstance(token, str) and isinstance(chat, str))
    require(len(token) <= 512 and re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token))
    require(len(chat) <= 20 and re.fullmatch(r"-?[0-9]+", chat))
    number = int(chat)
    require(-(2 ** 63) <= number < 2 ** 63 and number != 0)
    return token.encode(), str(number).encode()


def inspect(uid, gid):
    if not os.path.lexists(DIRECTORY):
        return None
    st = os.lstat(DIRECTORY)
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and st.st_gid == gid and stat.S_IMODE(st.st_mode) == 0o750)
    require(set(os.listdir(DIRECTORY)) <= set(FILES) | {".dragontools-managed"})
    require(regular(DIRECTORY + "/.dragontools-managed", 0, 0o400, gid=0) == MARKER)
    result = []
    for name in FILES:
        path = DIRECTORY + "/" + name
        result.append(regular(path, uid, 0o400, gid=gid) if os.path.lexists(path) else None)
    return result


def mark():
    try:
        fd = os.open(PENDING, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fsync(fd)
        os.close(fd)
    except FileExistsError:
        regular(PENDING, 0, limit=64, gid=0)


def write(path, data, uid, gid):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data)
            output.flush()
            os.fchown(fd, uid, gid)
            os.fchmod(fd, 0o400)
            os.fsync(fd)
    finally:
        os.close(fd)


def clean_staging(uid, gid):
    for name in os.listdir(BASE):
        if not re.fullmatch(r"[.]telegram[.][a-z0-9_]{8}", name):
            continue
        path = BASE + "/" + name
        st = os.lstat(path)
        require(stat.S_ISDIR(st.st_mode) and st.st_uid == 0)
        require((stat.S_IMODE(st.st_mode), st.st_gid) in ((0o700, 0), (0o750, gid)))
        # Only marker-proven private staging is removed. Unmarked leftovers are
        # preserved and fail closed instead of guessing whether we own them.
        require(regular(path + "/.dragontools-managed", 0, 0o400) == MARKER)
        require(set(os.listdir(path)) <= set(FILES) | {".dragontools-managed"})
        for entry in os.listdir(path):
            regular(path + "/" + entry, 0 if entry.startswith(".") else uid, 0o400)
        shutil.rmtree(path)


def install(payload, uid, gid):
    desired = values(payload)
    current = inspect(uid, gid)
    clean_staging(uid, gid)
    if current == list(desired):
        return "unchanged"
    temporary = tempfile.mkdtemp(prefix=".telegram.", dir=BASE)
    try:
        write(temporary + "/.dragontools-managed", MARKER, 0, 0)
        for name, data in zip(FILES, desired):
            write(temporary + "/" + name, data, uid, gid)
        mark()
        # Prevent a live notifier reading a token/chat pair between publications.
        # No-op runs return above; only a real credential change stops this unit.
        state = subprocess.run(["systemctl", "is-active", "dragontools-alertmanager.service"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=False)
        if state.stdout.strip() in (b"active", b"activating", b"reloading", b"deactivating"):
            subprocess.run(["systemctl", "stop", "dragontools-alertmanager.service"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
        else:
            require(state.returncode in (3, 4) and state.stdout.strip() in (b"inactive", b"failed", b"unknown"))
        if current is None:
            os.chown(temporary, 0, gid)
            os.chmod(temporary, 0o750)
            os.rename(temporary, DIRECTORY)
            temporary = None
        else:
            require(inspect(uid, gid) == current)
            for name in FILES:
                os.replace(temporary + "/" + name, DIRECTORY + "/" + name)
        require(inspect(uid, gid) == list(desired))
        return "changed"
    finally:
        if temporary is not None:
            shutil.rmtree(temporary)


def main():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.umask(0o077)
        account = pwd.getpwnam("dt-alertmanager")
        st = os.lstat(BASE)
        require(stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and st.st_gid == 0 and stat.S_IMODE(st.st_mode) == 0o755)
        if sys.argv[1:] == ["verify"]:
            current = inspect(account.pw_uid, account.pw_gid)
            require(current is not None and None not in current)
            require(tuple(current) == values({"token": current[0].decode(), "chat_id": current[1].decode()}))
            return 0
        require(sys.argv[1:] == ["install"])
        data = sys.stdin.buffer.read(8193)
        require(len(data) <= 8192)
        sys.stdout.write(install(json.loads(data), account.pw_uid, account.pw_gid))
        return 0
    except Exception:
        return 86


if __name__ == "__main__":
    sys.exit(main())
