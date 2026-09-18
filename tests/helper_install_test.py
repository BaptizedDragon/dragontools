"""Linux isolated filesystem test of the actual rendered helper installer.

No host paths touched: replace the fixed /opt prefix with a private temp root.
Pass --fixture and --agent paths compiled for this machine.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
p = argparse.ArgumentParser()
p.add_argument('--fixture', required=True)
p.add_argument('--agent', type=Path, required=True)
a = p.parse_args()
scripts = json.loads(subprocess.check_output([a.fixture, 'helper-scripts']))
with tempfile.TemporaryDirectory(prefix='dragontools-helper-') as temporary:
    opt = Path(temporary)/'opt'
    opt.mkdir(mode=0o755)
    commands = {key: scripts[key].replace('/opt', str(opt)) for key in ('inspect','verify','upload')}
    def run(kind, data=None, success=True):
        r = subprocess.run(['/bin/sh', '-c', commands[kind]], input=data, capture_output=True, timeout=30)
        assert (r.returncode == 0) == success, (kind, r.returncode)
        assert r.stderr == b''
        return r.stdout
    assert run('inspect') == b'upload'
    assert run('upload', a.agent.read_bytes()) == b'changed'
    root = opt/'dragontools/agent'
    target = root/'current'
    desired = target.readlink()
    before = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in root.rglob('*') if path.is_file()}
    assert run('inspect') == b'unchanged'
    assert run('verify') == b'unchanged'
    assert before == {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in root.rglob('*') if path.is_file()}
    # A previous checked managed release is preserved during the atomic switch.
    old = root/('0.0.0-old-' + scripts['sha256'])
    old.mkdir(mode=0o755)
    (old/'dragontool-agent').write_bytes(a.agent.read_bytes())
    (old/'dragontool-agent').chmod(0o755)
    (old/'.dragontools-managed').write_text('DragonTools native helper v1\n0.0.0-old\n' + scripts['sha256'] + '\n')
    (old/'.dragontools-managed').chmod(0o444)
    target.unlink()
    target.symlink_to(old)
    assert run('inspect') == b'upload'
    run('verify', success=False)
    run('upload', b'truncated-public-artifact', success=False)
    assert target.readlink() == old
    assert not list(root.glob('.upload-*'))
    assert run('upload', a.agent.read_bytes()) == b'changed'
    assert target.readlink() == desired and old.exists()
    assert run('inspect') == b'unchanged'
    (desired/'dragontool-agent').chmod(0o777)
    run('inspect', success=False)
    (desired/'dragontool-agent').chmod(0o755)
    target.unlink()
    target.symlink_to('/unexpected')
    run('inspect', success=False)
print('PASS: helper install, checksum refusal, no-op, version switch, retained release, unsafe metadata and symlink refusal.')
