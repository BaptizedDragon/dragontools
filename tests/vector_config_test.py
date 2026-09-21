"""Execute the production publication shell with local command fixtures.

No real service, ownership change, or Vector binary is invoked here. Native VRL
validation is covered separately by the pinned-process structured-log fixture.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

COMMAND = sys.argv[1]
FAKE = r'''
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['VECTOR_CONFIG_FIXTURE'])
if name == 'stat':
    print('0:0' if args[1] == '%u:%g' else oct(Path(args[-1]).stat().st_mode & 0o777)[2:])
elif name == 'chown':
    pass
elif name == 'mv':
    assert args[0] == '-fT'
    assert (root/'pending').exists(), 'intent must precede publication'
    assert (root/'validated').read_text() == args[1]
    os.replace(args[1], args[2])
elif name == 'runuser':
    assert args[:3] == ['-u', 'dt-vector', '--']
    assert args[4:8] == ['validate', '--no-environment', '--skip-healthchecks', '--config-yaml']
    assert args[-1] != str(root/'vector.yaml'), 'must validate a candidate'
    assert Path(args[-1]).read_text().startswith('# Managed by DragonTools\n')
    with (root/'calls').open('a') as f: f.write('validate\n')
    if os.environ.get('FAIL_VALIDATION'):
        print('PRIVATE-VALIDATOR-DIAGNOSTIC', file=sys.stderr)
        sys.exit(1)
    (root/'validated').write_text(args[-1])
else:
    raise AssertionError(name)
'''

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    bin_dir = root/'bin'; bin_dir.mkdir()
    for name in ('stat', 'chown', 'mv', 'runuser'):
        path = bin_dir/name
        path.write_text('#!' + sys.executable + '\n' + FAKE)
        path.chmod(0o755)
    args = shlex.split(COMMAND)
    assert args[:3] == ['sh', '-eu', '-c']
    args[-3], args[-1] = str(root/'vector.yaml'), str(root/'pending')
    target = root/'vector.yaml'
    original = '# Managed by DragonTools\noriginal working config\n'
    target.write_text(original); target.chmod(0o644)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], VECTOR_CONFIG_FIXTURE=str(root))
    def run(fail=False):
        result = subprocess.run(args, env=dict(env, **({'FAIL_VALIDATION': '1'} if fail else {})), capture_output=True, text=True)
        assert result.stderr == '', result.stderr
        assert not list(root.glob('vector.yaml.*')), 'candidate leaked'
        return result
    # Invalid VRL leaves an existing good config and its timestamp untouched.
    before = target.stat().st_mtime_ns
    assert run(True).returncode != 0
    assert target.read_text() == original and target.stat().st_mtime_ns == before
    assert not (root/'pending').exists()
    # An older interrupted restart intent must also survive failed validation.
    (root/'pending').touch()
    assert run(True).returncode != 0 and (root/'pending').exists()
    assert target.read_text() == original
    assert run().stdout == 'changed' and target.read_text() == args[-2]
    (root/'pending').unlink()  # Simulate successful verified finalization.
    before = target.stat().st_mtime_ns
    calls = (root/'calls').read_text()
    assert run().stdout == 'unchanged'
    assert target.stat().st_mtime_ns == before and not (root/'pending').exists()
    assert (root/'calls').read_text() == calls
    # No adoption of an arbitrary file or symlink.
    target.write_text('administrator config\n')
    assert run().returncode != 0 and target.read_text() == 'administrator config\n'
    target.unlink(); target.symlink_to(root/'outside')
    assert run().returncode != 0
print('PASS: Vector candidate validation, refusal, intent preservation and unchanged rerun.')
