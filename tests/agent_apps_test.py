"""Run actual ownership helper using temporary unprivileged files, no SSH."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('apps', ROOT / 'src/monitoring/agents/apps.py')
apps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apps)


def refused(call):
    try:
        call()
    except (ValueError, OSError):
        return
    raise AssertionError('expected ownership conflict')


def app(name, logs=True, metrics=True):
    return dict(name=name, environment='production', services=[dict(name='web', systemd=name+'.service', logs=logs, metrics_url='http://127.0.0.1:16000/metrics' if metrics else None)])


with tempfile.TemporaryDirectory() as path, patch.object(apps, 'ROOT', os.getuid()), patch.object(apps, 'GID', os.getgid()), patch.object(apps, 'BASE', path+'/agent-apps'):
    os.chmod(path, 0o755)
    def apply(value, mutate=True):
        return apps.reconcile(value, 'dt-'+'a'*32, 'station.example', mutate)
    first, changed = apply(app('doers'))
    assert changed and first['services'] == ['doers.service']
    manifest = Path(path+'/agent-apps/doers.json')
    before = (manifest.read_bytes(), manifest.stat().st_mtime_ns)
    assert apply(app('doers')) == (first, False)
    assert (manifest.read_bytes(), manifest.stat().st_mtime_ns) == before
    assert apply(app('doers'), False) == (first, False)
    second, changed = apply(app('orderflow'))
    assert changed and [value['name'] for value in second['applications']] == ['doers', 'orderflow']
    assert (manifest.read_bytes(), manifest.stat().st_mtime_ns) == before
    orderflow = Path(path+'/agent-apps/orderflow.json')
    other_before = (orderflow.read_bytes(), orderflow.stat().st_mtime_ns)
    third, changed = apply(app('doers', False, False))
    assert changed and third['services'] == ['orderflow.service']
    assert (orderflow.read_bytes(), orderflow.stat().st_mtime_ns) == other_before
    assert apply(app('doers', False, False)) == (third, False)
    refused(lambda: apply(app('doers'), False))
    duplicate = app('conflict'); duplicate['services'][0]['systemd'] = 'orderflow.service'
    refused(lambda: apply(duplicate))
    assert not Path(path+'/agent-apps/conflict.json').exists()
    # Host metrics without any selected service remain a valid scope.
    zero, changed = apply(dict(name='hostonly', environment='staging', services=[]))
    assert changed and len(zero['applications']) == 3
    # Simulate SIGKILL/disk-full during a new manifest write. Partial private
    # staging is never decoded as authoritative state, and rerun recovers it.
    pending = Path(path+'/agent-apps/.doers.pending')
    pending.write_bytes(b'{"application":')
    pending.chmod(0o600)
    recovered, changed = apply(app('doers', False, False))
    assert changed and not pending.exists()
    assert apply(app('doers', False, False)) == (recovered, False)
    pending.symlink_to(orderflow)
    refused(lambda: apply(app('doers', False, False)))
    pending.unlink()
    # A new endpoint updates only this app's owned metadata; other scopes merge
    # unchanged. Read-only verification never adopts an un-applied hostname.
    other_before = (orderflow.read_bytes(), orderflow.stat().st_mtime_ns)
    refused(lambda: apps.reconcile(app('doers', False, False), 'dt-'+'a'*32, 'new.example', False))
    updated, changed = apps.reconcile(app('doers', False, False), 'dt-'+'a'*32, 'new.example', True)
    assert changed and updated['station'] == 'new.example'
    assert (orderflow.read_bytes(), orderflow.stat().st_mtime_ns) == other_before
    assert apps.reconcile(app('doers', False, False), 'dt-'+'a'*32, 'new.example', True) == (updated, False)
    assert apps.reconcile(app('doers', False, False), 'dt-'+'a'*32, 'new.example', False) == (updated, False)
    # Corrupted or administrator-edited manifests cannot be adopted.
    manifest.write_bytes(manifest.read_bytes()+b' ')
    refused(lambda: apply(app('doers')))
    manifest.unlink(); manifest.symlink_to(orderflow)
    refused(lambda: apply(app('doers')))

with tempfile.TemporaryDirectory() as path, patch.object(apps, 'ROOT', os.getuid()), patch.object(apps, 'GID', os.getgid()), patch.object(apps, 'BASE', path+'/agent-apps'):
    os.chmod(path, 0o755)
    os.mkdir(path+'/vector')
    Path(path+'/vector/vector.yaml').write_text('# Managed by DragonTools\n')
    refused(lambda: apps.reconcile(app('doers'), 'dt-'+'a'*32, 'station.example', True))
    assert not Path(path+'/agent-apps').exists()
print('Application manifests: independent updates/removal/no-op, zero logs and conflict refusal passed.')
