"""Local UI tunnel lifecycle with fake SSH/opener and real loopback sockets.

Never connects to a station, resolves secrets or opens a real browser.
"""
import json
import errno
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get('TOOL', ROOT / 'zig-out/bin/dragontool')).resolve()
UI_ENDPOINTS = [
    ('metrics', 8428, '/vmui/'), ('logs', 9428, '/select/vmui/'),
    ('traces', 10428, '/select/vmui/'), ('grafana', 3000, '/'),
    ('alerts', 8881, '/vmalert/groups'), ('log-alerts', 8880, '/vmalert/groups'),
    ('alertmanager', 9093, '/'),
]
FAKE_SSH = r'''
import json, os, signal, socket, sys, threading
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ['UI_FIXTURE'])
with (root / 'calls').open('a') as f: f.write(json.dumps(args) + '\n')
assert 'StrictHostKeyChecking=yes' in args and 'BatchMode=yes' in args
assert args[-2:] == ['--', os.environ.get('UI_ALIAS', 'station-alias')]
control = args[args.index('-S') + 1]
mode = os.environ.get('UI_MODE', '')
if '-N' in args:
    assert '-F' not in args
    assert 'ClearAllForwardings=yes' in args
    assert 'ControlMaster=yes' in args and 'ControlPersist=no' in args
    assert 'ForkAfterAuthentication=no' in args and 'GatewayPorts=no' in args
    assert '-L' not in args and '-f' not in args
    (root / 'master.pid').write_text(str(os.getpid()))
    (root / 'control').write_text(control)
    if mode == 'auth-failure':
        print('PRIVATE-STDERR-SENTINEL', file=sys.stderr); sys.exit(255)
    if mode == 'ignore-term': signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if mode == 'authentication-wait': threading.Event().wait(30)
    assert Path(control).parent.stat().st_mode & 0o777 == 0o700
    channel = socket.socket(socket.AF_UNIX)
    channel.bind(control); channel.listen()
    listeners = []
    def serve(server, path):
        attempts = 0
        while True:
            peer, _ = server.accept()
            with peer:
                request = b''
                while b'\r\n\r\n' not in request:
                    chunk = peer.recv(1024)
                    if not chunk: break
                    request += chunk
                assert request.startswith(('GET ' + path + ' HTTP/1.1\r\n').encode())
                attempts += 1
                (root / 'http-attempts').write_text(str(attempts))
                if mode == 'http-stall': threading.Event().wait(30)
                if mode == 'readiness-gate' and not (root / 'allow-ready').exists():
                    peer.sendall(b'HTTP/1.1 503 Unavailable\r\nConnection: close\r\n\r\n'); continue
                status = b'503 Unavailable' if mode == 'unavailable' or (mode == 'delayed-ready' and attempts <= 2) else b'200 OK'
                if status == b'200 OK': (root / 'http-ready').touch()
                peer.sendall(b'HTTP/1.1 ' + status + b'\r\nContent-Length: 15\r\nConnection: close\r\n\r\n<h1>VMUI</h1>\n')
    raced = False
    while True:
        peer, _ = channel.accept()
        with peer:
            request = json.loads(peer.recv(2048))
            if request['operation'] == 'check':
                peer.sendall(b'0'); continue
            local, port, remote, remote_port = request['forward'].split(':')
            assert local == remote == '127.0.0.1'
            path = {'8428':'/vmui/', '9428':'/select/vmui/', '10428':'/select/vmui/', '3000':'/', '8881':'/vmalert/groups', '8880':'/vmalert/groups', '9093':'/'}[remote_port]
            if mode == 'forward-denied': peer.sendall(b'1'); continue
            server = socket.socket()
            try: server.bind((local, int(port))); server.listen()
            except OSError:
                server.close(); peer.sendall(b'1'); continue
            listeners.append(server)
            if mode == 'bind-race' and not raced:
                raced = True; peer.sendall(b'1'); continue
            threading.Thread(target=serve, args=(server,path), daemon=True).start()
            (root / 'forward').write_text(request['forward'])
            peer.sendall(b'0')
else:
    assert args[:2] == ['-F', '/dev/null']
    operation = args[args.index('-O') + 1]
    request = dict(operation=operation)
    if operation == 'forward': request['forward'] = args[args.index('-L') + 1]
    try:
        with socket.socket(socket.AF_UNIX) as peer:
            peer.connect(control); peer.sendall(json.dumps(request).encode())
            code = int(peer.recv(10))
    except OSError: code = 1
    if code: print('PRIVATE-STDERR-SENTINEL', file=sys.stderr)
    sys.exit(code)
'''


