#!/usr/bin/env python3
"""Exercise the built CLI without allowing a real SSH connection."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
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
    host_change_flags = ("--set-default-shell", "--update-managed-zshrc")
    config = directory / "monitoring config.toml"
    config.write_text('''version = 1
[connection]
ssh_host = "monitoring"
[grafana]
username = { op = "op://REDACTION-SENTINEL/Grafana/username" }
password = { op = "op://REDACTION-SENTINEL/Grafana/password" }
''')
    config_args = ["monitoring", "install", "--config", str(config), "--plan"]
    configured_credentials = "administrator credentials: configured via secret references"
    invalid_configs = []
    for name, contents, failure in (
        ("literal", 'version = 1\n[grafana]\npassword = "REDACTION-SENTINEL"\n', "InvalidMonitoringConfig"),
        ("unknown", 'version = 1\n[connection]\nhost = "REDACTION-SENTINEL"\n', "UnknownMonitoringConfigKey"),
        ("duplicate", 'version = 1\nversion = 1\n', "DuplicateMonitoringConfigKey"),
        ("version", 'version = 2\n', "UnsupportedMonitoringConfigVersion"),
        ("reference", 'version = 1\n[grafana]\nusername = { op = "REDACTION-SENTINEL" }\n', "InvalidSecretReference"),
        ("oversize", "#" * (64 * 1024 + 1), "MonitoringConfigTooLarge"),
    ):
        invalid = directory / f"{name}.toml"
        invalid.write_text(contents)
        invalid_configs.append((invalid, failure))
    partial_config = directory / "partial.toml"
    partial_config.write_text('version = 1\n[connection]\nssh_host = "monitoring"\n'
                              '[grafana]\nusername = { op = "op://Example/Grafana/username" }\n')
    plan_output = ""
    host_plans = {}
    cases = [
        (["--help"], 0, "VictoriaTraces"),
        ([], 0, "Usage:"),
        (["wizard"], 1, "InteractiveTerminalRequired"),
        (plan_args, 0, "No remote operations performed"),
        (host_plan_args, 0, "Host personalization plan (local; SSH not attempted)."),
        ([*host_plan_args, *host_change_flags], 0,
         "Host personalization plan (local; SSH not attempted)."),
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
        (["monitoring", "install", "--ssh-host", "REDACTION-SENTINEL", "--plan"], 0, "Grafana: loopback:3000"),
        (config_args, 0, configured_credentials),
        (["monitoring", "install", "--config", os.path.relpath(config), "--plan"], 0, configured_credentials),
        ([*config_args, "--ssh-host", "other"], 0, configured_credentials),
        ([*config_args, "--host", "example.com", "--user", "ops", "--port", "2222"], 0, configured_credentials),
        ([*config_args, "--user", "root"], 1, "ConflictingSshMode"),
        ([*config_args, "--port", "22"], 1, "ConflictingSshMode"),
        ([*config_args, "--grafana-user-op", "op://Other/Grafana/username"], 0, configured_credentials),
        (["monitoring", "install", "--config", str(partial_config), "--plan"], 1, "GrafanaCredentialReferencesRequired"),
        (["monitoring", "install", "--config", str(partial_config), "--grafana-password-op", "op://Other/Grafana/password", "--plan"], 0, configured_credentials),
        (["monitoring", "verify", "--config", str(directory / "missing.toml"), "--help"], 0, "Usage:"),
        (["monitoring", "install", "--config", str(directory / "missing.toml"), "--plan"], 1, "UnableToReadMonitoringConfig"),
        (["monitoring", "install", "--config", str(directory), "--plan"], 1, "InvalidMonitoringConfigFile"),
        (["monitoring", "install", "--ssh-host", "monitoring", "--grafana-user-op", "op://Example/Grafana/username", "--plan"], 1, "GrafanaCredentialReferencesRequired"),
        (["monitoring", "install", "--ssh-host", "monitoring", "--grafana-user-op", "op://Example/Grafana/username", "--grafana-password-op", "op://Example/Grafana/password", "--plan"], 0, configured_credentials),
        (["monitoring", "status", "--config", str(config), "--grafana-user-op", "op://Example/Grafana/username"], 1, "FlagNotAllowed"),
        (["host", "install-oh-my-zsh", "--config", str(config)], 1, "FlagNotAllowed"),
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
    for invalid, failure in invalid_configs:
        cases.append((["monitoring", "install", "--config", str(invalid), "--ssh-host", "monitoring", "--plan"], 1, failure))
    for command in ("install", "verify", "status"):
        base = ["monitoring", command, "--ssh-host", "monitoring"]
        cases.append(([*base, "--host", "example.com"], 1, "ConflictingHosts"))
        for flag, value in (("--user", "root"), ("--port", "22"),
                            ("--identity", "/tmp/key"), ("--ssh-sock", "/tmp/sock"),
                            ("--ssh-op-path", "op://vault/item/key")):
            cases.append(([*base, flag, value], 1, "ConflictingSshMode"))
        cases.append((["monitoring", command, "--ssh-host", "REDACTION-SENTINEL;id"], 1, "InvalidSshHost"))
    cases.append((["monitoring", "install", "--ssh-host", "monitoring", "--tls", "manual", "--plan"], 1, "NotImplemented"))
    for flag in host_change_flags:
        cases.extend([
            ([*host_plan_args, flag], 0, "Host personalization plan (local; SSH not attempted)."),
            ([*host_plan_args, flag, flag], 1, "DuplicateFlag"),
            ([*host_plan_args, flag, "true"], 1, "UnknownFlag"),
            ([*host_plan_args, f"{flag}=true"], 1, "UnknownFlag"),
            ([*plan_args, flag], 1, "FlagNotAllowed"),
        ])
    for args, code, expected in cases:
        result = local_run(args, code, expected)
        if args == plan_args:
            plan_output = result.stdout
        if args[:2] == ["host", "install-oh-my-zsh"] and code == 0 and "--plan" in args:
            key = tuple(flag in args for flag in host_change_flags)
            host_plans[key] = result.stdout

    for (set_shell, update_rc), output in host_plans.items():
        shell_text = ("Login shell: set to discovered zsh only if different and listed in /etc/shells."
                      if set_shell else "Login shell: unchanged (no --set-default-shell).")
        rc_text = (".zshrc: update only an exact known DragonTools template; preserve arbitrary or edited files."
                   if update_rc else ".zshrc: create only if absent; preserve existing files (no --update-managed-zshrc).")
        assert shell_text in output, (set_shell, output)
        assert rc_text in output, (update_rc, output)
    assert set(host_plans) == {(False, False), (True, False), (False, True), (True, True)}
    checked += 1

    # All four real components have install sections; native retention remains
    # distinct from provisional alert rendering and unavailable agent/runtime paths.
    vm_heading = "VictoriaMetrics: loopback:8428"
    vl_heading = "VictoriaLogs: loopback:9428"
    vt_heading = "VictoriaTraces: loopback:10428"
    grafana_heading = "Grafana: loopback:3000"
    unavailable_heading = "Not yet available:"
    for heading in (vm_heading, vl_heading, vt_heading, grafana_heading, unavailable_heading):
        assert heading in plan_output, (heading, plan_output)
    metrics, remainder = plan_output.split(vm_heading, 1)[1].split(vl_heading, 1)
    logs, traces = remainder.split(vt_heading, 1)
    traces, grafana = traces.split(grafana_heading, 1)
    grafana, unavailable = grafana.split(unavailable_heading, 1)
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
    for required in ("pinned OSS release", "local authentication enabled", "Metrics datasource", "http://127.0.0.1:8428", "Traces datasource", "http://127.0.0.1:10428/select/jaeger", "SSH port forwarding only", "manual verification"):
        assert required in grafana, (required, grafana)
    assert "Grafana Logs datasource" in unavailable and "dashboards" in unavailable
    for component in ("vmalert", "Alertmanager", "Vector", "vmagent",
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
    assert "--tls" in install_help and "--host" in install_help and "--ssh-host" in install_help
    assert all(flag in install_help for flag in ("--config", "--grafana-user-op", "--grafana-password-op"))
    assert "--service" not in install_help, install_help
    host_help = help_output[("host",)]
    assert "install-oh-my-zsh" in host_help, host_help
    host_install_help = help_output[("host", "install-oh-my-zsh")]
    for option in ("--ssh-host", "--host", "--target-user", "--plan", "--identity", *host_change_flags):
        assert option in host_install_help, (option, host_install_help)
    for text in ("preserved by default", "user@hostname directory prompt", "/etc/shells",
                 "even with a marker"):
        assert text in host_install_help, (text, host_install_help)
    assert "  --tls" not in host_install_help and "  --service" not in host_install_help
    for flag in host_change_flags:
        assert flag not in install_help, (flag, install_help)
    verify_help = help_output[("monitoring", "verify")]
    assert "--host" in verify_help and "--ssh-host" in verify_help
    assert all(flag in verify_help for flag in ("--config", "--grafana-user-op", "--grafana-password-op"))
    status_help = help_output[("monitoring", "status")]
    assert "--config" in status_help and "  --grafana-user-op" not in status_help
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
                     "ssh-host", "target-user", "set-default-shell", "update-managed-zshrc",
                     "tls", "manual", "cloudflare", "config", "grafana-user-op", "grafana-password-op"):
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
        assert set(host_change_flags) <= host_flags
        assert "--tls" not in host_flags and "--service" not in host_flags
        for flag in host_change_flags:
            # Boolean flags must not consume the following option as a value.
            assert "--ssh-host" in bash_complete(["dragontool", "host", "install-oh-my-zsh", flag, "--"])
        assert not bash_complete(["dragontool", "host", "install-oh-my-zsh", "--ssh-host", ""])
        assert {"install", "verify", "status", "agents", "firewall"} <= bash_complete(
            ["dragontool", "monitoring", ""])
        assert {"install", "verify", "status"} <= bash_complete(["dragontool", "monitoring", "agents", ""])
        install_flags = bash_complete(["dragontool", "monitoring", "install", "--"])
        assert {"--host", "--ssh-host", "--tls", "--plan", "--identity"} <= install_flags
        assert {"--config", "--grafana-user-op", "--grafana-password-op"} <= install_flags
        assert "--service" not in install_flags and "--station-ip" not in install_flags
        assert not set(host_change_flags) & install_flags
        verify_flags = bash_complete(["dragontool", "monitoring", "verify", "--"])
        assert {"--host", "--ssh-host"} <= verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert {"--config", "--grafana-user-op", "--grafana-password-op"} <= verify_flags
        assert bash_complete(["dragontool", "monitoring", "install", "--tls", ""]) == {"manual", "cloudflare"}
        assert bash_complete(["dragontool", "monitoring", "install", "--tls", "c"]) == {"cloudflare"}
        # A value that looks like a command must not switch the completion context.
        assert "--tls" in bash_complete(["dragontool", "monitoring", "install", "--host", "agents", "--"])
        assert bash_complete(["dragontool", "completion", ""]) >= {"bash", "zsh", "fish"}
        identity = directory / "identity-file"
        identity.write_text("path-completion fixture, not a private key\n")
        assert str(identity) in bash_complete(["dragontool", "monitoring", "install", "--identity", str(directory / "identity-")])
        assert str(config) in bash_complete(["dragontool", "monitoring", "install", "--config", str(directory / "monitoring")])
        assert "--grafana-user-op" not in bash_complete(["dragontool", "monitoring", "status", "--"])
        checked += 17
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
        assert set(host_change_flags) <= host_flags
        assert "--tls" not in host_flags and "--service" not in host_flags
        for flag in host_change_flags:
            assert "--ssh-host" in zsh_candidates(["dragontool", "host", "install-oh-my-zsh", flag, "--"])
        assert zsh_candidates(["dragontool", "host", "install-oh-my-zsh", "--identity", ""]) == {"NATIVE_PATH_COMPLETION"}
        assert {"install", "verify", "status"} <= zsh_candidates(["dragontool", "monitoring", "agents", ""])
        assert zsh_candidates(["dragontool", "monitoring", "install", "--tls", ""]) == {"manual", "cloudflare"}
        verify_flags = zsh_candidates(["dragontool", "monitoring", "verify", "--"])
        assert {"--host", "--ssh-host"} <= verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert {"--config", "--grafana-user-op", "--grafana-password-op"} <= verify_flags
        assert zsh_candidates(["dragontool", "monitoring", "install", "--identity", ""]) == {"NATIVE_PATH_COMPLETION"}
        assert zsh_candidates(["dragontool", "monitoring", "verify", "--config", ""]) == {"NATIVE_PATH_COMPLETION"}
        checked += 11
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
        assert set(host_change_flags) <= host_flags
        assert "--tls" not in host_flags and "--service" not in host_flags
        for flag in host_change_flags:
            assert "--ssh-host" in fish_complete(f"dragontool host install-oh-my-zsh {flag} --")
        assert not fish_complete("dragontool host install-oh-my-zsh --ssh-host ")
        assert not fish_complete("dragontool host install-oh-my-zsh --target-user ")
        assert {"install", "verify", "status"} <= fish_complete("dragontool monitoring agents ")
        assert fish_complete("dragontool monitoring install --tls ") == {"manual", "cloudflare"}
        verify_flags = fish_complete("dragontool monitoring verify --")
        assert {"--host", "--ssh-host"} <= verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert {"--config", "--grafana-user-op", "--grafana-password-op"} <= verify_flags
        assert fish_complete("dragontool monitoring install --tls c") == {"cloudflare"}
        assert not fish_complete("dragontool monitoring install --host ")
        assert not fish_complete("dragontool monitoring install --ssh-op-path ")
        identity = directory / "fish-identity-file"
        identity.write_text("path-completion fixture, not a private key\n")
        assert str(identity) in fish_complete(f"dragontool monitoring install --identity {directory}/fish-identity-")
        assert "--tls" in fish_complete("dragontool monitoring install --host 'agents' --")
        assert "--grafana-user-op" not in fish_complete("dragontool monitoring status --")
        assert not fish_complete("dragontool monitoring install --grafana-user-op ")
        checked += 17
    else:
        print("SKIP: Fish completion behavior (shell not installed)")

    # Every supported remote workflow reaches the transport and fails safely
    # under fake SSH; this is dispatch coverage, not a successful VM deployment.
    for command in ("install", "verify", "status"):
        for connection in (["--host", "example.com"], ["--ssh-host", "monitoring"]):
            marker.unlink(missing_ok=True)
            result = subprocess.run([str(binary), "monitoring", command, *connection],
                                    env=env, input="", capture_output=True, text=True, timeout=15)
            assert marker.exists(), (command, connection, "The supported workflow did not invoke SSH")
            assert result.returncode == 1, (command, result.stdout, result.stderr)
            phase = "status" if command == "status" else "detect"
            assert f"Failed at {phase};" in result.stdout, result.stdout
            if command != "status":
                assert "0 steps completed" in result.stdout, result.stdout
            assert "Component:" in result.stdout, result.stdout
            assert "REDACTION-SENTINEL" not in result.stdout + result.stderr
            assert not provider_marker.exists(), "Failed SSH invoked a secret/network provider"
            checked += 1

    # A normal status command reads references from config but must never resolve
    # them. It only reaches the intentionally failing fake SSH transport.
    marker.unlink(missing_ok=True)
    status = subprocess.run([str(binary), "monitoring", "status", "--config", str(config)],
                            env=env, input="", capture_output=True, text=True, timeout=15)
    assert marker.exists() and status.returncode == 1, (status.stdout, status.stderr)
    assert "Failed at status;" in status.stdout, status.stdout
    assert not provider_marker.exists(), "Status resolved configured Grafana credentials"
    assert "REDACTION-SENTINEL" not in status.stdout + status.stderr
    checked += 1

    # Resolution failure happens before SSH and cannot reveal provider output or
    # configured reference paths. The real 1Password CLI is never invoked.
    marker.unlink(missing_ok=True)
    op = directory / "op"
    op.write_text('#!/bin/sh\n: > "$DRAGONTOOLS_PROVIDER_MARKER"\n'
                  'printf "REDACTION-SENTINEL provider stdout\\n"\n'
                  'printf "REDACTION-SENTINEL provider stderr\\n" >&2\nexit 92\n')
    op.chmod(0o755)
    for command in ("install", "verify"):
        provider_marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), "monitoring", command, "--config", str(config)],
                                env=env, input="", capture_output=True, text=True, timeout=15)
        assert result.returncode == 1 and provider_marker.exists(), (result.stdout, result.stderr)
        assert not marker.exists(), "Credential resolution failure reached SSH"
        assert "REDACTION-SENTINEL" not in result.stdout + result.stderr
        checked += 1
    provider_marker.unlink(missing_ok=True)

    for empty_field, expected_error in (("username", "GrafanaUsernameResolutionFailed"),
                                        ("password", "GrafanaPasswordResolutionFailed")):
        values = {"username": "REDACTION-SENTINEL-user", "password": "REDACTION-SENTINEL-password"}
        values[empty_field] = ""
        op.write_text(f"#!{sys.executable}\nimport os, sys\nvalues = {values!r}\n"
                      + "with open(os.environ['DRAGONTOOLS_PROVIDER_MARKER'], 'a') as output: output.write('resolved\\n')\n"
                      + "sys.stdout.write(values[sys.argv[-1].rsplit('/', 1)[1]])\n")
        for command in ("install", "verify"):
            provider_marker.unlink(missing_ok=True)
            result = subprocess.run([str(binary), "monitoring", command, "--config", str(config)],
                                    env=env, input="", capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            assert result.returncode == 1 and expected_error in output, output
            assert provider_marker.exists() and not marker.exists(), "Empty secret reached SSH"
            assert "REDACTION-SENTINEL" not in output, output
            checked += 1
    provider_marker.unlink(missing_ok=True)

    missing_provider_bin = directory / "without-op"
    missing_provider_bin.mkdir()
    shutil.copy(ssh, missing_provider_bin / "ssh")
    without_op = dict(env, PATH=str(missing_provider_bin))
    for command in ("install", "verify"):
        result = subprocess.run([str(binary), "monitoring", command, "--config", str(config)],
                                env=without_op, input="", capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == 1 and "GrafanaUsernameResolutionFailed" in output, output
        assert not marker.exists() and not provider_marker.exists(), "Missing op reached SSH or a provider"
        assert "REDACTION-SENTINEL" not in output, output
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

    # Reach a semantic readiness check through fake SSH without executing any
    # remote command. A deterministic failure is reported once and stays redacted.
    ssh.write_text('''#!/bin/sh
for argument do command=$argument; done
case "$command" in
  *'/etc/os-release'*) printf 'ubuntu\\n24.04\\nx86_64\\n';;
  *"stat -f -c"*) printf '1000000 4096';;
  *'dragontools-victoriametrics-self_scrape_ready'*)
    printf 'probe\\n' >> "$DRAGONTOOLS_TEST_MARKER"
    printf 'REDACTION-SENTINEL remote stdout\\n'
    printf 'REDACTION-SENTINEL remote stderr\\n' >&2
    exit 1;;
  *'dragontools-victoriametrics-managed_state'*|*'dragontools-victoriametrics-service_active'*|*'dragontools-victoriametrics-http_ready'*) exit 0;;
  *) exit 91;;
esac
''')
    for connection in (["--host", "example.com"], ["--ssh-host", "monitoring"]):
        marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), "monitoring", "verify", *connection],
                                env=env, input="", capture_output=True, text=True, timeout=15)
        assert result.returncode == 1, (result.stdout, result.stderr)
        assert "Component: VictoriaMetrics. Check: self_scrape_ready." in result.stdout, result.stdout
        assert marker.read_text() == "probe\n", "Deterministic failure was retried"
        assert "REDACTION-SENTINEL" not in result.stdout + result.stderr
        assert "vm_app_version" not in result.stdout + result.stderr, "Remote command was exposed"
        assert not provider_marker.exists()
        checked += 1

    # Exercise real controller process/SSH wiring with successful fake replies.
    # This validates transport and progress only; it executes no remote helper.
    # Dummy resolved values must reach credential checks solely through stdin.
    dummy_credentials = {
        "username": "PRIVATE-GRAFANA-USERNAME",
        "password": "PRIVATE-GRAFANA-PASSWORD '\"$(literal)\\value\t",
    }
    op.write_text(f"#!{sys.executable}\n" + "import os, sys\n"
                  + f"values = {dummy_credentials!r}\n"
                  + "assert len(sys.argv) == 4 and sys.argv[1:3] == ['read', '--no-newline']\n"
                  + "field = sys.argv[3].rsplit('/', 1)[1]\n"
                  + "assert field in values\n"
                  + "with open(os.environ['DRAGONTOOLS_PROVIDER_MARKER'], 'a') as output: output.write('resolved\\n')\n"
                  + "sys.stdout.write(values[field])\n")
    ssh.write_text(f"#!{sys.executable}\n" + f"expected = {dummy_credentials!r}\n" + '''
import json, os, sys
from pathlib import Path
assert all(value not in argument for value in expected.values() for argument in sys.argv)
command = sys.argv[-1]
marker = Path(os.environ['DRAGONTOOLS_TEST_MARKER'])
metrics = {"status": "success", "data": {"resultType": "vector", "result": [
    {"metric": {"__name__": "vm_app_version"}, "value": [1, "1"]}]}}
if "Pinned Grafana credential operations" in command:
    assert json.load(sys.stdin) == expected
    with marker.open('a') as output: output.write('stdin credentials verified\\n')
    sys.stdout.write('unchanged')
elif '/etc/os-release' in command:
    sys.stdout.write('ubuntu\\n24.04\\nx86_64\\n')
elif 'stat -f -c' in command:
    sys.stdout.write('1000000 4096')
elif 'dragontools-victoriametrics-self_scrape_ready' in command:
    sys.stdout.write(json.dumps(metrics))
elif 'dragontools-victorialogs-storage_ready' in command:
    sys.stdout.write('vl_storage_is_read_only{path="/var/lib/dragontools/victorialogs"} 0\\n')
elif 'dragontools-victoriatraces-storage_ready' in command:
    sys.stdout.write('vt_storage_is_read_only{path="/var/lib/dragontools/victoriatraces"} 0\\n')
elif 'dragontools-grafana-http_ready' in command:
    sys.stdout.write('{"grafana":{"database":"ok","version":"13.2.2"}}')
elif 'dragontools-grafana-backend_ready' in command:
    sys.stdout.write(json.dumps({"metrics": metrics, "traces": {
        "data": [], "errors": None, "total": 0, "limit": 0, "offset": 0}}))
else:
    sys.stdout.write('unchanged')
''')
    for command in ("install", "verify", "install"):
        marker.unlink(missing_ok=True)
        provider_marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), "monitoring", command, "--config", str(config)],
                                env=env, input="", capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (command, result.stdout, result.stderr)
        output = result.stdout + result.stderr
        assert all(value not in output for value in dummy_credentials.values()), output
        assert "REDACTION-SENTINEL" not in output, output
        assert provider_marker.read_text() == "resolved\nresolved\n"
        checks = 2 if command == "install" else 1
        assert marker.read_text() == "stdin credentials verified\n" * checks
        for number, component in enumerate(("VictoriaMetrics", "VictoriaLogs", "VictoriaTraces", "Grafana"), 1):
            heading = f"[{number}/4] {component}"
            assert heading in result.stdout, result.stdout
            component_output = result.stdout.split(heading, 1)[1].split("[", 1)[0]
            assert "verifying..." in component_output and "healthy; no changes" in component_output
            assert component_output.index("verifying...") < component_output.index("healthy; no changes")
        assert "administrator credentials verified" in result.stdout
        assert "administrator credentials updated" not in result.stdout
        if command == "install":
            assert "No changes required." in result.stdout
        checked += 1
print(f"PASS: {checked} CLI smoke checks")
