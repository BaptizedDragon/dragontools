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
    station_config = directory / "station.toml"
    station_config.write_text(config.read_text() + '''
[telegram]
bot_token = { op = "op://REDACTION-SENTINEL/DragonTools/token" }
chat_id = { op = "op://REDACTION-SENTINEL/DragonTools/chat_id" }
[[probe]]
name = "landing"
url = "HTTPS://EXAMPLE.COM:443/healthz"
[[probe]]
name = "orders"
url = "https://orders.example.com/healthz"
''')
    configured_credentials = "administrator credentials: configured via secret references"
    invalid_configs = []
    for name, contents, failure in (
        ("literal", 'version = 1\n[grafana]\npassword = "REDACTION-SENTINEL"\n', "InvalidMonitoringConfig"),
        ("unknown", 'version = 1\n[connection]\nhost = "REDACTION-SENTINEL"\n', "UnknownMonitoringConfigKey"),
        ("duplicate", 'version = 1\nversion = 1\n', "DuplicateMonitoringConfigKey"),
        ("version", 'version = 2\n', "UnsupportedMonitoringConfigVersion"),
        ("reference", 'version = 1\n[grafana]\nusername = { op = "REDACTION-SENTINEL" }\n', "InvalidSecretReference"),
        ("probe-duplicate", "version=1\n[[probe]]\nname='same'\nurl='https://example.com/a'\n[[probe]]\nname='same'\nurl='https://example.com/b'\n", "DuplicateProbeName"),
        ("probe-scheme", "version=1\n[[probe]]\nname='example'\nurl='ftp://example.com/'\n", "InvalidProbeUrl"),
        ("probe-credentials", "version=1\n[[probe]]\nname='example'\nurl='https://REDACTION-SENTINEL@example.com/'\n", "InvalidProbeUrl"),
        ("probe-query", "version=1\n[[probe]]\nname='example'\nurl='https://example.com/?secret=REDACTION-SENTINEL'\n", "InvalidProbeUrl"),
        ("telegram-partial", "version=1\n[telegram]\nbot_token={op='op://Example/DragonTools/token'}\n", "TelegramCredentialReferencesRequired"),
        ("telegram-literal", "version=1\n[telegram]\nbot_token='REDACTION-SENTINEL'\n", "InvalidMonitoringConfig"),
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
        (["monitoring", "install", "--config", str(station_config), "--plan"], 0, "External HTTP probes: 2 configured"),
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
        (["monitoring", "notify-test", "--ssh-host", "monitoring"], 1, "TelegramConfigurationRequired"),
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

    # Storage/Grafana and four station services are implemented; agents remain
    # explicitly unavailable and plans perform no secret or network operations.
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
    for required in ("pinned OSS release", "local authentication enabled", "Metrics datasource", "http://127.0.0.1:8428", "Logs datasource", "http://127.0.0.1:9428", "official VictoriaLogs datasource plugin", "victoriametrics-logs-datasource", "0.32.0", "signed, SHA256-pinned", "Traces datasource", "http://127.0.0.1:10428/select/jaeger", "SSH port forwarding only", "manual verification"):
        assert required in grafana, (required, grafana)
    assert "Grafana Logs datasource" not in unavailable and "dashboards" in unavailable
    assert "Logs plugin query requires administrator references" in grafana
    configured_plan = local_run(config_args).stdout
    assert "verify Logs plugin health and a bounded read-only LogsQL query through Grafana" in configured_plan
    assert "Logs plugin query requires administrator references" not in configured_plan
    for component in ("Vector", "vmagent", "OTel", "agents", "firewall", "TLS"):
        assert component in unavailable, (component, unavailable)
    for component in ("vmalert", "Alertmanager", "Telegram"):
        assert component not in unavailable, (component, unavailable)
    for text in ("eight services", "loopback:9115", "loopback:9093", "logs loopback:8880", "metrics loopback:8881",
                 "ServiceProbeFailed", "probe_success == 0 for 2m", "reload without restart", "notify-test is a separate explicit command"):
        assert text in plan_output, (text, plan_output)
    assert "Host and systemd-service metric rules await verified agent contracts." in plan_output
    assert "Healthy unchanged services are not restarted" in plan_output, plan_output
    checked += 1

    help_paths = [
        ["host"], ["host", "install-oh-my-zsh"],
        ["monitoring"], ["monitoring", "install"], ["monitoring", "verify"],
        ["monitoring", "status"], ["monitoring", "notify-test"], ["monitoring", "agents"],
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
        for text in ("monitoring", "notify-test", "agents", "firewall", "host", "install-oh-my-zsh",
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
        assert {"install", "verify", "status", "notify-test", "agents", "firewall"} <= bash_complete(
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

    # Successful status performs eight service-state queries plus a stored-probe
    # read, with no target probes or credential resolution.
    # Datasource names are expected policy, never evidence of a plugin query.
    saved_ssh = ssh.read_text()
    ssh.write_text("""#!/bin/sh
for argument do command=$argument; done
case "$command" in
  *systemctl*show*--property=LoadState,ActiveState,SubState,UnitFileState*)
    printf 'status\\n' >> "$DRAGONTOOLS_TEST_MARKER"
    printf 'LoadState=loaded\\nActiveState=active\\nSubState=running\\nUnitFileState=enabled\\n';;
  *source=base64.b64decode*) printf 'probes\\n' >> "$DRAGONTOOLS_TEST_MARKER"; printf '[]';;
  *) exit 91;;
esac
""")
    marker.unlink(missing_ok=True)
    status = subprocess.run([str(binary), "monitoring", "status", "--config", str(config)],
                            env=env, input="", capture_output=True, text=True, timeout=15)
    assert status.returncode == 0, (status.stdout, status.stderr)
    assert marker.read_text() == "status\n" * 8 + "probes\n"
    assert "none configured" in status.stdout
    assert "datasources (expected policy; not queried):" in status.stdout
    for mapping in ("Metrics -> VictoriaMetrics", "Logs -> VictoriaLogs", "Traces -> VictoriaTraces"):
        assert mapping in status.stdout, status.stdout
    assert "query verified" not in status.stdout and "credentials verified" not in status.stdout
    assert "REDACTION-SENTINEL" not in status.stdout + status.stderr
    assert not provider_marker.exists(), "Successful status resolved references"
    ssh.write_text(saved_ssh)
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
    dummy_telegram = {"token": "123456789:PRIVATE_TELEGRAM_TOKEN", "chat_id": "-1009876543210"}
    dummy_values = {**dummy_credentials, **dummy_telegram}
    op.write_text(f"#!{sys.executable}\n" + "import os, sys\n"
                  + f"values = {dummy_values!r}\n"
                  + "assert len(sys.argv) == 4 and sys.argv[1:3] == ['read', '--no-newline']\n"
                  + "field = sys.argv[3].rsplit('/', 1)[1]\n"
                  + "assert field in values\n"
                  + "with open(os.environ['DRAGONTOOLS_PROVIDER_MARKER'], 'a') as output: output.write('resolved\\n')\n"
                  + "sys.stdout.write(values[field])\n")
    def zig_multiline(name):
        source = Path("src/monitoring/blackbox_tests.zig").read_text()
        block = source.split(f"pub const {name} =\n", 1)[1].split(";\n", 1)[0]
        return "\n".join(line.strip()[2:] for line in block.splitlines() if line.strip().startswith("\\\\"))
    ssh.write_text(f"#!{sys.executable}\n" + f"expected = {dummy_credentials!r}\ntelegram = {dummy_telegram!r}\n"
                  + f"blackbox_config = {zig_multiline('loaded_config')!r}\nblackbox_metrics = {zig_multiline('exporter_metrics')!r}\n" + '''
import base64, json, os, shlex, sys
from pathlib import Path
assert all(value not in argument for value in [*expected.values(), *telegram.values()] for argument in sys.argv)
command = sys.argv[-1]
marker = Path(os.environ['DRAGONTOOLS_TEST_MARKER'])
def python_arguments(text, needle, depth=0):
    if depth > 6:
        raise AssertionError('Missing fixture Python command')
    try:
        parts = shlex.split(text)
    except ValueError:
        return None
    for index, item in enumerate(parts):
        if item == 'python3' and parts[index + 1:index + 4] == ['-I', '-B', '-c'] and needle in parts[index + 4]:
            return parts[index:]
    for item in parts:
        if item != text and needle in item:
            found = python_arguments(item, needle, depth + 1)
            if found is not None:
                return found
    return None
metrics = {"status": "success", "data": {"resultType": "vector", "result": [
    {"metric": {"__name__": "vm_app_version"}, "value": [1, "1"]}]}}
if "Pinned Grafana credential operations" in command:
    assert json.load(sys.stdin) == expected
    # Alias mode wraps the fixed Python command in a privileged shell selection.
    args = python_arguments(command, "Pinned Grafana credential operations")
    mode = args[-1].removesuffix(";")
    assert mode in ("bootstrap", "reconcile", "verify", "logs_verify")
    with marker.open('a') as output: output.write('stdin ' + mode + ' verified\\n')
    if mode == "logs_verify" and os.environ.get("DRAGONTOOLS_LOGS_FAIL"):
        print("REDACTION-SENTINEL remote query stderr", file=sys.stderr)
        print(expected["password"])
        sys.exit(86)
    sys.stdout.write('unchanged')
elif 'Dedicated protected Telegram file transport' in command:
    args = python_arguments(command, 'Dedicated protected Telegram file transport')
    mode = args[-1].removesuffix(';')
    assert mode in ('install', 'verify')
    if mode == 'install':
        assert json.load(sys.stdin) == telegram
        with marker.open('a') as output: output.write('telegram stdin verified\\n')
    sys.stdout.write('unchanged')
elif 'Concrete Alertmanager API probes' in command:
    args = python_arguments(command, 'Concrete Alertmanager API probes')
    mode = args[-3]
    assert mode in ('check', 'health', 'notify')
    if mode == 'check':
        sys.stdout.write('enabled' if os.environ.get('DRAGONTOOLS_TELEGRAM_CONFIGURED') else 'disabled')
    elif mode == 'notify':
        assert os.environ.get('DRAGONTOOLS_ALLOW_NOTIFY') == '1'
        with marker.open('a') as output: output.write('notification accepted\\n')
elif 'source=base64.b64decode' in command:
    args = python_arguments(command, 'source=base64.b64decode')
    mode = args[6]
    assert mode in ('prepare', 'reconcile', 'finalize', 'managed', 'ready', 'stored', 'status')
    if mode == 'status':
        probes = json.loads(base64.b64decode(args[8]))
        sys.stdout.write(json.dumps(['unhealthy' if item['name'] == 'orders' else 'healthy' for item in probes]))
    elif mode in ('prepare', 'reconcile'):
        assert not os.environ.get('DRAGONTOOLS_ASSERT_READONLY')
        sys.stdout.write('unchanged')
    elif mode == 'finalize':
        assert not os.environ.get('DRAGONTOOLS_ASSERT_READONLY')
elif 'dragontools-blackbox-exporter-http_ready' in command:
    sys.stdout.write('Healthy')
elif 'dragontools-blackbox-exporter-provisioning_ready' in command:
    sys.stdout.write(blackbox_config)
elif 'dragontools-blackbox-exporter-storage_ready' in command:
    sys.stdout.write(blackbox_metrics)
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
        modes = ("bootstrap", "reconcile", "logs_verify") if command == "install" else ("verify", "logs_verify")
        assert marker.read_text() == "".join(f"stdin {mode} verified\n" for mode in modes)
        for number, component in enumerate(("VictoriaMetrics", "VictoriaLogs", "VictoriaTraces", "Grafana", "Blackbox exporter", "Alertmanager", "vmalert logs", "vmalert metrics"), 1):
            heading = f"[{number}/8] {component}"
            assert heading in result.stdout, result.stdout
            component_output = result.stdout.split(heading, 1)[1].split("[", 1)[0]
            assert "verifying..." in component_output and "healthy; no changes" in component_output
            assert component_output.index("verifying...") < component_output.index("healthy; no changes")
        assert "administrator credentials verified" in result.stdout
        assert "administrator credentials updated" not in result.stdout
        assert "Logs datasource health and query verified" in result.stdout
        assert "Logs plugin: health and authenticated query verified" in result.stdout
        for name in ("Metrics", "Logs", "Traces"):
            assert f"{name} datasource: provisioning and backend query verified" in result.stdout
        assert "authenticated query unchecked" not in result.stdout
        assert "No test notification sent." in result.stdout
        if command == "install":
            assert "No changes required." in result.stdout
            assert "checking VictoriaLogs datasource plugin..." in result.stdout
            assert "plugin current" in result.stdout and "datasources current" in result.stdout
        checked += 1

    # Unconfigured compatibility mode never resolves or sends credentials and
    # explicitly limits its evidence to provisioning/integrity/direct backends.
    for command in ("install", "verify"):
        marker.unlink(missing_ok=True)
        provider_marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), "monitoring", command, "--ssh-host", "monitoring"],
                                env=env, input="", capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (command, result.stdout, result.stderr)
        assert not marker.exists() and not provider_marker.exists()
        assert "Logs plugin query unchecked; configure administrator references to verify" in result.stdout
        assert "Logs plugin: authenticated query unchecked" in result.stdout
        assert "health and authenticated query verified" not in result.stdout
        assert "Logs datasource: provisioning and backend query verified" in result.stdout
        checked += 1

    # Probe configuration and Telegram references use the same regular command
    # model. Failed target telemetry is accepted by install; only explicit notify
    # sends a test alert. Verification uses remote protected files, not providers.
    station_env = dict(env, DRAGONTOOLS_TELEGRAM_CONFIGURED="1")
    for command in ("install", "verify", "install"):
        marker.unlink(missing_ok=True)
        provider_marker.unlink(missing_ok=True)
        command_env = dict(station_env, DRAGONTOOLS_ASSERT_READONLY="1") if command == "verify" else station_env
        result = subprocess.run([str(binary), "monitoring", command, "--config", str(station_config)],
                                env=command_env, input="", capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 0, output
        assert all(value not in output for value in dummy_values.values()), output
        assert "REDACTION-SENTINEL" not in output
        assert "VictoriaMetrics native scraper: 2 configured probes" in output
        assert "a down target is valid monitoring state" in output
        assert "No test notification sent." in output
        assert "notification accepted" not in marker.read_text()
        assert provider_marker.read_text() == "resolved\n" * (4 if command == "install" else 2)
        if command == "install":
            assert "No changes required." in output
            assert marker.read_text().endswith("telegram stdin verified\n")
        else:
            assert "telegram stdin" not in marker.read_text()
        checked += 1

    marker.unlink(missing_ok=True)
    provider_marker.unlink(missing_ok=True)
    result = subprocess.run([str(binary), "monitoring", "status", "--config", str(station_config)],
                            env=station_env, input="", capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "landing  healthy" in output and "orders  unhealthy" in output, output
    assert "recorded metrics; at most 90s old" in output
    assert not marker.exists() and not provider_marker.exists()
    assert "REDACTION-SENTINEL" not in output
    checked += 1

    result = subprocess.run([str(binary), "monitoring", "notify-test", "--config", str(station_config)],
                            env=dict(station_env, DRAGONTOOLS_ALLOW_NOTIFY="1"), input="", capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "Test alert accepted by Alertmanager." in output
    assert "acceptance does not prove delivery" in output
    assert marker.read_text() == "notification accepted\n"
    assert not provider_marker.exists(), "notify-test unnecessarily resolved secret references"
    assert all(value not in output for value in dummy_values.values()), output
    assert "REDACTION-SENTINEL" not in output
    checked += 1

    # Failure from the authenticated plugin query is a safe semantic failure,
    # without leaking commands, credentials, upstream response or stderr.
    marker.unlink(missing_ok=True)
    provider_marker.unlink(missing_ok=True)
    result = subprocess.run([str(binary), "monitoring", "verify", "--config", str(config)],
                            env=dict(env, DRAGONTOOLS_LOGS_FAIL="1"), input="",
                            capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert result.returncode == 1 and "GrafanaLogsQueryFailed" in output, output
    assert "Component: Grafana. Check: logs_datasource_ready." in output, output
    assert marker.read_text() == "stdin verify verified\nstdin logs_verify verified\n"
    assert "Logs datasource health and query verified" not in output
    assert "REDACTION-SENTINEL" not in output
    assert all(value not in output for value in dummy_credentials.values())
    assert "/api/ds/query" not in output
    checked += 1
print(f"PASS: {checked} CLI smoke checks")
