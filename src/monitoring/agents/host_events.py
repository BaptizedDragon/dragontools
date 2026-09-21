"""Read-only fixed host-maintenance unit/storage checks. No observer invocation."""
import contextlib
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


# Exit codes are private to host_events.zig; never print arbitrary exceptions.
CHECKS = (
    'host_events_account', 'host_events_helper', 'host_events_state_directory',
    'host_events_service_unit', 'host_events_timer_unit', 'host_events_timer_enabled',
    'host_events_timer_active', 'host_events_last_run', 'host_events_state_safe',
)


class CheckFailure(Exception):
    def __init__(self, check):
        self.check = check
        self.code = 200 + CHECKS.index(check)


@contextlib.contextmanager
def stage(check):
    try:
        yield
    except Exception:
        raise CheckFailure(check) from None


def account():
    user = pwd.getpwnam('dt-host-events')
    assert user.pw_uid != 0 and user.pw_dir == '/var/lib/dragontools/host-events' and user.pw_shell == '/usr/sbin/nologin'
    assert output('id', '-nG', 'dt-host-events') == 'dt-host-events'
    return user


def managed(spec):
    with stage('host_events_account'):
        user = account()
    with stage('host_events_state_directory'):
        node('/var/lib/dragontools', 0, 0, 0o755, True)
        node(user.pw_dir, user.pw_uid, user.pw_gid, 0o700, True)
    for kind in ('service', 'timer'):
        with stage('host_events_' + kind + '_unit'):
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
                assert props.get('UnitFileState') == 'static' and props.get('RemainAfterExit') == 'no'
                # systemctl's structured ExecStart formatting is bounded; exact argv
                # is checked through its JSON D-Bus value, never parsed shell text.
                value=json.loads(output('busctl','--system','--json=short','get-property','org.freedesktop.systemd1', '/org/freedesktop/systemd1/unit/dragontools_2dhost_2devents_2eservice','org.freedesktop.systemd1.Service','ExecStart'))
                assert value['type']=='a(sasbttttuii)' and len(value['data'])==1
                assert value['data'][0][0]=='/opt/dragontools/agent/current/dragontool-agent'
                assert value['data'][0][1]==['/opt/dragontools/agent/current/dragontool-agent','maintenance','events']
            else:
                assert props.get('Unit') == 'dragontools-host-events.service'
                assert props.get('AccuracyUSec') == '1s' and props.get('RandomizedDelayUSec') == '0'
    with stage('host_events_timer_enabled'):
        assert properties('dragontools-host-events.timer').get('UnitFileState') == 'enabled'


def timer_active():
    return properties('dragontools-host-events.timer').get('ActiveState') == 'active'


def last_run():
    service = properties('dragontools-host-events.service')
    # A running oneshot has not completed yet. Inactive/dead after exit 0 is
    # healthy; failure is deterministic, not startup absence to retry.
    if service.get('ActiveState') in ('activating', 'deactivating'):
        return False
    assert service.get('ActiveState') != 'failed' and service.get('Result') == 'success'
    started = int(service.get('ExecMainStartTimestampMonotonic', '0'))
    if started == 0:
        return False
    assert service.get('ActiveState') == 'inactive' and service.get('SubState') == 'dead'
    assert service.get('ExecMainCode') == '1' and service.get('ExecMainStatus') == '0'
    ended = int(service.get('ExecMainExitTimestampMonotonic', '0'))
    assert ended >= started
    return 0 <= time.monotonic() - started / 1_000_000 <= 360


def state_safe():
    user = account()
    node(user.pw_dir, user.pw_uid, user.pw_gid, 0o700, True)
    for suffix in ('state', 'next'):
        path = user.pw_dir + '/reboot-required.' + suffix
        if os.path.lexists(path):
            node(path, user.pw_uid, user.pw_gid, 0o600)
    # No marker observation, state writes or production event emission.
    output('runuser', '-u', 'dt-host-events', '--', '/opt/dragontools/agent/current/dragontool-agent', 'maintenance', 'events-verify')


def ready():
    if not timer_active() or not last_run():
        return False
    state_safe()
    return True


if __name__ == '__main__':
    try:
        mode = sys.argv[1]
        if mode == 'managed':
            managed(json.loads(sys.argv[2]))
        elif mode == 'state_safe':
            state_safe()
        elif mode in ('timer_active', 'last_run', 'ready'):
            if not dict(timer_active=timer_active, last_run=last_run, ready=ready)[mode]():
                sys.exit(75)
        else:
            sys.exit(1)
    except CheckFailure as failure:
        sys.exit(failure.code)
    except Exception:
        sys.exit(1)