class Tunnel(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dragontools-ui-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'station.toml'
        self.config.write_text('version=1\n[connection]\nssh_host="station-alias"\n[station]\nhostname="tls-must-not-select-ssh.example"\n[grafana]\nusername={op="op://Fixture/Grafana/user"}\npassword={op="op://Fixture/Grafana/password"}\n[telegram]\nbot_token={op="op://Fixture/Telegram/token"}\nchat_id={op="op://Fixture/Telegram/chat"}\n')
        (self.root / 'monitoring.toml').write_text('invalid application config must never load')
        self.script('ssh', FAKE_SSH)
        for program in ('open', 'xdg-open'):
            self.script(program, "import os,sys,threading\nfrom pathlib import Path\np=Path(os.environ['UI_FIXTURE'])\nassert (p/'http-ready').exists(), 'browser launched before HTTP readiness'\nassert len(sys.argv) == 2\n(p/'opened').write_text(sys.argv[1])\n(p/'opener.pid').write_text(str(os.getpid()))\nif os.environ.get('UI_OPEN_STALL'): threading.Event().wait(30)\nsys.exit(int(os.environ.get('UI_OPEN_EXIT','0')))\n")
        self.script('op', "from pathlib import Path\nimport os\nPath(os.environ['UI_FIXTURE'],'secret-provider-called').touch()\nraise SystemExit(99)\n")
        self.env = dict(os.environ, PATH=str(self.root), UI_FIXTURE=str(self.root))
        self.output = self.root / 'stdout'
        self.errors = self.root / 'stderr'

    def script(self, name, source):
        path = self.root / name
        path.write_text('#!' + sys.executable + '\n' + source)
        path.chmod(0o755)

    def start(self, ui='logs', extra=(), **env):
        out, err = self.output.open('w'), self.errors.open('w')
        self.addCleanup(out.close); self.addCleanup(err.close)
        process = subprocess.Popen([str(TOOL), 'monitoring', 'ui', ui, *extra], cwd=self.root,
                                   env=dict(self.env, **env), stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        def cleanup():
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            # A controller panic must not leak this test's fake SSH listeners.
            marker = self.root / 'master.pid'
            if marker.exists():
                pid = int(marker.read_text())
                command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
                if str(self.root / 'ssh') in command:
                    try: os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            control = self.root / 'control'
            if control.exists():
                parent = Path(control.read_text()).parent
                if parent.name.startswith('dragontools-ui-'): shutil.rmtree(parent, ignore_errors=True)
        self.addCleanup(cleanup)
        return process

    def wait_for(self, condition, process, budget=8):
        deadline = time.monotonic() + budget
        while time.monotonic() < deadline:
            if condition(): return
            if process.poll() is not None: break
            time.sleep(0.02)
        self.fail('Fixture readiness failed: ' + self.output.read_text() + self.errors.read_text())

    def ready(self, process):
        self.wait_for(lambda: 'Press Ctrl-C to close.' in self.output.read_text(), process)
        text = self.output.read_text()
        self.assertNotIn('PRIVATE-STDERR-SENTINEL', text + self.errors.read_text())
        self.assertNotIn('tls-must-not-select-ssh', text)
        self.assertNotIn('op://', text)
        self.assertFalse((self.root / 'secret-provider-called').exists())
        return next(line.strip() for line in text.splitlines() if line.strip().startswith('http://'))

    def closed(self, process):
        process.send_signal(signal.SIGINT)
        self.assertEqual(process.wait(timeout=4), 0)
        self.assertIn('Tunnel closed.', self.output.read_text())
        self.assert_clean()

    def assert_clean(self):
        self.assertEqual(self.errors.read_text().count('PRIVATE-STDERR-SENTINEL'), 0)
        if (self.root / 'control').exists():
            self.assertFalse(Path((self.root / 'control').read_text()).parent.exists())
        if (self.root / 'master.pid').exists():
            with self.assertRaises(ProcessLookupError): os.kill(int((self.root / 'master.pid').read_text()), 0)
        if (self.root / 'opener.pid').exists():
            with self.assertRaises(ProcessLookupError): os.kill(int((self.root / 'opener.pid').read_text()), 0)
        self.assertFalse((self.root / 'secret-provider-called').exists())

    def test_each_ui_configures_the_right_path_and_loopback_forward_then_ctrl_c_cleans_up(self):
        for ui, port, path in UI_ENDPOINTS:
            with self.subTest(ui=ui):
                process = self.start(ui)
                url = self.ready(process)
                self.assertTrue(url.startswith('http://127.0.0.1:') and url.endswith(path))
                fields = (self.root / 'forward').read_text().split(':')
                self.assertEqual(fields[0::2], ['127.0.0.1','127.0.0.1'])
                self.assertEqual(int(fields[3]), port)
                self.assertIn(':' + fields[1] + path, url)
                self.assertEqual((self.root / 'opened').read_text(), url)
                self.assertIn('Browser opened.', self.output.read_text())
                self.closed(process)

    def test_occupied_preferred_port_is_preserved(self):
        for ui, port in [('logs', 9428), ('alerts', 8881), ('log-alerts', 8880), ('alertmanager', 9093)]:
            with self.subTest(ui=ui), socket.socket() as existing:
                try: existing.bind(('127.0.0.1', port)); existing.listen()
                except OSError as error: self.assertEqual(error.errno, errno.EADDRINUSE)
                process = self.start(ui)
                self.assertNotIn(':' + str(port) + '/', self.ready(process))
                self.closed(process)
                # Either this fixture or a preexisting user listener still owns it.
                with socket.socket() as probe:
                    with self.assertRaises(OSError) as error: probe.bind(('127.0.0.1', port))
                    self.assertEqual(error.exception.errno, errno.EADDRINUSE)

    def test_bind_race_retries_only_after_failed_forward_acknowledgement(self):
        process = self.start(UI_MODE='bind-race')
        self.ready(process)
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        forwards = [args for args in calls if '-L' in args]
        self.assertEqual(len(forwards), 2)
        self.assertNotEqual(forwards[0][forwards[0].index('-L')+1], forwards[1][forwards[1].index('-L')+1])
        self.closed(process)

    def test_explicit_open_remains_supported(self):
        process = self.start(extra=['--open'])
        url = self.ready(process)
        self.wait_for(lambda: (self.root / 'opened').exists(), process)
        self.assertEqual((self.root / 'opened').read_text(), url)
        self.closed(process)

    def test_no_open_keeps_ready_tunnel_without_launching_browser(self):
        for ui, _, _ in UI_ENDPOINTS:
            with self.subTest(ui=ui):
                process = self.start(ui, extra=['--no-open'])
                self.ready(process)
                self.assertFalse((self.root / 'opened').exists())
                self.assertNotIn('Browser opened.', self.output.read_text())
                self.closed(process)

    def test_alerting_ui_unavailable_reports_component_and_cleans_up(self):
        for ui, title in [('alerts', 'Metrics/probe/host alert evaluation'), ('log-alerts', 'Log alert evaluation'), ('alertmanager', 'Alertmanager')]:
            with self.subTest(ui=ui):
                process = self.start(ui, UI_MODE='unavailable')
                self.assertEqual(process.wait(timeout=14), 1)
                self.assertIn(title + ' is not available on the monitoring station.', self.errors.read_text())
                self.assertIn('dragontool monitoring verify', self.errors.read_text())
                self.assertFalse((self.root / 'opened').exists())
                self.assert_clean()

    def test_alerting_help_is_local_and_describes_evaluation_versus_routing(self):
        for ui, description in [('alerts', 'metrics/probe/host alert rule evaluation'), ('log-alerts', 'log alert rule evaluation'), ('alertmanager', 'Alertmanager active alerts, silences and notification routing')]:
            with self.subTest(ui=ui):
                process = self.start(ui, extra=['--help'])
                self.assertEqual(process.wait(timeout=4), 0)
                text = self.output.read_text()
                self.assertIn(description, text)
                self.assertIn('--no-open', text)
                self.assertIn('pending/firing state', text)
                self.assertIn('grouping and notification routing', text)
                self.assertFalse((self.root / 'calls').exists())
                self.assertFalse((self.root / 'opened').exists())

    def test_readiness_retries_before_opening_browser(self):
        process = self.start(UI_MODE='readiness-gate')
        self.wait_for(lambda: (self.root / 'http-attempts').exists() and int((self.root / 'http-attempts').read_text() or '0') >= 3, process)
        self.assertFalse((self.root / 'opened').exists())
        self.assertNotIn('Open:', self.output.read_text())
        (self.root / 'allow-ready').touch()
        url = self.ready(process)
        self.assertEqual((self.root / 'opened').read_text(), url)
        self.closed(process)

    def test_health_fails_twice_then_succeeds_without_browser(self):
        process = self.start(extra=['--no-open'], UI_MODE='delayed-ready')
        self.ready(process)
        self.assertEqual((self.root / 'http-attempts').read_text(), '3')
        self.assertFalse((self.root / 'opened').exists())
        self.closed(process)

    def test_missing_or_failing_opener_keeps_tunnel_alive(self):
        for missing in (False, True):
            if missing:
                (self.root / 'open').unlink(); (self.root / 'xdg-open').unlink()
            process = self.start(UI_OPEN_EXIT='1')
            url = self.ready(process)
            self.wait_for(lambda: 'Tunnel remains active.' in self.output.read_text(), process)
            self.assertIsNone(process.poll())
            self.assertIn('Open manually:\n  ' + url, self.output.read_text())
            self.closed(process)

    def test_remote_ui_unavailable_reports_semantic_error_and_cleans_up(self):
        process = self.start(UI_MODE='unavailable')
        started = time.monotonic()
        self.assertEqual(process.wait(timeout=14), 1)
        self.assertGreaterEqual(time.monotonic() - started, 9)
        self.assertGreater(int((self.root / 'http-attempts').read_text()), 2)
        self.assertFalse((self.root / 'opened').exists())
        output = self.output.read_text() + self.errors.read_text()
        self.assertIn('VictoriaLogs VMUI is not available on the monitoring station.', output)
        self.assertIn('dragontool monitoring verify', output)
        self.assertIn('UiUnavailable', output)
        self.assertNotIn('Open:', output)
        self.assert_clean()

    def test_unresponsive_http_is_bounded_and_cleans_up(self):
        process = self.start(UI_MODE='http-stall')
        self.assertEqual(process.wait(timeout=14), 1)
        self.assertIn('UiUnavailable', self.errors.read_text())
        self.assertFalse((self.root / 'opened').exists())
        self.assert_clean()

    def test_authentication_and_forwarding_failures_are_redacted(self):
        for mode, error in [('auth-failure','UiSshUnavailable'),('forward-denied','UiForwardFailed')]:
            process = self.start(UI_MODE=mode)
            self.assertEqual(process.wait(timeout=8), 1)
            self.assertIn(error, self.errors.read_text())
            self.assertNotIn('Open:', self.output.read_text())
            self.assert_clean()

    def test_ctrl_c_during_authentication_and_term_ignoring_child(self):
        for mode in ('authentication-wait', 'ignore-term'):
            (self.root / 'master.pid').unlink(missing_ok=True)
            process = self.start(UI_MODE=mode)
            if mode == 'ignore-term': self.ready(process)
            else: self.wait_for(lambda: (self.root / 'master.pid').exists(), process)
            if mode == 'ignore-term':
                process.send_signal(signal.SIGINT)
                time.sleep(0.05) # Exercise another Ctrl-C while child cleanup is in progress.
            self.closed(process)

    def test_ctrl_c_during_readiness_and_browser_launch(self):
        for during_browser in (False, True):
            process = self.start(UI_MODE='' if during_browser else 'http-stall', UI_OPEN_STALL='1' if during_browser else '')
            marker = 'opener.pid' if during_browser else 'http-attempts'
            self.wait_for(lambda: (self.root / marker).exists(), process)
            self.closed(process)

    def test_ssh_exit_during_readiness_is_reported_without_opening_browser(self):
        process = self.start(UI_MODE='http-stall')
        self.wait_for(lambda: (self.root / 'http-attempts').exists(), process)
        os.kill(int((self.root / 'master.pid').read_text()), signal.SIGTERM)
        self.assertEqual(process.wait(timeout=4), 1)
        self.assertIn('UiTunnelClosed', self.errors.read_text())
        self.assertFalse((self.root / 'opened').exists())
        self.assert_clean()

    def test_dead_tunnel_is_reported_without_raw_stderr(self):
        process = self.start()
        self.ready(process)
        os.kill(int((self.root / 'master.pid').read_text()), signal.SIGTERM)
        self.assertEqual(process.wait(timeout=4), 1)
        self.assertIn('UiTunnelClosed', self.errors.read_text())
        self.assert_clean()

    def test_missing_invalid_and_explicit_config_before_ssh(self):
        original = self.config.read_text()
        self.config.unlink()
        for extra, expected in [([], 'StationConfigurationRequired'), (['--config','missing.toml'], 'UnableToReadMonitoringConfig')]:
            process = self.start(extra=extra)
            self.assertEqual(process.wait(timeout=4), 1)
            self.assertIn(expected, self.errors.read_text())
            self.assertFalse((self.root / 'calls').exists())
        self.config.write_text('invalid-default')
        alternate = self.root / 'another station.toml'
        alternate.write_text(original)
        process = self.start(extra=['--config', str(alternate), '--ssh-host', 'override-alias'], UI_ALIAS='override-alias')
        self.ready(process)
        self.closed(process)

    def test_help_and_rejected_options_are_local(self):
        for extra, code in [(['--help'],0), (['--remote-port','9999'],1), (['--ssh-host','bad; touch sentinel'],1), (['--open','--open'],1), (['--no-open','--no-open'],1), (['--open','--no-open'],1), (['--no-open','--open'],1)]:
            process = self.start(extra=extra)
            self.assertEqual(process.wait(timeout=4), code)
            self.assertFalse((self.root / 'calls').exists())
            self.assertFalse((self.root / 'opened').exists())


if __name__ == '__main__': unittest.main()
