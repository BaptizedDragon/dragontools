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
    empty_repository = directory / "empty-repository"
    empty_repository.mkdir()

    def run_process(*args, **kwargs):
        # Never consume a developer's station.toml from the checkout running tests.
        kwargs["cwd"] = kwargs.get("cwd") or empty_repository
        return subprocess.run(*args, **kwargs)

    def local_run(args, code=0, expected=None, cwd=None):
        """Pipe stdin explicitly so no-argument/wizard checks cannot read the terminal."""
        global checked
        result = run_process([str(binary), *args], env=env, input="", cwd=cwd,
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
    # Station defaults use only this CWD; explicit config replaces, never merges it.
    station_repository = directory / "station-repository"
    station_repository.mkdir()
    implicit_station = station_repository / "station.toml"
    station_text = station_config.read_text() + '\n[station]\nhostname="monitoring.baptizeddragon.com"\n'
    implicit_station.write_text(station_text)
    implicit = local_run(["monitoring", "install", "--plan"], cwd=station_repository).stdout
    explicit = local_run(["monitoring", "install", "--config", str(implicit_station), "--plan"]).stdout
    assert implicit == explicit
    for value in ("SSH alias: monitoring", "hostname: monitoring.baptizeddragon.com",
                  "metrics ingress: :9443", "logs ingress: :9444"):
        assert value in implicit, implicit
    override = local_run(["monitoring", "install", "--plan", "--ssh-host", "emergency-monitor",
                          "--ingress-hostname", "alternate.example"], cwd=station_repository).stdout
    assert "SSH alias: emergency-monitor" in override and "hostname: alternate.example" in override
    assert "monitoring.baptizeddragon.com" not in override
    for command in ("install", "verify", "status", "notify-test"):
        local_run(["monitoring", command], 1, "StationConfigurationRequired")
        implicit_station.write_text('version=1\n[station]\nhostname="https://REDACTION-SENTINEL"\n')
        local_run(["monitoring", command], 1, "InvalidStationHostname", cwd=station_repository)
    # Invalid implicit config is ignored when an explicit file was selected.
    local_run(config_args, expected="No remote operations performed", cwd=station_repository)
    implicit_station.write_text(station_text)
    for command in ("apply", "app-verify", "app-status"):
        local_run(["monitoring", command], 1, "UnableToReadApplicationConfig", cwd=station_repository)
    child_repository = station_repository / "child"
    child_repository.mkdir()
    local_run(["monitoring", "install", "--plan"], 1, "StationConfigurationRequired", cwd=child_repository)
    local_run([*plan_args, "--ingress-hostname", "station.example"], cwd=child_repository)
    (child_repository / "monitoring.toml").write_text('version=1\n[connection]\nssh_host="monitoring"\n')
    local_run(["monitoring", "install", "--plan"], 1, "StationConfigurationRequired", cwd=child_repository)
    for bad in ("https://station.example", "station.example:9443", "station.example/path", "127.0.0.1"):
        implicit_station.write_text('version=1\n[connection]\nssh_host="monitoring"\n[station]\nhostname="' + bad + '"\n')
        local_run(["monitoring", "install", "--plan"], 1, "InvalidStationHostname", cwd=station_repository)
    implicit_station.write_text(station_text + '\n[ingress]\nhostname="different.example"\n')
    local_run(["monitoring", "install", "--plan"], 1, "ConflictingStationHostname", cwd=station_repository)
    implicit_station.write_text(station_text + '\n[ingress]\nhostname="monitoring.baptizeddragon.com"\n')
    local_run(["monitoring", "install", "--plan"], cwd=station_repository)
    implicit_station.write_text(station_text)
    # Application repository defaults are one local file, never station config or
    # secret resolution. Plans and invalid configs must never spawn SSH.
    app_repository = directory / "application-repository"
    app_repository.mkdir()
    for command in ("apply", "app-verify", "app-status"):
        local_run(["monitoring", command], 1, "UnableToReadApplicationConfig", cwd=app_repository)
        local_run(["monitoring", command, "--config", str(directory / "missing.toml")],
                  1, "UnableToReadApplicationConfig")
        local_run(["monitoring", command, "--config", str(directory / "missing.toml"), "--help"],
                  expected="./monitoring.toml")
        for flag, value in (("--ssh-host", "app"), ("--station", "monitoring"),
                            ("--service", "app.service"), ("--grafana-user-op", "op://v/i/f")):
            local_run(["monitoring", command, flag, value], 1, "FlagNotAllowed")
    for command in ("app-verify", "app-status"):
        local_run(["monitoring", command, "--plan"], 1, "FlagNotAllowed")
    app_config = app_repository / "monitoring.toml"
    example_app = Path("examples/doers-monitoring.toml").read_text()
    app_config.write_text(example_app)
    app_plan = "Application monitoring plan (local; SSH not attempted)."
    implicit_plan = local_run(["monitoring", "apply", "--plan"], expected=app_plan,
                              cwd=app_repository).stdout
    explicit_plan = local_run(["monitoring", "apply", "--config", str(app_config), "--plan"],
                              expected=app_plan).stdout
    assert implicit_plan == explicit_plan
    for item in ("doers", "production", "softwarelanding", "monitoring", "Vector", "vmagent",
                 "HighErrorRate", "web", "/etc/dragontools/apps/doers/",
                 "SSH alias: monitoring", "ingestion hostname: monitoring.baptizeddragon.com",
                 "https://monitoring.baptizeddragon.com:9443", "https://monitoring.baptizeddragon.com:9444",
                 "TCP 9445 is reserved and closed", "Traces: skipped (unsupported)"):
        assert item in implicit_plan, (item, implicit_plan)
    checked += 1
    hostname_line = 'hostname = "monitoring.baptizeddragon.com"'
    for replacement, failure in (
        ("", "MissingStationHostname"),
        ('hostnmae = "station.example"', "UnknownApplicationConfigKey"),
        ('hostname = "https://station.example"', "InvalidStationHostname"),
        ('hostname = "station.example:9443"', "InvalidStationHostname"),
        ('hostname = "station.example/path"', "InvalidStationHostname"),
        ('hostname = "station example"', "InvalidStationHostname"),
        ('hostname = "127.0.0.1"', "InvalidStationHostname"),
    ):
        app_config.write_text(example_app.replace(hostname_line, replacement))
        for command in ("apply", "app-verify", "app-status"):
            local_run(["monitoring", command, "--config", str(app_config)], 1, failure)
    app_config.write_text(example_app)
    for name, suffix, failure in (
        ("app-secret", "\n[telegram]\nbot_token='REDACTION-SENTINEL'\n", "UnknownApplicationConfigKey"),
        ("app-duplicate", "\n[application]\n", "DuplicateApplicationConfigKey"),
        ("app-traces", "\n[[service]]\nname='worker'\nsystemd='worker.service'\n[service.traces]\nenabled=true\n", "ApplicationTracesUnsupported"),
        ("app-custom-metrics", "\n[[alert]]\nname='Custom'\nsource='metrics'\nseverity='warning'\n", "ApplicationMetricsAlertsUnsupported"),
        ("app-public-metrics", "\n[[service]]\nname='worker'\nsystemd='worker.service'\n[service.metrics]\nurl='https://public.example/metrics'\n", "InvalidMetricsTargetUrl"),
    ):
        invalid = directory / f"{name}.toml"
        invalid.write_text(example_app + suffix)
        local_run(["monitoring", "apply", "--config", str(invalid), "--plan"], 1, failure)
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
    large_agent_selection = ["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--plan"]
    for index in range(64):
        large_agent_selection += ["--metrics-target", f"app{index}=http://127.0.0.1/" + "a" * 2000]
    local_run(large_agent_selection, 1, "AgentSelectionsTooLarge")
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
        (["monitoring", "install", "--ssh-host", "monitoring", "--plan"], 0, "Grafana: loopback:3000"),
        (config_args, 0, configured_credentials),
        (["monitoring", "install", "--config", str(station_config), "--plan"], 0, "External HTTP probes: 2 configured"),
        (["monitoring", "install", "--config", os.path.relpath(config, empty_repository), "--plan"], 0, configured_credentials),
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
          "--service", "one.service", "--service", "two.service"], 1, "StationRequired"),
        (["monitoring", "agents", "verify", "--host", "example.com"], 1, "StationRequired"),
        (["monitoring", "agents", "status", "--host", "example.com"], 1, "StationRequired"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring"], 1, "ServiceRequired"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "https://monitoring.example/", "--service", "app.service"], 1, "InvalidSshHost"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--service", "app.service"], 1, "DuplicateService"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "REDACTION-SENTINEL;id.service"], 1, "InvalidService"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--metrics-target", "app=http://REDACTION-SENTINEL/metrics"], 1, "InvalidMetricsTargetUrl"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--metrics-target", "app=http://127.0.0.1/a", "--metrics-target", "app=http://127.0.0.1/b"], 1, "DuplicateMetricsTargetName"),
        (["monitoring", "agents", "install", "--ssh-host", "application", "--station", "monitoring", "--service", "app.service", "--metrics-target", "app=http://127.0.0.1:16000/metrics", "--plan"], 0, "Agent installation plan"),
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
          "--station", "monitoring", "--service", "one.service", "--plan"], 0, "Agent installation plan"),
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

    # Storage/Grafana and four station services are implemented. Plans perform
    # no secret or network operations; agents are a separate implemented workflow.
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
    assert "Grafana Logs datasource" not in unavailable and "dashboards" not in unavailable
    assert "Logs plugin query requires administrator references" in grafana
    configured_plan = local_run(config_args).stdout
    assert "verify Logs plugin health and a bounded read-only LogsQL query through Grafana" in configured_plan
    assert "Logs plugin query requires administrator references" not in configured_plan
    for component in ("OTel", "firewall", "TLS"):
        assert component in unavailable, (component, unavailable)
    for component in ("vmalert", "Alertmanager", "Telegram"):
        assert component not in unavailable, (component, unavailable)
    for text in ("ten services", "loopback:9115", "loopback:9093", "logs loopback:8880", "metrics loopback:8881",
                 "ServiceProbeFailed", "probe_success == 0 for 2m", "reload without restart", "notify-test is a separate explicit command"):
        assert text in plan_output, (text, plan_output)
    assert "Host metric rules use verified Vector contracts; systemd-service state alerts remain deferred." in plan_output
    assert "Healthy unchanged services are not restarted" in plan_output, plan_output
    checked += 1

    help_paths = [
        ["host"], ["host", "install-oh-my-zsh"],
        ["monitoring"], ["monitoring", "apply"], ["monitoring", "app-verify"], ["monitoring", "app-status"],
        ["monitoring", "install"], ["monitoring", "verify"],
        ["monitoring", "status"], ["monitoring", "notify-test"], ["monitoring", "agents"],
        ["monitoring", "agents", "install"], ["monitoring", "agents", "verify"],
        ["monitoring", "agents", "status"], ["monitoring", "firewall"],
        ["completion"], ["wizard"],
    ]
    help_output = {}
    for path in help_paths:
        result = local_run([*path, "--help"], expected="Usage:")
        help_output[tuple(path)] = result.stdout
    for command in ("apply", "app-verify", "app-status"):
        app_help = help_output[("monitoring", command)]
        assert "./monitoring.toml" in app_help and "--config PATH" in app_help
        assert "  --ssh-host" not in app_help and "  --host" not in app_help
        assert "  --grafana-user-op" not in app_help
        assert ("  --plan" in app_help) == (command == "apply")
    checked += 3
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
    assert all(flag in agents_help for flag in ("--service", "--station", "--ssh-host", "--metrics-target"))
    assert "Verify/status may omit selections" in agents_help
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
        syntax = run_process([shell_binary, "-n", str(script)], env=env,
                                input="", capture_output=True, text=True, timeout=15)
        assert syntax.returncode == 0, (shell, syntax.stderr)
        checked += 1

    bash = shutil.which("bash")
    if bash:
        def bash_complete(words):
            result = run_process(
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
        assert {"--ssh-host", "--station", "--service", "--metrics-target"} <= bash_complete(["dragontool", "monitoring", "agents", "install", "--"])
        assert {"apply", "app-verify", "app-status"} <= bash_complete(["dragontool", "monitoring", ""])
        assert bash_complete(["dragontool", "monitoring", "apply", "--"]) == {"--config", "--plan", "--help"}
        assert bash_complete(["dragontool", "monitoring", "app-verify", "--"]) == {"--config", "--help"}
        assert str(app_config) in bash_complete(["dragontool", "monitoring", "apply", "--config", str(app_repository / "monitoring")])
        checked += 4
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
        checked += 18
    else:
        print("SKIP: Bash completion behavior (shell not installed)")

    zsh = shutil.which("zsh")
    if zsh:
        def zsh_candidates(words):
            # Capture the candidates handed to Zsh's native UI. No terminal is needed.
            result = run_process(
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
        assert {"--ssh-host", "--station", "--service", "--metrics-target"} <= zsh_candidates(["dragontool", "monitoring", "agents", "install", "--"])
        assert zsh_candidates(["dragontool", "monitoring", "install", "--tls", ""]) == {"manual", "cloudflare"}
        assert {"apply", "app-verify", "app-status"} <= zsh_candidates(["dragontool", "monitoring", ""])
        assert zsh_candidates(["dragontool", "monitoring", "apply", "--"]) == {"--config", "--plan", "--help"}
        assert zsh_candidates(["dragontool", "monitoring", "app-status", "--"]) == {"--config", "--help"}
        assert zsh_candidates(["dragontool", "monitoring", "apply", "--config", ""]) == {"NATIVE_PATH_COMPLETION"}
        checked += 4
        verify_flags = zsh_candidates(["dragontool", "monitoring", "verify", "--"])
        assert {"--host", "--ssh-host"} <= verify_flags and "--tls" not in verify_flags and "--plan" not in verify_flags
        assert {"--config", "--grafana-user-op", "--grafana-password-op"} <= verify_flags
        assert zsh_candidates(["dragontool", "monitoring", "install", "--identity", ""]) == {"NATIVE_PATH_COMPLETION"}
        assert zsh_candidates(["dragontool", "monitoring", "verify", "--config", ""]) == {"NATIVE_PATH_COMPLETION"}
        checked += 12
    else:
        print("SKIP: Zsh completion behavior (shell not installed)")

    fish = shutil.which("fish")
    if fish:
        def fish_complete(command):
            result = run_process(
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
        assert {"--ssh-host", "--station", "--service", "--metrics-target"} <= fish_complete("dragontool monitoring agents install --")
        assert fish_complete("dragontool monitoring install --tls ") == {"manual", "cloudflare"}
        assert {"apply", "app-verify", "app-status"} <= fish_complete("dragontool monitoring ")
        assert fish_complete("dragontool monitoring apply --") == {"--config", "--plan", "--help"}
        assert fish_complete("dragontool monitoring app-verify --") == {"--config", "--help"}
        assert str(app_config) in fish_complete(f"dragontool monitoring apply --config {app_repository}/monitoring")
        checked += 4
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
        checked += 18
    else:
        print("SKIP: Fish completion behavior (shell not installed)")

    # Every supported remote workflow reaches the transport and fails safely
    # under fake SSH; this is dispatch coverage, not a successful VM deployment.
    for command in ("install", "verify", "status"):
        for connection in (["--host", "example.com"], ["--ssh-host", "monitoring"]):
            marker.unlink(missing_ok=True)
            result = run_process([str(binary), "monitoring", command, *connection],
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
    status = run_process([str(binary), "monitoring", "status", "--config", str(config)],
                            env=env, input="", capture_output=True, text=True, timeout=15)
    assert marker.exists() and status.returncode == 1, (status.stdout, status.stderr)
    assert "Failed at status;" in status.stdout, status.stdout
    assert not provider_marker.exists(), "Status resolved configured Grafana credentials"
    assert "REDACTION-SENTINEL" not in status.stdout + status.stderr
    checked += 1

    # Successful status performs ten service-state queries plus a stored-probe
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
    status = run_process([str(binary), "monitoring", "status", "--config", str(config)],
                            env=env, input="", capture_output=True, text=True, timeout=15)
    assert status.returncode == 0, (status.stdout, status.stderr)
    assert marker.read_text() == "status\n" * 10 + "probes\n"
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
        result = run_process([str(binary), "monitoring", command, "--config", str(config)],
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
            result = run_process([str(binary), "monitoring", command, "--config", str(config)],
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
        result = run_process([str(binary), "monitoring", command, "--config", str(config)],
                                env=without_op, input="", capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == 1 and "GrafanaUsernameResolutionFailed" in output, output
        assert not marker.exists() and not provider_marker.exists(), "Missing op reached SSH or a provider"
        assert "REDACTION-SENTINEL" not in output, output
        checked += 1

    for connection in (["--ssh-host", "monitoring"],
                       ["--host", "example.com", "--user", "root"]):
        marker.unlink(missing_ok=True)
        result = run_process([str(binary), "host", "install-oh-my-zsh", *connection],
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
  *'dt-helper-inspect'*) printf unchanged;;
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
        result = run_process([str(binary), "monitoring", "verify", *connection],
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
                  + f"telegram_template = {Path('src/monitoring/telegram.tmpl').read_bytes()!r}\n"
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
if "dt-helper-inspect" in command:
    print("unchanged", end="")
elif "Pinned Grafana credential operations" in command:
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
elif 'DragonTools public Telegram template transport' in command:
    args = python_arguments(command, 'DragonTools public Telegram template transport')
    mode = args[-1].removesuffix(';')
    assert mode in ('install', 'verify')
    assert sys.stdin.buffer.read() == telegram_template
    assert 'define "dragontools.telegram.message"' not in command
    if mode == 'install':
        assert not os.environ.get('DRAGONTOOLS_ASSERT_READONLY')
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
elif 'def managed_account(spec)' in command:
    args = python_arguments(command, 'def managed_account(spec)')
    failure = os.environ.get('DRAGONTOOLS_INGRESS_FAIL')
    caddy_runtime = args[5] == 'active' and json.loads(args[6].removesuffix(';'))['kind'] == 'caddy'
    tls_probe = 'Read-only station health:' in command
    if (args[5] == failure or (caddy_runtime and
            ((failure == 'caddy_listener' and not tls_probe) or (failure == 'caddy_tls' and tls_probe)))):
        print('REDACTION-SENTINEL private material', file=sys.stderr)
        print('REDACTION-SENTINEL remote command')
        sys.exit(1)
elif 'dragontool-agent' in command and '--stdin' in command:
    request = json.load(sys.stdin)
    assert request['action'] in ('station-ensure', 'station-verify')
    assert len(request['args']) == 1
    if request['action'] == 'station-ensure':
        assert not os.environ.get('DRAGONTOOLS_ASSERT_READONLY')
        if os.environ.get('DRAGONTOOLS_FRESH_STATION') and not request['args'][0]:
            sys.exit(90)
    sys.stdout.write('unchanged')
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
        result = run_process([str(binary), "monitoring", command, "--config", str(config)],
                                env=env, input="", capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (command, result.stdout, result.stderr)
        output = result.stdout + result.stderr
        assert all(value not in output for value in dummy_credentials.values()), output
        assert "REDACTION-SENTINEL" not in output, output
        assert provider_marker.read_text() == "resolved\nresolved\n"
        modes = ("bootstrap", "reconcile", "logs_verify") if command == "install" else ("verify", "logs_verify")
        assert marker.read_text() == "".join(f"stdin {mode} verified\n" for mode in modes)
        for number, component in enumerate(("VictoriaMetrics", "VictoriaLogs", "VictoriaTraces", "Grafana", "Blackbox exporter", "Alertmanager", "vmalert logs", "vmalert metrics", "Ingress authorization", "Caddy mTLS ingress"), 1):
            heading = f"[{number}/10] {component}"
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
        result = run_process([str(binary), "monitoring", command, "--ssh-host", "monitoring"],
                                env=env, input="", capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (command, result.stdout, result.stderr)
        assert not marker.exists() and not provider_marker.exists()
        assert "Logs plugin query unchecked; configure administrator references to verify" in result.stdout
        assert "Logs plugin: authenticated query unchecked" in result.stdout
        assert "health and authenticated query verified" not in result.stdout
        assert "Logs datasource: provisioning and backend query verified" in result.stdout
        checked += 1

    for check in ('managed_account', 'managed_unit', 'managed_helper', 'managed_directories',
                  'managed_registry', 'managed_server_state', 'managed_systemd_properties',
                  'caddy_account', 'caddy_binary', 'caddy_unit', 'caddy_systemd_properties',
                  'caddy_config', 'caddy_credentials', 'caddy_directories', 'caddy_listener', 'caddy_tls'):
        result = run_process([str(binary), 'monitoring', 'install', '--ssh-host', 'monitoring'],
                             env=dict(env, DRAGONTOOLS_INGRESS_FAIL=check), input='',
                             capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 1, output
        component = 'Caddy mTLS ingress' if check.startswith('caddy_') else 'Ingress authorization'
        assert f'Component: {component}. Check: {check}.' in result.stdout, output
        assert 'REDACTION-SENTINEL' not in output, output
        checked += 1

    # Probe configuration and Telegram references use the same regular command
    # model. Failed target telemetry is accepted by install; only explicit notify
    # sends a test alert. Verification uses remote protected files, not providers.
    station_env = dict(env, DRAGONTOOLS_TELEGRAM_CONFIGURED="1")
    for command in ("install", "verify", "install"):
        marker.unlink(missing_ok=True)
        provider_marker.unlink(missing_ok=True)
        command_env = dict(station_env, DRAGONTOOLS_ASSERT_READONLY="1") if command == "verify" else station_env
        result = run_process([str(binary), "monitoring", command, "--config", str(station_config)],
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
    result = run_process([str(binary), "monitoring", "status", "--config", str(station_config)],
                            env=station_env, input="", capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "landing  healthy" in output and "orders  unhealthy" in output, output
    assert "recorded metrics; at most 90s old" in output
    assert not marker.exists() and not provider_marker.exists()
    assert "REDACTION-SENTINEL" not in output
    checked += 1

    result = run_process([str(binary), "monitoring", "notify-test", "--config", str(station_config)],
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
    result = run_process([str(binary), "monitoring", "verify", "--config", str(config)],
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

    # Fresh station identity is explicit. Reusing a saved identity is allowed;
    # an absent one produces a safe actionable station error, never alias inference.
    for flags, expected in (([], 1), (["--ingress-hostname", "station.example"], 0)):
        result = run_process([str(binary), "monitoring", "install", "--ssh-host", "management-alias", *flags],
                                env=dict(env, DRAGONTOOLS_FRESH_STATION="1"), input="", capture_output=True, text=True, timeout=30)
        assert result.returncode == expected, result.stdout + result.stderr
        if expected:
            assert 'Check: ingress_hostname_required.' in result.stdout
            assert 'Fresh station ingress requires --ingress-hostname' in result.stdout
            assert 'Detail: ingress_hostname_required' in result.stdout
        else:
            assert 'zero registered clients is valid' in result.stdout
        checked += 1

    # Drive actual apply/SSH/stdin/error rendering through station ensure only.
    # No remote commands execute and no keys or credentials are generated here.
    app_config.write_text('''version = 1
[application]
name = "diagnostics"
environment = "test"
[target]
ssh_host = "application-fixture"
[station]
ssh_host = "station-fixture"
hostname = "station.example"
[[service]]
name = "web"
systemd = "web.service"
''')
    ssh.write_text(f"#!{sys.executable}\n" + r'''
import base64, json, os, re, sys, zlib
from pathlib import Path
command = sys.argv[-1]
if 'zlib.decompress' in command:
    encoded = max(re.findall(r'[A-Za-z0-9+/]{100,}={0,2}', command), key=len)
    command = zlib.decompress(base64.b64decode(encoded)).decode()
marker = Path(os.environ['DRAGONTOOLS_TEST_MARKER'])
if 'dragontool-agent' in command and '--stdin' in command:
    assert '--diagnostics' in command
    request = json.load(sys.stdin)
    if request['action'] == 'station-verify':
        print('unchanged')
        sys.exit(0)
    assert request['action'] == 'ensure'
    marker.write_text('station_ensure\n')
    diagnostic = os.environ['DRAGONTOOLS_AGENT_DIAGNOSTIC']
    sys.stderr.write('PRIVATE KEY REDACTION-SENTINEL' * 20000 if diagnostic == 'oversized' else diagnostic)
    sys.stdout.write('REDACTION-SENTINEL private output')
    sys.exit(int(os.environ['DRAGONTOOLS_AGENT_CODE']))
elif '/etc/machine-id' in command:
    sys.stdout.write('0123456789abcdef0123456789abcdef\n')
elif '/etc/os-release' in command:
    sys.stdout.write('ubuntu\n24.04\nx86_64\n')
elif 'Authoritative per-application signal manifests.' in command:
    print('unchanged')
    print(json.dumps({'version': 1, 'host': 'dt-0123456789abcdef0123456789abcdef',
        'station': 'station.example', 'services': [], 'metrics_targets': [],
        'applications': [{'name': 'diagnostics', 'environment': 'test',
            'services': [{'name': 'web', 'systemd': 'web.service'}]}]}))
else:
    sys.stdout.write('unchanged')
''')
    safe_message = 'AgentStage: ca_key_generation\nAgentError: CryptoKeyGenerationFailed\n'
    for code, detail, diagnostic, accepted in (
        (86, 'agent_internal_error', safe_message, True),
        (86, 'agent_internal_error', '', False),
        (86, 'agent_internal_error', safe_message + 'PRIVATE KEY REDACTION-SENTINEL', False),
        (86, 'agent_internal_error', 'oversized', False),
        (87, 'ca_maintenance', '', False),
        (88, 'client_identity_inconsistent', '', False),
        (89, 'registry_permissions', '', False),
    ):
        marker.unlink(missing_ok=True)
        provider_marker.unlink(missing_ok=True)
        result = run_process([str(binary), 'monitoring', 'apply', '--config', str(app_config)],
            env=dict(env, DRAGONTOOLS_AGENT_CODE=str(code), DRAGONTOOLS_AGENT_DIAGNOSTIC=diagnostic),
            input='', capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 1, output
        assert 'Application monitoring failed. Component: ingestion.' in output, output
        assert 'Stage: station_ensure\n' in output and f'Detail: {detail}\n' in output, output
        assert ('AgentError: CryptoKeyGenerationFailed' in output) == accepted, output
        assert ('AgentStage: ca_key_generation' in output) == accepted, output
        assert 'PRIVATE KEY' not in output and 'REDACTION-SENTINEL' not in output, output
        assert marker.read_text() == 'station_ensure\n'
        assert not provider_marker.exists()
        checked += 1

subprocess.run([sys.executable, '-I', '-B', str(Path(__file__).with_name('ui_tunnel_test.py'))],
               env=dict(os.environ, TOOL=str(binary)), check=True)
print(f"PASS: {checked} CLI smoke checks plus UI tunnel lifecycle suite")
