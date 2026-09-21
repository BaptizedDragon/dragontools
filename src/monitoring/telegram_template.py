"""DragonTools public Telegram template transport; payload travels only on stdin."""
import os
from pathlib import Path
import stat
import sys
import tempfile

BASE = Path('/etc/dragontools/alertmanager')
PENDING = Path('/var/lib/dragontools/alertmanager-restart-required')
MARKER = b'{{/* Managed by DragonTools: Telegram presentation v1. No safeHtml/safeUrl. */}}\n'
LIMIT = 32768


def node(path, directory=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise OSError('Unexpected symlink')
    if (info.st_uid, info.st_gid) != (0, 0) or not (
            stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1):
        raise ValueError('Unmanaged template state')
    return info


def reconcile(expected, install):
    if not expected.startswith(MARKER) or len(expected) > LIMIT:
        raise ValueError('Invalid template')
    for directory in (BASE.parent, BASE):
        if stat.S_IMODE(node(directory, True).st_mode) != 0o755:
            raise ValueError('Unmanaged template parent')
    directory, path = BASE / 'templates', BASE / 'templates/telegram.tmpl'
    if not os.path.lexists(directory):
        if not install:
            raise ValueError('Missing template directory')
        directory.mkdir(mode=0o755)
        directory.chmod(0o755)
    if stat.S_IMODE(node(directory, True).st_mode) != 0o755:
        raise ValueError('Unmanaged template directory')
    if os.path.lexists(path):
        info = node(path)
        if info.st_size > LIMIT or stat.S_IMODE(info.st_mode) != 0o644:
            raise ValueError('Unmanaged template file')
        actual = path.read_bytes()
        if not actual.startswith(MARKER):
            raise ValueError('Unmanaged template file')
        if actual == expected:
            return False
    if not install:
        raise ValueError('Template mismatch')
    if os.path.lexists(PENDING):
        node(PENDING)
    fd, staging = tempfile.mkstemp(prefix='.telegram.', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(expected)
            handle.flush()
            os.fchmod(handle.fileno(), 0o644)
            os.fsync(handle.fileno())
        if not os.path.lexists(PENDING):
            marker = os.open(PENDING, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.close(marker)
        os.replace(staging, path)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)
    return True


def main():
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('install', 'verify'):
            return 1
        changed = reconcile(sys.stdin.buffer.read(LIMIT + 1), sys.argv[1] == 'install')
        if sys.argv[1] == 'install':
            sys.stdout.write('changed' if changed else 'unchanged')
        return 0
    except Exception:
        return 40  # Fixed semantic error, never filesystem contents or tracebacks.


if __name__ == '__main__':
    sys.exit(main())
