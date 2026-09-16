#!/usr/bin/env python3
"""Exercise the built CLI without allowing a real SSH connection."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

binary = Path(os.environ.get("TOOL", "zig-out/bin/dragontool")).resolve()
with tempfile.TemporaryDirectory(prefix="dragontools-cli-") as directory:
    directory = Path(directory)
    marker = directory / "ssh-called"
    ssh = directory / "ssh"
    ssh.write_text('#!/bin/sh\n: > "$DRAGONTOOLS_TEST_MARKER"\n'
                   'printf "REDACTION-SENTINEL remote stdout\\n"\n'
                   'printf "REDACTION-SENTINEL remote stderr\\n" >&2\nexit 91\n')
    ssh.chmod(0o755)
    provider_marker = directory / "provider-called"
    for executable in ("op", "curl", "wget"):
        fake = directory / executable
        fake.write_text('#!/bin/sh\n: > "$DRAGONTOOLS_PROVIDER_MARKER"\nexit 92\n')
        fake.chmod(0o755)
    env = dict(os.environ, PATH=f"{directory}:{os.environ.get('PATH', '')}",
               DRAGONTOOLS_TEST_MARKER=str(marker),
               DRAGONTOOLS_PROVIDER_MARKER=str(provider_marker), NO_COLOR="1", TERM="dumb")
    checked = 0

    def local_run(args, code=0, expected=None):
        """Pipe stdin explicitly so no-argument/wizard checks cannot read the terminal."""
        global checked
        result = subprocess.run([str(binary), *args], env=env, input="",
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == code, (args, result.returncode, output)
        if expected is not None:
            assert expected in output, (args, output)
        assert "REDACTION-SENTINEL" not in output, output
        assert not marker.exists(), "A local or rejected workflow attempted SSH"
        assert not provider_marker.exists(), "A local or rejected workflow invoked a provider"
        checked += 1
        return result

    plan_args = ["monitoring", "install", "--host", "example.com", "--plan"]
    host_plan_args = ["host", "install-oh-my-zsh", "--ssh-host", "REDACTION-SENTINEL", "--plan"]
    plan_output = ""
    cases = [
        (["--help"], 0, "VictoriaTraces"),
        ([], 0, "Usage:"),
        (["wizard"], 1, "InteractiveTerminalRequired"),
        (plan_args, 0, "No remote operations performed"),
        (host_plan_args, 0, "Host personalization plan (local; SSH not attempted)."),
        ([*host_plan_args, "--target-user", "REDACTION-SENTINEL"], 0,
         "Host personalization plan (local; SSH not attempted)."),
        (["host", "install-oh-my-zsh", "--host", "example.com", "--user", "root",
          "--plan"], 0, "Host personalization plan (local; SSH not attempted)."),
        (["host", "install-oh-my-zsh"], 1, "HostRequired"),
        (["host", "install-oh-my-zsh", "--ssh-host"], 1, "MissingValue"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--host", "example.com"],
         1, "ConflictingHosts"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--user", "root"],
         1, "ConflictingSshMode"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--port", "22"],
         1, "ConflictingSshMode"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--ssh-sock", "/tmp/agent.sock"],
         1, "ConflictingSshMode"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--identity", "/tmp/key"],
         1, "ConflictingSshMode"),
        (["host", "install-oh-my-zsh", "--ssh-host", "REDACTION-SENTINEL;id"],
         1, "InvalidSshHost"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--target-user", "REDACTION-SENTINEL;id"],
         1, "InvalidUser"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--tls", "manual"],
         1, "FlagNotAllowed"),
        (["host", "install-oh-my-zsh", "--ssh-host", "monitoring", "--ssh-op-path", "op://vault/item/key"],
         1, "FlagNotAllowed"),
        (["monitoring", "install", "--ssh-host", "monitoring"], 1, "FlagNotAllowed"),
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
        (["completion", "unsupported-shell"], 1, "UnknownCommand"),
        (["wizard", "--host", "REDACTION-SENTINEL"], 1, "UnknownFlag"),
        (["monitoring", "verify", "--host", "example.com", "--tls", "manual"], 1, "FlagNotAllowed"),
        (["monitoring", "install", "--host", "example.com", "--ssh-op-path", "REDACTION-SENTINEL"], 1, "InvalidReference"),
        (["monitoring", "agents", "install", "--host", "example.com",
          "--service", "one.service", "--plan"], 1, "NotImplemented"),
        (["monitoring", "firewall", "--host", "example.com", "--plan"], 1, "NotImplemented"),
        (["monitoring", "install", "--host", "example.com", "--tls", "manual", "--plan"], 1, "NotImplemented"),
        (["monitoring", "install", "--host", "example.com", "--agent-ip", "192.0.2.10", "--plan"], 1, "NotImplemented"),
        (["monitoring", "install", "--host", "example.com", "--admin-ip", "192.0.2.11", "--plan"], 1, "NotImplemented"),
        (["monitoring", "install", "--host", "example.com", "--domain", "monitor.example.com", "--plan"], 1, "NotImplemented"),
    ]
    for args, code, expected in cases:
        result = local_run(args, code, expected)
        if args == plan_args:
            plan_output = result.stdout

    # All three real components have install sections; native retention remains
    # distinct from provisional alert rendering and unavailable agent/runtime paths.
    vm_heading = "VictoriaMetrics: loopback:8428"
    vl_heading = "VictoriaLogs: loopback:9428"
    vt_heading = "VictoriaTraces: loopback:10428"
    unavailable_heading = "Not yet available:"
    for heading in (vm_heading, vl_heading, vt_heading, unavailable_heading):
        assert heading in plan_output, (heading, plan_output)
    metrics, remainder = plan_output.split(vm_heading, 1)[1].split(vl_heading, 1)
    logs, traces = remainder.split(vt_heading, 1)
    traces, unavailable = traces.split(unavailable_heading, 1)
    for required in ("pinned", "v1.151.0", "90d", "20%", "reserve"):
        assert required in metrics, (required, metrics)
    for required in ("pinned", "v1.52.0", "100y", "logical", "75%", "partition"):
        assert required in logs, (required, logs)
    assert "periodic" in logs.lower(), logs
    assert re.search(r"(?:newest|last) (?:two|2) (?:daily )?partitions", logs), logs
    for required in ("pinned", "v0.11.0", "100y", "logical", "75%", "partition"):
        assert required in traces, (required, traces)
    assert re.search(r"(?:newest|last) (?:two|2) (?:daily )?partitions", traces), traces
    for component in ("VictoriaMetrics", "VictoriaLogs", "VictoriaTraces"):
        assert component not in unavailable, (component, unavailable)
    for component in ("Grafana", "vmalert", "Alertmanager", "Vector", "vmagent",
                      "OTel", "agents", "firewall", "TLS", "Telegram"):
        assert component in unavailable, (component, unavailable)
    # The old host metric expressions must not be described as deployed alerts.
    assert "provisional" in plan_output.lower(), plan_output
    assert "No rule deployment or alert evaluation/delivery" in plan_output, plan_output
    assert "Healthy unchanged services are not restarted" in plan_output, plan_output
    checked += 1

    help_paths = [
        ["host"], ["host", "install-oh-my-zsh"],
        ["monitoring"], ["monitoring", "install"], ["monitoring", "verify"],
        ["monitoring", "status"], ["monitoring", "agents"],
        ["monitoring", "agents", "install"], ["monitoring", "agents", "verify"],
        ["monitoring", "agents", "status"], ["monitoring", "firewall"],
        ["completion"], ["wizard"],
    ]
    help_output = {}
    for path in help_paths:
        result = local_run([*path, "--help"], expected="Usage:")
        help_output[tuple(path)] = result.stdout
    install_help = help_output[("monitoring", "install")]
    assert "--tls" in install_help and "--host" in install_help
    assert "--service" not in install_help, install_help
    host_help = help_output[("host",)]
    assert "install-oh-my-zsh" in host_help, host_help
    host_install_help = help_output[("host", "install-oh-my-zsh")]
    for option in ("--ssh-host", "--host", "--target-user", "--plan", "--identity"):
        assert option in host_install_help, (option, host_install_help)
    assert "  --tls" not in host_install_help and "  --service" not in host_install_help
    verify_help = help_output[("monitoring", "verify")]
    assert "--host" in verify_help
    assert "  --tls" not in verify_help and "  --plan" not in verify_help, verify_help
    agents_help = help_output[("monitoring", "agents", "install")]
    assert "--service" in agents_help and "--station-ip" in agents_help
    assert "--tls" not in agents_help, agents_help
    firewall_help = help_output[("monitoring", "firewall")]
    assert "--admin-ip" in firewall_help and "--agent-ip" in firewall_help
    assert "--service" not in firewall_help and "--tls" not in firewall_help

    scripts = {}
    for shell in ("bash", "zsh", "fish"):
        result = local_run(["completion", shell])
        assert result.stdout.strip(), (shell, "Empty completion script")
        assert not result.stderr, (shell, result.stderr)
        assert local_run(["completion", shell]).stdout == result.stdout, shell
        for text in ("monitoring", "agents", "firewall", "host", "install-oh-my-zsh",
                     "ssh-host", "target-user", "tls", "manual", "cloudflare"):
            assert text in result.stdout, (shell, text)
        script = directory / f"dragontool.{shell}"
        script.write_text(result.stdout)
        scripts[shell] = script
        shell_binary = shutil.which(shell)
        if shell_binary is None:
            print(f"SKIP: {shell} completion syntax (shell not installed)")
            continue
        syntax = subprocess.run([shell_binary, "-n", str(script)], env=env,
                                input="", capture_output=True, text=True, timeout=15)
        assert syntax.returncode == 0, (shell, syntax.stderr)
        checked += 1

    bash = shutil.which("bash")
    if bash:
        def bash_complete(words):
            result = subprocess.run(
                [bash, "--noprofile", "--norc", "-c",
                 'source "$1"\nshift\nCOMP_WORDS=("$@")\n'
                 'COMP_CWORD=$((${#COMP_WORDS[@]} - 1))\n'
                 '_dragontool\nprintf "%s\\n" "${COMPREPLY[@]}"',
                 "completion-test", str(scripts["bash"]), *words],
                env=env, input="", capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (words, result.stderr)
            assert not marker.exists() and not provider_marker.exists()
            return set(result.stdout.splitlines()) - {""}

        assert {"monitoring", "host", "wizard", "completion"} <= bash_complete(["dragontool", ""])
        assert bash_complete(["dragontool", "host", ""]) == {"--help", "install-oh-my-zsh"}
        host_flags = bash_complete(["dragontool", "host", "install-oh-my-zsh", "--"])
        assert {"--host", "--ssh-host", "--target-user", "--plan", "--identity"} <= host_flags
        assert "--tls" not in host_flags and "--service" not in host_flags
        assert not bash_complete(["dragontool", "host", "install-oh-my-zsh", "--ssh-host", ""])
        assert {"install", "verify", "status", "agents", "firewall"} <= bash_complete(
            ["dragontool", "monitoring", ""])
        assert {"install", "verify", "status"} <= bash_complete(["dragontool", "monitoring", "agents", ""])
        install_flags = bash_complete(["dragontool", "monitoring", "install", "--"])
        assert {"--host", "--tls", "--plan", "--identity"} <= install_flags
        assert "--service" not in install_flags and "--station-ip" not in install_flags
        verify_flags = bash_complete(["dragontool", "monitoring", "verify", "--"])
        assert "--host" in verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert bash_complete(["dragontool", "monitoring", "install", "--tls", ""]) == {"manual", "cloudflare"}
        assert bash_complete(["dragontool", "monitoring", "install", "--tls", "c"]) == {"cloudflare"}
        # A value that looks like a command must not switch the completion context.
        assert "--tls" in bash_complete(["dragontool", "monitoring", "install", "--host", "agents", "--"])
        assert bash_complete(["dragontool", "completion", ""]) >= {"bash", "zsh", "fish"}
        identity = directory / "identity-file"
        identity.write_text("path-completion fixture, not a private key\n")
        assert str(identity) in bash_complete(["dragontool", "monitoring", "install", "--identity", str(directory / "identity-")])
        checked += 13
    else:
        print("SKIP: Bash completion behavior (shell not installed)")

    zsh = shutil.which("zsh")
    if zsh:
        def zsh_candidates(words):
            # Capture the candidates handed to Zsh's native UI. No terminal is needed.
            result = subprocess.run(
                [zsh, "-f", "-c",
                 'script=$1\nshift\nwords=("$@")\nCURRENT=${#words[@]}\n'
                 '_describe() { print -rl -- "${candidates[@]}"; }\n'
                 '_files() { print -r -- NATIVE_PATH_COMPLETION; }\n'
                 'source "$script"', "completion-test", str(scripts["zsh"]), *words],
                env=env, input="", capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (words, result.stderr)
            assert not marker.exists() and not provider_marker.exists()
            return {line.split(":", 1)[0] for line in result.stdout.splitlines()}

        assert {"monitoring", "host", "wizard", "completion"} <= zsh_candidates(["dragontool", ""])
        assert zsh_candidates(["dragontool", "host", ""]) == {"--help", "install-oh-my-zsh"}
        host_flags = zsh_candidates(["dragontool", "host", "install-oh-my-zsh", "--"])
        assert {"--ssh-host", "--target-user", "--plan", "--identity"} <= host_flags
        assert "--tls" not in host_flags and "--service" not in host_flags
        assert zsh_candidates(["dragontool", "host", "install-oh-my-zsh", "--identity", ""]) == {"NATIVE_PATH_COMPLETION"}
        assert {"install", "verify", "status"} <= zsh_candidates(["dragontool", "monitoring", "agents", ""])
        assert zsh_candidates(["dragontool", "monitoring", "install", "--tls", ""]) == {"manual", "cloudflare"}
        verify_flags = zsh_candidates(["dragontool", "monitoring", "verify", "--"])
        assert "--host" in verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert zsh_candidates(["dragontool", "monitoring", "install", "--identity", ""]) == {"NATIVE_PATH_COMPLETION"}
        checked += 8
    else:
        print("SKIP: Zsh completion behavior (shell not installed)")

    fish = shutil.which("fish")
    if fish:
        def fish_complete(command):
            result = subprocess.run(
                [fish, "--no-config", "-c", 'source "$argv[1]"\ncomplete -C "$argv[2]"',
                 str(scripts["fish"]), command],
                env=env, input="", capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (command, result.stderr)
            assert not marker.exists() and not provider_marker.exists()
            return {line.split("\t", 1)[0] for line in result.stdout.splitlines()}

        assert {"monitoring", "host", "wizard", "completion"} <= fish_complete("dragontool ")
        assert fish_complete("dragontool host ") == {"install-oh-my-zsh"}
        host_flags = fish_complete("dragontool host install-oh-my-zsh --")
        assert {"--ssh-host", "--target-user", "--plan", "--identity"} <= host_flags
        assert "--tls" not in host_flags and "--service" not in host_flags
        assert not fish_complete("dragontool host install-oh-my-zsh --ssh-host ")
        assert not fish_complete("dragontool host install-oh-my-zsh --target-user ")
        assert {"install", "verify", "status"} <= fish_complete("dragontool monitoring agents ")
        assert fish_complete("dragontool monitoring install --tls ") == {"manual", "cloudflare"}
        verify_flags = fish_complete("dragontool monitoring verify --")
        assert "--host" in verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert fish_complete("dragontool monitoring install --tls c") == {"cloudflare"}
        assert not fish_complete("dragontool monitoring install --host ")
        assert not fish_complete("dragontool monitoring install --ssh-op-path ")
        identity = directory / "fish-identity-file"
        identity.write_text("path-completion fixture, not a private key\n")
        assert str(identity) in fish_complete(f"dragontool monitoring install --identity {directory}/fish-identity-")
        assert "--tls" in fish_complete("dragontool monitoring install --host 'agents' --")
        checked += 13
    else:
        print("SKIP: Fish completion behavior (shell not installed)")

    # Every supported remote workflow reaches the transport and fails safely
    # under fake SSH; this is dispatch coverage, not a successful VM deployment.
    for command in ("install", "verify", "status"):
        marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), "monitoring", command, "--host", "example.com"],
                                env=env, input="", capture_output=True, text=True, timeout=15)
        assert marker.exists(), (command, "The supported workflow did not invoke SSH")
        assert result.returncode == 1, (command, result.stdout, result.stderr)
        phase = "status" if command == "status" else "detect"
        assert f"Failed at {phase};" in result.stdout, result.stdout
        if command != "status":
            assert "0 steps completed" in result.stdout, result.stdout
        assert "Component:" in result.stdout, result.stdout
        assert "REDACTION-SENTINEL" not in result.stdout + result.stderr
        assert not provider_marker.exists(), "Failed SSH invoked a secret/network provider"
        checked += 1

    for connection in (["--ssh-host", "monitoring"],
                       ["--host", "example.com", "--user", "root"]):
        marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), "host", "install-oh-my-zsh", *connection],
                                env=env, input="", capture_output=True, text=True, timeout=15)
        assert marker.exists(), (connection, "Host workflow did not invoke SSH")
        assert result.returncode == 1, (connection, result.stdout, result.stderr)
        assert "Host personalization" in result.stdout, result.stdout
        assert "Failed at inspect." in result.stdout, result.stdout
        assert "REDACTION-SENTINEL" not in result.stdout + result.stderr
        assert not provider_marker.exists(), "Failed SSH invoked a secret/network provider"
        checked += 1
print(f"PASS: {checked} CLI smoke checks")
