#!/usr/bin/env python3
"""Exercise the built CLI without allowing a real SSH connection."""
import os
from pathlib import Path
import subprocess
import tempfile

binary = Path(os.environ.get("TOOL", "zig-out/bin/dragontool")).resolve()
with tempfile.TemporaryDirectory(prefix="dragontools-cli-") as directory:
    directory = Path(directory)
    marker = directory / "ssh-called"
    ssh = directory / "ssh"
    ssh.write_text('#!/bin/sh\n: > "$DRAGONTOOLS_TEST_MARKER"\nexit 91\n')
    ssh.chmod(0o755)
    env = dict(os.environ, PATH=f"{directory}:{os.environ.get('PATH', '')}",
               DRAGONTOOLS_TEST_MARKER=str(marker))
    cases = [
        (["--help"], 0, "VictoriaMetrics only"),
        (["monitoring", "install", "--host", "example.com", "--plan"], 0,
         "No remote operations performed"),
        (["monitoring", "agents", "install", "--host", "example.com",
          "--service", "one.service", "--service", "two.service"], 1, "NotImplemented"),
        (["monitoring", "agents", "verify", "--host", "example.com"], 1, "NotImplemented"),
        (["monitoring", "agents", "status", "--host", "example.com"], 1, "NotImplemented"),
        (["monitoring", "firewall", "--host", "example.com"], 1, "NotImplemented"),
        (["monitoring", "install", "--host", "example.com",
          "--telegram-bot-token-op", "op://REDACTION-SENTINEL/item/token"], 1, "NotImplemented"),
        (["monitoring", "install", "--host", "REDACTION-SENTINEL;id"], 1, "InvalidHost"),
        (["monitoring", "install", "--host", "example.com", "--identity"], 1, "MissingValue"),
        (["user", "create"], 1, "UnknownCommand"),
    ]
    for args, code, expected in cases:
        result = subprocess.run([str(binary), *args], env=env, capture_output=True,
                                text=True, timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == code, (args, result.returncode, output)
        assert expected in output, (args, output)
        assert "REDACTION-SENTINEL" not in output, output
        assert not marker.exists(), "A help/plan/rejected workflow attempted SSH"
    # A supported workflow reaches the transport and reports a safe failure phase.
    result = subprocess.run([str(binary), "monitoring", "install", "--host", "example.com"],
                            env=env, capture_output=True, text=True, timeout=15)
    assert marker.exists(), "The supported install did not invoke the SSH abstraction"
    assert result.returncode == 1
    assert "Failed at detect; 0 steps completed" in result.stdout
print(f"PASS: {len(cases) + 1} CLI smoke cases")
