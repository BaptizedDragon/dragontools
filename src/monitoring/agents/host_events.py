"""Read-only fixed host-maintenance unit/storage checks. No observer invocation."""
import json
import os
import pwd
import stat
import subprocess
import sys
import time


def output(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL, timeout=10).decode().strip()


def properties(unit):
    return dict(line.split('=', 1) for line in output('systemctl', 'show', '--all', unit).splitlines() if '=' in line)


def node(path, uid, gid, mode, directory=False):
    info = os.lstat(path)
    assert (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
    assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (uid, gid, mode)


def managed(spec):
    user = pwd.getpwnam('dt-host-events')
    assert user.pw_uid != 0 and user.pw_dir == '/var/lib/dragontools/host-events' and user.pw_shell == '/usr/sbin/nologin'
    assert output('id', '-nG', 'dt-host-events') == 'dt-host-events'
    node('/var/lib/dragontools', 0, 0, 0o755, True)
    node(user.pw_dir, user.pw_uid, user.pw_gid, 0o700, True)
    for suffix in ('state', 'next'):
        path = user.pw_dir + '/reboot-required.' + suffix
        if os.path.lexists(path): node(path, user.pw_uid, user.pw_gid, 0o600)
    for kind in ('service', 'timer'):
        name = 'dragontools-host-events.' + kind
        path = '/etc/systemd/system/' + name
        node(path, 0, 0, 0o644)
        with open(path) as stream: assert stream.read() == spec[kind]
        props = properties(name)
        assert all(props.get(k) == v for k,v in dict(FragmentPath=path, DropInPaths='', NeedDaemonReload='no', LoadState='loaded').items())
        if kind == 'service':
            desired = dict(line.split('=',1) for line in spec[kind].splitlines() if '=' in line)
            for key in ('User', 'Group', 'Type', 'NoNewPrivileges', 'PrivateTmp', 'PrivateDevices', 'ProtectHome', 'ProtectSystem', 'ProtectKernelTunables', 'ProtectKernelModules', 'ProtectControlGroups', 'RestrictSUIDSGID', 'LockPersonality', 'CapabilityBoundingSet', 'AmbientCapabilities', 'StandardOutput', 'StandardError', 'LimitCORE'):
                assert props.get(key) == desired[key]
            assert props.get('UMask') == '0077'
            for key in ('ReadWritePaths', 'RestrictAddressFamilies'): assert set(props.get(key,'').split()) == set(desired[key].split())
            assert props.get('LogNamespace') == ''
            # systemctl's structured ExecStart formatting is bounded; exact argv
            # is checked through its JSON D-Bus value, never parsed shell text.
            value=json.loads(output('busctl','--system','--json=short','get-property','org.freedesktop.systemd1', '/org/freedesktop/systemd1/unit/dragontools_2dhost_2devents_2eservice','org.freedesktop.systemd1.Service','ExecStart'))
            assert value['type']=='a(sasbttttuii)' and len(value['data'])==1
            assert value['data'][0][0]=='/opt/dragontools/agent/current/dragontool-agent'
            assert value['data'][0][1]==['/opt/dragontools/agent/current/dragontool-agent','maintenance','events']
        else:
            assert props.get('Unit') == 'dragontools-host-events.service'
            assert props.get('UnitFileState') == 'enabled'
            assert props.get('AccuracyUSec') == '1s' and props.get('RandomizedDelayUSec') == '0'


def ready():
    timer = properties('dragontools-host-events.timer')
    service = properties('dragontools-host-events.service')
    if timer.get('ActiveState') != 'active' or service.get('Result') != 'success' or int(service.get('ExecMainStartTimestampMonotonic','0')) == 0:
        return False
    started = int(service['ExecMainStartTimestampMonotonic']) / 1_000_000
    if not 0 <= time.monotonic() - started <= 360: return False
    # Verifies state under the same restricted owner; does not read markers,
    # update a state file, or emit any maintenance event.
    output('runuser','-u','dt-host-events','--','/opt/dragontools/agent/current/dragontool-agent','maintenance','events-verify')
    return True


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'managed': managed(json.loads(sys.argv[2]))
        elif sys.argv[1] == 'ready':
            if not ready(): sys.exit(75)
        else: sys.exit(1)
    except Exception:
        sys.exit(1)
