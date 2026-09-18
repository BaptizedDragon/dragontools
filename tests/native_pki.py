"""Test-only native fixture adapter. No OpenSSL CLI or Python PKI implementation."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("DRAGONTOOLS_PKI_FIXTURE", ROOT / "zig-out/bin/dragontool-pki-fixture"))


def invoke(*args, expected=0):
    runner = [os.environ["DRAGONTOOLS_PKI_RUNNER"]] if os.environ.get("DRAGONTOOLS_PKI_RUNNER") else []
    result = subprocess.run([*runner, str(BINARY), *map(str, args)], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
    assert not result.stdout and not result.stderr, "Native fixture must be silent"
    if expected is not None:
        assert result.returncode == expected, f"Native fixture exit {result.returncode}"
    return result.returncode


def ca(directory):
    invoke("ca", directory)


def issue(ca_directory, directory, kind, host):
    invoke("issue", ca_directory, directory, kind, host)


def endpoint(hostname, directory, port, host):
    return invoke("endpoint", hostname, directory, port, host, expected=None)
