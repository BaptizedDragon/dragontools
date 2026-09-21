"""Offline HTML snapshots; optional --amtool exercises the pinned native renderer."""
import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / 'src/monitoring/telegram.tmpl'
AMTOOL = None
if '--amtool' in sys.argv:
    index = sys.argv.index('--amtool')
    AMTOOL = Path(sys.argv[index + 1]).resolve()
    del sys.argv[index:index + 2]
    assert hashlib.sha256(AMTOOL.read_bytes()).hexdigest() in (ROOT / 'src/components/alertmanager.zig').read_text()


def alert(name='ServiceProbeFailed', state='firing', **labels):
    return dict(Status=state, Labels=dict(alertname=name, severity='critical', application='doers', **labels), Annotations={})


def data(*alerts):
    return dict(Status='firing' if any(a['Status'] == 'firing' for a in alerts) else 'resolved', Alerts=alerts)


class Message(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='dragontools-telegram-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.binary = cls.directory / 'render'
        if AMTOOL:
            # Check the production renderer's YAML together with the actual
            # template. Redirect only fixture paths; no credentials or network.
            source = (ROOT / 'src/monitoring/alertmanager.zig').read_text().split('pub const enabled_config =', 1)[1].split('\n;', 1)[0]
            config = '\n'.join(line.split('\\\\', 1)[1] for line in source.splitlines() if '\\\\' in line)
            config = config.replace('/etc/dragontools/alertmanager/templates/telegram.tmpl', str(TEMPLATE))
            for name, value in [('telegram-bot-token', '123456:fixture-not-a-real-token'), ('telegram-chat-id', '-123456')]:
                path = cls.directory / name
                path.write_text(value)
                path.chmod(0o400)
                config = config.replace('/etc/dragontools/alertmanager/secrets/' + name, str(path))
            path = cls.directory / 'alertmanager.yml'
            path.write_text(config)
            subprocess.run([str(AMTOOL), 'check-config', str(path)], check=True, capture_output=True)
        else:
            subprocess.run(['go', 'build', '-o', str(cls.binary), str(ROOT / 'tests/telegram_render.go')], check=True,
                           env=dict(os.environ, GO111MODULE='off', GOCACHE=os.environ.get('GOCACHE', '/tmp/dragontools-go-cache')),
                           capture_output=True)

    def render(self, *alerts):
        value = data(*alerts)
        if AMTOOL:
            path = self.directory / 'data.json'
            path.write_text(json.dumps(value))
            result = subprocess.run([str(AMTOOL), 'template', 'render', '--template.glob', str(TEMPLATE),
                                     '--template.text', '{{ template "dragontools.telegram.message" . }}',
                                     '--template.type=html', '--template.data', str(path)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stderr, '')
            return result.stdout
        result = subprocess.run([str(self.binary), str(TEMPLATE)], input=json.dumps([value]), capture_output=True, text=True, check=True)
        self.assertEqual(result.stderr, '')
        return json.loads(result.stdout)[0]

    def test_probe_firing_and_recovery_snapshots(self):
        a = alert(probe='web', target='https://doers.business/healthz')
        self.assertEqual(self.render(a), '🚨 <b>Doers unavailable</b>\n\nProbe: <code>web</code>\nTarget: https://doers.business/healthz\nStatus: HTTP health check failing\nSeverity: <b>critical</b>')
        a['Status'] = 'resolved'
        self.assertEqual(self.render(a), '✅ <b>Doers recovered</b>\n\nProbe: <code>web</code>\nTarget: https://doers.business/healthz\nStatus: healthy again')

    def test_error_burst_snapshots(self):
        a = alert('ErrorBurst', service='doers'); a['Labels']['severity'] = 'warning'
        self.assertEqual(self.render(a), '⚠️ <b>Doers error burst</b>\n\nError events exceeded the configured threshold.\n\nService: <code>doers</code>\nSeverity: <b>warning</b>')
        a['Status'] = 'resolved'
        self.assertEqual(self.render(a), '✅ <b>Doers error rate recovered</b>\n\nService: <code>doers</code>\nStatus: error rate returned below threshold')

    def test_critical_event_snapshots(self):
        a = alert('CriticalLogEvent', service='doers')
        self.assertEqual(self.render(a), '🚨 <b>Doers critical event</b>\n\nA critical or fatal application event was detected.\n\nService: <code>doers</code>\nSeverity: <b>critical</b>')
        a['Status'] = 'resolved'
        self.assertEqual(self.render(a), '✅ <b>Doers critical alert cleared</b>\n\nService: <code>doers</code>')

    def test_host_examples_use_available_host_and_mountpoint_only(self):
        for name, title in [('DiskWarning', 'disk'), ('DiskCritical', 'disk'), ('InodesCritical', 'inode'), ('CPUHigh', 'CPU'), ('MemoryPressure', 'memory')]:
            with self.subTest(name=name):
                a = alert(name, host='softwarelanding'); del a['Labels']['application']
                a['Labels']['severity'] = 'warning'
                if name in ('DiskWarning', 'DiskCritical', 'InodesCritical'): a['Labels']['mountpoint'] = '/'
                fields = '\n\nHost: <code>softwarelanding</code>' + ('\nFilesystem: <code>/</code>' if 'mountpoint' in a['Labels'] else '')
                self.assertEqual(self.render(a), f'⚠️ <b>softwarelanding {title} usage high</b>{fields}\nStatus: usage above threshold\nSeverity: <b>warning</b>')
                a['Status'] = 'resolved'
                self.assertEqual(self.render(a), f'✅ <b>softwarelanding {title} usage recovered</b>{fields}\nStatus: back below threshold')
        for name, title, detail, recovered, cleared in [
            ('SecurityUpdatesPending', 'security updates pending', 'Review pending security updates on this host.', 'security update alert cleared', 'security update condition cleared'),
            ('RebootRequired', 'reboot required', 'Schedule a host maintenance reboot.', 'reboot alert cleared', 'reboot request cleared'),
        ]:
            a = alert(name, host='softwarelanding'); del a['Labels']['application']
            a['Labels']['severity'] = 'warning'
            self.assertEqual(self.render(a), f'⚠️ <b>softwarelanding {title}</b>\n\n{detail}\nSeverity: <b>warning</b>')
            a['Status'] = 'resolved'
            self.assertEqual(self.render(a), f'✅ <b>softwarelanding {recovered}</b>\n\nStatus: {cleared}')

    def test_host_event_warning_clear_and_package_context(self):
        a = alert('HostRebootRequired', host='softwarelanding')
        a['Labels']['severity']='warning'
        a['Annotations']=dict(kernel='7.0.0-30-generic', uptime_human='12d 4h', packages_text='• linux-image-7.0\n• libc6\n+ 7 more\n')
        text=self.render(a)
        self.assertTrue(text.startswith('⚠️ <b>softwarelanding reboot required</b>'))
        for value in ('• libc6', '+ 7 more', 'Running kernel: <code>7.0.0-30-generic</code>', 'Uptime: 12d 4h', 'Severity: <b>warning</b>'): self.assertIn(value,html.unescape(text))
        a['Annotations']['packages_text']=''
        self.assertIn('Packages: unavailable',self.render(a))
        a['Labels']['alertname']='HostRebootRequirementCleared'; a['Labels']['severity']='info'
        a['Annotations'].update(kernel='7.0.0-31-generic',uptime_human='2m')
        text=self.render(a)
        self.assertTrue(text.startswith('✅ <b>softwarelanding reboot requirement cleared</b>'))
        self.assertIn('Host restarted or the reboot-required condition was cleared.',text)
        self.assertIn('Current kernel: <code>7.0.0-31-generic</code>\nUptime: 2m',text)
        self.assertNotIn('Packages:',text); self.assertNotIn('Severity:',text)

    def test_host_event_html_and_bounds(self):
        a=alert('HostRebootRequired',host='<>&' * 100); a['Labels']['severity']='warning'
        a['Annotations']=dict(kernel='<>&' * 100,uptime_human='3d 4h',packages_text='• libc6\n' * 1000)
        text=self.render(a)
        self.assertIn('&lt;&gt;&amp;',text); self.assertNotIn('<>&',text)
        self.assertLess(len(text),4096)

    def test_identity_fallback_order_and_camel_case(self):
        a = alert(service='worker', probe='web', host='server')
        for key, expected in [('application', 'Doers'), ('service', 'Worker'), ('probe', 'web'), ('host', 'server'), ('alertname', 'ServiceProbeFailed')]:
            self.assertIn('<b>' + expected + ' unavailable</b>', self.render(a))
            del a['Labels'][key]
        a = alert(); a['Labels']['application'] = 'OrderFlow'
        self.assertIn('<b>OrderFlow unavailable</b>', self.render(a))

    def test_severity_and_resolved_symbols(self):
        for severity, icon in [('critical', '🚨'), ('warning', '⚠️'), ('info', 'ℹ️'), ('unknown', 'ℹ️'), ('', 'ℹ️')]:
            a = alert(); a['Labels']['severity'] = severity
            self.assertTrue(self.render(a).startswith(icon + ' '))
            a['Status'] = 'resolved'
            self.assertTrue(self.render(a).startswith('✅ '))
        a = alert(); del a['Labels']['severity']
        self.assertTrue(self.render(a).startswith('ℹ️ '))
        self.assertNotIn('Severity:', self.render(a))

    def test_html_and_control_character_escaping_without_label_or_log_dumps(self):
        a = alert(probe='<>&', target='https://example.test/<x>&y', service='<>&')
        a['Labels']['application'] = '<>&"\''
        for key in ('job', 'instance', 'source', 'managed_by', 'environment', 'fingerprint', 'internal_id'):
            a['Labels'][key] = 'PRIVATE-SENTINEL'
        a['Annotations'] = dict(summary='PRIVATE-SENTINEL', description='raw log PRIVATE-SENTINEL')
        text = self.render(a)
        for escaped in ('&lt;', '&gt;', '&amp;', '&#34;', '&#39;'): self.assertIn(escaped, text)
        self.assertNotIn('PRIVATE-SENTINEL', text)
        self.assertNotIn('ServiceProbeFailed', text)
        self.assertNotIn('<x>', text)
        a['Labels']['application'] = 'a\nb\tc\x00d'
        self.assertIn('A b c d unavailable', self.render(a))

    def test_grouped_and_mixed_state_snapshots(self):
        values = [alert(), alert(), alert()]
        values[1]['Labels']['application'] = 'second'; values[2]['Labels']['application'] = 'OrderFlow'
        self.assertEqual(self.render(*values), '🚨 <b>3 critical alerts</b>\n\n• Doers unavailable\n• Second unavailable\n• OrderFlow unavailable')
        for a in values: a['Status'] = 'resolved'
        self.assertEqual(self.render(*values), '✅ <b>3 alerts resolved</b>\n\n• Doers recovered\n• Second recovered\n• OrderFlow recovered')
        values[0]['Status'] = 'firing'
        self.assertEqual(self.render(*values), '🚨 <b>3 alerts (1 firing, 2 resolved)</b>\n\n• Doers unavailable\n• Second recovered\n• OrderFlow recovered')
        for a in values:
            a['Status'] = 'firing'; a['Labels']['severity'] = 'warning'
        self.assertTrue(self.render(*values).startswith('⚠️ <b>3 warning alerts</b>'))
        for a in values: a['Labels'].pop('severity')
        self.assertTrue(self.render(*values).startswith('ℹ️ <b>3 alerts</b>'))

    def test_group_cap_and_size_bound_even_after_html_expansion(self):
        values = [alert() for _ in range(14)]
        for a in values: a['Labels']['application'] = '"' * 1000
        text = self.render(*values)
        self.assertEqual(text.count('• '), 10)
        self.assertTrue(text.endswith('+ 4 more'))
        self.assertLess(len(text), 3800)
        self.assertEqual(html.unescape(text).count('…'), 10)

    def test_long_unicode_fields_remain_valid_html_and_bounded(self):
        for name in ('ServiceProbeFailed', 'ErrorBurst', 'CriticalLogEvent', 'DiskWarning', 'CustomAlert'):
            a = alert(name, probe='&' * 1000, target='&' * 1000, service='&' * 1000, host='&' * 1000, mountpoint='&' * 1000)
            a['Labels']['application'] = '🦊' * 1000
            a['Labels']['severity'] = '"' * 1000
            a['Annotations'] = dict(summary='x' * 50000, description='x' * 50000)
            text = self.render(a)
            self.assertLess(len(text), 3800)
            self.assertNotIn('�', text)
            stack = []
            class Parser(HTMLParser):
                def handle_starttag(self, tag, attrs):
                    assert tag in ('b', 'code') and not attrs
                    stack.append(tag)
                def handle_endtag(self, tag): assert stack.pop() == tag
            Parser().feed(text)
            self.assertEqual(stack, [])

    def test_resolved_duration_requires_valid_start_and_end(self):
        a = alert(state='resolved')
        a.update(StartsAt='2026-09-19T12:00:00Z', EndsAt='2026-09-19T13:15:00Z')
        self.assertTrue(self.render(a).endswith('Duration: 1h15m0s'))
        for start, end in [('0001-01-01T00:00:00Z', a['EndsAt']), (a['StartsAt'], '0001-01-01T00:00:00Z'), (a['StartsAt'], a['StartsAt']), (a['EndsAt'], a['StartsAt'])]:
            value = dict(a, StartsAt=start, EndsAt=end)
            self.assertNotIn('Duration:', self.render(value))
        a['Status'] = 'firing'
        self.assertNotIn('Duration:', self.render(a))

    def test_notification_test_and_completion_are_not_an_outage(self):
        a = alert('DragonToolsNotificationTest')
        self.assertEqual(self.render(a), 'ℹ️ <b>DragonTools notification test</b>\n\nMonitoring station notification test.')
        a['Status'] = 'resolved'
        self.assertEqual(self.render(a), '✅ <b>DragonTools notification test completed</b>\n\nThe test alert has expired.')

    def test_unknown_alerts_are_safe_and_recover_without_failure_annotations(self):
        a = alert('CustomAlert'); a['Annotations']['description'] = 'PRIVATE log content'
        self.assertEqual(self.render(a), '🚨 <b>Doers alert active</b>\n\nStatus: alert condition active\nSeverity: <b>critical</b>')
        a['Status'] = 'resolved'
        self.assertEqual(self.render(a), '✅ <b>Doers alert cleared</b>\n\nStatus: alert condition cleared')
        # Application-owned rules may use custom names with these fixed sources.
        for source, firing, recovered in [('blackbox', 'unavailable', 'recovered'), ('victorialogs', 'log threshold reached', 'log alert cleared')]:
            a['Labels']['source'] = source
            for state, title in [('firing', firing), ('resolved', recovered)]:
                a['Status'] = state
                rendered = self.render(a)
                self.assertIn('<b>Doers ' + title + '</b>', rendered)
                self.assertNotIn('PRIVATE', rendered)
        self.assertEqual(self.render(), 'ℹ️ <b>No alerts</b>')


if __name__ == '__main__':
    unittest.main()
