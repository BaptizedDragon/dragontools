# Managed by DragonTools
"""Concrete journald bounds. Effective configuration is read before any write."""
import os
import re
import stat
import subprocess
import sys
import tempfile

PATH = '/etc/systemd/journald.conf.d/90-dragontools.conf'
MARKER = '/var/lib/dragontools/journald-restart-required'
KEYS = ('SystemMaxUse', 'RuntimeMaxUse', 'MaxRetentionSec')


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL, timeout=15).decode()


def size(value):
    match = re.fullmatch(r'([0-9]+)([KMGTPE]?)', value.strip())
    if not match:
        raise ValueError('unsupported journald size')
    return int(match[1]) * 1024 ** ('KMGTPE'.find(match[2]) + 1 if match[2] else 0)


def duration(value):
    units = {'': 1, 's': 1, 'sec': 1, 'second': 1, 'seconds': 1,
             'm': 60, 'min': 60, 'minute': 60, 'minutes': 60,
             'h': 3600, 'hour': 3600, 'hours': 3600,
             'd': 86400, 'day': 86400, 'days': 86400, 'w': 604800, 'week': 604800}
    matches = list(re.finditer(r'([0-9]+)\s*([a-z]*)\s*', value.strip()))
    if not matches or ''.join(m[0] for m in matches) != value.strip() or any(m[2] not in units for m in matches):
        raise ValueError('unsupported journald duration')
    return sum(int(m[1]) * units[m[2]] for m in matches)


def effective(text, replacement=None):
    section, source, result = '', '', {}
    for raw in text.splitlines():
        if raw.startswith('# /'):
            source = raw[2:].strip()
            section = ''
            if source == PATH and replacement is not None:
                result.update(effective(replacement))
            continue
        if source == PATH and replacement is not None:
            continue
        line = raw.strip()
        if not line or line.startswith(('#', ';')):
            continue
        if line.startswith('['):
            section = line
        elif section == '[Journal]' and '=' in line:
            key, value = (part.strip() for part in line.split('=', 1))
            if key in KEYS:
                # Empty resets and zero mean no explicit finite ceiling.
                result[key] = 0 if value in ('', 'infinity') else (duration(value) if key == 'MaxRetentionSec' else size(value))
    return result


def desired(system_capacity, runtime_capacity):
    return dict(zip(KEYS, (max(1, min(1024**3, system_capacity * 5 // 100)),
                           max(1, min(256 * 1024**2, runtime_capacity * 2 // 100)), 7 * 86400)))


def bounded(actual, limits):
    return all(0 < actual.get(key, 0) <= limit for key, limit in limits.items())


def render(actual, limits):
    values = {key: min(actual.get(key, 0) or limit, limit) for key, limit in limits.items()}
    return '# Managed by DragonTools\n[Journal]\n' + ''.join(f'{key}={values[key]}\n' for key in KEYS)


def regular(path):
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != 0 or st.st_gid != 0:
        raise ValueError('unsafe managed path')
    return st


def capacity(path):
    st = os.statvfs(path)
    return st.f_blocks * st.f_frsize


def check(mode):
    limits = desired(capacity('/var/log'), capacity('/run'))
    text = run('systemd-analyze', 'cat-config', 'systemd/journald.conf')
    actual = effective(text)
    if mode == 'verify':
        if not bounded(actual, limits):
            raise ValueError('unbounded journald configuration')
        run('systemctl', 'is-active', 'systemd-journald.service')
        run('journalctl', '--disk-usage')
        return
    if bounded(actual, limits) and not os.path.lexists(MARKER):
        check('verify')
        print('unchanged', end='')
        return
    if os.path.lexists(PATH):
        regular(PATH)
        with open(PATH) as stream:
            if not stream.read().startswith('# Managed by DragonTools\n'):
                raise ValueError('unmanaged journald drop-in')
    if os.path.lexists(MARKER):
        regular(MARKER)
    changed = False
    if not bounded(actual, limits):
        content = render(actual, limits)
        # cat-config includes headers for files in precedence order. Add our
        # projected file at its actual lexical position, before later overrides.
        if '# ' + PATH not in text:
            chunks = re.split(r'(?=^# /)', text, flags=re.MULTILINE)
            inserted, ordered = False, []
            for chunk in chunks:
                filename = chunk.splitlines()[0][2:].strip() if chunk.startswith('# /') else ''
                if '/journald.conf.d/' in filename and filename.rsplit('/', 1)[1] > '90-dragontools.conf' and not inserted:
                    ordered.append('# ' + PATH + '\n' + content)
                    inserted = True
                ordered.append(chunk)
            if not inserted:
                ordered.append('# ' + PATH + '\n' + content)
            projected = '\n'.join(ordered)
        else:
            projected = text
        if not bounded(effective(projected, content), limits):
            raise ValueError('later journald override conflicts with bounds')
        parent = os.path.dirname(PATH)
        if os.path.lexists(parent) and (os.path.islink(parent) or not os.path.isdir(parent)):
            raise ValueError('unsafe drop-in directory')
        os.makedirs(parent, mode=0o755, exist_ok=True)
        st = os.lstat(parent)
        if st.st_uid != 0 or st.st_gid != 0 or stat.S_IMODE(st.st_mode) & 0o022:
            raise ValueError('unsafe drop-in directory metadata')
        fd, tmp = tempfile.mkstemp(prefix='.dragontools-', dir=parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o644)
            if not os.path.exists(MARKER):
                fd = os.open(MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(fd)
            os.replace(tmp, PATH)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        changed = True
    if os.path.exists(MARKER):
        run('systemctl', 'restart', 'systemd-journald.service')
        check('verify')
        os.unlink(MARKER)
        changed = True
    print('changed' if changed else 'unchanged', end='')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('install', 'verify'):
            raise ValueError('invalid mode')
        check(sys.argv[1])
    except Exception:
        sys.exit(1)
